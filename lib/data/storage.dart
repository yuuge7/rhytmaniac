import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sembast/sembast_io.dart';

/// On-disk layout:
///
///     <documents>/rhytmaniac/
///       library.db                 sembast: songs, beatmaps, scores, settings
///       songs/<songId>/
///         source.<ext>             the imported media
///         cover.jpg                embedded art or a video frame
///         analysis.json
///         maps/<beatmapId>.json
///       replays/<scoreId>.json.gz  inputs of a run, for watching it again
///       tmp/                       scratch for imports and exports
class AppPaths {
  AppPaths(this.root);

  final String root;

  String get databaseFile => p.join(root, 'library.db');
  String get songsDir => p.join(root, 'songs');
  String get tmpDir => p.join(root, 'tmp');
  String get replaysDir => p.join(root, 'replays');
  String replayFile(String scoreId) => p.join(replaysDir, '$scoreId.json.gz');

  String songDir(String songId) => p.join(songsDir, songId);
  String analysisFile(String songId) => p.join(songDir(songId), 'analysis.json');
  String mapsDir(String songId) => p.join(songDir(songId), 'maps');
  String mapFile(String songId, String beatmapId) => p.join(mapsDir(songId), '$beatmapId.json');
  String sourceFile(String songId, String name) => p.join(songDir(songId), name);
  String coverFile(String songId, String name) => p.join(songDir(songId), name);

  Future<void> ensure() async {
    for (final d in [root, songsDir, tmpDir, replaysDir]) {
      await Directory(d).create(recursive: true);
    }
  }

  /// Clears leftovers from interrupted imports/exports.
  Future<void> cleanTmp() async {
    final d = Directory(tmpDir);
    if (await d.exists()) {
      await for (final e in d.list()) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    }
  }
}

/// Sembast stores used by the app.
class AppDatabase {
  AppDatabase(this.db);

  final Database db;
  final songs = stringMapStoreFactory.store('songs');
  final beatmaps = stringMapStoreFactory.store('beatmaps');
  final scores = stringMapStoreFactory.store('scores');
  final kv = stringMapStoreFactory.store('kv');

  static Future<AppDatabase> open(String path) async {
    final db = await databaseFactoryIo.openDatabase(path);
    return AppDatabase(db);
  }
}

Future<void> writeJsonFile(String path, Map<String, dynamic> json) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final tmp = File('$path.tmp');
  await tmp.writeAsString(jsonEncode(json), flush: true);
  await tmp.rename(path);
}

Future<Map<String, dynamic>> readJsonFile(String path) async =>
    jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
