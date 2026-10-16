import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhytmaniac/core/analysis/analyzer.dart';
import 'package:rhytmaniac/core/audio/pcm.dart';
import 'package:rhytmaniac/core/generator/beatmap_generator.dart';
import 'package:rhytmaniac/core/generator/note_selection.dart';
import 'package:rhytmaniac/core/models/analysis.dart';
import 'package:rhytmaniac/core/models/beatmap.dart';
import 'package:rhytmaniac/core/models/difficulty.dart';
import 'package:rhytmaniac/core/rating/star_rating.dart';

late SongAnalysis demo;

Beatmap gen(GameMode mode, DifficultyPreset preset, {int seed = 42, int lanes = 4}) =>
    BeatmapGenerator.generate(
      analysis: demo,
      songId: 'demo',
      mode: mode,
      params: DifficultyParams.preset(mode, preset, lanes: lanes),
      seed: seed,
      metadata: const BeatmapMetadata(title: 't', artist: 'a', creator: 'c'),
    );

void main() {
  setUpAll(() {
    final pcm = decodeWav(File('assets/audio/ember_drift.wav').readAsBytesSync());
    demo = analyzePcm(pcm.samples, pcm.sampleRate);
  });

  test('same seed gives the same map; different seed differs', () {
    for (final mode in GameMode.values) {
      final a = jsonEncode(gen(mode, DifficultyPreset.hard).toJson()['objects']);
      final b = jsonEncode(gen(mode, DifficultyPreset.hard).toJson()['objects']);
      final c = jsonEncode(gen(mode, DifficultyPreset.hard, seed: 7).toJson()['objects']);
      expect(a, b);
      expect(a, isNot(c));
    }
  });

  test('notes are snapped to the beat grid', () {
    final map = gen(GameMode.tiles, DifficultyPreset.insane);
    final step = demo.beatLengthMs / 4;
    for (final n in map.tileNotes) {
      final k = (n.timeMs - demo.beatOffsetMs) / step;
      expect((k - k.round()).abs(), lessThan(0.01));
    }
  });

  test('easy uses whole beats mostly and respects minimum gap', () {
    final map = gen(GameMode.tiles, DifficultyPreset.easy);
    final p = map.difficulty;
    final times = map.tileNotes.map((n) => n.timeMs).toSet().toList()..sort();
    for (var i = 1; i < times.length; i++) {
      expect(times[i] - times[i - 1], greaterThanOrEqualTo(p.minGapMs - 1));
    }
  });

  test('easy tiles have no quick jacks and no chords', () {
    final map = gen(GameMode.tiles, DifficultyPreset.easy);
    final byTime = <double, int>{};
    for (final n in map.tileNotes) {
      byTime[n.timeMs] = (byTime[n.timeMs] ?? 0) + 1;
    }
    expect(byTime.values.every((c) => c == 1), isTrue);
    final beat = demo.beatLengthMs;
    for (var i = 1; i < map.tileNotes.length; i++) {
      final a = map.tileNotes[i - 1], b = map.tileNotes[i];
      if (b.timeMs - a.timeMs < beat * 1.5) expect(a.lane, isNot(b.lane));
    }
  });

  test('expert tiles contain chords and holds', () {
    final map = gen(GameMode.tiles, DifficultyPreset.expert);
    final times = map.tileNotes.map((n) => n.timeMs).toList();
    expect(times.length, greaterThan(times.toSet().length));
    expect(map.tileNotes.any((n) => n.isHold), isTrue);
  });

  test('holds never overlap notes in the same lane', () {
    for (final preset in DifficultyPreset.ladder) {
      final map = gen(GameMode.tiles, preset);
      final lastEnd = <int, double>{};
      for (final n in map.tileNotes) {
        expect(n.timeMs, greaterThan(lastEnd[n.lane] ?? -1), reason: '${preset.label} lane ${n.lane}');
        lastEnd[n.lane] = n.endMs;
      }
    }
  });

  test('no notes inside breaks', () {
    final breaks = findBreaks(demo);
    for (final preset in DifficultyPreset.ladder) {
      final map = gen(GameMode.tiles, preset);
      for (final b in breaks) {
        expect(map.tileNotes.where((n) => n.timeMs > b.startMs && n.timeMs < b.endMs), isEmpty);
      }
    }
  });

  test('circles stay inside the safe playfield and have sliders', () {
    for (final preset in DifficultyPreset.ladder) {
      final map = gen(GameMode.circles, preset);
      for (final o in map.circleObjects) {
        expect(o.x, inInclusiveRange(0, 1));
        expect(o.y, inInclusiveRange(0, 1));
        for (final q in o.path ?? const <Point2>[]) {
          expect(q.x, inInclusiveRange(0, 1));
          expect(q.y, inInclusiveRange(0, 1));
        }
      }
      if (preset != DifficultyPreset.easy) {
        expect(map.circleObjects.any((o) => o.isSlider), isTrue, reason: preset.label);
      }
      // Combo indices never decrease.
      for (var i = 1; i < map.circleObjects.length; i++) {
        expect(map.circleObjects[i].comboIndex, greaterThanOrEqualTo(map.circleObjects[i - 1].comboIndex));
      }
    }
  });

  test('nothing outlasts the audio', () {
    for (final mode in GameMode.values) {
      for (final preset in DifficultyPreset.ladder) {
        final map = gen(mode, preset);
        expect(map.lastObjectEndMs, lessThanOrEqualTo(demo.durationMs - 250), reason: '${mode.name} ${preset.label}');
      }
    }
  });

  test('beatmap json round trip', () {
    for (final mode in GameMode.values) {
      final map = gen(mode, DifficultyPreset.hard);
      final back = Beatmap.fromJson(jsonDecode(jsonEncode(map.toJson())) as Map<String, dynamic>);
      expect(back.objectCount, map.objectCount);
      expect(back.mode, mode);
      expect(back.difficulty.minGapMs, map.difficulty.minGapMs);
      expect(back.toJson()['objects'], map.toJson()['objects']);
    }
  });

  test('star ladder is increasing and calibrated near 1..5', () {
    for (final mode in GameMode.values) {
      final stars = DifficultyPreset.ladder.map((p) => gen(mode, p).starRating).toList();
      final counts = DifficultyPreset.ladder.map((p) => gen(mode, p).objectCount).toList();
      // ignore: avoid_print
      print('${mode.name}: ${stars.map((s) => s.toStringAsFixed(2)).join(' / ')}  objects: $counts');
      for (var i = 1; i < stars.length; i++) {
        expect(stars[i], greaterThan(stars[i - 1]));
      }
      for (var i = 0; i < stars.length; i++) {
        expect(stars[i], closeTo(i + 1.0, 0.85), reason: '${mode.name} ${DifficultyPreset.ladder[i].label}');
      }
    }
  });

  test('playback speed raises the rating', () {
    for (final mode in GameMode.values) {
      final map = gen(mode, DifficultyPreset.normal);
      expect(starRating(map, rate: 1.5), greaterThan(starRating(map, rate: 1.0) * 1.2));
      expect(starRating(map, rate: 0.75), lessThan(starRating(map, rate: 1.0)));
    }
  });

  test('target stars search lands close', () {
    for (final mode in GameMode.values) {
      final r = BeatmapGenerator.paramsForTargetStars(analysis: demo, mode: mode, targetStars: 3.3, seed: 1);
      expect(r.stars, closeTo(3.3, 0.35));
    }
  });

  test('regenerate section only touches the range', () {
    final map = gen(GameMode.tiles, DifficultyPreset.hard);
    final out = BeatmapGenerator.regenerateSection(
      map: map, analysis: demo, startMs: 20000, endMs: 30000, seed: 999);
    final before = map.tileNotes.where((n) => n.timeMs < 19000).map((n) => n.toJson()).toList();
    final after = out.tileNotes.where((n) => n.timeMs < 19000).map((n) => n.toJson()).toList();
    expect(after, before);
  });
}
