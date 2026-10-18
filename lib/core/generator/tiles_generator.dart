import 'dart:math' as math;

import '../models/analysis.dart';
import '../models/beatmap.dart';
import '../models/difficulty.dart';
import '../util/rng.dart';
import 'note_selection.dart';

/// Lane assignment for Tiles mode.
///
/// - Pitch-following: bass-heavy onsets lean left, bright ones lean right.
/// - Jacks (same lane again soon) are forbidden at low difficulty and become
///   more likely as jackAllowance rises.
/// - Chords appear on strong, bass-heavy hits, more often at high difficulty.
/// - Fast passages fall into stairs and trills; hands alternate.
/// - Sustained sounds become holds; at low difficulty a hold ends before the
///   next note so only one lane is ever busy.
List<TileNote> generateTiles(SongAnalysis a, DifficultyParams p, int seed) {
  final candidates = selectNotes(a, p);
  return assignLanes(candidates, a, p, seed);
}

List<TileNote> assignLanes(List<NoteCandidate> candidates, SongAnalysis a, DifficultyParams p, int seed) {
  final rng = Rng(seed ^ 0x7111E5);
  final lanes = p.lanes.clamp(3, 6);
  final grid = a.grid;
  final notes = <TileNote>[];
  final laneFreeAt = List<double>.filled(lanes, -1e9);
  final laneLastTime = List<double>.filled(lanes, -1e9);
  var lastLanes = <int>[];
  var prevLanes = <int>[];
  var lastTime = -1e9;
  var stairDir = 1;
  final overlapHolds = p.chordAllowance >= 0.15;

  for (var i = 0; i < candidates.length; i++) {
    final c = candidates[i];
    final t = c.timeMs;
    final beat = grid.beatLengthAt(t);
    final releaseGap = math.max(p.minGapMs, beat / 2);
    final gap = t - lastTime;
    final nextTime = i + 1 < candidates.length ? candidates[i + 1].timeMs : double.infinity;

    // --- chord size ---------------------------------------------------------
    var k = 1;
    if (p.chordAllowance > 0) {
      final downbeat = c.strongBeat;
      var p2 = p.chordAllowance * math.pow(c.strength, 1.5) * (c.onset.low > 0.6 ? 1.3 : 0.8);
      if (downbeat) p2 *= 1.4;
      if (gap < beat / 4 + 1) p2 *= 0.4; // keep fast streams readable
      if (rng.chance(p2)) {
        k = 2;
        if (p.chordAllowance > 0.3 && rng.chance((p.chordAllowance - 0.3) * c.strength * 1.2)) k = 3;
      }
    }

    // --- free lanes -----------------------------------------------------------
    final free = <int>[
      for (var l = 0; l < lanes; l++)
        if (laneFreeAt[l] <= t - math.min(p.minGapMs, beat / 4)) l,
    ];
    if (free.isEmpty) continue;
    k = math.min(k, math.max(1, math.min(free.length, lanes - 1)));

    // --- weights ----------------------------------------------------------------
    final target = c.onset.brightness * (lanes - 1);
    final sigma = lanes * 0.45;
    final fast = gap <= beat / 2 + 1;
    int? patternLane;
    if (fast && lastLanes.length == 1) {
      final last = lastLanes.first;
      final trill = prevLanes.length == 1 && prevLanes.first != last && p.jackAllowance + p.chordAllowance > 0.25;
      if (trill && rng.chance(0.45)) {
        patternLane = prevLanes.first;
      } else {
        var next = last + stairDir;
        if (next < 0 || next >= lanes) {
          stairDir = -stairDir;
          next = last + stairDir;
        }
        patternLane = next;
      }
    }

    final weights = List<double>.filled(lanes, 0);
    for (final l in free) {
      var w = math.exp(-math.pow(l - target, 2) / (2 * sigma * sigma)) + 0.15;
      if (patternLane == l) w *= 3.5;
      // Jacks.
      if (lastLanes.contains(l)) {
        final slow = gap >= beat * 1.5;
        if (!slow) {
          final allowance = p.jackAllowance * (gap >= beat / 2 ? 1.0 : 0.6);
          w *= allowance <= 0 ? 0.0 : allowance;
        } else {
          w *= 0.5;
        }
      }
      // Lanes that were used very recently feel cramped.
      if (t - laneLastTime[l] < p.minGapMs * 1.5 && !lastLanes.contains(l)) w *= 0.7;
      // Hand alternation in streams.
      if (fast && lanes >= 4 && lastLanes.isNotEmpty) {
        final half = lanes / 2;
        final lastLeft = lastLanes.first < half;
        final left = l < half;
        if (lastLeft != left) w *= 1.4;
      }
      weights[l] = w;
    }
    if (weights.every((w) => w <= 0)) {
      // Only jack lanes remain: allow them rather than dropping the note.
      for (final l in free) {
        weights[l] = 1;
      }
    }

    final chosen = <int>[];
    for (var j = 0; j < k; j++) {
      if (weights.every((w) => w <= 0)) break;
      final l = rng.weighted(weights);
      chosen.add(l);
      weights[l] = 0;
    }
    chosen.sort();

    // --- holds ------------------------------------------------------------------
    double? holdEnd;
    final sustain = c.sustainEndMs;
    if (sustain != null && rng.chance(p.holdFrequency * (0.5 + 0.5 * c.strength) * 1.6)) {
      var end = sustain;
      if (!overlapHolds) end = math.min(end, nextTime - releaseGap);
      final minHold = math.max(beat * (p.snapDivisor == 1 ? 1.0 : 0.5), 180.0);
      if (end - t >= minHold) holdEnd = end;
    }

    for (var j = 0; j < chosen.length; j++) {
      final l = chosen[j];
      final isHold = holdEnd != null && j == 0;
      notes.add(TileNote(timeMs: t, lane: l, endTimeMs: isHold ? holdEnd : null));
      laneLastTime[l] = t;
      laneFreeAt[l] = isHold ? holdEnd + math.min(p.minGapMs, beat / 2) : t;
    }
    if (holdEnd != null && !overlapHolds) {
      // Nothing else may start while the hold is down.
      for (var l = 0; l < lanes; l++) {
        laneFreeAt[l] = math.max(laneFreeAt[l], holdEnd + releaseGap * 0.5);
      }
    }
    prevLanes = lastLanes;
    lastLanes = chosen;
    lastTime = t;
    if (rng.chance(0.12)) stairDir = -stairDir;
  }
  notes.sort((x, y) => x.timeMs != y.timeMs ? x.timeMs.compareTo(y.timeMs) : x.lane.compareTo(y.lane));
  return notes;
}
