import '../models/analysis.dart';
import '../models/beatmap.dart';
import '../models/difficulty.dart';
import '../rating/star_rating.dart';
import '../util/ids.dart';
import 'circles_generator.dart';
import 'tiles_generator.dart';

/// Entry point for map generation. Generation only reads the cached analysis,
/// so it is fast enough to run on demand.
class BeatmapGenerator {
  static Beatmap generate({
    required SongAnalysis analysis,
    required String songId,
    required GameMode mode,
    required DifficultyParams params,
    required int seed,
    required BeatmapMetadata metadata,
    String? name,
    String? id,
  }) {
    final map = Beatmap(
      id: id ?? newId(),
      songId: songId,
      mode: mode,
      name: name ?? params.preset.label,
      metadata: metadata,
      difficulty: params,
      seed: seed,
      starRating: 0,
      createdAt: DateTime.now(),
      tileNotes: mode == GameMode.tiles ? generateTiles(analysis, params, seed) : const [],
      circleObjects: mode == GameMode.circles ? generateCircles(analysis, params, seed) : const [],
    );
    return map.copyWith(starRating: starRating(map));
  }

  /// Re-runs the generator with a new seed and splices the result into
  /// [startMs, endMs] of [map], keeping everything outside the range.
  static Beatmap regenerateSection({
    required Beatmap map,
    required SongAnalysis analysis,
    required double startMs,
    required double endMs,
    required int seed,
  }) {
    final fresh = generate(
      analysis: analysis,
      songId: map.songId,
      mode: map.mode,
      params: map.difficulty,
      seed: seed,
      metadata: map.metadata,
      id: map.id,
    );
    bool inside(double t) => t >= startMs && t <= endMs;
    Beatmap result;
    if (map.mode == GameMode.tiles) {
      final kept = map.tileNotes.where((n) => !inside(n.timeMs) && !(n.timeMs < startMs && n.endMs > startMs));
      final added = fresh.tileNotes.where((n) => inside(n.timeMs) && n.endMs <= endMs);
      final notes = [...kept, ...added]
        ..sort((a, b) => a.timeMs != b.timeMs ? a.timeMs.compareTo(b.timeMs) : a.lane.compareTo(b.lane));
      result = map.copyWith(tileNotes: notes);
    } else {
      final kept = map.circleObjects.where((o) => !inside(o.timeMs) && !(o.timeMs < startMs && o.endMs > startMs));
      final added = fresh.circleObjects.where((o) => inside(o.timeMs) && o.endMs <= endMs);
      final objs = [...kept, ...added]..sort((a, b) => a.timeMs.compareTo(b.timeMs));
      result = map.copyWith(circleObjects: renumberCombos(objs, map.circleObjects));
    }
    return result.copyWith(starRating: starRating(result));
  }

  /// Searches the continuous difficulty level for a map near [targetStars].
  static ({DifficultyParams params, double stars}) paramsForTargetStars({
    required SongAnalysis analysis,
    required GameMode mode,
    required double targetStars,
    required int seed,
    int lanes = 4,
    double rate = 1.0,
  }) {
    double rate0(double level) {
      final p = DifficultyParams.level(mode, level, lanes: lanes).copyWith(playbackRate: rate);
      final map = generate(
        analysis: analysis,
        songId: '',
        mode: mode,
        params: p,
        seed: seed,
        metadata: const BeatmapMetadata(title: '', artist: '', creator: ''),
      );
      return map.starRating;
    }

    var lo = -0.5, hi = 5.0;
    var best = DifficultyParams.level(mode, 2, lanes: lanes);
    var bestStars = double.infinity;
    for (var i = 0; i < 14; i++) {
      final mid = (lo + hi) / 2;
      final s = rate0(mid);
      if ((s - targetStars).abs() < (bestStars - targetStars).abs()) {
        bestStars = s;
        best = DifficultyParams.level(mode, mid, lanes: lanes).copyWith(playbackRate: rate);
      }
      if ((s - targetStars).abs() < 0.03) break;
      if (s < targetStars) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (params: best, stars: bestStars);
  }

  /// Keeps combo groups monotonic after edits: objects keep their group
  /// boundaries relative to neighbours.
  static List<CircleObject> renumberCombos(List<CircleObject> objs, [List<CircleObject>? reference]) {
    if (objs.isEmpty) return objs;
    final out = <CircleObject>[];
    var combo = 0;
    for (var i = 0; i < objs.length; i++) {
      if (i > 0 && objs[i].comboIndex != objs[i - 1].comboIndex) combo++;
      out.add(objs[i].copyWith(comboIndex: combo));
    }
    return out;
  }
}
