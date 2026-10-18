import 'dart:math' as math;

import '../models/analysis.dart';
import '../models/difficulty.dart';
import '../models/timing.dart';

/// A rhythmic event chosen for the map, before mode-specific placement.
class NoteCandidate {
  NoteCandidate({
    required this.timeMs,
    required this.pos,
    required this.strength,
    required this.score,
    required this.onset,
  });

  /// Snapped time.
  final double timeMs;

  /// Where it sits on the beat grid.
  final GridPosition pos;
  final double strength;
  final double score;
  final Onset onset;

  /// Snapped end of a sustained sound starting here, if any.
  double? sustainEndMs;
  Band? sustainBand;

  double? get sustainMs => sustainEndMs == null ? null : sustainEndMs! - timeMs;

  /// On the first beat of a bar.
  bool get barStart => pos.downbeat;

  /// On beat 1 or 3 of a bar.
  bool get strongBeat => pos.onBeat && pos.barBeat.isEven;
}

/// Grid division notes snap to in a section: the difficulty's 1, 2 or 4, or
/// in triplet sections whole beats (Easy) or thirds.
int gridDivisor(TimingPoint section, int snapDivisor) =>
    section.triplet ? (snapDivisor <= 1 ? 1 : 3) : math.max(1, snapDivisor);

/// Whether a grid position is allowed at a difficulty's snap divisor.
bool _native(GridPosition pos, int snapDivisor) {
  if (pos.subdivisions == 4) return pos.sub % (4 ~/ snapDivisor.clamp(1, 4)) == 0;
  return snapDivisor <= 1 ? pos.sub == 0 : true;
}

class TimeRange {
  const TimeRange(this.startMs, this.endMs);
  final double startMs;
  final double endMs;

  bool contains(double t) => t >= startMs && t <= endMs;
  double get durationMs => endMs - startMs;

  Map<String, dynamic> toJson() => {'startMs': startMs, 'endMs': endMs};
}

/// Quiet stretches long enough to rest in. No notes are placed inside them.
List<TimeRange> findBreaks(SongAnalysis a, {double minLengthMs = 3200}) {
  if (a.energy.isEmpty) return const [];
  final sorted = List<double>.of(a.energy)..sort();
  final median = sorted[sorted.length ~/ 2];
  final threshold = math.min(0.32, median * 0.55);
  final res = a.energyResolutionMs;
  final breaks = <TimeRange>[];
  int? start;
  for (var i = 0; i <= a.energy.length; i++) {
    final t = i * res;
    final quiet = i < a.energy.length && a.smoothedEnergyAt(t, 1200) < threshold;
    if (quiet) {
      start ??= i;
    } else if (start != null) {
      final s = start * res, e = i * res;
      if (e - s >= minLengthMs) breaks.add(TimeRange(s, e));
      start = null;
    }
  }
  return breaks;
}

/// Loud, sustained stretches (choruses, drops) become kiai sections,
/// starting and ending on downbeats.
List<TimeSpan> findKiai(SongAnalysis a) {
  if (a.energy.length < 20) return const [];
  final res = a.energyResolutionMs;
  final smooth = [for (var i = 0; i < a.energy.length; i++) a.smoothedEnergyAt(i * res, 4000)];
  final sorted = List<double>.of(smooth)..sort();
  var threshold = math.max(0.55, sorted[(sorted.length * 0.72).floor()]);
  final grid = a.grid;
  double downbeatNear(double t) {
    var best = t;
    var bestD = double.infinity;
    final beat = grid.beatLengthAt(t);
    for (final l in grid.lines(t - beat * 4.5, t + beat * 4.5, 1)) {
      if (l.kind != GridLineKind.downbeat) continue;
      final d = (l.timeMs - t).abs();
      if (d < bestD) {
        bestD = d;
        best = l.timeMs;
      }
    }
    return best;
  }

  for (var attempt = 0; attempt < 4; attempt++) {
    final spans = <TimeSpan>[];
    int? start;
    for (var i = 0; i <= smooth.length; i++) {
      final loud = i < smooth.length && smooth[i] >= threshold;
      if (loud) {
        start ??= i;
      } else if (start != null) {
        final s = downbeatNear(start * res), e = downbeatNear(i * res);
        if (e - s >= grid.beatLengthAt(s) * 8) spans.add(TimeSpan(s, math.min(e, a.durationMs)));
        start = null;
      }
    }
    final total = spans.fold(0.0, (s, k) => s + k.durationMs);
    if (total <= a.durationMs * 0.45 || attempt == 3) return spans;
    threshold += 0.05;
  }
  return const [];
}

/// Snaps onsets to the beat grid, scores them, filters by difficulty and
/// enforces the minimum gap. Returns candidates sorted by time.
List<NoteCandidate> selectNotes(
  SongAnalysis a,
  DifficultyParams p, {
  List<TimeRange>? breaks,
}) {
  final grid = a.grid;
  final allBreaks = breaks ?? findBreaks(a);

  // 1. One candidate per grid slot (1/4 beats, or 1/3 in triplet sections);
  //    the strongest onset wins.
  final bySlot = <int, NoteCandidate>{};
  for (final o in a.onsets) {
    final snapped = grid.snapNatural(o.timeMs);
    final t = snapped.timeMs;
    if (t < 0 || t > a.durationMs - 100) continue;
    final energy = a.smoothedEnergyAt(t, 600);
    final score = o.strength * (0.6 + 0.4 * energy);
    final key = snapped.pos.key;
    final existing = bySlot[key];
    if (existing == null || existing.score < score) {
      bySlot[key] = NoteCandidate(timeMs: t, pos: snapped.pos, strength: o.strength, score: score, onset: o);
    }
  }

  // 2. Divisor and strength filter.
  bool inBreak(double t) => allBreaks.any((b) => t > b.startMs - 150 && t < b.endMs + 150);
  final eligible = <NoteCandidate>[];
  final fill = <NoteCandidate>[];
  for (final c in bySlot.values) {
    if (inBreak(c.timeMs)) continue;
    final native = _native(c.pos, p.snapDivisor);
    final passes = native
        ? c.score >= p.strengthThreshold
        : c.score >= math.max(0.75, p.strengthThreshold + 0.4);
    if (passes) {
      eligible.add(c);
    } else if (native && c.score >= p.strengthThreshold * 0.35) {
      fill.add(c);
    }
  }

  // 3. Greedy by score with the minimum gap.
  final accepted = _GapSet(p.minGapMs);
  eligible.sort((x, y) => y.score.compareTo(x.score));
  for (final c in eligible) {
    accepted.tryAdd(c);
  }

  // 4. Fill long empty stretches in loud sections so easy maps don't go
  //    silent through syncopated passages.
  fill.sort((x, y) => y.score.compareTo(x.score));
  for (final c in fill) {
    final energy = a.smoothedEnergyAt(c.timeMs, 1000);
    if (energy < 0.35) continue;
    final fillGap = grid.beatLengthAt(c.timeMs) * (p.snapDivisor == 1 ? 2.0 : 1.5);
    final gap = accepted.gapAround(c.timeMs);
    if (gap > fillGap) accepted.tryAdd(c);
  }

  // 5. Density cap: drop the weakest notes until under maxNotesPerSecond.
  var notes = accepted.sorted;
  final breakMs = allBreaks.fold(0.0, (s, b) => s + b.durationMs);
  final activeSec = math.max(10.0, (a.durationMs - breakMs) / 1000);
  final cap = (p.maxNotesPerSecond * activeSec).floor();
  if (notes.length > cap) {
    final keep = (List<NoteCandidate>.of(notes)..sort((x, y) => y.score.compareTo(x.score))).take(cap).toSet();
    notes = notes.where(keep.contains).toList();
  }

  // 6. Attach sustained sounds, snapped to the grid.
  for (final c in notes) {
    final beat = grid.beatLengthAt(c.timeMs);
    final slotLen = beat / 4;
    final minSustain = math.max(beat * (p.snapDivisor == 1 ? 1.0 : 0.5), 200.0);
    SustainRegion? best;
    for (final s in a.sustains) {
      if ((s.startMs - c.onset.timeMs).abs() <= slotLen * 0.75) {
        if (best == null || s.durationMs > best.durationMs) best = s;
      }
      if (s.startMs > c.onset.timeMs + slotLen) break;
    }
    if (best == null) continue;
    final endSection = grid.at(best.endMs);
    final div = gridDivisor(endSection, p.snapDivisor);
    final holdStep = endSection.beatLengthMs / div;
    var end = grid.snap(best.endMs, div);
    // Nothing may outlast the audio.
    final lastAllowed = a.durationMs - 300;
    while (end > lastAllowed) {
      end -= holdStep;
    }
    if (end - c.timeMs >= minSustain) {
      c.sustainEndMs = end;
      c.sustainBand = best.band;
    }
  }
  return notes;
}

/// Sorted set of candidates that keeps a minimum time gap between members.
class _GapSet {
  _GapSet(this.minGap);
  final double minGap;
  final List<NoteCandidate> _items = [];

  List<NoteCandidate> get sorted => List.unmodifiable(_items);

  int _lowerBound(double t) {
    var lo = 0, hi = _items.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_items[mid].timeMs < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  bool tryAdd(NoteCandidate c) {
    final i = _lowerBound(c.timeMs);
    if (i < _items.length && _items[i].timeMs - c.timeMs < minGap - 0.5) return false;
    if (i > 0 && c.timeMs - _items[i - 1].timeMs < minGap - 0.5) return false;
    _items.insert(i, c);
    return true;
  }

  /// Size of the empty stretch that [t] would fall into.
  double gapAround(double t) {
    final i = _lowerBound(t);
    final next = i < _items.length ? _items[i].timeMs : double.infinity;
    final prev = i > 0 ? _items[i - 1].timeMs : double.negativeInfinity;
    return next - prev;
  }
}
