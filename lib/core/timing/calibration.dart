import 'dart:math' as math;

/// Result of an offset calibration session.
class OffsetEstimate {
  const OffsetEstimate({required this.offsetMs, required this.deviationMs, required this.samples});

  /// Mean tap error in ms; positive = taps land after the beat.
  final double offsetMs;
  final double deviationMs;
  final int samples;
}

/// Signed error of [tapMs] to the nearest beat of a grid.
double errorToNearestBeat(double tapMs, double firstBeatMs, double beatMs) {
  final k = ((tapMs - firstBeatMs) / beatMs).round();
  return tapMs - (firstBeatMs + k * beatMs);
}

/// Averages tap errors against a metronome grid. The first [warmup] taps are
/// dropped (people need a few beats to lock in), and outliers beyond 2.2σ
/// of the median are rejected before averaging.
OffsetEstimate? estimateOffset(
  List<double> tapTimesMs, {
  required double firstBeatMs,
  required double beatMs,
  int warmup = 4,
  int minSamples = 8,
}) {
  if (tapTimesMs.length - warmup < minSamples) return null;
  final errors = tapTimesMs.skip(warmup).map((t) => errorToNearestBeat(t, firstBeatMs, beatMs)).toList();
  final sorted = List<double>.of(errors)..sort();
  final median = sorted[sorted.length ~/ 2];
  final mad = (errors.map((e) => (e - median).abs()).toList()..sort())[errors.length ~/ 2];
  final limit = math.max(15.0, 2.2 * 1.4826 * mad);
  final kept = errors.where((e) => (e - median).abs() <= limit).toList();
  if (kept.length < minSamples ~/ 2) return null;
  final mean = kept.reduce((a, b) => a + b) / kept.length;
  final variance = kept.fold(0.0, (s, e) => s + (e - mean) * (e - mean)) / kept.length;
  return OffsetEstimate(offsetMs: mean, deviationMs: math.sqrt(variance), samples: kept.length);
}
