import 'package:flutter_test/flutter_test.dart';
import 'package:rhytmaniac/core/gameplay/circles_session.dart';
import 'package:rhytmaniac/core/gameplay/tiles_session.dart';
import 'package:rhytmaniac/core/geometry/slider_curve.dart';
import 'package:rhytmaniac/core/import/osu_beatmap.dart';
import 'package:rhytmaniac/core/import/osu_convert.dart';
import 'package:rhytmaniac/core/models/beatmap.dart';
import 'package:rhytmaniac/core/models/difficulty.dart';
import 'package:rhytmaniac/core/models/score.dart';

String osu({int mode = 0, double cs = 4, String objects = ''}) => '''osu file format v14

[General]
AudioFilename: audio.mp3
PreviewTime: 30000
Mode: $mode

[Metadata]
Title:Test Song
TitleUnicode:テスト
Artist:Someone
Creator:Mapper
Version:Hard

[Difficulty]
HPDrainRate:6
CircleSize:$cs
OverallDifficulty:8
ApproachRate:9
SliderMultiplier:1.6
SliderTickRate:2

[Events]
//Background and Video events
0,0,"bg.jpg",0,0
2,58500,60500

[TimingPoints]
1000,500,4,2,0,60,1,0
30000,-100,4,2,0,60,0,1
45000,-50,4,2,0,60,0,0
61000,400,3,2,0,60,1,0

[HitObjects]
$objects''';

void main() {
  test('parses sections, timing, kiai and breaks', () {
    final m = parseOsu(osu(objects: '256,192,1000,5,0,0:0:0:0:\n'));
    expect(m.formatVersion, 14);
    expect(m.mode, 0);
    expect(m.displayTitle, 'テスト');
    expect(m.version, 'Hard');
    expect(m.cs, 4);
    expect(m.ar, 9);
    expect(m.background, 'bg.jpg');
    expect(m.breaks.single, (58500.0, 60500.0));
    expect(m.redPoints.length, 2);
    expect(m.redAt(50000).beatLength, 500);
    expect(m.redAt(70000).meter, 3);
    expect(m.velocityAt(20000), 1);
    expect(m.velocityAt(50000), 2);
    expect(m.velocityAt(62000), 1, reason: 'a red point resets the slider velocity');
    expect(m.kiaiRanges(100000).single, (30000.0, 45000.0));
  });

  test('rejects files that are not beatmaps', () {
    expect(() => parseOsu('hello'), throwsFormatException);
  });

  test('converts standard: rotation, sliders with repeats and ticks, spinners, combos', () {
    final m = parseOsu(osu(objects: '''
256,192,1000,5,0,0:0:0:0:
100,100,1500,2,0,L|260:100,2,160
200,300,3500,6,0,P|250:250|300:300,1,80
300,100,46000,2,0,B|400:100,1,160
256,192,50000,12,0,52000,0:0:0:0:
50,50,53000,1,0,0:0:0:0:
'''));
    final b = convertOsu(m, songId: 's', id: 'm')!;
    expect(b.mode, GameMode.circles);
    expect(b.origin, 'osu');
    expect(b.circleObjects.length, 6);

    // The centre of osu!'s field is the centre of ours.
    final first = b.circleObjects[0];
    expect(first.x, closeTo(0.5, 1e-6));
    expect(first.y, closeTo(0.5, 1e-6));

    // 160 px at 1.6 × 100 px per beat = one beat per pass, two passes.
    final slider = b.circleObjects[1];
    expect(slider.isSlider, isTrue);
    expect(slider.curve, SliderPathKind.linear);
    expect(slider.repeats, 1);
    expect(slider.endMs, closeTo(1500 + 2 * 500, 1e-6));
    expect(slider.tickMs, closeTo(250, 1e-6));
    expect(slider.tickTimes(), [closeTo(1750, 1e-6), closeTo(2250, 1e-6)]);
    expect(slider.repeatTimes(), [closeTo(2000, 1e-6)]);
    // After one repeat the slider ends where it started.
    expect(slider.endPosition.x, closeTo(slider.x, 1e-6));
    // The path keeps its declared length: 160 osu! px, where the field plus
    // a circle radius each side spans the playfield width.
    final radiusPx = 54.4 - 4.48 * 4;
    final scale = 1 / (384 + 2 * radiusPx);
    final len = SliderCurve.of(slider)!.length;
    expect(len, closeTo(160 * scale, 0.01));
    // Objects at the edge of osu!'s field stay fully on ours.
    for (final o in b.circleObjects) {
      expect(o.x - b.difficulty.circleRadius, greaterThanOrEqualTo(-1e-6));
      expect(o.x + b.difficulty.circleRadius, lessThanOrEqualTo(1 + 1e-6));
    }

    // Perfect-circle slider becomes an arc; new combo flags advance colours.
    final arc = b.circleObjects[2];
    expect(arc.comboIndex, greaterThan(slider.comboIndex));
    expect(SliderCurve.of(arc)!.points.length, greaterThan(3));

    // Double slider velocity halves the duration.
    final fast = b.circleObjects[3];
    expect(fast.endMs - fast.timeMs, closeTo(250, 1e-6));

    final spinner = b.circleObjects[4];
    expect(spinner.isSpinner, isTrue);
    expect(spinner.endMs, 52000);
    // The object after a spinner starts a new combo.
    expect(b.circleObjects[5].comboIndex, greaterThan(spinner.comboIndex));

    // Difficulty settings carry over.
    expect(b.difficulty.hpDrain, 6);
    expect(b.difficulty.approachMs, closeTo(1200 - 150 * 4, 1e-6));
    expect(b.difficulty.circleRadius, closeTo(radiusPx * scale, 1e-6));
    expect(b.difficulty.windows.perfect, closeTo(80 - 6 * 8, 0.5));
    expect(b.timing.length, 2);
    expect(b.kiai.single.startMs, 30000);
    expect(b.starRating, greaterThan(0));
    // Six heads, three slider tails, and two ticks plus a repeat on the first slider.
    expect(b.maxCombo, 6 + 3 + 2 + 1);

    // Round trip keeps repeats, ticks and the path kind.
    final back = Beatmap.fromJson(b.toJson());
    expect(back.circleObjects[1].repeats, 1);
    expect(back.circleObjects[1].tickMs, closeTo(250, 0.1));
    expect(back.circleObjects[1].curve, SliderPathKind.linear);
    expect(back.timing.length, 2);
  });

  test('converted sliders play: ticks and repeats feed the combo', () {
    final m = parseOsu(osu(objects: '100,100,1500,6,0,L|260:100,2,160\n'));
    final b = convertOsu(m, songId: 's', id: 'm')!;
    const windows = HitWindows(perfect: 40, great: 80, good: 120, miss: 160);
    final s = CirclesSession(map: b, mods: const Mods(autoplay: true), windows: windows);
    for (var t = 1000.0; t < 3000; t += 16) {
      s.update(t);
    }
    expect(s.complete, isTrue);
    expect(s.processor.maxCombo, 2 + 2 + 1);
    expect(s.processor.ticksHit, 3);
  });

  test('converts mania to Tiles with lanes and holds; skips taiko', () {
    final m = parseOsu(osu(mode: 3, cs: 7, objects: '''
36,192,1000,1,0,0:0:0:0:
475,192,1500,128,0,2000:0:0:0:0:
256,192,2000,1,0,0:0:0:0:
'''));
    final b = convertOsu(m, songId: 's', id: 'm')!;
    expect(b.mode, GameMode.tiles);
    expect(b.difficulty.lanes, 7);
    expect(b.name, 'Hard · 7K');
    final named = convertOsu(parseOsu(osu(mode: 3, cs: 7, objects: '36,192,1000,1,0,0:0:0:0:\n').replaceFirst('Version:Hard', 'Version:7K Hyper')),
        songId: 's', id: 'n')!;
    expect(named.name, '7K Hyper');
    expect(b.tileNotes.map((n) => n.lane), [0, 6, 3]);
    expect(b.tileNotes[1].endTimeMs, 2000);
    final s = TilesSession(map: b, mods: const Mods(autoplay: true), windows: b.difficulty.windows);
    for (var t = 0.0; t < 2600; t += 16) {
      s.update(t);
    }
    expect(s.complete, isTrue);

    expect(convertOsu(parseOsu(osu(mode: 1, objects: '256,192,1000,1,0,0:0:0:0:\n')), songId: 's', id: 't'), isNull);
  });
}
