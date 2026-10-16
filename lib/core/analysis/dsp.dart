import 'dart:math' as math;
import 'dart:typed_data';

/// The STFT window sees an attack before its centre does, so flux peaks land
/// early; this shifts them onto the attack.
/// Measured with synthetic click tracks in the unit tests.
const onsetLatencyCompensationMs = 14.0;

/// Value at quantile [q] (0..1) of [values]; does not modify the input.
double percentile(List<double> values, double q) {
  if (values.isEmpty) return 0;
  final sorted = List<double>.of(values)..sort();
  final pos = (sorted.length - 1) * q.clamp(0.0, 1.0);
  final i = pos.floor();
  final f = pos - i;
  if (i + 1 >= sorted.length) return sorted.last;
  return sorted[i] * (1 - f) + sorted[i + 1] * f;
}

/// Divides by the [q] percentile of non-zero values so bands of very
/// different magnitudes become comparable.
Float64List normalizeByPercentile(Float64List x, double q) {
  final nonZero = <double>[];
  for (final v in x) {
    if (v > 0) nonZero.add(v);
  }
  final ref = math.max(1e-12, percentile(nonZero, q));
  final out = Float64List(x.length);
  for (var i = 0; i < x.length; i++) {
    out[i] = x[i] / ref;
  }
  return out;
}

Float64List smooth3(Float64List x) {
  final out = Float64List(x.length);
  for (var i = 0; i < x.length; i++) {
    final a = i > 0 ? x[i - 1] : x[i];
    final b = i + 1 < x.length ? x[i + 1] : x[i];
    out[i] = 0.25 * a + 0.5 * x[i] + 0.25 * b;
  }
  return out;
}

/// Converts linear RMS values into a 0..1 loudness curve: 0 dB at the 95th
/// percentile maps to 1, and -40 dB below that maps to 0.
List<double> loudnessCurve(List<double> rms) {
  final db = rms.map((v) => v > 1e-9 ? 20 * math.log(v) / math.ln10 : -200.0).toList();
  final audible = db.where((d) => d > -150).toList();
  if (audible.isEmpty) return List<double>.filled(rms.length, 0);
  final top = percentile(audible, 0.95);
  const range = 40.0;
  return db.map((d) => ((d - (top - range)) / range).clamp(0.0, 1.0)).toList();
}

class Peak {
  const Peak(this.frame, this.position);

  /// Integer frame of the local maximum.
  final int frame;

  /// Sub-frame position after parabolic interpolation.
  final double position;
}

/// Adaptive-threshold peak picking (Böck et al. style): a frame is an onset if
/// it is the maximum of its neighbourhood, exceeds the local mean by a delta,
/// and is far enough from the previous onset.
List<Peak> pickPeaks(
  Float64List odf, {
  required double frameMs,
  double preMaxMs = 30,
  double postMaxMs = 30,
  double preAvgMs = 100,
  double postAvgMs = 70,
  double waitMs = 30,
  double? delta,
}) {
  final n = odf.length;
  if (n == 0) return const [];
  int frames(double ms) => math.max(1, (ms / frameMs).round());
  final preMax = frames(preMaxMs), postMax = frames(postMaxMs);
  final preAvg = frames(preAvgMs), postAvg = frames(postAvgMs);
  final wait = frames(waitMs);
  final d = delta ?? 0.08 * math.max(1e-9, percentile(odf.toList(), 0.9)) + 0.02;

  // Prefix sums for O(1) moving averages.
  final prefix = Float64List(n + 1);
  for (var i = 0; i < n; i++) {
    prefix[i + 1] = prefix[i] + odf[i];
  }

  final peaks = <Peak>[];
  var last = -wait - 1;
  for (var i = 1; i < n - 1; i++) {
    final v = odf[i];
    if (v <= 0) continue;
    final a = math.max(0, i - preAvg), b = math.min(n, i + postAvg + 1);
    final mean = (prefix[b] - prefix[a]) / (b - a);
    if (v < mean + d) continue;
    var isMax = true;
    for (var j = math.max(0, i - preMax); j <= math.min(n - 1, i + postMax); j++) {
      if (odf[j] > v || (odf[j] == v && j < i)) {
        isMax = false;
        break;
      }
    }
    if (!isMax || i - last < wait) continue;
    final y0 = odf[i - 1], y1 = v, y2 = odf[i + 1];
    final denom = y0 - 2 * y1 + y2;
    final shift = denom.abs() > 1e-12 ? (0.5 * (y0 - y2) / denom).clamp(-0.5, 0.5) : 0.0;
    peaks.add(Peak(i, i + shift));
    last = i;
  }
  return peaks;
}

/// Linear interpolation into a sampled signal at fractional [pos].
double sampleAt(Float64List x, double pos) {
  if (pos < 0 || pos >= x.length - 1) return 0;
  final i = pos.floor();
  final f = pos - i;
  return x[i] * (1 - f) + x[i + 1] * f;
}
