import 'dart:math' as math;

/// A stretch of the song with one tempo. Beats fall on
/// `timeMs + k * beatLengthMs`; the section runs until the next point.
///
/// `{ timeMs, beatLengthMs, meter, barOffsetBeats, triplet }`
class TimingPoint {
  const TimingPoint({
    required this.timeMs,
    required this.beatLengthMs,
    this.meter = 4,
    this.barOffsetBeats = 0,
    this.triplet = false,
  });

  /// A beat of this section (its first one, for every point but the first).
  final double timeMs;
  final double beatLengthMs;

  /// Beats per bar.
  final int meter;

  /// Which beat after [timeMs] (0..meter-1) is a downbeat.
  final int barOffsetBeats;

  /// The rhythm moves in thirds of a beat (triplets, swing).
  final bool triplet;

  double get bpm => 60000.0 / beatLengthMs;

  /// Beat positions within a beat that notes snap to: 4 (sixteenths) or 3.
  int get subdivisions => triplet ? 3 : 4;

  TimingPoint copyWith({double? timeMs, double? beatLengthMs, int? meter, int? barOffsetBeats, bool? triplet}) =>
      TimingPoint(
        timeMs: timeMs ?? this.timeMs,
        beatLengthMs: beatLengthMs ?? this.beatLengthMs,
        meter: meter ?? this.meter,
        barOffsetBeats: barOffsetBeats ?? this.barOffsetBeats,
        triplet: triplet ?? this.triplet,
      );

  Map<String, dynamic> toJson() => {
        'timeMs': _r1(timeMs),
        'beatLengthMs': (beatLengthMs * 1000).roundToDouble() / 1000,
        if (meter != 4) 'meter': meter,
        if (barOffsetBeats != 0) 'barOffsetBeats': barOffsetBeats,
        if (triplet) 'triplet': true,
      };

  factory TimingPoint.fromJson(Map<String, dynamic> j) => TimingPoint(
        timeMs: (j['timeMs'] as num).toDouble(),
        beatLengthMs: (j['beatLengthMs'] as num).toDouble(),
        meter: (j['meter'] as num?)?.toInt() ?? 4,
        barOffsetBeats: (j['barOffsetBeats'] as num?)?.toInt() ?? 0,
        triplet: j['triplet'] as bool? ?? false,
      );

  @override
  String toString() => 'TimingPoint(${timeMs.toStringAsFixed(1)} ms, ${bpm.toStringAsFixed(2)} BPM${triplet ? ', triplet' : ''})';
}

/// Where a time sits on the grid: beat [beat] (counted across sections from
/// the first point), [sub] of [subdivisions] parts into it.
class GridPosition {
  const GridPosition(this.section, this.beat, this.sub, this.subdivisions, this.barBeat);
  final int section;
  final int beat;
  final int sub;
  final int subdivisions;

  /// Beat within the bar, 0 = downbeat.
  final int barBeat;

  bool get onBeat => sub == 0;
  bool get downbeat => sub == 0 && barBeat == 0;

  /// Unique key on a 12-per-beat lattice (fits both 1/4 and 1/3 grids).
  int get key => beat * 12 + sub * (12 ~/ subdivisions);
}

enum GridLineKind { downbeat, beat, sub }

class GridLine {
  const GridLine(this.timeMs, this.kind, this.index);
  final double timeMs;
  final GridLineKind kind;

  /// Position within the beat (0 on beats).
  final int index;
}

/// The beat grid of a song: one or more [TimingPoint]s.
class BeatGrid {
  BeatGrid(List<TimingPoint> points)
      : points = (List<TimingPoint>.of(points)..sort((a, b) => a.timeMs.compareTo(b.timeMs))) {
    if (this.points.isEmpty) throw ArgumentError('a grid needs at least one timing point');
    var beats = 0;
    for (var i = 0; i < this.points.length; i++) {
      _firstBeat.add(beats);
      if (i + 1 < this.points.length) {
        final p = this.points[i];
        beats += ((this.points[i + 1].timeMs - p.timeMs) / p.beatLengthMs).round();
      }
    }
  }

  factory BeatGrid.single({required double bpm, required double offsetMs, int barOffsetBeats = 0}) =>
      BeatGrid([TimingPoint(timeMs: offsetMs, beatLengthMs: 60000 / bpm, barOffsetBeats: barOffsetBeats)]);

  final List<TimingPoint> points;
  final List<int> _firstBeat = [];

  bool get isSingle => points.length == 1;

  /// Index of the section that contains [t] (the first one before it starts).
  int sectionAt(double t) {
    var lo = 0, hi = points.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (points[mid].timeMs <= t + 0.5) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  TimingPoint at(double t) => points[sectionAt(t)];

  double beatLengthAt(double t) => at(t).beatLengthMs;

  /// Snaps [t] to the nearest 1/[divisor] of a beat in its section. Grid
  /// lines never pass the next section's first beat.
  double snap(double t, int divisor) {
    final i = sectionAt(t);
    final p = points[i];
    final step = p.beatLengthMs / math.max(1, divisor);
    var s = p.timeMs + ((t - p.timeMs) / step).round() * step;
    if (i + 1 < points.length) {
      final next = points[i + 1].timeMs;
      if (s > next - step / 2) s = next;
    }
    return s;
  }

  /// Snaps [t] to the section's own subdivision grid (1/4, or 1/3 in triplet
  /// sections) and says where it landed.
  ({double timeMs, GridPosition pos}) snapNatural(double t) {
    var i = sectionAt(t);
    var p = points[i];
    final subs = p.subdivisions;
    final step = p.beatLengthMs / subs;
    var k = ((t - p.timeMs) / step).round();
    var time = p.timeMs + k * step;
    if (i + 1 < points.length && time > points[i + 1].timeMs - step / 2) {
      i++;
      p = points[i];
      k = 0;
      time = p.timeMs;
    }
    final beatInSection = (k / subs).floor();
    final sub = k - beatInSection * subs;
    return (timeMs: time, pos: _position(i, beatInSection, sub, p.subdivisions));
  }

  GridPosition _position(int section, int beatInSection, int sub, int subs) {
    final p = points[section];
    final barBeat = ((beatInSection - p.barOffsetBeats) % p.meter + p.meter) % p.meter;
    return GridPosition(section, _firstBeat[section] + beatInSection, sub, subs, barBeat);
  }

  /// Grid lines between [from] and [to] at 1/[divisor] beats (per section).
  Iterable<GridLine> lines(double from, double to, int divisor) sync* {
    final d = math.max(1, divisor);
    for (var i = sectionAt(from); i < points.length; i++) {
      final p = points[i];
      final end = i + 1 < points.length ? points[i + 1].timeMs : double.infinity;
      final step = p.beatLengthMs / d;
      final start = math.max(from, p.timeMs - (i == 0 ? double.infinity : 0));
      var k = ((start - p.timeMs) / step).ceil();
      for (var t = p.timeMs + k * step; t <= to && t < end - 0.5; t = p.timeMs + (++k) * step) {
        final beatInSection = (k / d).floor();
        final sub = k - beatInSection * d;
        final barBeat = ((beatInSection - p.barOffsetBeats) % p.meter + p.meter) % p.meter;
        yield GridLine(t, sub != 0 ? GridLineKind.sub : (barBeat == 0 ? GridLineKind.downbeat : GridLineKind.beat), sub);
      }
      if (end > to) break;
    }
  }

  /// Beat times between [from] and [to].
  Iterable<double> beats(double from, double to) => lines(from, to, 1).map((l) => l.timeMs);

  List<Map<String, dynamic>> toJson() => points.map((p) => p.toJson()).toList();

  static BeatGrid? fromJson(Object? j) {
    if (j is! List || j.isEmpty) return null;
    return BeatGrid(j.map((e) => TimingPoint.fromJson((e as Map).cast<String, dynamic>())).toList());
  }
}

/// A span of song time, e.g. a kiai section or a break.
class TimeSpan {
  const TimeSpan(this.startMs, this.endMs);
  final double startMs;
  final double endMs;

  bool contains(double t) => t >= startMs && t <= endMs;
  double get durationMs => endMs - startMs;

  List<double> toJson() => [_r1(startMs), _r1(endMs)];

  static TimeSpan fromJson(Object? j) {
    final l = j as List;
    return TimeSpan((l[0] as num).toDouble(), (l[1] as num).toDouble());
  }
}

double _r1(double v) => (v * 10).roundToDouble() / 10;
