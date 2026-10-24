import 'dart:math' as math;

import '../geometry/slider_curve.dart';
import '../models/analysis.dart';
import '../models/beatmap.dart';
import '../models/difficulty.dart';
import '../util/rng.dart';
import 'note_selection.dart';

/// Placement for Circles mode, in "width units" (x ∈ [0,1], y ∈ [0, yScale]).
///
/// - Distance snapping: spacing grows with the time gap and difficulty, so
///   rhythm reads from distance.
/// - Flow: the heading drifts smoothly (curves), with occasional reversals
///   at combo starts (back-and-forth). Streams curve gently.
/// - Accents become jumps at higher spacing.
/// - Sustained sounds become sliders (long ones nearly always); a long held
///   sound becomes a short slider that turns back on each beat (repeats)
///   rather than one long path. Long loud gaps can become spinners.
/// - New combos start at phrase boundaries (every 2 bars) and after rests.
List<CircleObject> generateCircles(SongAnalysis a, DifficultyParams p, int seed) {
  final candidates = selectNotes(a, p);
  return placeCircles(candidates, a, p, seed);
}

/// How many times a slider [beats] long turns back so that every pass
/// lasts whole beats: 2 to 4 passes, or none when it can't split so (5 or
/// 7 beats, or not a whole number of beats).
int sliderTurns(double beats) {
  final whole = beats.round();
  if (whole < 2 || (beats - whole).abs() >= 0.05) return 0;
  for (var spans = 4; spans >= 2; spans--) {
    if (whole % spans == 0) return spans - 1;
  }
  return 0;
}

List<CircleObject> placeCircles(List<NoteCandidate> candidates, SongAnalysis a, DifficultyParams p, int seed) {
  final rng = Rng(seed ^ 0xC1C1E5);
  final grid = a.grid;
  final r = p.circleRadius;
  const margin = 0.02;
  final minX = r + margin, maxX = 1 - r - margin;
  final minY = r + margin, maxY = circlesYScale - r - margin;
  bool inBounds(Point2 q) => q.x >= minX && q.x <= maxX && q.y >= minY && q.y <= maxY;
  Point2 clampIn(Point2 q) => Point2(q.x.clamp(minX, maxX), q.y.clamp(minY, maxY));
  Point2 norm(Point2 q) => Point2(q.x, q.y / circlesYScale);

  final out = <CircleObject>[];
  // Placed objects in width units, for overlap checks.
  final placed = <({double time, double end, Point2 pos, Point2 endPos})>[];

  var pos = Point2(0.5, circlesYScale * 0.6);
  var heading = -math.pi / 2 + rng.range(-0.6, 0.6);
  var turn = 0.0;
  var combo = -1;
  var comboStart = -1e9;
  var comboLength = 0;
  var lastEnd = -1e9;
  var lastSpinner = -1e9;

  void newCombo(double t) {
    combo++;
    comboStart = t;
    comboLength = 0;
  }

  for (var i = 0; i < candidates.length; i++) {
    final c = candidates[i];
    final t = c.timeMs;
    final section = grid.at(t);
    final beat = section.beatLengthMs;
    final releaseGap = math.max(p.minGapMs, beat / 2);
    final nextTime = i + 1 < candidates.length ? candidates[i + 1].timeMs : a.durationMs;
    final gap = t - lastEnd;

    // --- spinner in a long, loud gap ---------------------------------------------
    if (p.spinners && out.isNotEmpty && gap >= beat * 5 && t - lastSpinner > 30000) {
      final s = lastEnd + beat;
      final e = math.min(t - beat * 1.5, a.durationMs - 500);
      if (e - s >= beat * 2.5 && a.smoothedEnergyAt((s + e) / 2, e - s) > 0.5) {
        newCombo(s);
        out.add(CircleObject(
          type: CircleObjectType.spinner,
          timeMs: s,
          x: 0.5,
          y: 0.5,
          comboIndex: combo,
          endTimeMs: e,
        ));
        placed.add((time: s, end: e, pos: Point2(0.5, circlesYScale / 2), endPos: Point2(0.5, circlesYScale / 2)));
        lastSpinner = e;
        lastEnd = e;
        pos = Point2(0.5, circlesYScale / 2);
        comboStart = -1e9; // force a new combo after the spinner
      }
    }

    // --- combo ------------------------------------------------------------------------
    final phrase = c.barStart;
    final sinceCombo = t - comboStart;
    final startCombo = combo < 0 ||
        t - lastEnd >= beat * 2 ||
        comboLength >= 14 ||
        (sinceCombo >= beat * 7.5 && phrase) ||
        sinceCombo >= beat * 12;
    var reversed = false;
    if (startCombo) {
      newCombo(t);
      if (out.isNotEmpty && rng.chance(0.35)) {
        heading += math.pi + rng.range(-0.5, 0.5);
        reversed = true;
      }
    }

    // --- distance --------------------------------------------------------------------
    final gapBeats = (t - lastEnd) / beat;
    double dist;
    if (out.isEmpty) {
      dist = 0;
    } else if (gapBeats <= 0.26) {
      dist = 0.075 * p.spacing;
      turn *= 0.5;
    } else {
      dist = 0.26 * p.spacing * math.pow(math.min(gapBeats, 2.0), 0.85);
      if (c.strength > 0.8 && p.spacing > 1.3) dist *= 1 + 0.35 * (p.spacing - 1.3);
    }
    dist = dist.clamp(0.0, 0.75);

    // --- heading ----------------------------------------------------------------------
    if (!reversed) {
      turn = 0.75 * turn + rng.gaussian() * (gapBeats <= 0.26 ? 0.12 : 0.35);
      heading += turn;
    }
    // Drift back toward the middle when wandering near the edges, so the
    // pattern keeps room to flow instead of piling up against a wall.
    final center = Point2(0.5, circlesYScale * 0.55);
    final off = pos - center;
    final offLen = math.sqrt(off.x * off.x + (off.y / circlesYScale) * (off.y / circlesYScale) * 2.6);
    if (offLen > 0.22) {
      final toCenter = math.atan2(-off.y, -off.x);
      var diff = toCenter - heading;
      while (diff > math.pi) {
        diff -= 2 * math.pi;
      }
      while (diff < -math.pi) {
        diff += 2 * math.pi;
      }
      heading += diff * ((offLen - 0.22) * 1.6).clamp(0.0, 0.6);
    }

    // --- slider? ------------------------------------------------------------------------
    double? sliderEnd;
    var absorbs = false;
    final sustain = c.sustainEndMs;
    // A long sustain with room before the next note nearly always slides.
    final roomBeats = sustain == null ? 0.0 : (math.min(sustain, nextTime - releaseGap) - t) / beat;
    final sliderChance = roomBeats >= 2
        ? math.min(1.0, p.holdFrequency * 2.2)
        : p.holdFrequency * (0.5 + 0.5 * c.strength) * 1.5;
    if (sustain != null && rng.chance(sliderChance)) {
      final minLen = beat * (p.snapDivisor == 1 ? 1.0 : 0.5);
      var end = math.min(sustain, nextTime - releaseGap);
      if (end - t < minLen && sustain - t >= minLen && rng.chance(0.5)) {
        // Dense passage: the slider may swallow a note or two under its body,
        // but not the rhythm: it stops before a stronger note or a third one.
        var cut = sustain;
        var swallowed = 0;
        for (var j = i + 1; j < candidates.length && candidates[j].timeMs < sustain + releaseGap; j++) {
          if (candidates[j].strength > c.strength || swallowed == 2) {
            cut = candidates[j].timeMs - releaseGap;
            break;
          }
          swallowed++;
        }
        end = cut;
        absorbs = true;
      }
      if (end - t >= minLen) {
        final step = beat / gridDivisor(section, p.snapDivisor);
        sliderEnd = t + ((end - t) / step).floor() * step;
        if (sliderEnd - t < minLen) sliderEnd = null;
      }
    }

    // --- place the head ---------------------------------------------------------------
    Point2? head;
    var d = dist;
    for (var attempt = 0; attempt < 3 && head == null; attempt++) {
      for (var k = 0; k <= 18; k++) {
        final delta = (k == 0 ? 0 : ((k + 1) ~/ 2) * (math.pi / 9)) * (k.isOdd ? 1 : -1);
        final ang = heading + delta;
        final q = Point2(pos.x + d * math.cos(ang), pos.y + d * math.sin(ang));
        if (!inBounds(q)) continue;
        if (_overlapsVisible(q, t, placed, p.approachMs, r, ignoreLast: d < r * 1.6)) continue;
        head = q;
        heading = ang;
        break;
      }
      d *= 0.85;
    }
    head ??= clampIn(Point2(pos.x + dist * math.cos(heading), pos.y + dist * math.sin(heading)));

    // --- slider body ----------------------------------------------------------------------
    if (sliderEnd != null) {
      final beats = (sliderEnd - t) / beat;
      // Two beats or more: a short track travelled back and forth, turning
      // on the beats, instead of one long path across the screen.
      var repeats = 0;
      if (beats >= 1.9 && p.snapDivisor > 1 && rng.chance(0.55)) repeats = sliderTurns(beats);
      final spanBeats = beats / (repeats + 1);
      final length = (0.17 * p.spacing * spanBeats).clamp(0.12, repeats > 0 ? 0.32 : 0.6);
      List<Point2>? ctrl;
      for (var k = 0; k <= 11 && ctrl == null; k++) {
        final delta = (k == 0 ? 0 : ((k + 1) ~/ 2) * (math.pi / 6)) * (k.isOdd ? 1 : -1);
        final ang = heading + delta;
        final end = Point2(head.x + length * math.cos(ang), head.y + length * math.sin(ang));
        final bend = rng.range(-0.35, 0.35) * length;
        final mid = Point2(
          (head.x + end.x) / 2 - math.sin(ang) * bend,
          (head.y + end.y) / 2 + math.cos(ang) * bend,
        );
        if (inBounds(end) && inBounds(mid)) {
          ctrl = [head, mid, end];
          // An odd number of turns ends back at the head, heading home.
          heading = repeats.isOdd ? math.atan2(head.y - mid.y, head.x - mid.x) : math.atan2(end.y - mid.y, end.x - mid.x);
        }
      }
      if (ctrl == null) {
        sliderEnd = null;
      } else {
        final normalized = ctrl.map(norm).toList();
        out.add(CircleObject(
          type: CircleObjectType.slider,
          timeMs: t,
          x: normalized.first.x,
          y: normalized.first.y,
          comboIndex: combo,
          path: normalized,
          endTimeMs: sliderEnd,
          tickMs: beat,
          repeats: repeats,
        ));
        placed.add((time: t, end: sliderEnd, pos: head, endPos: ctrl.last));
        pos = repeats.isOdd ? head : ctrl.last;
        lastEnd = sliderEnd;
        comboLength++;
        if (absorbs) {
          while (i + 1 < candidates.length && candidates[i + 1].timeMs < sliderEnd + releaseGap) {
            i++;
          }
        }
        continue;
      }
    }

    final n = norm(head);
    out.add(CircleObject(type: CircleObjectType.circle, timeMs: t, x: n.x, y: n.y, comboIndex: combo));
    placed.add((time: t, end: t, pos: head, endPos: head));
    pos = head;
    lastEnd = t;
    comboLength++;
  }
  return out;
}

bool _overlapsVisible(
  Point2 q,
  double t,
  List<({double time, double end, Point2 pos, Point2 endPos})> placed,
  double approachMs,
  double r, {
  required bool ignoreLast,
}) {
  for (var i = placed.length - 1; i >= 0; i--) {
    final o = placed[i];
    if (t - o.end > approachMs * 0.8) break;
    if (ignoreLast && i == placed.length - 1) continue;
    final dx = o.pos.x - q.x, dy = o.pos.y - q.y;
    final ex = o.endPos.x - q.x, ey = o.endPos.y - q.y;
    final min2 = (r * 1.7) * (r * 1.7);
    if (dx * dx + dy * dy < min2 || ex * ex + ey * ey < min2) return true;
  }
  return false;
}
