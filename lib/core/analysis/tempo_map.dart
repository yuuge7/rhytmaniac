import 'dart:math' as math;
import 'dart:typed_data';

import '../models/analysis.dart';
import '../models/timing.dart';
import 'dsp.dart';
import 'tempo.dart';

/// Finds tempo changes and parts that move in triplets (or swing).
///
/// 1. The onset envelope is cut into overlapping 12 s windows; each gets a
///    local tempo from a comb search, with a prior that keeps it near the
///    song's overall tempo (so it doesn't jump octaves).
/// 2. A new section starts only when two windows in a row agree on a tempo
///    more than 3.5% away from the current one, so fills and breakdowns
///    don't split the song.
/// 3. Each section's grid is fitted away from its edges, then every
///    boundary is moved to where the old grid stops and the new one starts
///    explaining the onsets best. Sections start on a beat.
/// 4. Off-beat onsets vote, window by window, for a 1/4 or a 1/3 beat grid;
///    stretches with a clear 1/3 majority become triplet sections (same
///    tempo, new subdivision), which covers swing and shuffle feels.
///
/// Returns no points when the whole song is one straight tempo, so such
/// songs keep exactly the single-tempo grid of [global].
List<TimingPoint> detectTimingSections({
  required Float64List odf,
  required double frameMs,
  required TempoEstimate global,
  required List<Onset> onsets,
  required double durationMs,
  Float64List? lowEnvelope,
}) {
  final n = odf.length;
  if (n < 64 || global.confidence <= 0) return const [];

  // Rectified, smoothed envelope (as in estimateTempo).
  final half = math.max(1, (500 / frameMs).round());
  final prefix = Float64List(n + 1);
  for (var i = 0; i < n; i++) {
    prefix[i + 1] = prefix[i] + odf[i];
  }
  final rect = Float64List(n);
  for (var i = 0; i < n; i++) {
    final a = math.max(0, i - half), b = math.min(n, i + half + 1);
    rect[i] = math.max(0, odf[i] - (prefix[b] - prefix[a]) / (b - a));
  }
  final env = smooth3(smooth3(rect));
  int frame(double ms) => (ms / frameMs).round().clamp(0, n - 1);

  // --- 1. Local tempo per window -----------------------------------------------------
  const windowMs = 12000.0, hopMs = 4000.0;
  final windows = <({double start, double end, double bpm})>[];
  for (var s = 0.0; s + windowMs * 0.6 < durationMs; s += hopMs) {
    final e = math.min(durationMs, s + windowMs);
    final a = frame(s), b = frame(e);
    var bestBpm = global.bpm, bestValue = -1.0;
    void consider(double bpm) {
      final c = _comb(env, a, b, bpm, frameMs, phaseStep: 1);
      final value = (c.best - c.mean) * _prior(bpm, global.bpm);
      if (value > bestValue) {
        bestValue = value;
        bestBpm = bpm;
      }
    }

    for (var bpm = 60.0; bpm <= 200.0; bpm += 1.0) {
      consider(bpm);
    }
    final coarse = bestBpm;
    for (var bpm = coarse - 1; bpm <= coarse + 1; bpm += 0.1) {
      consider(bpm);
    }
    windows.add((start: s, end: e, bpm: bestBpm));
  }
  if (windows.isEmpty) return const [];

  // --- 2. Segment ----------------------------------------------------------------------
  bool close(double x, double y, double tol) => (x / y - 1).abs() <= tol;
  final cuts = <({double timeMs, double bpm})>[(timeMs: 0, bpm: windows.first.bpm)];
  var current = windows.first.bpm;
  for (var i = 1; i + 1 < windows.length; i++) {
    final w = windows[i], next = windows[i + 1];
    if (!close(w.bpm, current, 0.035) && close(w.bpm, next.bpm, 0.02)) {
      // The change is somewhere in the overlap of these windows.
      cuts.add((timeMs: w.start + windowMs * 0.5, bpm: w.bpm));
      current = w.bpm;
      i++;
    } else if (close(w.bpm, current, 0.02)) {
      current = current * 0.7 + w.bpm * 0.3;
    }
  }
  final merged = <({double timeMs, double bpm})>[];
  for (var i = 0; i < cuts.length; i++) {
    final end = i + 1 < cuts.length ? cuts[i + 1].timeMs : durationMs;
    if (merged.isNotEmpty && (end - cuts[i].timeMs < 9000 || close(cuts[i].bpm, merged.last.bpm, 0.015))) continue;
    merged.add(cuts[i]);
  }
  if (merged.length > 8) merged.removeRange(8, merged.length);

  // --- 3. Fit grids, then place the boundaries ---------------------------------------------
  final grids = <_Grid>[];
  if (merged.length == 1) {
    grids.add(_Grid(60000 / global.bpm, global.offsetMs));
  } else {
    for (var i = 0; i < merged.length; i++) {
      final start = merged[i].timeMs;
      final end = i + 1 < merged.length ? merged[i + 1].timeMs : durationMs;
      // Fit away from the uncertain edges.
      final a = frame(i == 0 ? start : start + 6000), b = frame(i + 1 < merged.length ? end - 6000 : end);
      grids.add(_fit(env, b > a + 200 ? a : frame(start), b > a + 200 ? b : frame(end), merged[i].bpm, frameMs));
    }
  }
  final starts = <double>[0];
  for (var i = 1; i < grids.length; i++) {
    final g1 = grids[i - 1], g2 = grids[i];
    final cut = merged[i].timeMs;
    var bestB = cut, bestScore = double.negativeInfinity;
    for (var b = cut - 10000; b <= cut + 10000; b += 50) {
      if (b <= starts.last + 4000 || b >= durationMs - 2000) continue;
      final s = _gridScore(env, g1, b - 8000, b, frameMs) + _gridScore(env, g2, b, b + 8000, frameMs);
      if (s > bestScore) {
        bestScore = s;
        bestB = b;
      }
    }
    starts.add(g2.firstBeatAtOrAfter(bestB - g2.beatMs * 0.5));
  }

  // --- 4. Feel: straight or triplet, window by window ---------------------------------
  final points = <TimingPoint>[];
  for (var i = 0; i < grids.length; i++) {
    final g = grids[i];
    final secStart = starts[i];
    final secEnd = i + 1 < grids.length ? starts[i + 1] : durationMs;
    final first = i == 0 ? g.firstBeatAtOrAfter(0) : secStart;
    final bar = merged.length == 1 ? global.barOffsetBeats : _downbeat(lowEnvelope, first, g.beatMs, secEnd, frameMs);
    // Votes per 8 s window; consecutive agreeing windows form a stretch.
    final feel = <({double start, bool triplet})>[];
    for (var w = math.max(0.0, secStart); w < secEnd - 4000; w += 4000) {
      final we = math.min(secEnd, w + 8000);
      final t = _isTriplet(onsets, g, w, we);
      if (t == null) continue;
      if (feel.isEmpty || feel.last.triplet != t) feel.add((start: w, triplet: t));
    }
    // A feel must hold for 8 s to count.
    final stretches = <({double start, bool triplet})>[];
    for (var k = 0; k < feel.length; k++) {
      final end = k + 1 < feel.length ? feel[k + 1].start : secEnd;
      if (stretches.isNotEmpty && end - feel[k].start < 8000) continue;
      if (stretches.isNotEmpty && stretches.last.triplet == feel[k].triplet) continue;
      stretches.add(feel[k]);
    }
    if (stretches.isEmpty) stretches.add((start: secStart, triplet: false));
    for (var k = 0; k < stretches.length; k++) {
      final at = k == 0 ? first : g.firstBeatAtOrAfter(stretches[k].start + 2000);
      if (at >= secEnd - g.beatMs) continue;
      final beatsIn = ((at - first) / g.beatMs).round();
      points.add(TimingPoint(
        timeMs: at,
        beatLengthMs: g.beatMs,
        barOffsetBeats: shiftBarOffset(bar, beatsIn),
        triplet: stretches[k].triplet,
      ));
    }
  }
  // Drop points that repeat the previous one exactly.
  for (var i = points.length - 1; i > 0; i--) {
    final a = points[i - 1], b = points[i];
    if (b.timeMs <= a.timeMs + a.beatLengthMs) {
      points.removeAt(i);
    } else if (a.triplet == b.triplet && (a.beatLengthMs - b.beatLengthMs).abs() < 0.01) {
      points.removeAt(i);
    }
  }

  if (points.length == 1 && !points.first.triplet) return const [];
  return points;
}

/// A beat grid: beats at `anchor + k * beatMs`.
class _Grid {
  _Grid(this.beatMs, this.anchor);
  final double beatMs;
  final double anchor;

  double firstBeatAtOrAfter(double t) => anchor + ((t - anchor) / beatMs).ceil() * beatMs;
}

double _prior(double bpm, double around) {
  final x = math.log(bpm / around) / math.ln2 / 0.35;
  return math.exp(-0.5 * x * x);
}

({double best, double phase, double mean}) _comb(Float64List env, int a, int b, double bpm, double frameMs, {double phaseStep = 1}) {
  final period = 60000 / (bpm * frameMs);
  var best = -1.0, bestPhase = 0.0, total = 0.0;
  var count = 0;
  for (var phase = 0.0; phase < period; phase += phaseStep) {
    var s = 0.0;
    var beats = 0;
    for (var p = a + phase; p < b; p += period) {
      s += sampleAt(env, p);
      beats++;
    }
    if (beats == 0) continue;
    s /= beats;
    total += s;
    count++;
    if (s > best) {
      best = s;
      bestPhase = phase;
    }
  }
  return (best: best, phase: bestPhase, mean: count == 0 ? 0 : total / count);
}

/// Fine tempo and phase over frames [a, b), preferring round BPMs.
_Grid _fit(Float64List env, int a, int b, double guess, double frameMs) {
  var best = _comb(env, a, b, guess, frameMs, phaseStep: 0.5);
  var bpm = guess;
  for (var x = guess * 0.985; x <= guess * 1.015; x += 0.02) {
    final c = _comb(env, a, b, x, frameMs, phaseStep: 0.5);
    if (c.best > best.best) {
      best = c;
      bpm = x;
    }
  }
  for (final rounded in [bpm.roundToDouble(), (bpm * 2).roundToDouble() / 2]) {
    if ((rounded - bpm).abs() < 0.6) {
      final c = _comb(env, a, b, rounded, frameMs, phaseStep: 0.5);
      if (c.best >= best.best * 0.985) {
        best = c;
        bpm = rounded;
        break;
      }
    }
  }
  return _Grid(60000 / bpm, (a + best.phase) * frameMs + onsetLatencyCompensationMs);
}

/// Mean envelope on a grid's beats within [from, to) (latency-corrected).
double _gridScore(Float64List env, _Grid g, double from, double to, double frameMs) {
  var s = 0.0;
  var count = 0;
  for (var t = g.firstBeatAtOrAfter(from); t < to; t += g.beatMs) {
    s += sampleAt(env, (t - onsetLatencyCompensationMs) / frameMs);
    count++;
  }
  return count == 0 ? 0 : s / count;
}

int _downbeat(Float64List? low, double firstMs, double beatMs, double endMs, double frameMs) {
  if (low == null) return 0;
  final sums = List<double>.filled(4, 0);
  var k = 0;
  for (var t = firstMs; t < endMs; t += beatMs, k++) {
    sums[k % 4] += sampleAt(low, (t - onsetLatencyCompensationMs) / frameMs);
  }
  var best = 0;
  for (var i = 1; i < 4; i++) {
    if (sums[i] > sums[best] * 1.05) best = i;
  }
  return best;
}

/// Off-beat onsets in [from, to) vote for the 1/4 or the 1/3 grid. Null
/// when there are too few to tell.
bool? _isTriplet(List<Onset> onsets, _Grid g, double from, double to) {
  var three = 0.0, four = 0.0;
  for (final o in onsets) {
    if (o.timeMs < from || o.timeMs >= to || o.strength < 0.12) continue;
    final x = (o.timeMs - g.anchor) / g.beatMs;
    final phase = x - x.floor();
    if (phase < 0.08 || phase > 0.92) continue; // on the beat: fits both
    double dist(int d) {
      final k = (phase * d).round();
      return (phase - k / d).abs();
    }

    final e3 = dist(3), e4 = dist(4);
    if (e3 < 0.04 && e4 > 0.05) three += o.strength;
    if (e4 < 0.04 && e3 > 0.05) four += o.strength;
  }
  if (three + four < 1.5) return null;
  return three > four * 2.2;
}
