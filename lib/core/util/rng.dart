import 'dart:math' as math;

/// Small deterministic PRNG (mulberry32). Same seed gives the same sequence on
/// every platform and Dart version, which `dart:math` Random does not promise.
class Rng {
  Rng(int seed) : _state = seed & 0xFFFFFFFF;

  int _state;
  double? _spareGaussian;

  int nextUint32() {
    _state = (_state + 0x6D2B79F5) & 0xFFFFFFFF;
    var t = _state;
    t = _imul(t ^ (t >> 15), t | 1);
    t ^= (t + _imul(t ^ (t >> 7), t | 61)) & 0xFFFFFFFF;
    return (t ^ (t >> 14)) & 0xFFFFFFFF;
  }

  /// Uniform in [0, 1).
  double nextDouble() => nextUint32() / 4294967296.0;

  /// Uniform integer in [0, max).
  int nextInt(int max) => (nextDouble() * max).floor().clamp(0, max - 1);

  bool chance(double p) => nextDouble() < p;

  double range(double min, double max) => min + (max - min) * nextDouble();

  /// Standard normal via Box-Muller.
  double gaussian() {
    final spare = _spareGaussian;
    if (spare != null) {
      _spareGaussian = null;
      return spare;
    }
    double u, v, s;
    do {
      u = nextDouble() * 2 - 1;
      v = nextDouble() * 2 - 1;
      s = u * u + v * v;
    } while (s >= 1 || s == 0);
    final m = math.sqrt(-2 * math.log(s) / s);
    _spareGaussian = v * m;
    return u * m;
  }

  /// Picks an index with probability proportional to [weights].
  int weighted(List<double> weights) {
    var total = 0.0;
    for (final w in weights) {
      total += w;
    }
    if (total <= 0) return nextInt(weights.length);
    var r = nextDouble() * total;
    for (var i = 0; i < weights.length; i++) {
      r -= weights[i];
      if (r < 0) return i;
    }
    return weights.length - 1;
  }

  static int _imul(int a, int b) {
    final aHi = (a >> 16) & 0xFFFF;
    final aLo = a & 0xFFFF;
    final bHi = (b >> 16) & 0xFFFF;
    final bLo = b & 0xFFFF;
    return ((aLo * bLo) + ((((aHi * bLo) + (aLo * bHi)) << 16) & 0xFFFFFFFF)) &
        0xFFFFFFFF;
  }
}
