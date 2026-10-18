import 'dart:math' as math;

import '../models/difficulty.dart';
import '../models/score.dart';

/// Everything a play's performance points depend on.
class PlayFacts {
  const PlayFacts({
    required this.mode,
    required this.stars,
    required this.accuracy,
    required this.misses,
    required this.maxCombo,
    required this.mapMaxCombo,
    required this.objectCount,
    required this.strictness,
    required this.mods,
    this.failed = false,
  });

  final GameMode mode;

  /// Star rating at the play's speed.
  final double stars;
  final double accuracy;
  final int misses;
  final int maxCombo;
  final int mapMaxCombo;
  final int objectCount;

  /// The map's timing strictness 0..10 after Easy / Hard Rock (like OD).
  final double strictness;
  final Mods mods;
  final bool failed;
}

/// Performance points (pp) for one play, modelled on osu!.
///
/// Circles (like osu!standard): aim and speed values grow with the cube of
/// the stars, accuracy has its own value that grows with strictness, and
/// the three are combined with a 1.1 power sum. Length bonus, combo and
/// misses scale the result. Tiles (like osu!mania): a strain value from
/// the stars scaled by how close accuracy is to perfect.
///
/// Failed, practice and autoplay runs are worth nothing.
double performancePoints(PlayFacts f) {
  if (f.failed || f.mods.autoplay || f.stars <= 0) return 0;
  final acc = f.accuracy.clamp(0.0, 1.0);
  final n = math.max(1, f.objectCount);
  final length = 0.95 + 0.4 * math.min(1.0, n / 2000) + (n > 2000 ? math.log(n / 2000) / math.ln10 * 0.5 : 0);
  double pp;
  if (f.mode == GameMode.circles) {
    final half = f.stars / 2;
    final base = math.pow(5 * math.max(1.0, half / 0.0675) - 4, 3) / 100000;
    final combo = f.mapMaxCombo > 0 ? math.min(1.0, math.pow(f.maxCombo / f.mapMaxCombo, 0.8).toDouble()) : 1.0;
    final misses = math.pow(0.97, f.misses);
    final aim = base * length * combo * misses * (0.5 + acc / 2);
    final speed = base * length * combo * misses * math.pow(acc, 6);
    final accuracy = math.pow(1.52163, f.strictness) * math.pow(acc, 24) * 2.83 * math.min(1.15, math.pow(n / 1000, 0.3));
    pp = math.pow(math.pow(aim, 1.1) + math.pow(speed, 1.1) + math.pow(accuracy, 1.1), 1 / 1.1) * 1.12;
  } else {
    final strain = 8 * math.pow(math.max(f.stars - 0.15, 0.05), 2.2);
    pp = strain * math.max(0.0, 5 * acc - 4) * (1 + 0.1 * math.min(1.0, n / 1500));
  }
  return pp * modPerformanceFactor(f.mods);
}

/// How mods scale pp (speed is already in the stars).
double modPerformanceFactor(Mods m) {
  var k = 1.0;
  if (m.noFail) k *= 0.9;
  if (m.easy) k *= 0.6;
  if (m.hidden) k *= 1.06;
  if (m.hardRock) k *= 1.1;
  if (m.flashlight) k *= 1.15;
  return k;
}

/// Profile total: best plays weighted 100%, 95%, 90.25%, … plus a small
/// bonus for the number of maps played, as osu! does.
double totalPerformance(Iterable<double> bestFirst) {
  var total = 0.0, w = 1.0;
  var count = 0;
  for (final pp in bestFirst) {
    total += pp * w;
    w *= 0.95;
    count++;
  }
  return total + 416.6667 * (1 - math.pow(0.9994, count));
}

/// Timing strictness after mods: Easy widens and Hard Rock narrows the
/// windows, which moves the 0..10 setting the same way.
double effectiveStrictness(double hitWindow, Mods mods) {
  final scale = (1.4 - 0.08 * hitWindow) * mods.windowFactor;
  return ((1.4 - scale) / 0.08).clamp(-5.0, 15.0);
}
