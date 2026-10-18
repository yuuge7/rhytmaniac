import '../models/beatmap.dart';
import '../models/score.dart';
import '../models/timing.dart';
import '../scoring/score_processor.dart';

/// Something the renderer and feedback layer (haptics, sounds) react to.
class HitFeedback {
  const HitFeedback({
    required this.timeMs,
    required this.judgment,
    this.errorMs,
    this.lane,
    this.position,
    this.isRelease = false,
  });

  /// Song time when the judgment happened.
  final double timeMs;
  final Judgment judgment;
  final double? errorMs;
  final int? lane;
  final Point2? position;
  final bool isRelease;
}

/// Smaller moments that only need a sound or a flash.
enum SessionEvent { tick, tickMiss, repeat, spinBonus }

/// Shared interface of the per-mode gameplay rules.
abstract class GameSession {
  GameSession({required this.mods, required this.hpDrain});

  final Mods mods;

  /// The map's HP setting, 0..10.
  final double hpDrain;

  ScoreProcessor get processor;

  /// Advances to song time [timeMs]: detects misses, finishes holds and
  /// sliders, drains health, and plays objects when autoplay is on.
  void update(double timeMs);

  /// Song time of the first object.
  double get firstObjectMs;

  /// Song time after which nothing is left to judge.
  double get endTimeMs;

  /// Rests between objects (no health drain, a break banner).
  List<TimeSpan> get breaks;

  /// Recent feedback, newest last. The renderer prunes old entries.
  List<HitFeedback> get feedback;

  /// Called for each judgment as it happens.
  void Function(HitFeedback)? onFeedback;

  /// Called for slider ticks, repeats and spinner bonus spins.
  void Function(SessionEvent event, Point2? position)? onEvent;

  bool get complete => processor.finished;

  double get _rate => mods.rate;

  TimeSpan? breakAt(double t) {
    for (final b in breaks) {
      if (t >= b.startMs && t <= b.endMs) return b;
      if (b.startMs > t) break;
    }
    return null;
  }

  double _lastDrainAt = double.nan;

  /// Passive health drain while objects are in play (not before the first,
  /// after the last or during breaks), like osu!'s HP drain.
  void applyDrain(double t) {
    final last = _lastDrainAt;
    _lastDrainAt = t;
    if (last.isNaN) return;
    final dt = t - last;
    if (dt <= 0 || dt > 1000 || mods.autoplay) return;
    if (t < firstObjectMs || t > endTimeMs || breakAt(t) != null) return;
    processor.drain(drainPerSecond(hpDrain, mods) * realMs(dt, _rate) / 1000);
  }

  /// Health lost per real second of play.
  static double drainPerSecond(double hp, Mods mods) => 0.004 * hp * mods.drainFactor;

  /// A score processor set up for this map and mods.
  static ScoreProcessor processorFor({
    required int judgments,
    int ticks = 0,
    required double hp,
    required Mods mods,
  }) =>
      ScoreProcessor(
        totalJudgments: judgments,
        totalTicks: ticks,
        noFail: mods.noFail,
        healthScale: (0.6 + 0.08 * hp) * mods.drainFactor,
        gainScale: 1.15 - 0.03 * hp,
        multiplier: mods.scoreMultiplier,
        suddenDeath: mods.suddenDeath,
        perfectOnly: mods.perfect,
      );
}

/// Gaps of at least 3.5 real seconds between objects become breaks, from
/// shortly after one object ends to a moment before the next one starts.
List<TimeSpan> findMapBreaks(Iterable<(double, double)> objects, double rate) {
  final out = <TimeSpan>[];
  double? prevEnd;
  for (final (start, end) in objects) {
    if (prevEnd != null && start - prevEnd >= 3500 * rate) {
      out.add(TimeSpan(prevEnd + 400 * rate, start - 1200 * rate));
    }
    if (prevEnd == null || end > prevEnd) prevEnd = end;
  }
  return out;
}

/// Converts a song-time delta into real milliseconds at a playback rate.
double realMs(double songDeltaMs, double rate) => songDeltaMs / rate;
