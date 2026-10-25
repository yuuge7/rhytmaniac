import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhytmaniac/core/analysis/analyzer.dart';
import 'package:rhytmaniac/core/generator/beatmap_generator.dart';
import 'package:rhytmaniac/core/models/analysis.dart';
import 'package:rhytmaniac/core/models/beatmap.dart';
import 'package:rhytmaniac/core/models/difficulty.dart';

import 'synth.dart';

/// Four on the floor: kick on every beat, open hat on every off-beat,
/// claps on 2 and 4. The hats' sharp attacks used to pull the grid onto
/// the off-beats.
SynthSong house({double bpm = 128, double seconds = 60, bool offbeatBass = false}) {
  final s = SynthSong(seconds);
  final beat = 60000 / bpm;
  var k = 0;
  for (var t = 400.0; t < seconds * 1000 - 500; t += beat, k++) {
    s.kick(t);
    s.hat(t + beat / 2, open: true, gain: 0.45);
    if (k % 2 == 1) s.snare(t, gain: 0.4);
    if (offbeatBass) s.tone(t + beat / 2, beat * 0.4, 55, gain: 0.3);
  }
  return s;
}

/// A band-like groove on beats from [beats]: kick on 1 and 3, snare on 2
/// and 4, closed hats on eighths, a held bass note per bar and a lead
/// with held notes that climbs and falls.
SynthSong groove(List<double> beats, double seconds, {int seed = 5}) {
  final s = SynthSong(seconds, seed: seed);
  const lead = [440.0, 494.0, 554.0, 659.0, 740.0, 659.0, 554.0, 494.0];
  for (var k = 0; k + 1 < beats.length; k++) {
    final t = beats[k], len = beats[k + 1] - t;
    if (k % 2 == 0) {
      s.kick(t);
    } else {
      s.snare(t);
    }
    s.hat(t, gain: 0.18);
    s.hat(t + len / 2, gain: 0.18);
    if (k % 4 == 0) s.tone(t, len * 3.6, k % 8 == 0 ? 55 : 73.4, gain: 0.25);
    if (k % 2 == 0) s.tone(t + len / 2, len * (k % 8 == 4 ? 1.4 : 0.4), lead[(k ~/ 2) % lead.length], gain: 0.16);
  }
  return s;
}

SongAnalysis analyze(SynthSong s) => analyzePcm(s.samples, s.sr);

/// Distance from [t] to the nearest beat of the analysis grid.
double gridError(SongAnalysis a, double t) {
  final g = a.grid;
  var best = double.infinity;
  for (final b in g.beats(t - 2000, t + 2000)) {
    best = math.min(best, (b - t).abs());
  }
  return best;
}

List<double> noteTimes(SongAnalysis a, DifficultyPreset preset) {
  final map = BeatmapGenerator.generate(
    analysis: a,
    songId: 's',
    mode: GameMode.tiles,
    params: DifficultyParams.preset(GameMode.tiles, preset),
    seed: 3,
    metadata: const BeatmapMetadata(title: '', artist: '', creator: ''),
  );
  return map.tileNotes.map((n) => n.timeMs).toList();
}

void main() {
  test('four on the floor: the grid sits on the kicks', () {
    for (final bass in [false, true]) {
      final s = house(offbeatBass: bass);
      final a = analyze(s);
      final kickErr = gridError(a, 400 + 60000 / 128 * 40);
      // ignore: avoid_print
      expect(a.timingPoints, isEmpty, reason: 'a steady song keeps one grid');
      // ignore: avoid_print
      print('house bass=$bass: bpm=${a.bpm.toStringAsFixed(2)} kick→grid ${kickErr.toStringAsFixed(1)} ms');
      expect(a.bpm, closeTo(128, 0.3));
      expect(kickErr, lessThan(15), reason: 'offbeat bass: $bass');
    }
  });

  test('a tempo between whole numbers stays on the beat to the end', () {
    const bpm = 127.37, seconds = 150.0;
    final beats = SynthSong.beats(startMs: 300, endMs: seconds * 1000 - 600, bpmAt: (_) => bpm);
    final s = groove(beats, seconds);
    final a = analyze(s);
    final errs = [for (final b in beats.skip(beats.length - 16)) gridError(a, b)];
    final worst = errs.reduce(math.max);
    final hard = fractionNear(noteTimes(a, DifficultyPreset.hard), s.events, 12);
    // ignore: avoid_print
    print('127.37: offset=${a.beatOffsetMs.toStringAsFixed(1)} (kicks at 300 + k·942.1) bpm=${a.bpm.toStringAsFixed(3)} last beats off by ≤ ${worst.toStringAsFixed(1)} ms; hard notes on a sound: ${(hard * 100).toStringAsFixed(1)}%');
    expect(worst, lessThan(8));
    expect(a.timingPoints, isEmpty, reason: 'a steady song keeps one grid');
    expect(hard, greaterThan(0.95));
  });

  test('a band that speeds up a little stays on the beat', () {
    const seconds = 150.0;
    double bpmAt(double ms) => 118 + 4 * ms / (seconds * 1000);
    final beats = SynthSong.beats(startMs: 300, endMs: seconds * 1000 - 600, bpmAt: bpmAt);
    final s = groove(beats, seconds, seed: 9);
    final a = analyze(s);
    final errs = [for (final b in beats) gridError(a, b)]..sort();
    final p90 = errs[(errs.length * 0.9).floor()];
    final hard = fractionNear(noteTimes(a, DifficultyPreset.hard), s.events, 12);
    // ignore: avoid_print
    print('118→122: sections=${a.timingPoints.length} p90 beat error ${p90.toStringAsFixed(1)} ms; hard notes on a sound: ${(hard * 100).toStringAsFixed(1)}%');
    expect(p90, lessThan(15));
    expect(hard, greaterThan(0.9));
  });

  test('fast runs follow the melody and long sounds become holds', () {
    const bpm = 130.0, seconds = 64.0;
    final beat = 60000 / bpm;
    final s = SynthSong(seconds, seed: 11);
    const scale = [262.0, 294.0, 330.0, 349.0, 392.0, 440.0, 494.0, 523.0];
    final pads = <double>[];
    var k = 0;
    for (var t = 400.0; t < seconds * 1000 - 2000; t += beat, k++) {
      final bar = k ~/ 4;
      // Drums under the held chords; the runs play on their own.
      if (bar % 4 >= 2) {
        s.kick(t);
        if (k % 2 == 1) s.snare(t, gain: 0.35);
      }
      if (bar % 4 < 2) {
        // Eighth-note runs: up the scale in one bar, down in the next.
        for (var e = 0; e < 2; e++) {
          final step = (k % 4) * 2 + e;
          final note = bar % 2 == 0 ? scale[step] : scale[7 - step];
          s.tone(t + e * beat / 2, beat * 0.35, note, gain: 0.2);
        }
      } else if (k % 4 == 0) {
        // Held chords: a long sound every bar.
        s.tone(t, beat * 3.5, 196, gain: 0.3);
        pads.add(t);
      }
    }
    final a = analyze(s);
    // Lanes and holds are drawn at random, and one map has only 16 pads, so
    // a single seed swings a lot (rounding differences between platforms are
    // enough to land on a bad one). Pool several seeds.
    var agree = 0, total = 0, holdsOnPads = 0, notedPads = 0;
    for (final seed in [1, 3, 7, 42]) {
      final map = BeatmapGenerator.generate(
        analysis: a,
        songId: 's',
        mode: GameMode.tiles,
        params: DifficultyParams.preset(GameMode.tiles, DifficultyPreset.hard),
        seed: seed,
        metadata: const BeatmapMetadata(title: '', artist: '', creator: ''),
      );
      final notes = map.tileNotes;
      // Consecutive single notes half a beat apart inside the runs: does the
      // lane move the way the pitch does?
      for (var i = 1; i < notes.length; i++) {
        final x = notes[i - 1], y = notes[i];
        if ((y.timeMs - x.timeMs - beat / 2).abs() > 5 || x.lane == y.lane) continue;
        final ox = a.onsets.where((o) => (o.timeMs - x.timeMs).abs() < 25 && o.tone != null).toList();
        final oy = a.onsets.where((o) => (o.timeMs - y.timeMs).abs() < 25 && o.tone != null).toList();
        if (ox.isEmpty || oy.isEmpty) continue;
        final dTone = oy.last.tone! - ox.last.tone!;
        if (dTone.abs() < 0.015) continue;
        // At the edge of the field a climb has to turn back.
        if (dTone > 0 ? x.lane == 3 : x.lane == 0) continue;
        total++;
        if ((y.lane > x.lane) == (dTone > 0)) agree++;
      }
      holdsOnPads += pads.where((t) => notes.any((n) => n.isHold && (n.timeMs - t).abs() < 15)).length;
      notedPads += pads.where((t) => notes.any((n) => (n.timeMs - t).abs() < 15)).length;
    }
    // ignore: avoid_print
    print('melody: lane follows pitch $agree/$total; held sounds as holds $holdsOnPads/$notedPads');
    expect(total, greaterThan(60));
    expect(agree / total, greaterThan(0.8));
    expect(holdsOnPads / notedPads, greaterThan(0.6));
  });

  test('ornaments between grid slots do not become notes', () {
    const bpm = 120.0, seconds = 60.0;
    final beats = SynthSong.beats(startMs: 500, endMs: seconds * 1000 - 600, bpmAt: (_) => bpm);
    final s = groove(beats, seconds, seed: 4);
    // A grace note an eighth of a beat after every fourth beat.
    final graces = <double>[];
    for (var k = 3; k < beats.length; k += 4) {
      final t = beats[k] + 500 / 8;
      s.hat(t, open: true, gain: 0.5);
      graces.add(t);
    }
    final a = analyze(s);
    final truth = s.events.where((e) => !graces.contains(e)).toList();
    final expert = noteTimes(a, DifficultyPreset.expert);
    final onSound = fractionNear(expert, s.events, 12);
    final offSlot = expert.where((t) => fractionNear([t], truth, 12) == 0).length;
    // ignore: avoid_print
    print('graces: expert notes on a sound ${(onSound * 100).toStringAsFixed(1)}%, notes away from the real beats $offSlot');
    expect(onSound, greaterThan(0.97));
  });
}
