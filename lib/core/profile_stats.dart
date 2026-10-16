import 'dart:math' as math;

import 'models/difficulty.dart';
import 'models/score.dart';

class SongPlays {
  const SongPlays(this.key, this.title, this.artist, this.plays, this.songId);
  final String key;
  final String title;
  final String artist;
  final int plays;
  final String songId;
}

/// Aggregates for the profile screen.
class ProfileStats {
  ProfileStats._({
    required this.plays,
    required this.playMs,
    required this.notesHit,
    required this.averageAccuracy,
    required this.bestCombo,
    required this.streakDays,
    required this.pulse,
    required this.grades,
    required this.bestPlays,
    required this.mostPlayed,
    required this.recent,
    required this.accuracyTrend,
    required this.playsByMode,
    required this.pulseByMode,
    required this.fullCombos,
  });

  final int plays;
  final double playMs;
  final int notesHit;
  final double averageAccuracy;
  final int bestCombo;
  final int streakDays;

  /// Overall performance: best plays' pulse with 0.95 geometric weights.
  final double pulse;
  final Map<Grade, int> grades;
  final List<ScoreRecord> bestPlays;
  final List<SongPlays> mostPlayed;
  final List<ScoreRecord> recent;

  /// Accuracy of the most recent completed plays, oldest first.
  final List<double> accuracyTrend;
  final Map<GameMode, int> playsByMode;
  final Map<GameMode, double> pulseByMode;
  final int fullCombos;

  static double weightedPulse(Iterable<ScoreRecord> plays) {
    var total = 0.0, w = 1.0;
    for (final s in plays) {
      total += s.pulse * w;
      w *= 0.95;
    }
    return total;
  }

  factory ProfileStats.compute(List<ScoreRecord> all, {DateTime? now}) {
    final scores = all.where((s) => !s.mods.autoplay && !s.practice).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final completed = scores.where((s) => !s.failed).toList();

    // Best play per difficulty, ranked by pulse.
    final bestByMap = <String, ScoreRecord>{};
    for (final s in completed) {
      final b = bestByMap[s.beatmapId];
      if (b == null || s.pulse > b.pulse) bestByMap[s.beatmapId] = s;
    }
    final best = bestByMap.values.where((s) => s.pulse > 0).toList()..sort((a, b) => b.pulse.compareTo(a.pulse));

    final grades = {for (final g in Grade.values) g: 0};
    for (final s in bestByMap.values) {
      grades[s.grade] = grades[s.grade]! + 1;
    }

    final bySong = <String, List<ScoreRecord>>{};
    for (final s in scores) {
      bySong.putIfAbsent(s.songHash.isNotEmpty ? s.songHash : s.songId, () => []).add(s);
    }
    final mostPlayed = bySong.entries
        .map((e) => SongPlays(e.key, e.value.last.songTitle, e.value.last.songArtist, e.value.length, e.value.last.songId))
        .toList()
      ..sort((a, b) => b.plays.compareTo(a.plays));

    // Day streak ending today or yesterday.
    final today = _day(now ?? DateTime.now());
    final days = scores.map((s) => _day(s.timestamp)).toSet();
    var streak = 0;
    var cursor = days.contains(today) ? today : today.subtract(const Duration(days: 1));
    while (days.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }

    int hits(ScoreRecord s) => s.count(Judgment.perfect) + s.count(Judgment.great) + s.count(Judgment.good);

    return ProfileStats._(
      plays: scores.length,
      playMs: scores.fold(0.0, (t, s) => t + s.durationMs / s.mods.rate),
      notesHit: scores.fold(0, (t, s) => t + hits(s)),
      averageAccuracy: completed.isEmpty ? 0 : completed.fold(0.0, (t, s) => t + s.accuracy) / completed.length,
      bestCombo: scores.fold(0, (t, s) => math.max(t, s.maxCombo)),
      streakDays: streak,
      pulse: weightedPulse(best),
      grades: grades,
      bestPlays: best.take(10).toList(),
      mostPlayed: mostPlayed.take(5).toList(),
      recent: scores.reversed.take(10).toList(),
      accuracyTrend: completed.skip(math.max(0, completed.length - 30)).map((s) => s.accuracy).toList(),
      playsByMode: {for (final m in GameMode.values) m: scores.where((s) => s.mode == m).length},
      pulseByMode: {for (final m in GameMode.values) m: weightedPulse(best.where((s) => s.mode == m))},
      fullCombos: bestByMap.values.where((s) => s.fullCombo).length,
    );
  }

  static DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);
}
