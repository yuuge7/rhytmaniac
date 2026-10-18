import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/import/osu_beatmap.dart';
import '../core/import/osu_convert.dart';
import '../core/models/beatmap.dart';
import '../core/models/song.dart';
import '../core/util/ids.dart';
import '../platform/native_bridge.dart';
import 'analysis_worker.dart';
import 'library_repository.dart';

enum ImportStage {
  copying('Copying file'),
  reading('Reading tags'),
  decoding('Decoding audio'),
  analyzing('Finding beats'),
  saving('Building maps'),
  done('Ready'),
  failed('Failed');

  const ImportStage(this.label);
  final String label;
}

class ImportProgress {
  const ImportProgress(this.stage, this.progress, {this.title, this.error, this.songId});
  final ImportStage stage;

  /// 0..1 overall.
  final double progress;
  final String? title;
  final String? error;
  final String? songId;
}

class DuplicateSongException implements Exception {
  DuplicateSongException(this.existing);
  final Song existing;
  @override
  String toString() => '"${existing.title}" is already in your library';
}

/// Media types accepted by the importer.
const importMimeTypes = ['video/mp4', 'audio/*', 'video/*'];

/// What an osu! beatmap set import produced.
class OszImportResult {
  const OszImportResult({required this.song, required this.added, required this.skipped, required this.existingSong});
  final Song song;

  /// Converted difficulties.
  final List<Beatmap> added;

  /// Difficulties left out, and why.
  final List<OsuSkip> skipped;

  /// The song was already in the library; only difficulties were added.
  final bool existingSong;
}

/// Import → extract audio → analyze (isolate) → generate default maps.
class ImportService {
  ImportService(this.repo, {NativeBridge? bridge}) : _bridge = bridge ?? NativeBridge.instance;

  final LibraryRepository repo;
  final NativeBridge _bridge;

  /// Content hash: SHA-1 of the size plus the first and last MiB. Fast on big
  /// videos and stable across devices.
  static Future<String> contentHash(File f) async {
    final len = await f.length();
    final raf = await f.open();
    try {
      const chunk = 1 << 20;
      final head = await raf.read(chunk);
      var tail = <int>[];
      if (len > chunk * 2) {
        await raf.setPosition(len - chunk);
        tail = await raf.read(chunk);
      }
      return sha1.convert([...'$len:'.codeUnits, ...head, ...tail]).toString();
    } finally {
      await raf.close();
    }
  }

  Future<Song> importPicked(PickedFile picked, void Function(ImportProgress) onProgress) async {
    final id = newId();
    final ext = p.extension(picked.name).toLowerCase();
    final sourceName = 'source${ext.isEmpty ? '.mp4' : ext}';
    final dir = Directory(repo.paths.songDir(id));
    final fallbackTitle = p.basenameWithoutExtension(picked.name);
    try {
      await dir.create(recursive: true);
      onProgress(ImportProgress(ImportStage.copying, 0.02, title: fallbackTitle));
      final dest = repo.paths.sourceFile(id, sourceName);
      await _bridge.copyUri(picked.uri, dest);
      return await _process(id, dest, sourceName, fallbackTitle, onProgress);
    } catch (e) {
      if (await dir.exists()) await dir.delete(recursive: true);
      rethrow;
    }
  }

  Future<Song> _process(
    String id,
    String sourcePath,
    String sourceName,
    String fallbackTitle,
    void Function(ImportProgress) onProgress, {
    String? title,
    String? artist,
    String? cover,
    double? previewMs,
    String? hash,
  }) async {
    hash ??= await contentHash(File(sourcePath));
    final dup = await repo.songByHash(hash);
    if (dup != null) throw DuplicateSongException(dup);
    final titleOverride = title, artistOverride = artist;

    onProgress(ImportProgress(ImportStage.reading, 0.06, title: fallbackTitle));
    final coverPath = repo.paths.coverFile(id, 'cover.jpg');
    var meta = const MediaMetadata();
    try {
      meta = await _bridge.readMetadata(sourcePath, coverPath);
    } on PlatformException {
      // Tags are optional.
    }
    title = titleOverride ?? meta.title ?? _prettify(fallbackTitle);
    artist = artistOverride ?? meta.artist ?? 'Unknown artist';

    final pcmPath = p.join(repo.paths.songDir(id), 'pcm.raw');
    onProgress(ImportProgress(ImportStage.decoding, 0.08, title: title));
    final decoded = await _bridge.decodeAudio(
      sourcePath,
      pcmPath,
      onProgress: (v) => onProgress(ImportProgress(ImportStage.decoding, 0.08 + v * 0.32, title: title)),
    );
    if (decoded.samples < 22050) throw Exception('The audio track is too short to map');

    final settings = await repo.settings();
    final result = await runAnalysisJob(
      AnalysisJob(
        audioPath: pcmPath,
        isWav: false,
        songId: id,
        title: title,
        artist: artist,
        lanes: settings.defaultLanes,
        seed: newSeed(),
      ),
      onProgress: (v) => onProgress(ImportProgress(
        v < 0.8 ? ImportStage.analyzing : ImportStage.saving,
        0.4 + v * 0.55,
        title: title,
      )),
    );
    try {
      await File(pcmPath).delete();
    } catch (_) {}

    return _save(
      id: id,
      title: title,
      artist: artist,
      sourceName: sourceName,
      hash: hash,
      hasVideo: meta.hasVideo,
      cover: cover ?? (meta.hasCover ? 'cover.jpg' : null),
      result: result,
      onProgress: onProgress,
      previewMs: previewMs,
    );
  }

  /// Imports an osu! beatmap set (`.osz`): the song comes in like any other
  /// import (analysis and generated difficulties included) and every
  /// osu!standard and osu!mania difficulty is converted alongside. If the
  /// song is already in the library, only the difficulties are added.
  Future<OszImportResult> importOsz(PickedFile picked, void Function(ImportProgress) onProgress) async {
    final label = p.basenameWithoutExtension(picked.name);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    // The archive helper picks its decoder from the extension.
    final zipPath = p.join(repo.paths.tmpDir, 'incoming_$stamp.zip');
    final dir = Directory(p.join(repo.paths.tmpDir, 'osz_$stamp'));
    try {
      onProgress(ImportProgress(ImportStage.copying, 0.02, title: label));
      await Directory(repo.paths.tmpDir).create(recursive: true);
      await _bridge.copyUri(picked.uri, zipPath);
      try {
        await extractFileToDisk(zipPath, dir.path);
      } catch (_) {
        throw const FormatException('This file is not an osu! beatmap set (.osz).');
      }
      return await importOszFolder(dir, onProgress, label: label);
    } finally {
      try {
        await File(zipPath).delete();
      } catch (_) {}
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Imports an extracted beatmap set folder.
  Future<OszImportResult> importOszFolder(Directory dir, void Function(ImportProgress) onProgress, {String label = 'osu! beatmap'}) async {
    onProgress(ImportProgress(ImportStage.reading, 0.05, title: label));
    final files = await dir.list(recursive: true).where((e) => e is File).cast<File>().toList();
    File? find(String name) {
      final want = name.toLowerCase().replaceAll('\\', '/');
      for (final f in files) {
        final rel = p.relative(f.path, from: dir.path).toLowerCase().replaceAll('\\', '/');
        if (rel == want || p.basename(rel) == want) return f;
      }
      return null;
    }

    final parsed = <OsuBeatmap>[];
    for (final f in files.where((f) => f.path.toLowerCase().endsWith('.osu'))) {
      try {
        parsed.add(parseOsu(await f.readAsString()));
      } catch (_) {
        // A broken difficulty file doesn't stop the others.
      }
    }
    if (parsed.isEmpty) throw const FormatException('No osu! difficulties (.osu files) in this beatmap set.');

    // The audio most difficulties use.
    final counts = <String, int>{};
    for (final m in parsed) {
      counts[m.audioFilename] = (counts[m.audioFilename] ?? 0) + 1;
    }
    final audioName = (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    final audio = find(audioName);
    if (audio == null) throw FormatException('The beatmap set is missing its audio file ($audioName).');
    final first = parsed.firstWhere((m) => m.audioFilename == audioName);
    final title = first.displayTitle.trim().isEmpty ? label : first.displayTitle.trim();
    final artist = first.displayArtist.trim().isEmpty ? 'Unknown artist' : first.displayArtist.trim();

    final hash = await contentHash(audio);
    var song = await repo.songByHash(hash);
    final existing = song != null;
    if (song == null) {
      final id = newId();
      final songDir = Directory(repo.paths.songDir(id));
      try {
        await songDir.create(recursive: true);
        final ext = p.extension(audio.path).toLowerCase();
        final sourceName = 'source${ext.isEmpty ? '.mp3' : ext}';
        final dest = repo.paths.sourceFile(id, sourceName);
        await audio.copy(dest);
        String? cover;
        final bg = first.background == null ? null : find(first.background!);
        if (bg != null) {
          final bext = p.extension(bg.path).toLowerCase();
          if (const ['.jpg', '.jpeg', '.png', '.webp'].contains(bext)) {
            cover = 'cover$bext';
            await bg.copy(repo.paths.coverFile(id, cover));
          }
        }
        song = await _process(
          id,
          dest,
          sourceName,
          title,
          onProgress,
          title: title,
          artist: artist,
          cover: cover,
          previewMs: first.previewTime >= 0 ? first.previewTime.toDouble() : null,
          hash: hash,
        );
      } catch (e) {
        if (await songDir.exists()) await songDir.delete(recursive: true);
        rethrow;
      }
    }

    final added = <Beatmap>[];
    final skipped = <OsuSkip>[];
    // Difficulties imported from osu! before, by mode and name.
    final existingNames = (await repo.beatmaps())
        .where((b) => b.songId == song!.id && b.origin == 'osu')
        .map((b) => '${b.mode.name}|${b.name}')
        .toSet();
    for (final m in parsed) {
      if (m.audioFilename != audioName) {
        skipped.add(OsuSkip(m.version, 'uses a different audio file'));
        continue;
      }
      final map = convertOsu(m, songId: song.id, id: newId());
      if (map == null) {
        skipped.add(OsuSkip(m.version, '${osuModeName(m.mode)} maps can’t be played here yet'));
        continue;
      }
      if (map.objectCount == 0) {
        skipped.add(OsuSkip(m.version, 'has no objects'));
        continue;
      }
      if (!existingNames.add('${map.mode.name}|${map.name}')) {
        skipped.add(OsuSkip(m.version, 'already imported'));
        continue;
      }
      await repo.saveBeatmap(map);
      added.add(map);
    }
    onProgress(ImportProgress(ImportStage.done, 1, title: title, songId: song.id));
    return OszImportResult(song: song, added: added, skipped: skipped, existingSong: existing);
  }

  Future<Song> _save({
    required String id,
    required String title,
    required String artist,
    required String sourceName,
    required String hash,
    required bool hasVideo,
    required String? cover,
    required AnalysisJobResult result,
    required void Function(ImportProgress) onProgress,
    bool isDemo = false,
    double? previewMs,
  }) async {
    await repo.saveAnalysis(id, result.analysis);
    for (final m in result.beatmaps) {
      await repo.saveBeatmap(m);
    }
    final song = Song(
      id: id,
      title: title,
      artist: artist,
      durationMs: result.analysis.durationMs,
      bpm: result.analysis.bpm,
      addedAt: DateTime.now(),
      sourceFile: sourceName,
      contentHash: hash,
      hasVideo: hasVideo,
      coverFile: cover,
      status: AnalysisStatus.ready,
      fingerprint: result.analysis.fingerprint(64),
      isDemo: isDemo,
      previewMs: previewMs,
    );
    await repo.putSong(song);
    onProgress(ImportProgress(ImportStage.done, 1, title: title, songId: id));
    return song;
  }

  /// Installs the bundled demo song (an original synthesized track).
  Future<Song> installDemo(void Function(ImportProgress) onProgress) async {
    const title = 'Ember Drift';
    final id = newId();
    final dir = Directory(repo.paths.songDir(id));
    await dir.create(recursive: true);
    try {
      onProgress(const ImportProgress(ImportStage.copying, 0.05, title: title));
      final data = await rootBundle.load('assets/audio/ember_drift.wav');
      final dest = repo.paths.sourceFile(id, 'source.wav');
      await File(dest).writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      final hash = await contentHash(File(dest));
      final existing = await repo.songByHash(hash);
      if (existing != null) {
        await dir.delete(recursive: true);
        onProgress(ImportProgress(ImportStage.done, 1, title: title, songId: existing.id));
        return existing;
      }
      final settings = await repo.settings();
      final result = await runAnalysisJob(
        AnalysisJob(
          audioPath: dest,
          isWav: true,
          songId: id,
          title: title,
          artist: 'Rhytmaniac',
          lanes: settings.defaultLanes,
          seed: 20261016,
        ),
        onProgress: (v) => onProgress(ImportProgress(ImportStage.analyzing, 0.1 + v * 0.85, title: title)),
      );
      return await _save(
        id: id,
        title: title,
        artist: 'Rhytmaniac',
        sourceName: 'source.wav',
        hash: hash,
        hasVideo: false,
        cover: null,
        result: result,
        onProgress: onProgress,
        isDemo: true,
      );
    } catch (e) {
      if (await dir.exists()) await dir.delete(recursive: true);
      rethrow;
    }
  }

  /// Re-decodes and re-analyzes a song (keeps its difficulties).
  Future<void> reanalyze(Song song, void Function(ImportProgress) onProgress) async {
    final source = repo.paths.sourceFile(song.id, song.sourceFile);
    final isWav = song.sourceFile.toLowerCase().endsWith('.wav') && song.isDemo;
    var audioPath = source;
    if (!isWav) {
      audioPath = p.join(repo.paths.songDir(song.id), 'pcm.raw');
      await _bridge.decodeAudio(
        source,
        audioPath,
        onProgress: (v) => onProgress(ImportProgress(ImportStage.decoding, v * 0.4, title: song.title)),
      );
    }
    final result = await runAnalysisJob(
      AnalysisJob(
        audioPath: audioPath,
        isWav: isWav,
        songId: song.id,
        title: song.title,
        artist: song.artist,
        lanes: 4,
        seed: 0,
        generateDefaults: false,
      ),
      onProgress: (v) => onProgress(ImportProgress(ImportStage.analyzing, 0.4 + v * 0.6, title: song.title)),
    );
    if (!isWav) {
      try {
        await File(audioPath).delete();
      } catch (_) {}
    }
    await repo.saveAnalysis(song.id, result.analysis);
    await repo.putSong(song.copyWith(bpm: result.analysis.bpm, fingerprint: result.analysis.fingerprint(64)));
    onProgress(ImportProgress(ImportStage.done, 1, title: song.title, songId: song.id));
  }

  static String _prettify(String name) {
    final s = name.replaceAll(RegExp(r'[_]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.isEmpty ? 'Untitled' : s;
  }
}
