import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models/beatmap.dart';
import '../core/models/difficulty.dart';
import '../core/models/score.dart';
import '../core/models/song.dart';
import '../core/util/ids.dart';
import '../data/import_service.dart';
import '../data/library_repository.dart';
import '../data/pack_service.dart';
import '../data/settings.dart';
import '../data/storage.dart';
import '../platform/native_bridge.dart';

/// Everything opened at startup. Overridden in `main()`.
class AppServices {
  AppServices({
    required this.paths,
    required this.repo,
    required this.importer,
    required this.packs,
    required this.initialSettings,
    required this.initialProfile,
    required this.initialScores,
    required this.initialSongs,
    required this.initialBeatmaps,
  });

  final AppPaths paths;
  final LibraryRepository repo;
  final ImportService importer;
  final PackService packs;
  final AppSettings initialSettings;
  final PlayerProfile initialProfile;
  final List<ScoreRecord> initialScores;
  final List<Song> initialSongs;
  final List<BeatmapSummary> initialBeatmaps;
}

final servicesProvider = Provider<AppServices>((ref) => throw UnimplementedError('override in main'));

// --- library -----------------------------------------------------------------------

class LibraryState {
  const LibraryState({required this.songs, required this.beatmaps});

  final List<Song> songs;
  final List<BeatmapSummary> beatmaps;

  Song? song(String id) {
    for (final s in songs) {
      if (s.id == id) return s;
    }
    return null;
  }

  List<BeatmapSummary> mapsFor(String songId, [GameMode? mode]) {
    final list = beatmaps.where((b) => b.songId == songId && (mode == null || b.mode == mode)).toList()
      ..sort((a, b) => a.stars.compareTo(b.stars));
    return list;
  }

  double maxStars(String songId, [GameMode? mode]) {
    var m = 0.0;
    for (final b in beatmaps) {
      if (b.songId == songId && (mode == null || b.mode == mode) && b.stars > m) m = b.stars;
    }
    return m;
  }
}

class LibraryNotifier extends Notifier<LibraryState> {
  LibraryRepository get _repo => ref.read(servicesProvider).repo;

  @override
  LibraryState build() {
    final s = ref.read(servicesProvider);
    return LibraryState(songs: s.initialSongs, beatmaps: s.initialBeatmaps);
  }

  Future<void> refresh() async {
    state = LibraryState(songs: await _repo.songs(), beatmaps: await _repo.beatmaps());
  }

  Future<void> updateSong(Song song) async {
    await _repo.putSong(song);
    state = LibraryState(
      songs: [for (final s in state.songs) s.id == song.id ? song : s],
      beatmaps: state.beatmaps,
    );
  }

  Future<void> deleteSong(String id) async {
    await _repo.deleteSong(id);
    state = LibraryState(
      songs: state.songs.where((s) => s.id != id).toList(),
      beatmaps: state.beatmaps.where((b) => b.songId != id).toList(),
    );
  }

  Future<BeatmapSummary> saveBeatmap(Beatmap map) async {
    final summary = await _repo.saveBeatmap(map);
    state = LibraryState(
      songs: state.songs,
      beatmaps: [...state.beatmaps.where((b) => b.id != map.id), summary],
    );
    return summary;
  }

  Future<void> deleteBeatmap(BeatmapSummary b) async {
    await _repo.deleteBeatmap(b.songId, b.id);
    state = LibraryState(songs: state.songs, beatmaps: state.beatmaps.where((x) => x.id != b.id).toList());
  }

  /// Bumps play stats after a run.
  Future<void> recordPlay(String songId) async {
    final s = state.song(songId);
    if (s == null) return;
    await updateSong(s.copyWith(playCount: s.playCount + 1, lastPlayedAt: DateTime.now()));
  }
}

final libraryProvider = NotifierProvider<LibraryNotifier, LibraryState>(LibraryNotifier.new);

// --- imports -----------------------------------------------------------------------

class ImportJob {
  const ImportJob(this.id, this.progress);
  final String id;
  final ImportProgress progress;

  bool get active => progress.stage != ImportStage.done && progress.stage != ImportStage.failed;
}

class ImportNotifier extends Notifier<List<ImportJob>> {
  @override
  List<ImportJob> build() => const [];

  void _set(String id, ImportProgress p) {
    final exists = state.any((j) => j.id == id);
    state = exists
        ? [for (final j in state) j.id == id ? ImportJob(id, p) : j]
        : [...state, ImportJob(id, p)];
  }

  void dismiss(String id) => state = state.where((j) => j.id != id).toList();

  Future<Song?> _run(String label, Future<Song> Function(void Function(ImportProgress)) work) async {
    final id = newId();
    _set(id, ImportProgress(ImportStage.copying, 0, title: label));
    try {
      final song = await work((p) => _set(id, p));
      await ref.read(libraryProvider.notifier).refresh();
      Future.delayed(const Duration(seconds: 3), () => dismiss(id));
      return song;
    } catch (e) {
      final current = state.firstWhere((j) => j.id == id, orElse: () => ImportJob(id, ImportProgress(ImportStage.failed, 0, title: label)));
      _set(id, ImportProgress(ImportStage.failed, current.progress.progress, title: current.progress.title ?? label, error: _describe(e)));
      return null;
    }
  }

  static String _describe(Object e) {
    if (e is DuplicateSongException) return e.toString();
    final s = e.toString();
    if (s.contains('no audio track')) return 'This file has no audio track.';
    if (s.startsWith('Exception: ')) return s.substring(11).split('\n').first;
    return s.split('\n').first;
  }

  Future<Song?> importPicked(PickedFile file) =>
      _run(file.name, (cb) => ref.read(servicesProvider).importer.importPicked(file, cb));

  Future<Song?> installDemo() async {
    final song = await _run('Ember Drift', (cb) => ref.read(servicesProvider).importer.installDemo(cb));
    if (song != null) {
      final settings = ref.read(settingsProvider);
      await ref.read(settingsProvider.notifier).update(settings.copyWith(demoInstalled: true));
    }
    return song;
  }

  Future<Song?> reanalyze(Song song) async {
    return _run(song.title, (cb) async {
      await ref.read(servicesProvider).importer.reanalyze(song, cb);
      return (await ref.read(servicesProvider).repo.song(song.id))!;
    });
  }
}

final importProvider = NotifierProvider<ImportNotifier, List<ImportJob>>(ImportNotifier.new);

// --- settings, scores, profile -------------------------------------------------------

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.read(servicesProvider).initialSettings;

  Future<void> update(AppSettings s) async {
    state = s;
    await ref.read(servicesProvider).repo.saveSettings(s);
  }

  Future<void> reload() async => state = await ref.read(servicesProvider).repo.settings();
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

class ScoresNotifier extends Notifier<List<ScoreRecord>> {
  @override
  List<ScoreRecord> build() => ref.read(servicesProvider).initialScores;

  Future<void> add(ScoreRecord s) async {
    await ref.read(servicesProvider).repo.addScore(s);
    state = [...state, s];
  }

  Future<void> reload() async => state = await ref.read(servicesProvider).repo.scores();

  /// Best non-practice, non-autoplay score on a difficulty.
  ScoreRecord? best(String beatmapId) {
    ScoreRecord? b;
    for (final s in state) {
      if (s.beatmapId != beatmapId || s.practice || s.mods.autoplay || s.failed) continue;
      if (b == null || s.score > b.score) b = s;
    }
    return b;
  }
}

final scoresProvider = NotifierProvider<ScoresNotifier, List<ScoreRecord>>(ScoresNotifier.new);

class ProfileNotifier extends Notifier<PlayerProfile> {
  @override
  PlayerProfile build() => ref.read(servicesProvider).initialProfile;

  Future<void> update(PlayerProfile p) async {
    state = p;
    await ref.read(servicesProvider).repo.saveProfile(p);
  }

  Future<void> reload() async => state = await ref.read(servicesProvider).repo.profile();
}

final profileProvider = NotifierProvider<ProfileNotifier, PlayerProfile>(ProfileNotifier.new);

/// Which mode the library and song screens show.
class ModeNotifier extends Notifier<GameMode> {
  @override
  GameMode build() => GameMode.tiles;
  void set(GameMode m) => state = m;
}

final modeProvider = NotifierProvider<ModeNotifier, GameMode>(ModeNotifier.new);
