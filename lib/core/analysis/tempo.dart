import 'dart:math' as math;
import 'dart:typed_data';

import 'dsp.dart';

class TempoEstimate {
  const TempoEstimate({
    required this.bpm,
    required this.offsetMs,
    required this.confidence,
    required this.barOffsetBeats,
  });

  final double bpm;

  /// First beat at or after 0 ms.
  final double offsetMs;
  final double confidence;
  final int barOffsetBeats;
}

/// Single-BPM tempo and beat-phase estimation.
///
/// 1. Autocorrelation of the rectified onset envelope with harmonic
///    enhancement and a log-normal prior around 120 BPM picks the octave.
/// 2. A fine comb search over BPM ± 3% and every beat phase maximizes the
///    envelope sampled on the grid; near-integer BPMs are preferred.
TempoEstimate estimateTempo(
  Float64List odf, {
  required double frameMs,
  Float64List? lowEnvelope,
  Float64List? midEnvelope,
  double minBpm = 60,
  double maxBpm = 200,
}) {
  final n = odf.length;
  final fallback = TempoEstimate(bpm: 120, offsetMs: 0, confidence: 0, barOffsetBeats: 0);
  if (n < 64) return fallback;

  // Rectified envelope: subtract a ~1 s moving average.
  final half = math.max(1, (500 / frameMs).round());
  final prefix = Float64List(n + 1);
  for (var i = 0; i < n; i++) {
    prefix[i + 1] = prefix[i] + odf[i];
  }
  final env = Float64List(n);
  for (var i = 0; i < n; i++) {
    final a = math.max(0, i - half), b = math.min(n, i + half + 1);
    env[i] = math.max(0, odf[i] - (prefix[b] - prefix[a]) / (b - a));
  }

  // --- 1. Autocorrelation ------------------------------------------------------
  final minLag = (60000 / (maxBpm * 1.05) / frameMs).floor();
  final maxLag = math.min(n ~/ 2, (60000 / (minBpm * 0.95) / frameMs).ceil());
  if (maxLag <= minLag + 2) return fallback;
  final acMax = math.min(n - 1, maxLag * 3 + 2);
  final ac = Float64List(acMax + 1);
  for (var lag = minLag ~/ 2; lag <= acMax; lag++) {
    var s = 0.0;
    for (var i = 0; i + lag < n; i++) {
      s += env[i] * env[i + lag];
    }
    ac[lag] = s / (n - lag);
  }
  double acAt(double lag) => sampleAt(ac, lag);

  var bestLag = minLag;
  var bestScore = -1.0;
  final scores = Float64List(maxLag + 1);
  for (var lag = minLag; lag <= maxLag; lag++) {
    final bpm = 60000 / (lag * frameMs);
    if (bpm < minBpm || bpm > maxBpm) continue;
    final harmonic = ac[lag] + 0.5 * acAt(lag * 2.0) + 0.25 * acAt(lag * 4.0);
    final prior = math.exp(-0.5 * math.pow(math.log(bpm / 120) / math.ln2 / 0.8, 2));
    final s = harmonic * prior;
    scores[lag] = s;
    if (s > bestScore) {
      bestScore = s;
      bestLag = lag;
    }
  }
  var lagF = bestLag.toDouble();
  if (bestLag > minLag && bestLag < maxLag) {
    final y0 = scores[bestLag - 1], y1 = scores[bestLag], y2 = scores[bestLag + 1];
    final d = y0 - 2 * y1 + y2;
    if (d.abs() > 1e-12) lagF += (0.5 * (y0 - y2) / d).clamp(-0.5, 0.5);
  }
  final coarseBpm = 60000 / (lagF * frameMs);

  // --- 2. Fine comb search ------------------------------------------------------
  final combEnv = smooth3(smooth3(env));

  ({double score, double phase, double mean}) comb(double bpm) {
    final period = 60000 / (bpm * frameMs);
    var best = -1.0, bestPhase = 0.0, total = 0.0;
    var count = 0;
    for (var phase = 0.0; phase < period; phase += 0.5) {
      var s = 0.0;
      var beats = 0;
      for (var p = phase; p < n - 1; p += period) {
        s += sampleAt(combEnv, p);
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
    return (score: best, phase: bestPhase, mean: count == 0 ? 0 : total / count);
  }

  double prior(double bpm) => math.exp(-0.5 * math.pow(math.log(bpm / 120) / math.ln2 / 0.8, 2));

  // Metrical relatives of the autocorrelation winner compete on grid
  // contrast (beats vs. average phase), so 3:2 confusions like 150 → 100
  // are resolved by where the onsets actually fall.
  var best = comb(coarseBpm);
  var bpm = coarseBpm;
  var bestValue = -1.0;
  for (final ratio in const [1.0, 2.0, 0.5, 1.5, 2 / 3, 4 / 3, 0.75]) {
    final center = coarseBpm * ratio;
    if (center < minBpm || center > maxBpm) continue;
    for (var b = center * 0.975; b <= center * 1.025; b += 0.05) {
      final c = comb(b);
      final value = (c.score - c.mean) * math.sqrt(prior(b));
      if (value > bestValue) {
        bestValue = value;
        best = c;
        bpm = b;
      }
    }
  }
  // Fine-tune at 0.01 BPM around the winner.
  final coarseWinner = bpm;
  for (var b = coarseWinner - 0.05; b <= coarseWinner + 0.05; b += 0.01) {
    final c = comb(b);
    if (c.score > best.score) {
      best = c;
      bpm = b;
    }
  }
  // Prefer a round tempo when it fits almost as well.
  for (final rounded in [bpm.roundToDouble(), (bpm * 2).roundToDouble() / 2]) {
    if ((rounded - bpm).abs() < 0.6) {
      final c = comb(rounded);
      if (c.score >= best.score * 0.985) {
        best = c;
        bpm = rounded;
        break;
      }
    }
  }

  // Octave check: if the off-beats of this grid are nearly as busy as the
  // beats, the real pulse is twice as fast (e.g. 174 BPM read as 87).
  if (bpm * 2 <= maxBpm) {
    final period = 60000 / (bpm * frameMs);
    var on = 0.0, off = 0.0;
    for (var p = best.phase; p < n - 1 - period / 2; p += period) {
      on += sampleAt(combEnv, p);
      off += _maxNear(combEnv, p + period / 2, 1.5);
    }
    if (on > 0 && off / on > 0.6) {
      final doubled = comb(bpm * 2);
      best = doubled;
      bpm *= 2;
    }
  }

  // Backbeat check: kick and snare taking turns on every beat read like a
  // slow tempo with the kick on the beat and the snare between. When the
  // in-between hits are mid-heavy (snares, claps) and nearly as strong as
  // the beats, they are beats too.
  if (bpm < 100 && bpm * 2 <= maxBpm && midEnvelope != null) {
    final period = 60000 / (bpm * frameMs);
    var on = 0.0, off = 0.0, midOn = 0.0, midOff = 0.0;
    for (var p = best.phase; p < n - 1 - period / 2; p += period) {
      on += _maxNear(combEnv, p, 1.5);
      off += _maxNear(combEnv, p + period / 2, 1.5);
      midOn += _maxNear(midEnvelope, p, 1.5);
      midOff += _maxNear(midEnvelope, p + period / 2, 1.5);
    }
    if (on > 0 && off / on > 0.35 && midOff > midOn * 1.2) {
      best = comb(bpm * 2);
      bpm *= 2;
    }
  }

  // Half-beat check. On the right grid the beats carry the weight (kicks,
  // bass, snares) and the snares or claps take turns with the kicks, so the
  // mid band alternates from beat to beat. Off-beat hats and bass stabs
  // have sharper attacks and can win the comb; when the low and mid bands,
  // or that alternation, clearly sit half a beat away, so do the beats.
  if (lowEnvelope != null && midEnvelope != null) {
    final period = 60000 / (bpm * frameMs);
    var on = 0.0, off = 0.0, midOffSum = 0.0;
    final altOn = [0.0, 0.0], altOff = [0.0, 0.0];
    var k = 0;
    for (var p = best.phase; p < n - 1 - period / 2; p += period, k++) {
      final mOn = _maxNear(midEnvelope, p, 1.5), mOff = _maxNear(midEnvelope, p + period / 2, 1.5);
      on += _maxNear(lowEnvelope, p, 1.5) + mOn;
      off += _maxNear(lowEnvelope, p + period / 2, 1.5) + mOff;
      altOn[k % 2] += mOn;
      altOff[k % 2] += mOff;
      midOffSum += mOff;
    }
    final alternationOn = (altOn[0] - altOn[1]).abs();
    final alternationOff = (altOff[0] - altOff[1]).abs();
    final backbeatAway = alternationOff > 2 * alternationOn && alternationOff > 0.08 * midOffSum;
    if (off > on * 1.4 || (backbeatAway && off > on * 0.8)) {
      best = (score: best.score, phase: (best.phase + period / 2) % period, mean: best.mean);
    }
  }

  final beatMs = 60000 / bpm;
  var offset = best.phase * frameMs + onsetLatencyCompensationMs;
  offset %= beatMs;
  if (offset < 0) offset += beatMs;
  final confidence = best.score > 0 ? (1 - best.mean / best.score).clamp(0.0, 1.0) : 0.0;

  // Downbeat: which of the 4 beat phases carries the most bass.
  var barOffset = 0;
  if (lowEnvelope != null) {
    final period = beatMs / frameMs;
    final sums = List<double>.filled(4, 0);
    var k = 0;
    for (var p = best.phase; p < lowEnvelope.length - 1; p += period, k++) {
      sums[k % 4] += sampleAt(lowEnvelope, p);
    }
    for (var i = 1; i < 4; i++) {
      if (sums[i] > sums[barOffset] * 1.05) barOffset = i;
    }
  }

  return TempoEstimate(
    bpm: bpm,
    offsetMs: offset,
    confidence: confidence.toDouble(),
    barOffsetBeats: barOffset,
  );
}

double _maxNear(Float64List x, double pos, double radius) {
  var m = 0.0;
  for (var p = pos - radius; p <= pos + radius; p += 0.5) {
    m = math.max(m, sampleAt(x, p));
  }
  return m;
}
