import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../core/models/beatmap.dart';
import '../core/models/progress.dart';
import '../core/models/score.dart';
import '../core/models/song.dart';
import '../core/util/ids.dart';
import 'library_repository.dart';
import 'settings.dart';
import 'storage.dart';

class PackImportResult {
  const PackImportResult({this.songsAdded = 0, this.mapsAdded = 0, this.scoresAdded = 0, this.settingsApplied = false});
  final int songsAdded;
  final int mapsAdded;
  final int scoresAdded;
  final bool settingsApplied;
}

/// Zip-based sharing.
///
/// Song pack (`*.rhpack.zip`):
///
/// ```text
/// manifest.json            {formatVersion, type: "songpack", songs: [Song]}
/// songs/<id>/source.<ext>, cover.jpg, analysis.json, maps/<beatmapId>.json
/// ```
///
/// Profile (`*.rhprofile.zip`): manifest {type: "profile"}, profile.json with
/// player, portable settings, scores and per-song stats; optionally the full
/// library in the same layout as a song pack.
class PackService {
  PackService(this.repo);

  final LibraryRepository repo;
  static const formatVersion = 1;

  AppPaths get _paths => repo.paths;

  Future<String> _tmpZip(String name) async {
    await Directory(_paths.tmpDir).create(recursive: true);
    return p.join(_paths.tmpDir, name);
  }

  static String safeName(String s) {
    final cleaned = s.replaceAll(RegExp(r'[^\w\s\-]+'), '').trim().replaceAll(RegExp(r'\s+'), '_');
    return cleaned.isEmpty ? 'pack' : (cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned);
  }

  Future<void> _addSong(ZipFileEncoder zip, Song song) async {
    final dir = Directory(_paths.songDir(song.id));
    if (!await dir.exists()) return;
    await for (final e in dir.list(recursive: true)) {
      if (e is! File) continue;
      final rel = p.relative(e.path, from: dir.path).replaceAll('\\', '/');
      if (rel.endsWith('.tmp') || rel == 'pcm.raw') continue;
      // Media is already compressed; storing it saves time.
      final compress = rel.endsWith('.json');
      await zip.addFile(e, 'songs/${song.id}/$rel', compress ? 6 : 0);
    }
  }

  /// Writes a song pack to a temp file and returns its path.
  Future<String> exportSongs(List<Song> songs) async {
    final name = songs.length == 1 ? '${safeName(songs.first.title)}.rhpack.zip' : 'Rhytmaniac_${songs.length}_songs.rhpack.zip';
    final out = await _tmpZip(name);
    final zip = ZipFileEncoder()..create(out);
    zip.addArchiveFile(ArchiveFile.string(
      'manifest.json',
      jsonEncode({
        'formatVersion': formatVersion,
        'type': 'songpack',
        'app': 'Rhytmaniac',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'songs': songs.map((s) => s.toJson()).toList(),
      }),
    ));
    for (final s in songs) {
      await _addSong(zip, s);
    }
    await zip.close();
    return out;
  }

  Future<String> exportProfile({
    required PlayerProfile profile,
    required AppSettings settings,
    required List<ScoreRecord> scores,
    required List<Song> songs,
    required bool includeLibrary,
    Progress progress = const Progress(),
    Map<String, List<String>> collections = const {},
  }) async {
    final hashById = {for (final s in songs) s.id: s.contentHash};
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    final out = await _tmpZip('${safeName(profile.name)}_$stamp.rhprofile.zip');
    final zip = ZipFileEncoder()..create(out);
    zip.addArchiveFile(ArchiveFile.string(
      'manifest.json',
      jsonEncode({
        'formatVersion': formatVersion,
        'type': 'profile',
        'app': 'Rhytmaniac',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'includesLibrary': includeLibrary,
        'songs': includeLibrary ? songs.map((s) => s.toJson()).toList() : const [],
      }),
    ));
    zip.addArchiveFile(ArchiveFile.string(
      'profile.json',
      jsonEncode({
        'formatVersion': formatVersion,
        'player': profile.toJson(),
        'settings': settings.portableJson(),
        'scores': scores.map((s) => s.toJson()).toList(),
        'progress': progress.toJson(),
        // Songs are named by audio hash so collections survive new ids.
        'collections': {
          for (final e in collections.entries) e.key: [for (final id in e.value) if (hashById[id] != null) hashById[id]],
        },
        'songStats': songs
            .map((s) => {
                  'contentHash': s.contentHash,
                  'title': s.title,
                  'artist': s.artist,
                  'playCount': s.playCount,
                  'lastPlayedAt': s.lastPlayedAt?.toUtc().toIso8601String(),
                  'offsetMs': s.offsetMs,
                })
            .toList(),
      }),
    ));
    if (includeLibrary) {
      for (final s in songs) {
        await _addSong(zip, s);
      }
    }
    await zip.close();
    return out;
  }

  /// Extracts [zipPath] and returns the folder plus its parsed manifest.
  Future<(Directory, Map<String, dynamic>)> _extract(String zipPath) async {
    final dir = Directory(p.join(_paths.tmpDir, 'import_${newId()}'));
    await dir.create(recursive: true);
    var source = zipPath;
    if (!source.toLowerCase().endsWith('.zip')) {
      source = p.join(_paths.tmpDir, '${newId()}.zip');
      await File(zipPath).copy(source);
    }
    await extractFileToDisk(source, dir.path);
    final manifestFile = File(p.join(dir.path, 'manifest.json'));
    if (!await manifestFile.exists()) {
      throw const FormatException('This file is not a Rhytmaniac pack or profile');
    }
    final manifest = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    final v = manifest['formatVersion'] as int? ?? 1;
    if (v > formatVersion) throw const FormatException('This file was made by a newer version of Rhytmaniac');
    return (dir, manifest);
  }

  /// Imports songs from an extracted folder. Songs already present (same
  /// audio hash) only receive the difficulties they don't have yet.
  Future<(int songs, int maps)> _importSongs(Directory root, List<dynamic> songJson) async {
    var songsAdded = 0, mapsAdded = 0;
    final existingMaps = (await repo.beatmaps()).map((b) => b.id).toSet();
    for (final raw in songJson) {
      final incoming = Song.fromJson((raw as Map).cast<String, dynamic>());
      final src = Directory(p.join(root.path, 'songs', incoming.id));
      if (!await src.exists()) continue;
      final existing = await repo.songByHash(incoming.contentHash);
      final mapsDir = Directory(p.join(src.path, 'maps'));
      if (existing != null) {
        if (await mapsDir.exists()) {
          await for (final f in mapsDir.list()) {
            if (f is! File || !f.path.endsWith('.json')) continue;
            final map = Beatmap.fromJson(await readJsonFile(f.path));
            if (existingMaps.contains(map.id)) continue;
            final rebased = Beatmap.fromJson({...map.toJson(), 'songId': existing.id});
            await repo.saveBeatmap(rebased);
            mapsAdded++;
          }
        }
        continue;
      }
      // Keep the id unless it collides with a different local song.
      final id = (await repo.song(incoming.id)) == null ? incoming.id : newId();
      final dest = Directory(_paths.songDir(id));
      await _copyDir(src, dest);
      final song = Song.fromJson({...incoming.toJson(), 'id': id, 'addedAt': DateTime.now().toUtc().toIso8601String()});
      await repo.putSong(song);
      final destMaps = Directory(_paths.mapsDir(id));
      if (await destMaps.exists()) {
        await for (final f in destMaps.list()) {
          if (f is! File || !f.path.endsWith('.json')) continue;
          final map = Beatmap.fromJson(await readJsonFile(f.path));
          final fixed = map.songId == id ? map : Beatmap.fromJson({...map.toJson(), 'songId': id});
          await repo.saveBeatmap(fixed);
          mapsAdded++;
        }
      }
      songsAdded++;
    }
    return (songsAdded, mapsAdded);
  }

  Future<PackImportResult> importSongPack(String zipPath) async {
    final (dir, manifest) = await _extract(zipPath);
    try {
      if (manifest['type'] != 'songpack') {
        throw const FormatException('This is a profile file. Import it from the Profile tab.');
      }
      final (songs, maps) = await _importSongs(dir, manifest['songs'] as List? ?? const []);
      return PackImportResult(songsAdded: songs, mapsAdded: maps);
    } finally {
      await dir.delete(recursive: true);
    }
  }

  /// Merges a profile: scores (deduplicated), player name, portable settings,
  /// per-song play stats, and the bundled library if present.
  Future<PackImportResult> importProfile(String zipPath, {required AppSettings current}) async {
    final (dir, manifest) = await _extract(zipPath);
    try {
      if (manifest['type'] != 'profile') {
        throw const FormatException('This is a song pack. Import it from the Library tab.');
      }
      var songs = 0, maps = 0;
      if (manifest['includesLibrary'] == true) {
        (songs, maps) = await _importSongs(dir, manifest['songs'] as List? ?? const []);
      }
      final profileJson = await readJsonFile(p.join(dir.path, 'profile.json'));
      final player = PlayerProfile.fromJson((profileJson['player'] as Map?)?.cast<String, dynamic>());
      await repo.saveProfile(player);
      final settings = AppSettings.fromJson((profileJson['settings'] as Map?)?.cast<String, dynamic>(), base: current);
      await repo.saveSettings(settings);

      // Re-link scores to local songs by audio hash.
      final localByHash = {for (final s in await repo.songs()) s.contentHash: s};
      final scores = (profileJson['scores'] as List? ?? const []).map((raw) {
        final s = ScoreRecord.fromJson((raw as Map).cast<String, dynamic>());
        final local = localByHash[s.songHash];
        if (local == null || local.id == s.songId) return s;
        return ScoreRecord.fromJson({...s.toJson(), 'songId': local.id});
      });
      final added = await repo.addScoresIfMissing(scores);

      final incomingProgress = Progress.fromJson((profileJson['progress'] as Map?)?.cast<String, dynamic>());
      await repo.saveProgress((await repo.progress()).merge(incomingProgress));

      final collections = await repo.collections();
      ((profileJson['collections'] as Map?) ?? const {}).forEach((name, hashes) {
        final ids = [
          for (final h in (hashes as List))
            if (localByHash[h] != null) localByHash[h]!.id,
        ];
        collections[name as String] = {...?collections[name], ...ids}.toList();
      });
      await repo.saveCollections(collections);

      for (final raw in profileJson['songStats'] as List? ?? const []) {
        final st = (raw as Map).cast<String, dynamic>();
        final local = localByHash[st['contentHash']];
        if (local == null) continue;
        final plays = (st['playCount'] as num?)?.toInt() ?? 0;
        final last = DateTime.tryParse(st['lastPlayedAt'] as String? ?? '')?.toLocal();
        await repo.putSong(local.copyWith(
          playCount: plays > local.playCount ? plays : local.playCount,
          lastPlayedAt: (last != null && (local.lastPlayedAt == null || last.isAfter(local.lastPlayedAt!))) ? last : null,
          offsetMs: local.offsetMs == 0 ? (st['offsetMs'] as num?)?.toDouble() : null,
        ));
      }
      return PackImportResult(songsAdded: songs, mapsAdded: maps, scoresAdded: added, settingsApplied: true);
    } finally {
      await dir.delete(recursive: true);
    }
  }

  static Future<void> _copyDir(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final e in from.list(recursive: true)) {
      final rel = p.relative(e.path, from: from.path);
      final target = p.join(to.path, rel);
      if (e is Directory) {
        await Directory(target).create(recursive: true);
      } else if (e is File) {
        await File(target).parent.create(recursive: true);
        await e.copy(target);
      }
    }
  }
}
