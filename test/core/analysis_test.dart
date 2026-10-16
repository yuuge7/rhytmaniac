import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhytmaniac/core/analysis/analyzer.dart';
import 'package:rhytmaniac/core/analysis/dsp.dart';
import 'package:rhytmaniac/core/audio/pcm.dart';
import 'package:rhytmaniac/core/models/analysis.dart';

/// Click track: short decaying noise bursts on every beat.
Float32List clickTrack({
  required double bpm,
  required double offsetMs,
  required double seconds,
  int sr = analysisSampleRate,
  double accentEvery = 4,
}) {
  final out = Float32List((seconds * sr).round());
  final rnd = math.Random(3);
  final beat = 60000 / bpm;
  var k = 0;
  for (var t = offsetMs; t < seconds * 1000; t += beat, k++) {
    final start = (t * sr / 1000).round();
    final gain = k % accentEvery == 0 ? 0.9 : 0.6;
    for (var i = 0; i < sr * 0.04 && start + i < out.length; i++) {
      final env = math.exp(-i / (sr * 0.006));
      out[start + i] += gain * env * (rnd.nextDouble() * 2 - 1) +
          gain * env * math.sin(2 * math.pi * 120 * i / sr);
    }
  }
  return out;
}

void main() {
  group('dsp', () {
    test('percentile interpolates', () {
      expect(percentile([1, 2, 3, 4, 5], 0.5), 3);
      expect(percentile([0, 10], 0.25), 2.5);
    });

    test('loudness curve maps top to 1 and silence to 0', () {
      final curve = loudnessCurve([0, 0.001, 0.5, 0.5, 0.5]);
      expect(curve.first, 0);
      expect(curve.last, closeTo(1, 1e-9));
    });

    test('wav round trip', () {
      final s = Float32List.fromList(List.generate(2205, (i) => math.sin(i / 10) * 0.5));
      final wav = encodeWav16(s, 22050);
      final back = decodeWav(wav);
      expect(back.sampleRate, 22050);
      expect(back.samples.length, s.length);
      expect(back.samples[100], closeTo(s[100], 1e-3));
    });

    test('resampling halves length', () {
      final s = Float32List(44100);
      expect(resampleLinear(s, 44100, 22050).length, 22050);
    });
  });

  group('analyzer on click tracks', () {
    for (final bpm in [92.0, 128.0, 174.0]) {
      test('detects $bpm BPM and onsets', () {
        const offset = 350.0;
        final pcm = clickTrack(bpm: bpm, offsetMs: offset, seconds: 30);
        final a = analyzePcm(pcm, analysisSampleRate);
        expect(a.bpm, closeTo(bpm, 0.5), reason: 'bpm');
        final beat = 60000 / bpm;
        final phaseErr = ((a.beatOffsetMs - offset) % beat + beat) % beat;
        expect(math.min(phaseErr, beat - phaseErr), lessThan(12), reason: 'beat phase');

        // Every click is found within 15 ms, with few false positives.
        var matched = 0;
        var expected = 0;
        for (var t = offset; t < 29500; t += beat) {
          expected++;
          if (a.onsets.any((o) => (o.timeMs - t).abs() < 15)) matched++;
        }
        expect(matched / expected, greaterThan(0.95));
        expect(a.onsets.length, lessThan(expected * 1.3));
      });
    }

    test('json round trip keeps data', () {
      final a = analyzePcm(clickTrack(bpm: 120, offsetMs: 0, seconds: 8), analysisSampleRate);
      final b = SongAnalysis.fromJson(a.toJson());
      expect(b.bpm, closeTo(a.bpm, 1e-3));
      expect(b.onsets.length, a.onsets.length);
      expect(b.energy.length, a.energy.length);
      expect(b.formatVersion, SongAnalysis.currentFormatVersion);
    });
  });

  test('analyzes the bundled demo song', () {
    final bytes = File('assets/audio/ember_drift.wav').readAsBytesSync();
    final pcm = decodeWav(bytes);
    final sw = Stopwatch()..start();
    final a = analyzePcm(pcm.samples, pcm.sampleRate);
    // ignore: avoid_print
    print('demo: bpm=${a.bpm.toStringAsFixed(2)} offset=${a.beatOffsetMs.toStringAsFixed(1)} '
        'conf=${a.tempoConfidence.toStringAsFixed(2)} bar=${a.barOffsetBeats} '
        'onsets=${a.onsets.length} sustains=${a.sustains.length} in ${sw.elapsedMilliseconds}ms');
    expect(a.bpm, closeTo(128, 0.5));
    final beat = 60000 / 128;
    final phaseErr = ((a.beatOffsetMs - 500) % beat + beat) % beat;
    expect(math.min(phaseErr, beat - phaseErr), lessThan(15));
    expect(a.sustains, isNotEmpty);
  });
}
