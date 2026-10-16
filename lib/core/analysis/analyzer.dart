import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

import '../models/analysis.dart';
import 'dsp.dart';
import 'tempo.dart';

/// Parameters for [analyzePcm]. Defaults suit 22.05 kHz mono input.
class AnalyzerConfig {
  const AnalyzerConfig({
    this.frameSize = 1024,
    this.hopSize = 256,
    this.lowCutHz = 200,
    this.highCutHz = 2000,
    this.energyResolutionMs = 100,
    this.waveformResolutionMs = 20,
  });

  final int frameSize;
  final int hopSize;
  final double lowCutHz;
  final double highCutHz;
  final double energyResolutionMs;
  final double waveformResolutionMs;
}

/// Full analysis: STFT → band spectral flux → adaptive peak picking → tempo
/// and beat grid → energy curves → sustained regions → waveform peaks.
///
/// Pure Dart with no Flutter imports, so it runs inside an isolate.
SongAnalysis analyzePcm(
  Float32List samples,
  int sampleRate, {
  AnalyzerConfig config = const AnalyzerConfig(),
  void Function(double progress)? onProgress,
}) {
  final n = config.frameSize;
  final hop = config.hopSize;
  final durationMs = samples.length * 1000.0 / sampleRate;
  final frameMs = hop * 1000.0 / sampleRate;
  final frames = math.max(1, (samples.length / hop).ceil());

  final waveform = _waveformPeaks(samples, sampleRate, config.waveformResolutionMs);

  // --- STFT and per-band features ------------------------------------------
  final fft = FFT(n);
  final window = Float64List(n);
  for (var i = 0; i < n; i++) {
    window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
  }
  final bins = n ~/ 2 + 1;
  final binHz = sampleRate / n;
  final lowEnd = (config.lowCutHz / binHz).round().clamp(2, bins - 1);
  final midEnd = (config.highCutHz / binHz).round().clamp(lowEnd + 1, bins - 1);

  final fluxLow = Float64List(frames);
  final fluxMid = Float64List(frames);
  final fluxHigh = Float64List(frames);
  final powLow = Float64List(frames);
  final powMid = Float64List(frames);
  final powHigh = Float64List(frames);

  var prev = Float64List(bins);
  var cur = Float64List(bins);
  final buf = Float64List(n);
  for (var f = 0; f < frames; f++) {
    final center = f * hop;
    final start = center - n ~/ 2;
    for (var i = 0; i < n; i++) {
      final s = start + i;
      buf[i] = (s >= 0 && s < samples.length) ? samples[s] * window[i] : 0.0;
    }
    final spec = fft.realFft(buf);
    double pl = 0, pm = 0, ph = 0;
    for (var k = 0; k < bins; k++) {
      final c = spec[k];
      final mag2 = c.x * c.x + c.y * c.y;
      final mag = math.sqrt(mag2);
      cur[k] = math.log(1 + 10 * mag);
      if (k == 0) continue;
      if (k < lowEnd) {
        pl += mag2;
      } else if (k < midEnd) {
        pm += mag2;
      } else {
        ph += mag2;
      }
    }
    powLow[f] = pl;
    powMid[f] = pm;
    powHigh[f] = ph;
    if (f > 0) {
      // SuperFlux-style: compare with a 3-bin max filter of the previous
      // frame, which suppresses vibrato and slow glides.
      double fl = 0, fm = 0, fh = 0;
      for (var k = 1; k < bins; k++) {
        final p = math.max(prev[k], math.max(prev[k - 1], k + 1 < bins ? prev[k + 1] : 0.0));
        final d = cur[k] - p;
        if (d <= 0) continue;
        if (k < lowEnd) {
          fl += d;
        } else if (k < midEnd) {
          fm += d;
        } else {
          fh += d;
        }
      }
      fluxLow[f] = fl;
      fluxMid[f] = fm;
      fluxHigh[f] = fh;
    }
    final t = prev;
    prev = cur;
    cur = t;
    if (onProgress != null && f % 512 == 0) onProgress(0.7 * f / frames);
  }

  // --- Onset detection function ----------------------------------------------
  final nLow = normalizeByPercentile(fluxLow, 0.97);
  final nMid = normalizeByPercentile(fluxMid, 0.97);
  final nHigh = normalizeByPercentile(fluxHigh, 0.97);
  final odfRaw = Float64List(frames);
  for (var f = 0; f < frames; f++) {
    odfRaw[f] = 0.4 * nLow[f] + 0.35 * nMid[f] + 0.25 * nHigh[f];
  }
  final odf = smooth3(odfRaw);
  onProgress?.call(0.75);

  final peaks = pickPeaks(odf, frameMs: frameMs);
  final peakValues = Float64List.fromList(peaks.map((p) => odf[p.frame]).toList());
  final strengthRef = math.max(1e-9, percentile(peakValues, 0.95));
  double bandAt(Float64List b, int f) {
    var m = 0.0;
    for (var i = math.max(0, f - 1); i <= math.min(b.length - 1, f + 1); i++) {
      m = math.max(m, b[i]);
    }
    return m;
  }

  final onsets = <Onset>[];
  for (final p in peaks) {
    final l = bandAt(nLow, p.frame), m = bandAt(nMid, p.frame), h = bandAt(nHigh, p.frame);
    final maxBand = math.max(l, math.max(m, h));
    onsets.add(Onset(
      timeMs: math.max(0, p.position * frameMs + onsetLatencyCompensationMs),
      strength: (odf[p.frame] / strengthRef).clamp(0.0, 1.0),
      low: maxBand > 0 ? (l / maxBand).clamp(0.0, 1.0) : 0,
      mid: maxBand > 0 ? (m / maxBand).clamp(0.0, 1.0) : 0,
      high: maxBand > 0 ? (h / maxBand).clamp(0.0, 1.0) : 0,
    ));
  }

  // --- Tempo and beat grid ---------------------------------------------------
  final lowEnvelope = Float64List(frames);
  for (var f = 0; f < frames; f++) {
    lowEnvelope[f] = nLow[f];
  }
  final tempo = estimateTempo(odf, frameMs: frameMs, lowEnvelope: lowEnvelope);
  onProgress?.call(0.85);

  // --- Energy curves ----------------------------------------------------------
  final energy = _rmsCurve(samples, sampleRate, config.energyResolutionMs);
  final framesPerBucket = config.energyResolutionMs / frameMs;
  List<double> bandCurve(Float64List pow) {
    final buckets = energy.length;
    final out = Float64List(buckets);
    for (var b = 0; b < buckets; b++) {
      final a = (b * framesPerBucket).floor();
      final e = math.min(frames, ((b + 1) * framesPerBucket).ceil());
      var s = 0.0;
      for (var i = a; i < e; i++) {
        s += pow[i];
      }
      out[b] = e > a ? math.sqrt(s / (e - a)) : 0;
    }
    return loudnessCurve(out);
  }

  final eLow = bandCurve(powLow);
  final eMid = bandCurve(powMid);
  final eHigh = bandCurve(powHigh);
  onProgress?.call(0.92);

  // --- Sustained regions --------------------------------------------------------
  final sustains = <SustainRegion>[
    ..._sustains(onsets, powLow, nLow, Band.low, frameMs),
    ..._sustains(onsets, powMid, nMid, Band.mid, frameMs),
  ]..sort((a, b) => a.startMs.compareTo(b.startMs));
  onProgress?.call(1.0);

  return SongAnalysis(
    sampleRate: sampleRate,
    hopSize: hop,
    durationMs: durationMs,
    bpm: tempo.bpm,
    beatOffsetMs: tempo.offsetMs,
    tempoConfidence: tempo.confidence,
    barOffsetBeats: tempo.barOffsetBeats,
    onsets: onsets,
    energyResolutionMs: config.energyResolutionMs,
    energy: energy,
    energyLow: eLow,
    energyMid: eMid,
    energyHigh: eHigh,
    sustains: sustains,
    waveformResolutionMs: config.waveformResolutionMs,
    waveform: waveform,
  );
}

List<double> _waveformPeaks(Float32List s, int sr, double resMs) {
  final per = math.max(1, (sr * resMs / 1000).round());
  final count = (s.length / per).ceil();
  final out = List<double>.filled(count, 0);
  var globalMax = 1e-9;
  for (var b = 0; b < count; b++) {
    var m = 0.0;
    final end = math.min(s.length, (b + 1) * per);
    for (var i = b * per; i < end; i++) {
      final v = s[i].abs();
      if (v > m) m = v;
    }
    out[b] = m;
    if (m > globalMax) globalMax = m;
  }
  for (var i = 0; i < count; i++) {
    out[i] = out[i] / globalMax;
  }
  return out;
}

List<double> _rmsCurve(Float32List s, int sr, double resMs) {
  final per = math.max(1, (sr * resMs / 1000).round());
  final count = math.max(1, (s.length / per).ceil());
  final rms = Float64List(count);
  for (var b = 0; b < count; b++) {
    var sum = 0.0;
    final start = b * per;
    final end = math.min(s.length, start + per);
    for (var i = start; i < end; i++) {
      sum += s[i] * s[i];
    }
    rms[b] = end > start ? math.sqrt(sum / (end - start)) : 0;
  }
  return loudnessCurve(rms);
}

/// Finds onsets whose band energy holds up after the attack. The reference
/// level is taken ~90 ms after the onset, once drum transients have decayed,
/// and the region ends when energy falls below -8 dB of it (brief dips are
/// tolerated) or the band is re-articulated by a comparably strong onset.
List<SustainRegion> _sustains(
  List<Onset> onsets,
  Float64List power,
  Float64List bandFlux,
  Band band,
  double frameMs,
) {
  final out = <SustainRegion>[];
  final frames = power.length;
  final smoothPow = smooth3(smooth3(power));
  final refOffset = (90 / frameMs).round();
  final maxDip = (40 / frameMs).round();
  final minRearticulationFrames = (130 / frameMs).round();
  for (var i = 0; i < onsets.length; i++) {
    final o = onsets[i];
    final bandShare = band == Band.low ? o.low : o.mid;
    if (o.strength < 0.12 || bandShare < 0.4) continue;
    final f0 = (o.timeMs / frameMs).round();
    final ref = f0 + refOffset;
    if (ref >= frames) continue;
    final eRef = smoothPow[ref];
    if (eRef <= 1e-9) continue;
    var refFlux = 0.0;
    for (var k = math.max(0, f0 - 2); k <= math.min(frames - 1, f0 + 2); k++) {
      refFlux = math.max(refFlux, bandFlux[k]);
    }
    var f = ref;
    var lastGood = ref;
    while (f + 1 < frames) {
      f++;
      if (f - f0 > minRearticulationFrames &&
          bandFlux[f] > 0.6 * refFlux &&
          _isLocalMax(bandFlux, f)) {
        break;
      }
      if (smoothPow[f] >= 0.16 * eRef) {
        lastGood = f;
      } else if (f - lastGood > maxDip) {
        break;
      }
    }
    final endMs = lastGood * frameMs;
    if (endMs - o.timeMs >= 260) {
      out.add(SustainRegion(startMs: o.timeMs, endMs: endMs, band: band, strength: o.strength));
    }
  }
  return out;
}

bool _isLocalMax(Float64List x, int i) {
  final a = i > 0 ? x[i - 1] : 0.0;
  final b = i + 1 < x.length ? x[i + 1] : 0.0;
  return x[i] >= a && x[i] >= b;
}
