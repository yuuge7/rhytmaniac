import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rhytmaniac/core/analysis/analyzer.dart';
import 'package:rhytmaniac/core/audio/pcm.dart';
import 'package:rhytmaniac/core/generator/beatmap_generator.dart';
import 'package:rhytmaniac/core/models/beatmap.dart';
import 'package:rhytmaniac/core/models/difficulty.dart';
import 'package:rhytmaniac/core/models/score.dart';
import 'package:rhytmaniac/core/models/song.dart';
import 'package:rhytmaniac/data/import_service.dart';
import 'package:rhytmaniac/data/library_repository.dart';
import 'package:rhytmaniac/data/pack_service.dart';
import 'package:rhytmaniac/data/settings.dart';
import 'package:rhytmaniac/data/storage.dart';

import '../core/analysis_test.dart' show clickTrack;

Future<LibraryRepository> makeRepo(Directory root) async {
  final paths = AppPaths(root.path);
  await paths.ensure();
  final db = await AppDatabase.open(paths.databaseFile);
  return LibraryRepository(paths, db);
}

Future<Song> addSong(LibraryRepository repo, String id) async {
  final pcm = clickTrack(bpm: 120, offsetMs: 200, seconds: 12);
  final wav = File(repo.paths.sourceFile(id, 'source.wav'));
  await wav.parent.create(recursive: true);
  await wav.writeAsBytes(encodeWav16(pcm, analysisSampleRate));
  final analysis = analyzePcm(pcm, analysisSampleRate);
  await repo.saveAnalysis(id, analysis);
  for (final mode in GameMode.values) {
    await repo.saveBeatmap(BeatmapGenerator.generate(
      analysis: analysis,
      songId: id,
      mode: mode,
      params: DifficultyParams.preset(mode, DifficultyPreset.normal),
      seed: 3,
      metadata: const BeatmapMetadata(title: 'Clicks', artist: 'Test', creator: 'gen'),
    ));
  }
  final song = Song(
    id: id,
    title: 'Clicks',
    artist: 'Test',
    durationMs: analysis.durationMs,
    bpm: analysis.bpm,
    addedAt: DateTime(2026, 1, 1),
    sourceFile: 'source.wav',
    contentHash: await ImportService.contentHash(wav),
    status: AnalysisStatus.ready,
    fingerprint: analysis.fingerprint(16),
  );
  await repo.putSong(song);
  return song;
}

ScoreRecord score(Song song, String beatmapId) => ScoreRecord(
      id: 'score1',
      songId: song.id,
      songHash: song.contentHash,
      beatmapId: beatmapId,
      beatmapName: 'Normal',
      mode: GameMode.tiles,
      stars: 2.1,
      score: 912345,
      accuracy: 0.95,
      maxCombo: 120,
      counts: const {Judgment.perfect: 100, Judgment.great: 10, Judgment.good: 5, Judgment.miss: 1},
      mods: const Mods(rate: 1.25),
      grade: Grade.s,
      failed: false,
      timestamp: DateTime(2026, 10, 1),
      durationMs: 60000,
      meanErrorMs: 4,
      unstableRate: 120,
      songTitle: song.title,
      songArtist: song.artist,
    );

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('rhytmaniac_test'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('song pack round trip to a second library', () async {
    final a = await makeRepo(Directory(p.join(tmp.path, 'a')));
    final song = await addSong(a, 'song1');
    final zip = await PackService(a).exportSongs([song]);
    expect(File(zip).existsSync(), isTrue);

    final b = await makeRepo(Directory(p.join(tmp.path, 'b')));
    final r = await PackService(b).importSongPack(zip);
    expect(r.songsAdded, 1);
    expect(r.mapsAdded, 2);
    final songs = await b.songs();
    expect(songs.single.contentHash, song.contentHash);
    final maps = await b.beatmaps();
    expect(maps, hasLength(2));
    final loaded = await b.loadBeatmap(songs.single.id, maps.first.id);
    expect(loaded.objectCount, greaterThan(0));
    expect(await b.analysis(songs.single.id), isNotNull);

    // Importing again adds nothing.
    final again = await PackService(b).importSongPack(zip);
    expect(again.songsAdded, 0);
    expect(again.mapsAdded, 0);
  });

  test('profile export/import merges scores, player and settings', () async {
    final a = await makeRepo(Directory(p.join(tmp.path, 'a')));
    final song = await addSong(a, 'song1');
    final mapId = (await a.beatmaps()).first.id;
    await a.addScore(score(song, mapId));
    await a.saveProfile(PlayerProfile(name: 'Ionel', createdAt: DateTime(2026), avatarSeed: 3));
    final settings = const AppSettings(globalOffsetMs: 27, scrollSpeed: 1.3, exportFolderUri: 'content://x');
    final zip = await PackService(a).exportProfile(
      profile: await a.profile(),
      settings: settings,
      scores: await a.scores(),
      songs: await a.songs(),
      includeLibrary: true,
    );

    final b = await makeRepo(Directory(p.join(tmp.path, 'b')));
    final r = await PackService(b).importProfile(zip, current: const AppSettings());
    expect(r.scoresAdded, 1);
    expect(r.songsAdded, 1);
    expect((await b.profile()).name, 'Ionel');
    final s = await b.settings();
    expect(s.globalOffsetMs, 27);
    expect(s.scrollSpeed, 1.3);
    // Device-specific settings don't travel.
    expect(s.exportFolderUri, isNull);
    final imported = (await b.scores()).single;
    expect(imported.score, 912345);
    expect(imported.mods.rate, 1.25);

    final again = await PackService(b).importProfile(zip, current: s);
    expect(again.scoresAdded, 0);
  });

  test('rejects files that are not packs', () async {
    final a = await makeRepo(Directory(p.join(tmp.path, 'a')));
    final bogus = File(p.join(tmp.path, 'bogus.zip'))..writeAsBytesSync(Uint8List.fromList([1, 2, 3]));
    expect(() => PackService(a).importSongPack(bogus.path), throwsA(anything));
  });

  test('tells a foreign zip apart from a profile opened as a pack', () async {
    final a = await makeRepo(Directory(p.join(tmp.path, 'a')));
    final foreign = File(p.join(tmp.path, 'set.zip'))
      ..writeAsBytesSync(ZipEncoder().encode(Archive()..add(ArchiveFile.string('song.osu', 'osu file format v14'))));
    await expectLater(PackService(a).importSongPack(foreign.path), throwsA(isA<NotAPackException>()));

    final profile = await PackService(a).exportProfile(
      profile: await a.profile(),
      settings: const AppSettings(),
      scores: const [],
      songs: const [],
      includeLibrary: false,
    );
    await expectLater(
      PackService(a).importSongPack(profile),
      throwsA(isA<FormatException>().having((e) => e is NotAPackException, 'is NotAPackException', false)),
    );
  });

  test('deleting a song keeps its scores', () async {
    final a = await makeRepo(Directory(p.join(tmp.path, 'a')));
    final song = await addSong(a, 'song1');
    await a.addScore(score(song, 'x'));
    await a.deleteSong(song.id);
    expect(await a.songs(), isEmpty);
    expect(await a.beatmaps(), isEmpty);
    expect(await a.scores(), hasLength(1));
    expect(Directory(a.paths.songDir(song.id)).existsSync(), isFalse);
  });
}
