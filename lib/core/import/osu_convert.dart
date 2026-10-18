import 'dart:math' as math;

import '../geometry/slider_curve.dart';
import '../models/beatmap.dart';
import '../models/difficulty.dart';
import '../models/timing.dart';
import '../rating/star_rating.dart';
import 'osu_beatmap.dart';

/// Why an osu! difficulty wasn't converted.
class OsuSkip {
  const OsuSkip(this.version, this.reason);
  final String version;
  final String reason;
}

/// osu!standard → Circles, osu!mania → Tiles. Taiko and catch maps are
/// skipped (returns null).
///
/// The osu! playfield (512×384, landscape) is turned a quarter turn
/// clockwise to fit the tall portrait field: osu! x runs down the screen,
/// osu! y runs right to left. A rotation keeps every pattern's shape, flow
/// and spacing; circle size (relative to the field), approach rate, hit
/// windows and HP carry over.
Beatmap? convertOsu(OsuBeatmap osu, {required String songId, required String id, DateTime? createdAt}) {
  final meta = BeatmapMetadata(title: osu.displayTitle, artist: osu.displayArtist, creator: osu.creator);
  final timing = [
    for (final p in osu.redPoints)
      TimingPoint(timeMs: p.time, beatLengthMs: p.beatLength.clamp(6.0, 60000.0), meter: p.meter.clamp(1, 16)),
  ];
  final lastTime = osu.hitObjects.isEmpty
      ? 0.0
      : osu.hitObjects.map((o) => o.endTime ?? o.time).reduce(math.max) + 60000;
  final kiai = [for (final (s, e) in osu.kiaiRanges(lastTime)) TimeSpan(s, e)];

  Beatmap? map;
  if (osu.mode == 0) {
    map = _standard(osu, meta, songId, id, createdAt ?? DateTime.now());
  } else if (osu.mode == 3) {
    map = _mania(osu, meta, songId, id, createdAt ?? DateTime.now());
  }
  if (map == null) return null;
  final withTiming = map.copyWith(timing: timing, kiai: kiai);
  return withTiming.copyWith(starRating: starRating(withTiming));
}

/// Maps osu! pixels onto the portrait playfield. osu! lets circles hang
/// over the edge of its 512×384 field, so the field plus a circle radius on
/// every side is fitted into ours (turned a quarter turn, centred).
class _Rotation {
  _Rotation(this.radiusPx) {
    scale = math.min(1 / (384 + 2 * radiusPx), circlesYScale / (512 + 2 * radiusPx));
    offsetX = (1 - (384 + 2 * radiusPx) * scale) / 2;
    offsetY = (circlesYScale - (512 + 2 * radiusPx) * scale) / 2;
  }

  final double radiusPx;

  /// Width units per osu! pixel.
  late final double scale;
  late final double offsetX;
  late final double offsetY;

  Point2 call(double x, double y) =>
      Point2(offsetX + (384 - y + radiusPx) * scale, (offsetY + (x + radiusPx) * scale) / circlesYScale);
}

double _approachMs(double ar) => ar < 5 ? 1800 - 120 * ar : 1200 - 150 * (ar - 5);

/// Our 0..10 window strictness for a Perfect window of [perfectMs].
double _hitWindowFor(double perfectMs) => ((1.4 - perfectMs / 40) / 0.08).clamp(-2.0, 12.0);

Beatmap _standard(OsuBeatmap osu, BeatmapMetadata meta, String songId, String id, DateTime createdAt) {
  final radiusPx = 54.4 - 4.48 * osu.cs;
  final toPortrait = _Rotation(radiusPx);
  final radius = radiusPx * toPortrait.scale;
  final params = DifficultyParams.level(GameMode.circles, 2).copyWith(
    preset: DifficultyPreset.custom,
    circleSize: (0.115 - radius) / 0.0055,
    approachMs: _approachMs(osu.ar).clamp(300.0, 2400.0),
    hitWindow: _hitWindowFor(80 - 6 * osu.od),
    hpDrain: osu.hp.clamp(0.0, 10.0),
    spinners: true,
  );

  final out = <CircleObject>[];
  var combo = -1;
  var prevSpinner = false;
  for (var i = 0; i < osu.hitObjects.length; i++) {
    final o = osu.hitObjects[i];
    if (o.kind == OsuObjectKind.hold) continue;
    if (out.isEmpty || o.newCombo || o.kind == OsuObjectKind.spinner || prevSpinner) combo += 1 + o.comboSkip;
    prevSpinner = o.kind == OsuObjectKind.spinner;
    switch (o.kind) {
      case OsuObjectKind.spinner:
        final end = o.endTime ?? o.time + 1000;
        if (end - o.time < 100) continue;
        out.add(CircleObject(type: CircleObjectType.spinner, timeMs: o.time, x: 0.5, y: 0.5, comboIndex: combo, endTimeMs: end));
      case OsuObjectKind.slider:
        final red = osu.redAt(o.time);
        final velocity = osu.sliderMultiplier * 100 * osu.velocityAt(o.time) / red.beatLength; // px per ms
        final pathPx = simplifyPath(osuSliderPath(o), 5);
        if (pathPx.length < 2 || velocity <= 0 || o.length <= 0) {
          final p = toPortrait(o.x, o.y);
          out.add(CircleObject(type: CircleObjectType.circle, timeMs: o.time, x: p.x, y: p.y, comboIndex: combo));
          continue;
        }
        final span = o.length / velocity;
        final path = pathPx.map((q) => toPortrait(q.$1, q.$2)).toList();
        out.add(CircleObject(
          type: CircleObjectType.slider,
          timeMs: o.time,
          x: path.first.x,
          y: path.first.y,
          comboIndex: combo,
          path: path,
          curve: SliderPathKind.linear,
          repeats: o.slides - 1,
          tickMs: red.beatLength / osu.sliderTickRate,
          endTimeMs: o.time + span * o.slides,
        ));
      case OsuObjectKind.circle:
        final p = toPortrait(o.x, o.y);
        out.add(CircleObject(type: CircleObjectType.circle, timeMs: o.time, x: p.x, y: p.y, comboIndex: combo));
      case OsuObjectKind.hold:
        break;
    }
  }
  // Keep combo numbers small and dense like generated maps.
  final renumbered = <CircleObject>[];
  var last = -1, n = -1;
  for (final o in out) {
    if (o.comboIndex != last) {
      n++;
      last = o.comboIndex;
    }
    renumbered.add(o.copyWith(comboIndex: n));
  }
  return Beatmap(
    id: id,
    songId: songId,
    mode: GameMode.circles,
    name: osu.version,
    metadata: meta,
    difficulty: params,
    seed: 0,
    starRating: 0,
    createdAt: createdAt,
    circleObjects: renumbered,
    origin: 'osu',
  );
}

Beatmap _mania(OsuBeatmap osu, BeatmapMetadata meta, String songId, String id, DateTime createdAt) {
  final keys = osu.cs.round().clamp(1, 10);
  final params = DifficultyParams.level(GameMode.tiles, 2, lanes: keys).copyWith(
    preset: DifficultyPreset.custom,
    lanes: keys,
    hitWindow: _hitWindowFor(64 - 3 * osu.od),
    hpDrain: osu.hp.clamp(0.0, 10.0),
    scrollSpeed: 2.6,
  );
  final notes = <TileNote>[];
  for (final o in osu.hitObjects) {
    final lane = (o.x * keys / 512).floor().clamp(0, keys - 1);
    final end = o.kind == OsuObjectKind.hold ? o.endTime : null;
    notes.add(TileNote(timeMs: o.time, lane: lane, endTimeMs: end != null && end > o.time + 30 ? end : null));
  }
  notes.sort((a, b) => a.timeMs != b.timeMs ? a.timeMs.compareTo(b.timeMs) : a.lane.compareTo(b.lane));
  return Beatmap(
    id: id,
    songId: songId,
    mode: GameMode.tiles,
    // "Hyper" → "Hyper · 7K", but "7K Hyper" stays as it is.
    name: osu.version.toUpperCase().contains('${keys}K') ? osu.version : '${osu.version} · ${keys}K',
    metadata: meta,
    difficulty: params,
    seed: 0,
    starRating: 0,
    createdAt: createdAt,
    tileNotes: notes,
    origin: 'osu',
  );
}

/// Human name of an osu! game mode.
String osuModeName(int mode) => switch (mode) {
      0 => 'osu!',
      1 => 'osu!taiko',
      2 => 'osu!catch',
      3 => 'osu!mania',
      _ => 'unknown mode',
    };
