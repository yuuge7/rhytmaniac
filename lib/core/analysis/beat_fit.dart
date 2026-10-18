import 'dart:math' as math;

import '../models/analysis.dart';
import '../models/timing.dart';
import 'tempo.dart';

/// Fine-tunes a single-tempo grid on the onsets that sit on its beats.
///
/// The comb search works on 11.6 ms frames and a 0.01 BPM step, and likes
/// round tempos; over a few minutes a tempo that is a hair off drifts far
/// enough from the music to feel late or early. A weighted least-squares
/// line through the onsets near each beat (time = offset + k × beat) pins
/// both down to well under a millisecond. Round tempos stay round when they
/// explain the onsets just as well.
TempoEstimate refineTempo(TempoEstimate t, List<Onset> onsets, {double minStrength = 0.15}) {
  var period = 60000 / t.bpm;
  var offset = t.offsetMs;

  ({double a, double b, int n})? fit(double period, double offset, {bool fixedPeriod = false}) {
    final tol = math.min(30.0, period * 0.08);
    double sw = 0, sk = 0, st = 0, skk = 0, skt = 0;
    var n = 0;
    for (final o in onsets) {
      if (o.strength < minStrength) continue;
      final k = ((o.timeMs - offset) / period).round();
      if ((o.timeMs - (offset + k * period)).abs() > tol) continue;
      final w = o.strength;
      sw += w;
      sk += w * k;
      st += w * o.timeMs;
      skk += w * k * k;
      skt += w * k * o.timeMs;
      n++;
    }
    if (n < 12 || sw <= 0) return null;
    if (fixedPeriod) return (a: (st - period * sk) / sw, b: period, n: n);
    final denom = sw * skk - sk * sk;
    if (denom.abs() < 1e-9) return null;
    final b = (sw * skt - sk * st) / denom;
    return (a: (st - b * sk) / sw, b: b, n: n);
  }

  for (var iter = 0; iter < 3; iter++) {
    final f = fit(period, offset);
    // A refinement, not a different tempo.
    if (f == null || (f.b / period - 1).abs() > 0.004) break;
    period = f.b;
    offset = f.a;
  }

  var bpm = 60000 / period;
  for (final round in [bpm.roundToDouble(), (bpm * 2).roundToDouble() / 2]) {
    if ((round - bpm).abs() < 0.02) {
      final f = fit(60000 / round, offset, fixedPeriod: true);
      if (f != null) {
        bpm = round;
        period = 60000 / round;
        offset = f.a;
      }
      break;
    }
  }

  // Keep the first beat at or after 0 and the downbeat where it was.
  final shift = (offset / period).floor();
  offset -= shift * period;
  return TempoEstimate(
    bpm: bpm,
    offsetMs: offset,
    confidence: t.confidence,
    barOffsetBeats: ((t.barOffsetBeats - shift) % 4 + 4) % 4,
  );
}

/// Follows a tempo that wanders a little, as a band without a click track
/// does (a few percent over a song, too gentle for [detectTimingSections]
/// to call it a tempo change).
///
/// A phase-locked loop walks the beats: each predicted beat is pulled
/// towards a strong onset next to it, and the tempo follows the pulls. If
/// the walked beats stray more than [driftMs] from the straight grid for a
/// while, the song gets a timing point every few bars that keeps the grid
/// on the music. A steady song returns no points and keeps its single grid.
List<TimingPoint> followDrift(
  TempoEstimate t,
  List<Onset> onsets,
  double durationMs, {
  double driftMs = 12,
  int beatsPerPoint = 4,
}) {
  final period0 = 60000 / t.bpm;
  final strong = [for (final o in onsets) if (o.strength >= 0.15) o];
  if (strong.length < 32) return const [];

  // --- Walk the beats ------------------------------------------------------------
  final tol = math.min(45.0, period0 * 0.11);
  final beats = <double>[];
  var period = period0;
  var b = t.offsetMs;
  var j = 0;
  while (b < durationMs - period * 0.25) {
    while (j < strong.length && strong[j].timeMs < b - tol) {
      j++;
    }
    Onset? best;
    var bestScore = 0.0;
    for (var i = j; i < strong.length && strong[i].timeMs <= b + tol; i++) {
      final o = strong[i];
      final score = o.strength * (1 - (o.timeMs - b).abs() / tol);
      if (score > bestScore) {
        bestScore = score;
        best = o;
      }
    }
    if (best != null) {
      final err = best.timeMs - b;
      b += 0.5 * err;
      period = (period + 0.05 * err).clamp(period0 * 0.94, period0 * 1.06);
    }
    beats.add(b);
    b += period;
  }
  if (beats.length < beatsPerPoint * 3) return const [];

  // --- Is there drift worth following? -----------------------------------------------
  var worst = 0.0;
  const window = 8;
  for (var k = 0; k + window <= beats.length; k++) {
    var dev = 0.0;
    for (var i = k; i < k + window; i++) {
      dev += beats[i] - (t.offsetMs + i * period0);
    }
    worst = math.max(worst, (dev / window).abs());
  }
  if (worst < driftMs) return const [];

  // --- A timing point every few bars, merged while the tempo holds -------------------
  final points = <TimingPoint>[];
  int bar(int beatIndex) => ((t.barOffsetBeats - beatIndex) % 4 + 4) % 4;
  var startIndex = 0;
  var startTime = beats.first;
  var length = beats.length > beatsPerPoint ? (beats[beatsPerPoint] - beats[0]) / beatsPerPoint : period0;
  points.add(TimingPoint(timeMs: startTime, beatLengthMs: length, barOffsetBeats: bar(0)));
  for (var s = beatsPerPoint; s + 1 < beats.length; s += beatsPerPoint) {
    final end = math.min(beats.length - 1, s + beatsPerPoint);
    final segLength = (beats[end] - beats[s]) / (end - s);
    final predicted = startTime + (s - startIndex) * length;
    if ((predicted - beats[s]).abs() < 4 && (segLength / length - 1).abs() < 0.002) continue;
    startIndex = s;
    startTime = beats[s];
    length = segLength;
    points.add(TimingPoint(timeMs: startTime, beatLengthMs: length, barOffsetBeats: bar(s)));
  }
  return points.length > 1 ? points : const [];
}
