import 'dart:math' as math;

import '../models/analysis.dart';
import '../models/difficulty.dart';

/// A rhythmic event chosen for the map, before mode-specific placement.
class NoteCandidate {
  NoteCandidate({
    required this.timeMs,
    required this.slot,
    required this.strength,
    required this.score,
    required this.onset,
  });

  /// Snapped time.
  final double timeMs;

  /// Index on the 1/4 grid (0 = beat at beatOffsetMs).
  final int slot;
  final double strength;
  final double score;
  final Onset onset;

  /// Snapped end of a sustained sound starting here, if any.
  double? sustainEndMs;
  Band? sustainBand;

  double? get sustainMs => sustainEndMs == null ? null : sustainEndMs! - timeMs;

  /// Position within the bar: 0 = downbeat, 4 = beat 2, ... (1/4 grid).
  int barSlot(int barOffsetBeats) => ((slot - barOffsetBeats * 4) % 16 + 16) % 16;
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

/// Snaps onsets to the beat grid, scores them, filters by difficulty and
/// enforces the minimum gap. Returns candidates sorted by time.
List<NoteCandidate> selectNotes(
  SongAnalysis a,
  DifficultyParams p, {
  List<TimeRange>? breaks,
}) {
  final beat = a.beatLengthMs;
  final slotLen = beat / 4;
  final allBreaks = breaks ?? findBreaks(a);

  // 1. One candidate per 1/4 grid slot (strongest onset wins).
  final bySlot = <int, NoteCandidate>{};
  for (final o in a.onsets) {
    final slot = ((o.timeMs - a.beatOffsetMs) / slotLen).round();
    final t = a.beatOffsetMs + slot * slotLen;
    if (t < 0 || t > a.durationMs - 100) continue;
    final energy = a.smoothedEnergyAt(t, 600);
    final score = o.strength * (0.6 + 0.4 * energy);
    final existing = bySlot[slot];
    if (existing == null || existing.score < score) {
      bySlot[slot] = NoteCandidate(timeMs: t, slot: slot, strength: o.strength, score: score, onset: o);
    }
  }

  // 2. Divisor and strength filter.
  final step = 4 ~/ p.snapDivisor.clamp(1, 4);
  bool inBreak(double t) => allBreaks.any((b) => t > b.startMs - 150 && t < b.endMs + 150);
  final eligible = <NoteCandidate>[];
  final fill = <NoteCandidate>[];
  for (final c in bySlot.values) {
    if (inBreak(c.timeMs)) continue;
    final native = c.slot % step == 0;
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
  final fillGap = beat * (p.snapDivisor == 1 ? 2.0 : 1.5);
  fill.sort((x, y) => y.score.compareTo(x.score));
  for (final c in fill) {
    final energy = a.smoothedEnergyAt(c.timeMs, 1000);
    if (energy < 0.35) continue;
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
  final holdStep = beat / math.max(1, p.snapDivisor);
  final minSustain = math.max(beat * (p.snapDivisor == 1 ? 1.0 : 0.5), 200.0);
  for (final c in notes) {
    SustainRegion? best;
    for (final s in a.sustains) {
      if ((s.startMs - c.onset.timeMs).abs() <= slotLen * 0.75) {
        if (best == null || s.durationMs > best.durationMs) best = s;
      }
      if (s.startMs > c.onset.timeMs + slotLen) break;
    }
    if (best == null) continue;
    var end = a.beatOffsetMs + ((best.endMs - a.beatOffsetMs) / holdStep).round() * holdStep;
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
