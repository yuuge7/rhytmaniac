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
/// Score is out of 1,000,000 before mods: 70% from accuracy, 30% from combo
/// (each judgment weighted by the square root of the combo it was hit at).
/// Slider ticks and repeats only feed the combo. The mod [multiplier] scales
/// the result and spinner [bonus] points come on top, as in osu!.
class ScoreProcessor {
  ScoreProcessor({
    required this.totalJudgments,
    this.totalTicks = 0,
    this.noFail = false,
    this.healthScale = 1.0,
    this.gainScale = 1.0,
    this.multiplier = 1.0,
    this.suddenDeath = false,
    this.perfectOnly = false,
  }) {
    var sum = 0.0;
    for (var i = 1; i <= totalJudgments + totalTicks; i++) {
      sum += _comboWeight(i);
    }
    _maxComboSum = math.max(1, sum);
  }

  final int totalJudgments;

  /// Combo-only events (slider ticks and repeats) in the map.
  final int totalTicks;
  final bool noFail;

  /// Multiplies health lost to misses and passive drain.
  final double healthScale;

  /// Multiplies health gained from hits.
  final double gainScale;
  final double multiplier;

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
  double _comboSum = 0;
  late final double _maxComboSum;
  int ticksHit = 0;
  int ticksMissed = 0;

  /// Spinner bonus points (outside the 1,000,000).
  int bonus = 0;

  int get judged => _judged;
  bool get finished => _judged >= totalJudgments;

  static double _comboWeight(int combo) => math.sqrt(math.min(combo, 400).toDouble());

  void apply(Judgment j, {double? errorMs, double? timeMs}) {
    counts[j] = counts[j]! + 1;
    _judged++;
    _accSum += j.accuracyWeight;
    if (j.breaksCombo) {
      combo = 0;
    } else {
      combo++;
      maxCombo = math.max(maxCombo, combo);
      _comboSum += j.accuracyWeight * _comboWeight(combo);
    }
    if (errorMs != null && timeMs != null && j != Judgment.miss) {
      errors.add(HitError(timeMs, errorMs));
    }
    final delta = j.healthDelta < 0 ? j.healthDelta * healthScale : j.healthDelta * gainScale;
    health = (health + delta).clamp(0.0, 1.0);
    if (health <= 0 && !noFail) failed = true;
    if ((suddenDeath && j.breaksCombo) || (perfectOnly && j != Judgment.perfect)) failed = true;
  }

  /// A slider tick or repeat: followed ([hit]) or dropped.
  void applyTick(bool hit) {
    if (hit) {
      ticksHit++;
      combo++;
      maxCombo = math.max(maxCombo, combo);
      _comboSum += _comboWeight(combo);
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

  int get score {
    if (totalJudgments == 0) return bonus;
    final acc = _accSum / totalJudgments;
    final comboPart = _comboSum / _maxComboSum;
    return (1000000 * (0.7 * acc + 0.3 * comboPart) * multiplier).round() + bonus;
  }

  /// Longest possible combo.
  int get maxPossibleCombo => totalJudgments + totalTicks;

  Grade get grade => Grade.fromAccuracy(accuracy, failed: failed);

  double get meanError {
    if (errors.isEmpty) return 0;
    return errors.fold(0.0, (s, e) => s + e.errorMs) / errors.length;
  }

  /// Unstable rate: 10 × standard deviation of hit errors.
  double get unstableRate {
    if (errors.length < 2) return 0;
    final mean = meanError;
    final v = errors.fold(0.0, (s, e) => s + (e.errorMs - mean) * (e.errorMs - mean)) / errors.length;
    return 10 * math.sqrt(v);
  }
}
