import 'dart:convert';
import 'dart:io';

import 'package:sembast/sembast.dart';

import '../core/models/analysis.dart';
import '../core/models/beatmap.dart';
import '../core/models/replay.dart';
import '../core/models/score.dart';
import '../core/models/song.dart';
import 'settings.dart';
import 'storage.dart';

/// Reads and writes the library: song index, difficulty files, scores and
/// key-value records (settings, profile).
class LibraryRepository {
  LibraryRepository(this.paths, this.database);

  final AppPaths paths;
  final AppDatabase database;

  Database get _db => database.db;

  // --- songs ---------------------------------------------------------------------

  Future<List<Song>> songs() async {
    final records = await database.songs.find(_db);
    return records.map((r) => Song.fromJson(Map<String, dynamic>.from(r.value))).toList();
  }

  Future<Song?> song(String id) async {
    final v = await database.songs.record(id).get(_db);
    return v == null ? null : Song.fromJson(Map<String, dynamic>.from(v));
  }

  Future<void> putSong(Song song) => database.songs.record(song.id).put(_db, song.toJson());

  Future<Song?> songByHash(String hash) async {
    final r = await database.songs.findFirst(_db, finder: Finder(filter: Filter.equals('contentHash', hash)));
    return r == null ? null : Song.fromJson(Map<String, dynamic>.from(r.value));
  }

  /// Deletes the song, its files and difficulties. Scores are kept so the
  /// profile history stays intact.
  Future<void> deleteSong(String id) async {
    await _db.transaction((txn) async {
      await database.songs.record(id).delete(txn);
      await database.beatmaps.delete(txn, finder: Finder(filter: Filter.equals('songId', id)));
    });
    final dir = Directory(paths.songDir(id));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  // --- analysis ------------------------------------------------------------------

  Future<SongAnalysis?> analysis(String songId) async {
    final f = File(paths.analysisFile(songId));
    if (!await f.exists()) return null;
    return SongAnalysis.fromJson(await readJsonFile(f.path));
  }

  Future<void> saveAnalysis(String songId, SongAnalysis a) => writeJsonFile(paths.analysisFile(songId), a.toJson());

  // --- beatmaps ------------------------------------------------------------------

  Future<List<BeatmapSummary>> beatmaps() async {
    final records = await database.beatmaps.find(_db);
    return records.map((r) => BeatmapSummary.fromJson(Map<String, dynamic>.from(r.value))).toList();
  }

  Future<Beatmap> loadBeatmap(String songId, String beatmapId) async =>
      Beatmap.fromJson(await readJsonFile(paths.mapFile(songId, beatmapId)));

  static BeatmapSummary summarize(Beatmap b) => BeatmapSummary(
        id: b.id,
        songId: b.songId,
        mode: b.mode,
        name: b.name,
        stars: b.starRating,
        preset: b.difficulty.preset,
        edited: b.edited,
        objectCount: b.objectCount,
        createdAt: b.createdAt,
        lanes: b.difficulty.lanes,
        origin: b.origin,
      );

  Future<BeatmapSummary> saveBeatmap(Beatmap b) async {
    await writeJsonFile(paths.mapFile(b.songId, b.id), b.toJson());
    final summary = summarize(b);
    await database.beatmaps.record(b.id).put(_db, summary.toJson());
    return summary;
  }

  Future<void> deleteBeatmap(String songId, String beatmapId) async {
    await database.beatmaps.record(beatmapId).delete(_db);
    final f = File(paths.mapFile(songId, beatmapId));
    if (await f.exists()) await f.delete();
  }

  // --- scores --------------------------------------------------------------------

  Future<List<ScoreRecord>> scores() async {
    final records = await database.scores.find(_db);
    return records.map((r) => ScoreRecord.fromJson(Map<String, dynamic>.from(r.value))).toList();
  }

  Future<void> addScore(ScoreRecord s) => database.scores.record(s.id).put(_db, s.toJson());

  Future<int> addScoresIfMissing(Iterable<ScoreRecord> scores) async {
    var added = 0;
    await _db.transaction((txn) async {
      for (final s in scores) {
        final rec = database.scores.record(s.id);
        if (await rec.exists(txn)) continue;
        await rec.put(txn, s.toJson());
        added++;
      }
    });
    return added;
  }

  // --- replays ----------------------------------------------------------------------

  Future<void> saveReplay(Replay r) async {
    final f = File(paths.replayFile(r.scoreId));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(gzip.encode(utf8.encode(jsonEncode(r.toJson()))), flush: true);
  }

  Future<Replay?> loadReplay(String scoreId) async {
    final f = File(paths.replayFile(scoreId));
    if (!await f.exists()) return null;
    final j = jsonDecode(utf8.decode(gzip.decode(await f.readAsBytes()))) as Map<String, dynamic>;
    return Replay.fromJson(j);
  }

  // --- key-value -------------------------------------------------------------------

  Future<AppSettings> settings() async {
    final v = await database.kv.record('settings').get(_db);
    return AppSettings.fromJson(v == null ? null : Map<String, dynamic>.from(v));
  }

  Future<void> saveSettings(AppSettings s) => database.kv.record('settings').put(_db, s.toJson());

  Future<PlayerProfile> profile() async {
    final v = await database.kv.record('profile').get(_db);
    return PlayerProfile.fromJson(v == null ? null : Map<String, dynamic>.from(v));
  }

  Future<void> saveProfile(PlayerProfile p) => database.kv.record('profile').put(_db, p.toJson());
}
