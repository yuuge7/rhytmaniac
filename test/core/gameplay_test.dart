import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhytmaniac/core/gameplay/circles_session.dart';
import 'package:rhytmaniac/core/gameplay/tiles_session.dart';
import 'package:rhytmaniac/core/models/beatmap.dart';
import 'package:rhytmaniac/core/models/difficulty.dart';
import 'package:rhytmaniac/core/models/score.dart';
import 'package:rhytmaniac/core/scoring/score_processor.dart';
import 'package:rhytmaniac/core/timing/calibration.dart';
import 'package:rhytmaniac/core/timing/song_clock.dart';

Beatmap tilesMap(List<TileNote> notes, {int lanes = 4}) => Beatmap(
      id: 'm',
      songId: 's',
      mode: GameMode.tiles,
      name: 'test',
      metadata: const BeatmapMetadata(title: '', artist: '', creator: ''),
      difficulty: DifficultyParams.preset(GameMode.tiles, DifficultyPreset.normal, lanes: lanes),
      seed: 1,
      starRating: 1,
      createdAt: DateTime(2026),
      tileNotes: notes,
    );

Beatmap circlesMap(List<CircleObject> objs) => Beatmap(
      id: 'c',
      songId: 's',
      mode: GameMode.circles,
      name: 'test',
      metadata: const BeatmapMetadata(title: '', artist: '', creator: ''),
      difficulty: DifficultyParams.preset(GameMode.circles, DifficultyPreset.normal),
      seed: 1,
      starRating: 1,
      createdAt: DateTime(2026),
      circleObjects: objs,
    );

const windows = HitWindows(perfect: 40, great: 80, good: 120, miss: 160);

void main() {
  group('judge', () {
    const judge = Judge(windows);
    test('windows', () {
      expect(judge.judgePress(0), Judgment.perfect);
      expect(judge.judgePress(-40), Judgment.perfect);
      expect(judge.judgePress(60), Judgment.great);
      expect(judge.judgePress(-100), Judgment.good);
      expect(judge.judgePress(140), Judgment.miss);
      expect(judge.judgePress(-150), Judgment.miss);
      expect(judge.judgePress(-200), isNull);
    });

    test('hit window setting scales windows', () {
      final strict = DifficultyParams.preset(GameMode.tiles, DifficultyPreset.normal).copyWith(hitWindow: 10).windows;
      final lenient = DifficultyParams.preset(GameMode.tiles, DifficultyPreset.normal).copyWith(hitWindow: 0).windows;
      final normal = DifficultyParams.preset(GameMode.tiles, DifficultyPreset.normal).copyWith(hitWindow: 5).windows;
      expect(normal.perfect, closeTo(40, 1e-9));
      expect(strict.perfect, lessThan(normal.perfect));
      expect(lenient.good, greaterThan(normal.good));
    });
  });

  group('score processor', () {
    test('all perfect is 1,000,000 and SS', () {
      final p = ScoreProcessor(totalJudgments: 50);
      for (var i = 0; i < 50; i++) {
        p.apply(Judgment.perfect, errorMs: 0, timeMs: i * 100.0);
      }
      expect(p.score, 1000000);
      expect(p.accuracy, 1.0);
      expect(p.grade, Grade.ss);
      expect(p.maxCombo, 50);
    });

    test('miss breaks combo and drains health', () {
      final p = ScoreProcessor(totalJudgments: 10);
      p.apply(Judgment.perfect);
      p.apply(Judgment.perfect);
      p.apply(Judgment.miss);
      expect(p.combo, 0);
      expect(p.maxCombo, 2);
      expect(p.health, lessThan(1.0));
    });

    test('enough misses fail unless no-fail', () {
      final a = ScoreProcessor(totalJudgments: 40);
      final b = ScoreProcessor(totalJudgments: 40, noFail: true);
      for (var i = 0; i < 20; i++) {
        a.apply(Judgment.miss);
        b.apply(Judgment.miss);
      }
      expect(a.failed, isTrue);
      expect(b.failed, isFalse);
      expect(a.grade, Grade.f);
    });

    test('grades by accuracy', () {
      expect(Grade.fromAccuracy(0.99), Grade.ss);
      expect(Grade.fromAccuracy(0.95), Grade.s);
      expect(Grade.fromAccuracy(0.9), Grade.a);
      expect(Grade.fromAccuracy(0.82), Grade.b);
      expect(Grade.fromAccuracy(0.72), Grade.c);
      expect(Grade.fromAccuracy(0.5), Grade.d);
    });

    test('unstable rate and mean error', () {
      final p = ScoreProcessor(totalJudgments: 4);
      for (final e in [-10.0, 10.0, -10.0, 10.0]) {
        p.apply(Judgment.perfect, errorMs: e, timeMs: 0);
      }
      expect(p.meanError, 0);
      expect(p.unstableRate, closeTo(100, 1e-9));
    });
  });

  group('tiles session', () {
    test('tap judged by timing; late notes become misses', () {
      final s = TilesSession(
        map: tilesMap(const [TileNote(timeMs: 1000, lane: 0), TileNote(timeMs: 2000, lane: 1)]),
        mods: const Mods(),
        windows: windows,
      );
      s.press(0, 1030);
      s.release(0, 1060);
      expect(s.processor.counts[Judgment.perfect], 1);
      s.update(2200);
      expect(s.processor.counts[Judgment.miss], 1);
      expect(s.complete, isTrue);
    });

    test('pressing far too early is ignored', () {
      final s = TilesSession(
        map: tilesMap(const [TileNote(timeMs: 1000, lane: 0)]),
        mods: const Mods(),
        windows: windows,
      );
      s.press(0, 500);
      expect(s.processor.judged, 0);
    });

    test('hold judges head and release; early release misses the tail', () {
      final s = TilesSession(
        map: tilesMap(const [
          TileNote(timeMs: 1000, lane: 2, endTimeMs: 2000),
          TileNote(timeMs: 3000, lane: 2, endTimeMs: 4000),
        ]),
        mods: const Mods(),
        windows: windows,
      );
      s.press(2, 1000);
      s.update(1500);
      s.release(2, 2010);
      expect(s.processor.counts[Judgment.perfect], 2);
      s.press(2, 3000);
      s.release(2, 3300);
      expect(s.processor.counts[Judgment.miss], 1);
      expect(s.processor.combo, 0);
    });

    test('speed mod keeps windows constant in real time', () {
      final s = TilesSession(
        map: tilesMap(const [TileNote(timeMs: 1000, lane: 0)]),
        mods: const Mods(rate: 1.5),
        windows: windows,
      );
      // 60 song-ms late at 1.5× is 40 real ms: still Perfect.
      s.press(0, 1060);
      expect(s.processor.counts[Judgment.perfect], 1);
    });

    test('mirror flips lanes', () {
      final s = TilesSession(
        map: tilesMap(const [TileNote(timeMs: 1000, lane: 0)]),
        mods: const Mods(mirror: true),
        windows: windows,
      );
      expect(s.notes.single.note.lane, 3);
    });

    test('autoplay gets a perfect score', () {
      final notes = [
        for (var i = 0; i < 40; i++)
          TileNote(timeMs: 500.0 + i * 250, lane: i % 4, endTimeMs: i % 5 == 0 ? 600.0 + i * 250 : null),
      ];
      final s = TilesSession(map: tilesMap(notes), mods: const Mods(autoplay: true), windows: windows);
      for (var t = 0.0; t < 11000; t += 16) {
        s.update(t);
      }
      expect(s.complete, isTrue);
      expect(s.processor.score, 1000000);
    });
  });

  group('circles session', () {
    test('hit inside the circle at the right time; outside does nothing', () {
      final s = CirclesSession(
        map: circlesMap(const [
          CircleObject(type: CircleObjectType.circle, timeMs: 1000, x: 0.3, y: 0.5, comboIndex: 0),
          CircleObject(type: CircleObjectType.circle, timeMs: 1500, x: 0.7, y: 0.5, comboIndex: 0),
        ]),
        mods: const Mods(),
        windows: windows,
      );
      s.pointerDown(1, const Point2(0.9, 0.9), 1000);
      expect(s.processor.judged, 0);
      s.pointerUp(1, 1000);
      s.pointerDown(2, const Point2(0.3, 0.5), 1010);
      expect(s.processor.counts[Judgment.perfect], 1);
      expect(s.objects.first.comboNumber, 1);
      expect(s.objects.last.comboNumber, 2);
    });

    test('note lock: the later circle cannot be hit first', () {
      final s = CirclesSession(
        map: circlesMap(const [
          CircleObject(type: CircleObjectType.circle, timeMs: 1000, x: 0.3, y: 0.5, comboIndex: 0),
          CircleObject(type: CircleObjectType.circle, timeMs: 1100, x: 0.7, y: 0.5, comboIndex: 0),
        ]),
        mods: const Mods(),
        windows: windows,
      );
      s.pointerDown(1, const Point2(0.7, 0.5), 1000);
      expect(s.processor.judged, 0);
    });

    test('slider: following the ball gives a perfect tail; letting go misses', () {
      final slider = CircleObject(
        type: CircleObjectType.slider,
        timeMs: 1000,
        x: 0.2,
        y: 0.5,
        comboIndex: 0,
        path: const [Point2(0.2, 0.5), Point2(0.5, 0.45), Point2(0.8, 0.5)],
        endTimeMs: 2000,
      );
      final follow = CirclesSession(map: circlesMap([slider]), mods: const Mods(), windows: windows);
      follow.pointerDown(1, const Point2(0.2, 0.5), 1000);
      for (var t = 1000.0; t <= 2016; t += 16) {
        follow.pointerMove(1, follow.objects.first.ballAt(t), t);
        follow.update(t);
      }
      expect(follow.processor.counts[Judgment.perfect], 2);

      final drop = CirclesSession(map: circlesMap([slider]), mods: const Mods(), windows: windows);
      drop.pointerDown(1, const Point2(0.2, 0.5), 1000);
      drop.update(1000);
      drop.pointerUp(1, 1050);
      for (var t = 1050.0; t <= 2016; t += 16) {
        drop.update(t);
      }
      expect(drop.processor.counts[Judgment.miss], 1);
    });

    test('spinner judged by rotations', () {
      const spinner = CircleObject(
          type: CircleObjectType.spinner, timeMs: 1000, x: 0.5, y: 0.5, comboIndex: 0, endTimeMs: 3000);
      final s = CirclesSession(map: circlesMap(const [spinner]), mods: const Mods(), windows: windows);
      s.pointerDown(1, const Point2(0.7, 0.5), 1000);
      var a = 0.0;
      for (var t = 1000.0; t <= 3016; t += 16) {
        a += 0.25;
        s.pointerMove(1, Point2(0.5 + 0.2 * math.cos(a), 0.5 + 0.1 * math.sin(a)), t);
        s.update(t);
      }
      expect(s.processor.counts[Judgment.perfect], 1);
    });

    test('autoplay clears sliders and spinners', () {
      final objs = <CircleObject>[
        const CircleObject(type: CircleObjectType.circle, timeMs: 500, x: 0.5, y: 0.3, comboIndex: 0),
        const CircleObject(
          type: CircleObjectType.slider,
          timeMs: 1000,
          x: 0.3,
          y: 0.5,
          comboIndex: 0,
          path: [Point2(0.3, 0.5), Point2(0.5, 0.6), Point2(0.7, 0.5)],
          endTimeMs: 1600,
        ),
        const CircleObject(
            type: CircleObjectType.spinner, timeMs: 2000, x: 0.5, y: 0.5, comboIndex: 1, endTimeMs: 4000),
      ];
      final s = CirclesSession(map: circlesMap(objs), mods: const Mods(autoplay: true), windows: windows);
      for (var t = 0.0; t < 4200; t += 16) {
        s.update(t);
      }
      expect(s.complete, isTrue);
      expect(s.processor.score, 1000000);
    });
  });

  group('song clock', () {
    test('extrapolates between jittery reports and stays monotonic', () {
      var wall = 0;
      final clock = SongClock(wallMicros: () => wall);
      clock.start(0);
      final rnd = math.Random(1);
      var last = double.negativeInfinity;
      var maxErr = 0.0;
      for (var frame = 0; frame < 600; frame++) {
        wall += 16667;
        final trueAudio = wall / 1000.0;
        if (frame % 3 == 0) clock.sync(trueAudio + (rnd.nextDouble() - 0.5) * 20);
        final t = clock.timeMs;
        expect(t, greaterThanOrEqualTo(last));
        last = t;
        if (frame > 60) maxErr = math.max(maxErr, (t - trueAudio).abs());
      }
      expect(maxErr, lessThan(12));
    });

    test('rate scales time and offset shifts it', () {
      var wall = 0;
      final clock = SongClock(rate: 1.5, offsetMs: 30, wallMicros: () => wall);
      clock.start(1000);
      wall = 1000000;
      expect(clock.timeMs, closeTo(1000 + 1500 - 30, 1e-6));
    });

    test('large drift snaps', () {
      var wall = 0;
      final clock = SongClock(wallMicros: () => wall);
      clock.start(0);
      wall = 100000;
      clock.sync(5000);
      expect(clock.audioTimeMs, closeTo(5000, 1e-6));
    });

    test('pause holds time', () {
      var wall = 0;
      final clock = SongClock(wallMicros: () => wall);
      clock.start(0);
      wall = 500000;
      clock.pause();
      wall = 900000;
      expect(clock.audioTimeMs, closeTo(500, 1e-6));
      clock.resume();
      wall = 1000000;
      expect(clock.audioTimeMs, closeTo(600, 1e-6));
    });
  });

  group('offset calibration', () {
    test('recovers a constant latency', () {
      final rnd = math.Random(5);
      final taps = [for (var k = 0; k < 24; k++) 500 + k * 600 + 35 + (rnd.nextDouble() - 0.5) * 20];
      final est = estimateOffset(taps, firstBeatMs: 500, beatMs: 600)!;
      expect(est.offsetMs, closeTo(35, 4));
    });

    test('rejects outliers and needs enough taps', () {
      final taps = [for (var k = 0; k < 20; k++) 500 + k * 600 - 20.0];
      taps[10] += 250;
      expect(estimateOffset(taps, firstBeatMs: 500, beatMs: 600)!.offsetMs, closeTo(-20, 1e-6));
      expect(estimateOffset(taps.take(6).toList(), firstBeatMs: 500, beatMs: 600), isNull);
    });
  });
}
