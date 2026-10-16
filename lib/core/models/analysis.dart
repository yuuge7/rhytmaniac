import 'dart:math' as math;

/// A detected note onset.
class Onset {
  const Onset({
    required this.timeMs,
    required this.strength,
    required this.low,
    required this.mid,
    required this.high,
  });

  final double timeMs;

  /// 0..1, relative to the strongest onsets in the song.
  final double strength;

  /// Relative spectral-flux contribution of each band, 0..1.
  final double low;
  final double mid;
  final double high;

  /// 0 = bass-heavy, 1 = treble-heavy.
  double get brightness {
    final sum = low + mid + high;
    if (sum <= 1e-9) return 0.5;
    return (mid * 0.5 + high) / sum;
  }

  Map<String, dynamic> toJson() => {
        'timeMs': _r1(timeMs),
        'strength': _r3(strength),
        'low': _r3(low),
        'mid': _r3(mid),
        'high': _r3(high),
      };

  factory Onset.fromJson(Map<String, dynamic> j) => Onset(
        timeMs: (j['timeMs'] as num).toDouble(),
        strength: (j['strength'] as num).toDouble(),
        low: (j['low'] as num?)?.toDouble() ?? 0,
        mid: (j['mid'] as num?)?.toDouble() ?? 0,
        high: (j['high'] as num?)?.toDouble() ?? 0,
      );
}

enum Band { low, mid, high }

/// A region where energy stays high after an onset (held note, pad, bass).
class SustainRegion {
  const SustainRegion({
    required this.startMs,
    required this.endMs,
    required this.band,
    required this.strength,
  });

  final double startMs;
  final double endMs;
  final Band band;
  final double strength;

  double get durationMs => endMs - startMs;

  Map<String, dynamic> toJson() => {
        'startMs': _r1(startMs),
        'endMs': _r1(endMs),
        'band': band.name,
        'strength': _r3(strength),
      };

  factory SustainRegion.fromJson(Map<String, dynamic> j) => SustainRegion(
        startMs: (j['startMs'] as num).toDouble(),
        endMs: (j['endMs'] as num).toDouble(),
        band: Band.values.byName(j['band'] as String),
        strength: (j['strength'] as num).toDouble(),
      );
}

/// Cached result of analysing a song. Serialized as `analysis.json`.
class SongAnalysis {
  SongAnalysis({
    required this.sampleRate,
    required this.hopSize,
    required this.durationMs,
    required this.bpm,
    required this.beatOffsetMs,
    required this.tempoConfidence,
    required this.barOffsetBeats,
    required this.onsets,
    required this.energyResolutionMs,
    required this.energy,
    required this.energyLow,
    required this.energyMid,
    required this.energyHigh,
    required this.sustains,
    required this.waveformResolutionMs,
    required this.waveform,
    this.formatVersion = currentFormatVersion,
  });

  static const currentFormatVersion = 1;

  final int formatVersion;
  final int sampleRate;
  final int hopSize;
  final double durationMs;
  final double bpm;

  /// Time of a beat; every beat is at `beatOffsetMs + k * beatLengthMs`.
  final double beatOffsetMs;
  final double tempoConfidence;

  /// Which beat (0..3) after [beatOffsetMs] is the downbeat of a bar.
  final int barOffsetBeats;
  final List<Onset> onsets;
  final double energyResolutionMs;

  /// Overall loudness, 0..1, sampled every [energyResolutionMs].
  final List<double> energy;
  final List<double> energyLow;
  final List<double> energyMid;
  final List<double> energyHigh;
  final List<SustainRegion> sustains;
  final double waveformResolutionMs;

  /// Peak amplitude per bucket, 0..1.
  final List<double> waveform;

  double get beatLengthMs => 60000.0 / bpm;

  double get firstDownbeatMs => beatOffsetMs + barOffsetBeats * beatLengthMs;

  /// Linear interpolation into the energy curve.
  double energyAt(double timeMs, [List<double>? curve]) {
    final c = curve ?? energy;
    if (c.isEmpty) return 0;
    final x = timeMs / energyResolutionMs;
    final i = x.floor();
    if (i < 0) return c.first;
    if (i >= c.length - 1) return c.last;
    final f = x - i;
    return c[i] * (1 - f) + c[i + 1] * f;
  }

  /// Mean energy over a window centred on [timeMs].
  double smoothedEnergyAt(double timeMs, double windowMs) {
    if (energy.isEmpty) return 0;
    final a = ((timeMs - windowMs / 2) / energyResolutionMs).floor();
    final b = ((timeMs + windowMs / 2) / energyResolutionMs).ceil();
    var sum = 0.0;
    var n = 0;
    for (var i = math.max(0, a); i <= math.min(energy.length - 1, b); i++) {
      sum += energy[i];
      n++;
    }
    return n == 0 ? 0 : sum / n;
  }

  /// Snaps [timeMs] to the nearest 1/[divisor] beat grid line.
  double snap(double timeMs, int divisor) {
    final step = beatLengthMs / divisor;
    return beatOffsetMs + ((timeMs - beatOffsetMs) / step).round() * step;
  }

  Map<String, dynamic> toJson() => {
        'formatVersion': formatVersion,
        'sampleRate': sampleRate,
        'hopSize': hopSize,
        'durationMs': _r1(durationMs),
        'bpm': _r3(bpm),
        'beatOffsetMs': _r1(beatOffsetMs),
        'beatLengthMs': _r3(beatLengthMs),
        'tempoConfidence': _r3(tempoConfidence),
        'barOffsetBeats': barOffsetBeats,
        'onsets': onsets.map((o) => o.toJson()).toList(),
        'energy': {
          'resolutionMs': energyResolutionMs,
          'total': energy.map(_r3).toList(),
          'low': energyLow.map(_r3).toList(),
          'mid': energyMid.map(_r3).toList(),
          'high': energyHigh.map(_r3).toList(),
        },
        'sustains': sustains.map((s) => s.toJson()).toList(),
        'waveform': {
          'resolutionMs': waveformResolutionMs,
          'peaks': waveform.map(_r3).toList(),
        },
      };

  factory SongAnalysis.fromJson(Map<String, dynamic> j) {
    final version = j['formatVersion'] as int? ?? 1;
    if (version > currentFormatVersion) {
      throw FormatException('analysis.json formatVersion $version is newer than supported');
    }
    final e = j['energy'] as Map<String, dynamic>;
    final w = j['waveform'] as Map<String, dynamic>;
    List<double> nums(dynamic l) =>
        (l as List? ?? const []).map((v) => (v as num).toDouble()).toList();
    return SongAnalysis(
      formatVersion: version,
      sampleRate: j['sampleRate'] as int,
      hopSize: j['hopSize'] as int,
      durationMs: (j['durationMs'] as num).toDouble(),
      bpm: (j['bpm'] as num).toDouble(),
      beatOffsetMs: (j['beatOffsetMs'] as num).toDouble(),
      tempoConfidence: (j['tempoConfidence'] as num?)?.toDouble() ?? 0,
      barOffsetBeats: j['barOffsetBeats'] as int? ?? 0,
      onsets: (j['onsets'] as List)
          .map((o) => Onset.fromJson(o as Map<String, dynamic>))
          .toList(),
      energyResolutionMs: (e['resolutionMs'] as num).toDouble(),
      energy: nums(e['total']),
      energyLow: nums(e['low']),
      energyMid: nums(e['mid']),
      energyHigh: nums(e['high']),
      sustains: (j['sustains'] as List)
          .map((s) => SustainRegion.fromJson(s as Map<String, dynamic>))
          .toList(),
      waveformResolutionMs: (w['resolutionMs'] as num).toDouble(),
      waveform: nums(w['peaks']),
    );
  }

  /// Compact 3-band loudness summary for drawing a song's fingerprint strip.
  List<List<double>> fingerprint(int columns) {
    if (energy.isEmpty) return List.generate(columns, (_) => [0, 0, 0]);
    final out = <List<double>>[];
    final per = energy.length / columns;
    for (var c = 0; c < columns; c++) {
      final a = (c * per).floor();
      final b = math.max(a + 1, ((c + 1) * per).floor()).clamp(0, energy.length);
      double avg(List<double> l) {
        if (l.isEmpty) return 0;
        var s = 0.0;
        for (var i = a; i < b && i < l.length; i++) {
          s += l[i];
        }
        return s / math.max(1, b - a);
      }

      out.add([_r3(avg(energyLow)), _r3(avg(energyMid)), _r3(avg(energyHigh))]);
    }
    return out;
  }
}

double _r1(double v) => (v * 10).roundToDouble() / 10;
double _r3(double v) => (v * 1000).roundToDouble() / 1000;
