import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

import '../models/analysis.dart';
import '../models/timing.dart';
import 'beat_fit.dart';
import 'dsp.dart';
import 'tempo.dart';
import 'tempo_map.dart';

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

  // Where each frame's new energy arrives: the mean log-frequency of the
  // bins that got louder, weighted by how much louder (linear magnitude),
  // between 40 Hz and 10 kHz. Onsets take it as their [Onset.tone].
  final toneLo = math.max(1, (40 / binHz).ceil());
  final toneHi = math.min(bins - 1, (10000 / binHz).floor());
  final log2Hz = Float64List(bins);
  for (var k = 1; k < bins; k++) {
    log2Hz[k] = math.log(k * binHz) / math.ln2;
  }
  final toneSum = Float64List(frames);
  final toneWeight = Float64List(frames);
  var prevMag = Float64List(bins);
  var curMag = Float64List(bins);
  // A compact spectrogram of 40 Hz .. 2.5 kHz, where held notes live, for
  // following sustained sounds through the drums.
  final specLo = math.max(1, (40 / binHz).floor());
  final specHi = math.min(bins - 1, (2500 / binHz).ceil());
  final specBins = specHi - specLo + 1;
  final spectrogram = Float32List(frames * specBins);

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
      curMag[k] = mag;
      if (k >= specLo && k <= specHi) spectrogram[f * specBins + k - specLo] = mag;
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
      double ts = 0, tw = 0;
      for (var k = toneLo; k <= toneHi; k++) {
        final dm = curMag[k] - prevMag[k];
        if (dm <= 0) continue;
        ts += dm * log2Hz[k];
        tw += dm;
      }
      toneSum[f] = ts;
      toneWeight[f] = tw;
    }
    final t = prev;
    prev = cur;
    cur = t;
    final tm = prevMag;
    prevMag = curMag;
    curMag = tm;
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

  final lowestTone = math.log(40) / math.ln2, highestTone = math.log(10000) / math.ln2;
  double? toneAt(int f) {
    double s = 0, w = 0;
    for (var i = math.max(0, f - 1); i <= math.min(frames - 1, f + 1); i++) {
      s += toneSum[i];
      w += toneWeight[i];
    }
    if (w <= 1e-12) return null;
    return ((s / w - lowestTone) / (highestTone - lowestTone)).clamp(0.0, 1.0);
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
      tone: toneAt(p.frame),
    ));
  }

  // --- Tempo and beat grid ---------------------------------------------------
  // Tempo reads a log-compressed envelope: a few huge hits (a kick on a bass
  // note every bar) must not drown out the snares that carry the beats in
  // between, or the song reads at half its tempo.
  double compress(double x) => math.log(1 + 2 * x) / math.log(3);
  final lowEnvelope = Float64List(frames);
  final midEnvelope = Float64List(frames);
  final tempoRaw = Float64List(frames);
  for (var f = 0; f < frames; f++) {
    lowEnvelope[f] = compress(nLow[f]);
    midEnvelope[f] = compress(nMid[f]);
    tempoRaw[f] = 0.4 * lowEnvelope[f] + 0.35 * midEnvelope[f] + 0.25 * compress(nHigh[f]);
  }
  final tempoOdf = smooth3(tempoRaw);
  // The comb search finds the tempo; the onsets on its beats then pin it down.
  final tempo = refineTempo(
    estimateTempo(tempoOdf, frameMs: frameMs, lowEnvelope: lowEnvelope, midEnvelope: midEnvelope),
    onsets,
  );
  onProgress?.call(0.8);
  // Tempo changes and triplet parts. Empty for a straight single tempo.
  final sections = detectTimingSections(
    odf: tempoOdf,
    frameMs: frameMs,
    global: tempo,
    onsets: onsets,
    durationMs: durationMs,
    lowEnvelope: lowEnvelope,
  );
  // A steady tempo that wanders a little (a band without a click) gets
  // timing points that follow it; the summary still describes the whole.
  final drift = sections.isEmpty ? followDrift(tempo, onsets, durationMs) : const <TimingPoint>[];
  var bpm = tempo.bpm, beatOffset = tempo.offsetMs, barOffset = tempo.barOffsetBeats;
  if (sections.length > 1) {
    // Summary values describe the longest section.
    var longest = 0, longestMs = -1.0;
    for (var i = 0; i < sections.length; i++) {
      final end = i + 1 < sections.length ? sections[i + 1].timeMs : durationMs;
      if (end - sections[i].timeMs > longestMs) {
        longestMs = end - sections[i].timeMs;
        longest = i;
      }
    }
    final s = sections[longest];
    bpm = s.bpm;
    beatOffset = s.timeMs % s.beatLengthMs;
    barOffset = ((s.barOffsetBeats - (s.timeMs / s.beatLengthMs).floor()) % 4 + 4) % 4;
  }
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
    ..._tonalSustains(onsets, spectrogram, specBins, specLo, binHz, frameMs),
  ]..sort((a, b) => a.startMs.compareTo(b.startMs));
  onProgress?.call(1.0);

  return SongAnalysis(
    sampleRate: sampleRate,
    hopSize: hop,
    durationMs: durationMs,
    bpm: bpm,
    beatOffsetMs: beatOffset,
    tempoConfidence: tempo.confidence,
    barOffsetBeats: barOffset,
    timingPoints: sections.isNotEmpty ? sections : drift,
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

/// Follows held notes by their spectral peaks. A band's energy (what
/// [_sustains] watches) jumps at every drum hit, which cut held vocals and
/// pads into one-beat pieces; the peaks of a held tone just keep sounding
/// under the drums. For each onset that starts a new tonal sound, the
/// strongest peaks ~90 ms in are followed until they fade below -10 dB,
/// or the same pitch is struck again.
List<SustainRegion> _tonalSustains(
  List<Onset> onsets,
  Float32List spec,
  int width,
  int firstBin,
  double binHz,
  double frameMs,
) {
  final frames = spec.length ~/ width;
  final out = <SustainRegion>[];
  final refOffset = (90 / frameMs).round();
  final maxDip = (45 / frameMs).round();
  final minRestrike = (130 / frameMs).round();
  double at(int f, int i) {
    final base = f * width;
    var m = spec[base + i];
    if (i > 0 && spec[base + i - 1] > m) m = spec[base + i - 1];
    if (i + 1 < width && spec[base + i + 1] > m) m = spec[base + i + 1];
    return m;
  }

  final row = Float64List(width);
  for (final o in onsets) {
    if (o.strength < 0.12) continue;
    final f0 = (o.timeMs / frameMs).round();
    final ref = f0 + refOffset;
    if (f0 < 3 || ref >= frames - 2) continue;
    for (var i = 0; i < width; i++) {
      row[i] = spec[ref * width + i];
    }
    // Tonal peaks: local maxima well above the frame's median.
    final sorted = List<double>.of(row)..sort();
    final median = sorted[width ~/ 2];
    final peaks = <int>[];
    for (var i = 1; i + 1 < width; i++) {
      if (row[i] > row[i - 1] && row[i] >= row[i + 1] && row[i] > median * 6) peaks.add(i);
    }
    if (peaks.isEmpty) continue;
    peaks.sort((x, y) => row[y].compareTo(row[x]));
    final top = peaks.take(3).where((i) => row[i] >= row[peaks.first] * 0.25).toList();
    double level(int f) => top.fold(0.0, (s, i) => s + at(f, i));
    // How much the main peak stands out from the bins around it: a new
    // strike of the same note keeps it sharp, a drum smears energy over
    // the neighbourhood.
    final main = top.first;
    double sharpness(int f) {
      var sum = 0.0;
      var n = 0;
      for (var i = math.max(0, main - 5); i <= math.min(width - 1, main + 5); i++) {
        if ((i - main).abs() <= 1) continue;
        sum += spec[f * width + i];
        n++;
      }
      return n == 0 ? 0 : at(f, main) / math.max(1e-9, sum / n);
    }

    final refSharpness = sharpness(ref);
    final e = level(ref);
    if (e <= 1e-9) continue;
    // Only a sound that starts here: those peaks were quiet just before.
    if (level(f0 - 2) > e * 0.5) continue;

    var lastGood = ref;
    for (var f = ref + 1; f < frames; f++) {
      final l = level(f);
      if (f - f0 > minRestrike && l > e * 0.5 && l > level(f - 2) * 1.6 && sharpness(f) >= refSharpness * 0.8) break;
      if (l >= e * 0.32) {
        lastGood = f;
      } else if (f - lastGood > maxDip) {
        break;
      }
    }
    final endMs = lastGood * frameMs;
    if (endMs - o.timeMs < 260) continue;
    final hz = (firstBin + top.first) * binHz;
    out.add(SustainRegion(startMs: o.timeMs, endMs: endMs, band: hz < 200 ? Band.low : Band.mid, strength: o.strength));
  }
  return out;
}

bool _isLocalMax(Float64List x, int i) {
  final a = i > 0 ? x[i - 1] : 0.0;
  final b = i + 1 < x.length ? x[i + 1] : 0.0;
  return x[i] >= a && x[i] >= b;
}
