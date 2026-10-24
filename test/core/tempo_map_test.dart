import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhytmaniac/core/analysis/analyzer.dart';
import 'package:rhytmaniac/core/analysis/beat_fit.dart';
import 'package:rhytmaniac/core/analysis/tempo.dart';
import 'package:rhytmaniac/core/generator/beatmap_generator.dart';
import 'package:rhytmaniac/core/models/analysis.dart';
import 'package:rhytmaniac/core/models/beatmap.dart';
import 'package:rhytmaniac/core/models/difficulty.dart';
import 'package:rhytmaniac/core/models/timing.dart';

const sr = 22050;

/// Drum-machine sections: kick and snare on beats, hats on every
/// subdivision (4 = sixteenths, 3 = triplets), a pitched pluck on each hat.
Float32List synth(List<(double seconds, double bpm, int subs)> parts, {double leadIn = 0.5}) {
  final total = leadIn + parts.fold(0.0, (s, p) => s + p.$1) + 1;
  final out = Float32List((total * sr).round());
  final rng = math.Random(4);
  void add(double at, double Function(double t) f, double len) {
    final i0 = (at * sr).round();
    for (var i = 0; i < len * sr && i0 + i < out.length; i++) {
      out[i0 + i] += f(i / sr);
    }
  }

  var t = leadIn;
  var k = 0;
  for (final (seconds, bpm, subs) in parts) {
    final beat = 60 / bpm;
    final end = t + seconds;
    while (t < end - 1e-6) {
      if (k.isEven) {
        add(t, (x) => math.sin(2 * math.pi * (50 + 110 * math.exp(-x * 30)) * x) * math.exp(-x * 9) * 0.9, 0.3);
      } else {
        add(t, (x) => (rng.nextDouble() * 2 - 1) * math.exp(-x * 20) * 0.5, 0.2);
      }
      for (var s = 0; s < subs; s++) {
        final at = t + s * beat / subs;
        add(at, (x) => (rng.nextDouble() * 2 - 1) * math.exp(-x * 90) * 0.25, 0.05);
        final hz = 220.0 * math.pow(2, ((k * subs + s) % 7) / 12);
        add(at, (x) => math.sin(2 * math.pi * hz * x) * math.exp(-x * 14) * 0.3, 0.18);
      }
      t += beat;
      k++;
    }
  }
  return out;
}

void main() {
  test('a steady straight song keeps a single grid', () {
    final a = analyzePcm(synth([(40, 128, 4)]), sr);
    expect(a.timingPoints, isEmpty);
    expect(a.bpm, closeTo(128, 0.6));
  });

  test('finds a tempo change and places sections on beats', () {
    final a = analyzePcm(synth([(32, 120, 4), (32, 150, 4)]), sr);
    expect(a.timingPoints.length, 2, reason: '${a.timingPoints}');
    final first = a.timingPoints[0], second = a.timingPoints[1];
    expect(first.bpm, closeTo(120, 1.2));
    expect(second.bpm, closeTo(150, 1.5));
    // The change is at 32.5 s; the second section starts within a beat of it.
    expect(second.timeMs, closeTo(32500, 500));
    // Beats of the second section land on the generated kicks/snares.
    final beat2 = 60000 / 150;
    final k = ((40000 - second.timeMs) / second.beatLengthMs).round();
    final predicted = second.timeMs + k * second.beatLengthMs;
    final nearestTrue = 32500 + ((predicted - 32500) / beat2).round() * beat2;
    expect((predicted - nearestTrue).abs(), lessThan(25));

    // Generated maps follow the new grid.
    final map = BeatmapGenerator.generate(
      analysis: a,
      songId: 's',
      mode: GameMode.tiles,
      params: DifficultyParams.preset(GameMode.tiles, DifficultyPreset.hard),
      seed: 1,
      metadata: const BeatmapMetadata(title: '', artist: '', creator: ''),
    );
    expect(map.timing.length, 2);
    final grid = BeatGrid(map.timing);
    for (final n in map.tileNotes) {
      final p = grid.at(n.timeMs);
      final x = (n.timeMs - p.timeMs) / (p.beatLengthMs / 4);
      expect((x - x.round()).abs(), lessThan(0.02), reason: 'note at ${n.timeMs} off the grid');
    }
  });

  test('the single-tempo summary keeps the downbeats of the section it describes', () {
    // The second section is the longest and starts an odd number of its
    // beats after 0 (61), where counting the wrong way lands 2 beats off.
    final a = analyzePcm(synth([(24.5, 120, 4), (40, 150, 4)]), sr);
    expect(a.timingPoints.length, 2, reason: '${a.timingPoints}');
    final described = a.timingPoints.last;
    expect((described.timeMs / described.beatLengthMs).floor().isOdd, isTrue);
    expect(a.bpm, described.bpm);
    final sectionDownbeat = described.timeMs + described.barOffsetBeats * described.beatLengthMs;
    final beats = ((sectionDownbeat - a.firstDownbeatMs) / described.beatLengthMs).round();
    expect(beats % 4, 0, reason: 'summary downbeat ${a.firstDownbeatMs} vs section $described');
  });

  test('marks a shuffle (triplet) part and snaps its notes to thirds', () {
    final a = analyzePcm(synth([(30, 110, 4), (36, 110, 3)]), sr);
    expect(a.timingPoints, isNotEmpty);
    final last = a.timingPoints.last;
    expect(last.triplet, isTrue, reason: '${a.timingPoints}');
    expect(a.timingPoints.first.triplet, isFalse);

    final map = BeatmapGenerator.generate(
      analysis: a,
      songId: 's',
      mode: GameMode.circles,
      params: DifficultyParams.preset(GameMode.circles, DifficultyPreset.insane),
      seed: 3,
      metadata: const BeatmapMetadata(title: '', artist: '', creator: ''),
    );
    var thirds = 0;
    for (final o in map.circleObjects.where((o) => o.timeMs > last.timeMs + 1000)) {
      final x = (o.timeMs - last.timeMs) / (last.beatLengthMs / 3);
      expect((x - x.round()).abs(), lessThan(0.02));
      if (x.round() % 3 != 0) thirds++;
    }
    expect(thirds, greaterThan(5), reason: 'off-beat notes should land on triplet positions');
  });

  group('refineTempo keeps the downbeat when the first beat moves', () {
    // Beats every 500 ms on -2 + k × 500, downbeats (strong) on k = 0, 4, 8…
    // The comb said the first beat is at 3 ms and beat 0 is a downbeat; the
    // fit pulls it to -2, so the first beat at or after 0 becomes 498 ms.
    List<Onset> onsets(double first) => [
          for (var k = 0; k < 64; k++)
            if (first + k * 500 >= 0)
              Onset(timeMs: first + k * 500, strength: k % 4 == 0 ? 1.0 : 0.5, low: 1, mid: 0, high: 0),
        ];

    test('first beat moves later', () {
      final r = refineTempo(
        const TempoEstimate(bpm: 120, offsetMs: 3, confidence: 1, barOffsetBeats: 0),
        onsets(-2),
      );
      expect(r.offsetMs, closeTo(498, 0.5));
      // Downbeats on 1998, 3998, …: beat 3 after 498.
      expect(r.barOffsetBeats, 3);
    });

    test('first beat moves earlier', () {
      // Beats on 2 + k × 500, downbeats on 2, 2002, …. The comb put the
      // first beat at 497 (so 2002 is its beat 3); the fit lands on 502 and
      // the first beat wraps back to 2, a downbeat.
      final r = refineTempo(
        const TempoEstimate(bpm: 120, offsetMs: 497, confidence: 1, barOffsetBeats: 3),
        onsets(2),
      );
      expect(r.offsetMs, closeTo(2, 0.5));
      expect(r.barOffsetBeats, 0);
    });
  });
}
