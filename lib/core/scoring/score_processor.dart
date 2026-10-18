import 'dart:math' as math;

import '../models/difficulty.dart';
import '../models/score.dart';

class HitError {
  const HitError(this.timeMs, this.errorMs);

  /// Song time of the object.
  final double timeMs;

  /// Real milliseconds; negative = early.
  final double errorMs;
}

/// Judges timing errors against windows.
class Judge {
  const Judge(this.windows);
  final HitWindows windows;

  /// Judgment for a press [errorMs] (real ms) away from the object, or null
  /// when it's so early it should be ignored.
  Judgment? judgePress(double errorMs) {
    if (errorMs < -windows.miss) return null;
    final e = errorMs.abs();
    if (e <= windows.perfect) return Judgment.perfect;
    if (e <= windows.great) return Judgment.great;
    if (e <= windows.good) return Judgment.good;
    return Judgment.miss;
  }

  /// Release judgments use 1.5× wider windows.
  Judgment judgeRelease(double errorMs) {
    final e = errorMs.abs();
    if (e <= windows.perfect * 1.5) return Judgment.perfect;
    if (e <= windows.great * 1.5) return Judgment.great;
    if (e <= windows.good * 1.5) return Judgment.good;
    return Judgment.miss;
  }
}

/// Score, combo, accuracy and health for one run.
///
/// Scoring works like osu!'s classic score: every hit is worth its
/// judgment's points (300 / 100 / 50) plus a combo bonus of
/// `points × (combo − 1) × difficulty × mods ÷ 25`, so there is no fixed
/// maximum: long maps, hard maps and long combos all score higher. Slider
/// ticks give 10 and repeats 30 points; spinner [bonus] spins 1,000 each.
class ScoreProcessor {
  ScoreProcessor({
    required this.totalJudgments,
    this.totalTicks = 0,
    this.noFail = false,
    this.healthScale = 1.0,
    this.gainScale = 1.0,
    this.multiplier = 1.0,
    this.difficultyMultiplier = 2,
    this.suddenDeath = false,
    this.perfectOnly = false,
  });

  final int totalJudgments;

  /// Combo-only events (slider ticks and repeats) in the map.
  final int totalTicks;
  final bool noFail;

  /// Multiplies health lost to misses and passive drain.
  final double healthScale;

  /// Multiplies health gained from hits.
  final double gainScale;

  /// Mod score multiplier (applies to the combo bonus).
  final double multiplier;

  /// 1..6 from the map's settings and density, like osu!'s difficulty
  /// multiplier (see [scoreDifficulty]).
  final int difficultyMultiplier;

  /// Fail on the first combo break.
  final bool suddenDeath;

  /// Fail on anything less than Perfect.
  final bool perfectOnly;

  final Map<Judgment, int> counts = {for (final j in Judgment.values) j: 0};
  final List<HitError> errors = [];
  int combo = 0;
  int maxCombo = 0;
  double health = 1.0;
  bool failed = false;
  double _accSum = 0;
  int _judged = 0;
  int _points = 0;
  int ticksHit = 0;
  int ticksMissed = 0;

  /// Spinner bonus points.
  int bonus = 0;

  int get judged => _judged;
  bool get finished => _judged >= totalJudgments;

  void apply(Judgment j, {double? errorMs, double? timeMs}) {
    counts[j] = counts[j]! + 1;
    _judged++;
    _accSum += j.accuracyWeight;
    final value = j.scoreValue;
    if (value > 0) {
      final comboBonus = value * math.max(0, combo - 1) * difficultyMultiplier * multiplier / 25;
      _points += value + comboBonus.floor();
    }
    if (j.breaksCombo) {
      combo = 0;
    } else {
      combo++;
      maxCombo = math.max(maxCombo, combo);
    }
    if (errorMs != null && timeMs != null && j != Judgment.miss) {
      errors.add(HitError(timeMs, errorMs));
    }
    final delta = j.healthDelta < 0 ? j.healthDelta * healthScale : j.healthDelta * gainScale;
    health = (health + delta).clamp(0.0, 1.0);
    if (health <= 0 && !noFail) failed = true;
    if ((suddenDeath && j.breaksCombo) || (perfectOnly && j != Judgment.perfect)) failed = true;
  }

  /// A slider tick (or [repeat]): followed ([hit]) or dropped.
  void applyTick(bool hit, {bool repeat = false}) {
    if (hit) {
      ticksHit++;
      _points += repeat ? 30 : 10;
      combo++;
      maxCombo = math.max(maxCombo, combo);
      health = (health + 0.004 * gainScale).clamp(0.0, 1.0);
    } else {
      ticksMissed++;
      combo = 0;
      health = (health - 0.025 * healthScale).clamp(0.0, 1.0);
      if (health <= 0 && !noFail) failed = true;
      if (suddenDeath || perfectOnly) failed = true;
    }
  }

  /// Passive health loss (already scaled by the caller).
  void drain(double amount) {
    if (amount <= 0 || failed) return;
    health = (health - amount).clamp(0.0, 1.0);
    if (health <= 0 && !noFail) failed = true;
  }

  /// Accuracy over judged objects so far (1.0 before anything is judged).
  double get accuracy => _judged == 0 ? 1.0 : _accSum / _judged;

  int get score => _points + bonus;

  /// Longest possible combo.
  int get maxPossibleCombo => totalJudgments + totalTicks;

  Grade get grade => Grade.fromAccuracy(accuracy, failed: failed);

  double get meanError {
    if (errors.isEmpty) return 0;
    return errors.fold(0.0, (s, e) => s + e.errorMs) / errors.length;
  }

  /// osu!'s difficulty multiplier for scoring: HP, circle size (lanes in
  /// Tiles), timing strictness and note density, 1..6.
  static int scoreDifficulty({
    required double hp,
    required double size,
    required double strictness,
    required int objects,
    required double drainSeconds,
  }) {
    final density = drainSeconds <= 0 ? 0.0 : (objects / drainSeconds * 8).clamp(0.0, 16.0);
    return ((hp + size + strictness + density) / 38 * 5).round().clamp(1, 6);
  }

  /// Unstable rate: 10 × standard deviation of hit errors.
  double get unstableRate {
    if (errors.length < 2) return 0;
    final mean = meanError;
    final v = errors.fold(0.0, (s, e) => s + (e.errorMs - mean) * (e.errorMs - mean)) / errors.length;
    return 10 * math.sqrt(v);
  }
}
