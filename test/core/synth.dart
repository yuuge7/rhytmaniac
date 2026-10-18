import 'dart:math' as math;
import 'dart:typed_data';

import 'package:rhytmaniac/core/audio/pcm.dart';

/// A tiny drum machine and synth for tests: renders mono audio at the
/// analysis rate and remembers when every sound starts.
class SynthSong {
  SynthSong(this.seconds, {this.sr = analysisSampleRate, int seed = 5})
      : samples = Float32List((seconds * sr).round()),
        _rnd = math.Random(seed);

  final double seconds;
  final int sr;
  final Float32List samples;
  final math.Random _rnd;

  /// Start of every percussive or melodic sound, in ms.
  final List<double> events = [];

  /// Start and end of every held tone, in ms.
  final List<(double, double)> held = [];

  double _noise() => _rnd.nextDouble() * 2 - 1;

  void _add(double ms, int length, double Function(double t, int i) voice) {
    final start = (ms * sr / 1000).round();
    for (var i = 0; i < length && start + i < samples.length; i++) {
      if (start + i < 0) continue;
      samples[start + i] += voice(i / sr, i);
    }
  }

  /// Pitch-dropping sine with a short click, like an electronic kick.
  void kick(double ms, {double gain = 0.9}) {
    events.add(ms);
    var phase = 0.0;
    _add(ms, (sr * 0.35).round(), (t, i) {
      final f = 48 + 110 * math.exp(-t * 32);
      phase += 2 * math.pi * f / sr;
      return gain * (math.sin(phase) * math.exp(-t * 9) + 0.25 * _noise() * math.exp(-t * 900));
    });
  }

  /// Noise burst with a body tone.
  void snare(double ms, {double gain = 0.6}) {
    events.add(ms);
    _add(ms, (sr * 0.25).round(), (t, i) {
      return gain * (0.7 * _noise() * math.exp(-t * 22) + 0.4 * math.sin(2 * math.pi * 185 * t) * math.exp(-t * 35));
    });
  }

  /// High, bright noise: differentiated white noise. Open hats ring longer.
  void hat(double ms, {bool open = false, double gain = 0.3}) {
    events.add(ms);
    var last = 0.0;
    _add(ms, (sr * (open ? 0.3 : 0.06)).round(), (t, i) {
      final n = _noise();
      final v = n - last;
      last = n;
      return gain * v * math.exp(-t * (open ? 14 : 70));
    });
  }

  /// A held tone with a few harmonics: bass lines, leads and pads.
  void tone(double ms, double durMs, double hz, {double gain = 0.35}) {
    events.add(ms);
    held.add((ms, ms + durMs));
    final len = ((durMs + 40) * sr / 1000).round();
    _add(ms, len, (t, i) {
      final tm = t * 1000;
      final env = tm < 6 ? tm / 6 : (tm > durMs ? math.max(0.0, 1 - (tm - durMs) / 40) : 1.0);
      final w = 2 * math.pi * hz * t;
      return gain * env * (math.sin(w) + 0.5 * math.sin(2 * w) + 0.25 * math.sin(3 * w));
    });
  }

  /// Beat times for a tempo that may change smoothly: [bpmAt] gives the
  /// tempo at a song time in ms.
  static List<double> beats({required double startMs, required double endMs, required double Function(double ms) bpmAt}) {
    final out = <double>[];
    for (var t = startMs; t < endMs; t += 60000 / bpmAt(t)) {
      out.add(t);
    }
    return out;
  }
}

/// Fraction of [times] within [tolMs] of one of [truth] (both sorted).
double fractionNear(List<double> times, List<double> truth, double tolMs) {
  if (times.isEmpty) return 0;
  final sorted = List<double>.of(truth)..sort();
  var near = 0;
  for (final t in times) {
    var lo = 0, hi = sorted.length;
    while (lo < hi) {
      final m = (lo + hi) >> 1;
      if (sorted[m] < t) {
        lo = m + 1;
      } else {
        hi = m;
      }
    }
    var best = double.infinity;
    for (final j in [lo - 1, lo]) {
      if (j >= 0 && j < sorted.length) best = math.min(best, (sorted[j] - t).abs());
    }
    if (best <= tolMs) near++;
  }
  return near / times.length;
}
