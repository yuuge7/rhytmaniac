import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/medals.dart';
import '../core/models/beatmap.dart';
import '../core/models/progress.dart';
import '../core/models/difficulty.dart';
import '../core/models/score.dart';
import '../core/models/song.dart';
import '../core/util/ids.dart';
import '../data/analysis_worker.dart';
import '../data/import_service.dart';
import '../data/library_repository.dart';
import '../data/pack_service.dart';
import '../data/settings.dart';
import '../data/storage.dart';
import '../platform/native_bridge.dart';
import '../ui/theme.dart';

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
    this.initialProgress = const Progress(),
    this.initialCollections = const {},
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
  final Progress initialProgress;
  final Map<String, List<String>> initialCollections;
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
    await ref.read(collectionsProvider.notifier).forget(id);
  }

  Future<BeatmapSummary> saveBeatmap(Beatmap map) async {
    final summary = await _repo.saveBeatmap(map);
    state = LibraryState(
      songs: state.songs,
      beatmaps: [...state.beatmaps.where((b) => b.id != map.id), summary],
    );
    return summary;
  }

  /// The generated difficulties of [songId]: not edited, not from osu!.
  List<BeatmapSummary> generatedFor(String songId) =>
      state.beatmaps.where((b) => b.songId == songId && !b.edited && b.origin == null).toList();

  /// Makes the generated difficulties of [songId] again from its current
  /// analysis, with the same settings and seeds. They get new ids, so scores
  /// set on the old notes stay with those. Returns how many were rebuilt.
  Future<int> rebuildGenerated(String songId) async {
    final analysis = await _repo.analysis(songId);
    final old = generatedFor(songId);
    if (analysis == null || old.isEmpty) return 0;
    final maps = [for (final b in old) await _repo.loadBeatmap(songId, b.id)];
    final fresh = await regenerateMaps(analysis, maps);
    final summaries = await _repo.replaceBeatmaps(old, fresh);
    final gone = {for (final b in old) b.id};
    state = LibraryState(
      songs: state.songs,
      beatmaps: [...state.beatmaps.where((b) => !gone.contains(b.id)), ...summaries],
    );
    return fresh.length;
  }

  Future<void> deleteBeatmap(BeatmapSummary b) async {
    await _repo.deleteBeatmap(b.songId, b.id);
    state = LibraryState(songs: state.songs, beatmaps: state.beatmaps.where((x) => x.id != b.id).toList());
  }

  Future<void> toggleFavorite(String songId) async {
    final s = state.song(songId);
    if (s != null) await updateSong(s.copyWith(favorite: !s.favorite));
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
    if (e is FormatException) return e.message;
    final s = e.toString();
    if (s.contains('no audio track')) return 'This file has no audio track.';
    if (s.startsWith('Exception: ')) return s.substring(11).split('\n').first;
    return s.split('\n').first;
  }

  Future<Song?> importPicked(PickedFile file) =>
      _run(file.name, (cb) => ref.read(servicesProvider).importer.importPicked(file, cb));

  /// Imports an osu! beatmap set (.osz).
  Future<OszImportResult?> importOsz(PickedFile file) async {
    OszImportResult? result;
    await _run(file.name, (cb) async {
      result = await ref.read(servicesProvider).importer.importOsz(file, cb);
      return result!.song;
    });
    return result;
  }

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
    final before = state;
    state = s;
    applyDeviceSettings(s, previous: before);
    await ref.read(servicesProvider).repo.saveSettings(s);
  }

  Future<void> reload() async {
    final before = state;
    state = await ref.read(servicesProvider).repo.settings();
    applyDeviceSettings(state, previous: before);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

/// Settings that live outside Flutter's widget tree: the display refresh
/// rate and the colour palette.
void applyDeviceSettings(AppSettings s, {AppSettings? previous}) {
  Palette.colorblind = s.colorblind;
  final wantHigh = s.highRefreshRate && !s.reducedEffects;
  final hadHigh = previous == null ? null : previous.highRefreshRate && !previous.reducedEffects;
  if (hadHigh != wantHigh) NativeBridge.instance.setHighRefreshRate(wantHigh);
}

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

/// Medals and the counters behind them.
class ProgressNotifier extends Notifier<Progress> {
  @override
  Progress build() => ref.read(servicesProvider).initialProgress;

  Future<void> _save(Progress p) async {
    state = p;
    await ref.read(servicesProvider).repo.saveProgress(p);
  }

  /// Unlocks every medal that is now earned and returns the new ones.
  Future<List<Medal>> check() async {
    final c = MedalContext(
      scores: ref.read(scoresProvider),
      songCount: ref.read(libraryProvider).songs.length,
      counters: state.counters,
    );
    final earned = newlyEarned(c, state.medals.keys.toSet());
    if (earned.isEmpty) return const [];
    final now = DateTime.now();
    await _save(state.copyWith(medals: {...state.medals, for (final m in earned) m.id: now}));
    return earned;
  }

  /// Counts a moment (a watched replay, a calibration, …), then checks.
  Future<List<Medal>> bump(String counter, [int by = 1]) async {
    await _save(state.copyWith(counters: {...state.counters, counter: (state.counters[counter] ?? 0) + by}));
    return check();
  }

  Future<void> reload() async => state = await ref.read(servicesProvider).repo.progress();
}

final progressProvider = NotifierProvider<ProgressNotifier, Progress>(ProgressNotifier.new);

/// Named song collections.
class CollectionsNotifier extends Notifier<Map<String, List<String>>> {
  @override
  Map<String, List<String>> build() => ref.read(servicesProvider).initialCollections;

  Future<void> _save(Map<String, List<String>> c) async {
    state = c;
    await ref.read(servicesProvider).repo.saveCollections(c);
  }

  Future<void> setMembership(String songId, Set<String> names) => _save({
        for (final e in state.entries)
          e.key: names.contains(e.key)
              ? {...e.value, songId}.toList()
              : e.value.where((id) => id != songId).toList(),
        for (final n in names)
          if (!state.containsKey(n)) n: [songId],
      });

  /// Renaming onto an existing collection merges the two.
  Future<void> rename(String from, String to) async {
    final moved = state[from];
    if (moved == null || from == to) return;
    final next = {...state}..remove(from);
    next[to] = {...?next[to], ...moved}.toList();
    await _save(next);
  }

  /// Drops a deleted song from every collection.
  Future<void> forget(String songId) async {
    if (!state.values.any((ids) => ids.contains(songId))) return;
    await _save({for (final e in state.entries) e.key: e.value.where((id) => id != songId).toList()});
  }

  Future<void> delete(String name) => _save({...state}..remove(name));

  Future<void> reload() async => state = await ref.read(servicesProvider).repo.collections();
}

final collectionsProvider = NotifierProvider<CollectionsNotifier, Map<String, List<String>>>(CollectionsNotifier.new);

/// Which mode the library and song screens show.
class ModeNotifier extends Notifier<GameMode> {
  @override
  GameMode build() => GameMode.tiles;
  void set(GameMode m) => state = m;
}

final modeProvider = NotifierProvider<ModeNotifier, GameMode>(ModeNotifier.new);
