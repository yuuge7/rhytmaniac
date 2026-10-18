import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhytmaniac/core/gameplay/circles_session.dart';
import 'package:rhytmaniac/core/gameplay/replay_driver.dart';
import 'package:rhytmaniac/core/gameplay/session.dart';
import 'package:rhytmaniac/core/gameplay/tiles_session.dart';
import 'package:rhytmaniac/core/models/beatmap.dart';
import 'package:rhytmaniac/core/models/difficulty.dart';
import 'package:rhytmaniac/core/models/replay.dart';
import 'package:rhytmaniac/core/models/score.dart';

const windows = HitWindows(perfect: 40, great: 80, good: 120, miss: 160);

Beatmap map(GameMode mode, {List<TileNote> notes = const [], List<CircleObject> objects = const []}) => Beatmap(
      id: 'm',
      songId: 's',
      mode: mode,
      name: 't',
      metadata: const BeatmapMetadata(title: '', artist: '', creator: ''),
      difficulty: DifficultyParams.preset(mode, DifficultyPreset.normal),
      seed: 1,
      starRating: 1,
      createdAt: DateTime(2026),
      tileNotes: notes,
      circleObjects: objects,
    );

/// Runs a session live: frames every [frameMs], inputs at their own times
/// (session updated first, as the play screen does), recording a replay.
List<ReplayFrame> playLive(GameSession s, List<ReplayFrame> inputs, double frameMs, double endMs) {
  final rec = ReplayRecorder();
  var i = 0;
  for (var t = 0.0; t <= endMs; t += frameMs) {
    while (i < inputs.length && inputs[i].timeMs <= t) {
      final f = inputs[i++];
      s.update(f.timeMs);
      rec.add(f);
      if (s is TilesSession) {
        f.action == ReplayAction.press ? s.press(f.lane, f.timeMs) : s.release(f.lane, f.timeMs);
      } else if (s is CirclesSession) {
        switch (f.action) {
          case ReplayAction.down:
            s.pointerDown(f.id, Point2(f.x, f.y), f.timeMs);
          case ReplayAction.move:
            s.pointerMove(f.id, Point2(f.x, f.y), f.timeMs);
          default:
            s.pointerUp(f.id, f.timeMs);
        }
      }
    }
    s.update(t);
  }
  return rec.frames;
}

void replay(GameSession s, List<ReplayFrame> frames, double frameMs, double endMs) {
  final d = ReplayDriver(frames, s);
  for (var t = 0.0; t <= endMs; t += frameMs) {
    d.advanceTo(t);
    s.update(t);
  }
}

void main() {
  test('tiles replay gives the same judgments at another frame rate', () {
    final rng = math.Random(9);
    final notes = <TileNote>[];
    for (var i = 0; i < 60; i++) {
      final t = 1000.0 + i * 230;
      notes.add(TileNote(timeMs: t, lane: rng.nextInt(4), endTimeMs: i % 9 == 4 ? t + 400 : null));
    }
    final inputs = <ReplayFrame>[];
    for (final n in notes) {
      final err = (rng.nextDouble() - 0.5) * 220;
      if (rng.nextDouble() < 0.1) continue; // a few misses
      inputs.add(ReplayFrame(n.timeMs + err, ReplayAction.press, n.lane));
      inputs.add(ReplayFrame(n.endMs + err + (n.isHold ? (rng.nextDouble() - 0.6) * 300 : 60), ReplayAction.release, n.lane));
    }
    inputs.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    final m = map(GameMode.tiles, notes: notes);
    final live = TilesSession(map: m, mods: const Mods(), windows: windows);
    final frames = playLive(live, inputs, 16.7, 16000);

    // Through JSON, as stored on disk.
    final stored = Replay.fromJson(jsonDecode(jsonEncode(Replay(
      scoreId: 'x',
      beatmapId: 'm',
      mode: GameMode.tiles,
      mods: const Mods(),
      player: 'p',
      createdAt: DateTime(2026),
      frames: frames,
    ).toJson())) as Map<String, dynamic>);
    final again = TilesSession(map: m, mods: const Mods(), windows: windows);
    replay(again, stored.frames, 11.1, 16000);

    expect(again.processor.counts, live.processor.counts);
    expect(again.processor.score, live.processor.score);
    expect(again.processor.maxCombo, live.processor.maxCombo);
  });

  test('circles replay keeps hits, slider ticks and spinner spins', () {
    final objects = [
      const CircleObject(type: CircleObjectType.circle, timeMs: 1000, x: 0.3, y: 0.3, comboIndex: 0),
      const CircleObject(
        type: CircleObjectType.slider,
        timeMs: 1600,
        x: 0.2,
        y: 0.5,
        comboIndex: 0,
        path: [Point2(0.2, 0.5), Point2(0.4, 0.55), Point2(0.6, 0.5)],
        endTimeMs: 2600,
        repeats: 1,
        tickMs: 250,
      ),
      const CircleObject(type: CircleObjectType.spinner, timeMs: 3200, x: 0.5, y: 0.5, comboIndex: 1, endTimeMs: 5200),
    ];
    final m = map(GameMode.circles, objects: objects);
    final s0 = CirclesSession(map: m, mods: const Mods(), windows: windows);
    final slider = s0.objects[1];
    final inputs = <ReplayFrame>[
      const ReplayFrame(1012, ReplayAction.down, 1, 0.3, 0.3),
      const ReplayFrame(1080, ReplayAction.up, 1),
      const ReplayFrame(1590, ReplayAction.down, 2, 0.2, 0.5),
      for (var t = 1600.0; t <= 2600; t += 20) ReplayFrame(t, ReplayAction.move, 2, slider.ballAt(t).x, slider.ballAt(t).y),
      const ReplayFrame(2650, ReplayAction.up, 2),
      const ReplayFrame(3200, ReplayAction.down, 3, 0.8, 0.5),
      for (var t = 3200.0; t <= 5200; t += 16)
        ReplayFrame(t, ReplayAction.move, 3, 0.5 + 0.3 * math.cos(t / 40), 0.5 + 0.3 / 1.6 * math.sin(t / 40)),
      const ReplayFrame(5250, ReplayAction.up, 3),
    ];
    final live = CirclesSession(map: m, mods: const Mods(), windows: windows);
    final frames = playLive(live, inputs, 16.7, 6000);
    expect(live.processor.ticksHit, greaterThan(0));
    expect(live.processor.bonus, greaterThan(0));

    final again = CirclesSession(map: m, mods: const Mods(), windows: windows);
    replay(again, frames, 9.0, 6000);
    expect(again.processor.counts, live.processor.counts);
    expect(again.processor.ticksHit, live.processor.ticksHit);
    expect(again.processor.maxCombo, live.processor.maxCombo);
    expect(again.processor.score, closeTo(live.processor.score, 5));
  });

  test('recorder thins moves but keeps presses and lifts', () {
    final r = ReplayRecorder();
    r.add(const ReplayFrame(0, ReplayAction.down, 1, 0.5, 0.5));
    for (var t = 1.0; t < 100; t += 1) {
      r.add(ReplayFrame(t, ReplayAction.move, 1, 0.5 + t * 0.0001, 0.5));
    }
    r.add(const ReplayFrame(100, ReplayAction.up, 1));
    expect(r.frames.first.action, ReplayAction.down);
    expect(r.frames.last.action, ReplayAction.up);
    expect(r.frames.length, lessThan(15));
  });
}
