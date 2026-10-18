import 'dart:math' as math;

import 'difficulty.dart';
import 'timing.dart';

enum TileNoteType { tap, hold }

/// Tiles mode object: `{ type: "tap" | "hold", timeMs, lane, endTimeMs? }`.
class TileNote {
  const TileNote({required this.timeMs, required this.lane, this.endTimeMs});

  final double timeMs;
  final int lane;
  final double? endTimeMs;

  TileNoteType get type => endTimeMs == null ? TileNoteType.tap : TileNoteType.hold;
  bool get isHold => endTimeMs != null;
  double get endMs => endTimeMs ?? timeMs;

  TileNote copyWith({double? timeMs, int? lane, double? endTimeMs, bool clearEnd = false}) =>
      TileNote(
        timeMs: timeMs ?? this.timeMs,
        lane: lane ?? this.lane,
        endTimeMs: clearEnd ? null : (endTimeMs ?? this.endTimeMs),
      );

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'timeMs': _r1(timeMs),
        'lane': lane,
        if (endTimeMs != null) 'endTimeMs': _r1(endTimeMs!),
      };

  factory TileNote.fromJson(Map<String, dynamic> j) {
    final type = j['type'] as String? ?? 'tap';
    return TileNote(
      timeMs: (j['timeMs'] as num).toDouble(),
      lane: (j['lane'] as num).toInt(),
      endTimeMs: type == 'hold' ? (j['endTimeMs'] as num?)?.toDouble() : null,
    );
  }
}

enum CircleObjectType { circle, slider, spinner }

/// How a slider's [CircleObject.path] is read.
enum SliderPathKind {
  /// One Bezier curve through the control polygon (generated maps, editor).
  bezier,

  /// A polyline, already sampled (imported osu! sliders).
  linear,
}

/// Circles mode object, in normalized playfield coordinates (0..1).
/// `{ type, timeMs, x, y, comboIndex, path?, curve?, repeats?, tickMs?, endTimeMs? }`.
///
/// For sliders, [path] starts at (x, y). The ball travels the path
/// `repeats + 1` times, turning back at each end; slider ticks fall every
/// [tickMs] along each pass. Spinners sit at the playfield centre.
class CircleObject {
  const CircleObject({
    required this.type,
    required this.timeMs,
    required this.x,
    required this.y,
    required this.comboIndex,
    this.path,
    this.endTimeMs,
    this.repeats = 0,
    this.tickMs,
    this.curve = SliderPathKind.bezier,
  });

  final CircleObjectType type;
  final double timeMs;
  final double x;
  final double y;

  /// Combo group this object belongs to. Increments at phrase boundaries.
  final int comboIndex;
  final List<Point2>? path;
  final double? endTimeMs;

  /// Slider: times the ball turns back.
  final int repeats;

  /// Slider: song ms between ticks on each pass (null: no ticks).
  final double? tickMs;
  final SliderPathKind curve;

  double get endMs => endTimeMs ?? timeMs;
  bool get isSlider => type == CircleObjectType.slider;
  bool get isSpinner => type == CircleObjectType.spinner;

  /// Song ms of one pass along the path.
  double get spanMs => (endMs - timeMs) / (repeats + 1);

  /// Where the slider finishes (its head again after an odd number of
  /// repeats), or the object itself.
  Point2 get endPosition {
    if (!isSlider || path == null || path!.isEmpty) return Point2(x, y);
    return repeats.isOdd ? Point2(x, y) : path!.last;
  }

  /// Song times of the slider ticks, in order.
  List<double> tickTimes() {
    final step = tickMs;
    if (!isSlider || step == null || step <= 1 || endTimeMs == null) return const [];
    final span = spanMs;
    final offsets = <double>[];
    for (var d = step; d < span - 10; d += step) {
      offsets.add(d);
    }
    final out = <double>[];
    for (var j = 0; j <= repeats; j++) {
      final start = timeMs + j * span;
      if (j.isEven) {
        for (final d in offsets) {
          out.add(start + d);
        }
      } else {
        for (final d in offsets.reversed) {
          out.add(start + span - d);
        }
      }
    }
    return out;
  }

  /// Song times the ball turns back.
  List<double> repeatTimes() => [for (var j = 1; j <= repeats; j++) timeMs + j * spanMs];

  /// Judgments that only feed the combo: ticks and repeats.
  int get comboEvents => isSlider ? tickTimes().length + repeats : 0;

  CircleObject copyWith({
    CircleObjectType? type,
    double? timeMs,
    double? x,
    double? y,
    int? comboIndex,
    List<Point2>? path,
    double? endTimeMs,
    int? repeats,
    double? tickMs,
    SliderPathKind? curve,
  }) =>
      CircleObject(
        type: type ?? this.type,
        timeMs: timeMs ?? this.timeMs,
        x: x ?? this.x,
        y: y ?? this.y,
        comboIndex: comboIndex ?? this.comboIndex,
        path: path ?? this.path,
        endTimeMs: endTimeMs ?? this.endTimeMs,
        repeats: repeats ?? this.repeats,
        tickMs: tickMs ?? this.tickMs,
        curve: curve ?? this.curve,
      );

  /// Moves the object (and its slider path) by a delta.
  CircleObject translated(double dx, double dy) => copyWith(
        x: x + dx,
        y: y + dy,
        path: path?.map((p) => Point2(p.x + dx, p.y + dy)).toList(),
      );

  CircleObject mirrored() => copyWith(
        x: 1 - x,
        path: path?.map((p) => Point2(1 - p.x, p.y)).toList(),
      );

  /// Upside down (Hard Rock).
  CircleObject flipped() => copyWith(
        y: 1 - y,
        path: path?.map((p) => Point2(p.x, 1 - p.y)).toList(),
      );

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'timeMs': _r1(timeMs),
        'x': _r4(x),
        'y': _r4(y),
        'comboIndex': comboIndex,
        if (path != null) 'path': path!.map((p) => [_r4(p.x), _r4(p.y)]).toList(),
        if (isSlider && curve != SliderPathKind.bezier) 'curve': curve.name,
        if (repeats > 0) 'repeats': repeats,
        if (tickMs != null) 'tickMs': _r1(tickMs!),
        if (endTimeMs != null) 'endTimeMs': _r1(endTimeMs!),
      };

  factory CircleObject.fromJson(Map<String, dynamic> j) => CircleObject(
        type: CircleObjectType.values.asNameMap()[j['type']] ?? CircleObjectType.circle,
        timeMs: (j['timeMs'] as num).toDouble(),
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        comboIndex: (j['comboIndex'] as num?)?.toInt() ?? 0,
        path: (j['path'] as List?)
            ?.map((p) => Point2(((p as List)[0] as num).toDouble(), (p[1] as num).toDouble()))
            .toList(),
        endTimeMs: (j['endTimeMs'] as num?)?.toDouble(),
        repeats: (j['repeats'] as num?)?.toInt() ?? 0,
        tickMs: (j['tickMs'] as num?)?.toDouble(),
        curve: SliderPathKind.values.asNameMap()[j['curve']] ?? SliderPathKind.bezier,
      );
}

class Point2 {
  const Point2(this.x, this.y);
  final double x;
  final double y;

  Point2 operator +(Point2 o) => Point2(x + o.x, y + o.y);
  Point2 operator -(Point2 o) => Point2(x - o.x, y - o.y);
  Point2 operator *(double s) => Point2(x * s, y * s);
  double get length => math.sqrt(x * x + y * y);
  double distanceTo(Point2 o) => (this - o).length;

  @override
  bool operator ==(Object other) => other is Point2 && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Point2(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)})';
}

class BeatmapMetadata {
  const BeatmapMetadata({required this.title, required this.artist, required this.creator});

  final String title;
  final String artist;
  final String creator;

  Map<String, dynamic> toJson() => {'title': title, 'artist': artist, 'creator': creator};

  factory BeatmapMetadata.fromJson(Map<String, dynamic> j) => BeatmapMetadata(
        title: j['title'] as String? ?? '',
        artist: j['artist'] as String? ?? '',
        creator: j['creator'] as String? ?? '',
      );
}

/// A playable difficulty. Serialized as `beatmap.json`.
class Beatmap {
  Beatmap({
    required this.id,
    required this.songId,
    required this.mode,
    required this.name,
    required this.metadata,
    required this.difficulty,
    required this.seed,
    required this.starRating,
    required this.createdAt,
    this.edited = false,
    this.tileNotes = const [],
    this.circleObjects = const [],
    this.timing = const [],
    this.kiai = const [],
    this.origin,
    this.formatVersion = currentFormatVersion,
  });

  /// 2: slider repeats and ticks, timing points, kiai, origin, hpDrain.
  static const currentFormatVersion = 2;

  final int formatVersion;
  final String id;
  final String songId;
  final GameMode mode;
  final String name;
  final BeatmapMetadata metadata;
  final DifficultyParams difficulty;
  final int seed;
  final double starRating;
  final bool edited;
  final DateTime createdAt;
  final List<TileNote> tileNotes;
  final List<CircleObject> circleObjects;

  /// The map's beat grid (empty for maps saved before version 2).
  final List<TimingPoint> timing;

  /// Loud, climactic stretches: the playfield pulses on the beat.
  final List<TimeSpan> kiai;

  /// Where the map came from: null (generated or edited here) or "osu".
  final String? origin;

  BeatGrid? get grid => timing.isEmpty ? null : BeatGrid(timing);

  int get objectCount => mode == GameMode.tiles ? tileNotes.length : circleObjects.length;

  double get firstObjectMs {
    if (mode == GameMode.tiles) return tileNotes.isEmpty ? 0 : tileNotes.first.timeMs;
    return circleObjects.isEmpty ? 0 : circleObjects.first.timeMs;
  }

  double get lastObjectEndMs {
    var end = 0.0;
    if (mode == GameMode.tiles) {
      for (final n in tileNotes) {
        end = math.max(end, n.endMs);
      }
    } else {
      for (final o in circleObjects) {
        end = math.max(end, o.endMs);
      }
    }
    return end;
  }

  /// Number of judgments a full play produces (holds and sliders count twice).
  int get judgmentCount {
    if (mode == GameMode.tiles) {
      return tileNotes.fold(0, (s, n) => s + (n.isHold ? 2 : 1));
    }
    return circleObjects.fold(0, (s, o) => s + (o.isSlider ? 2 : 1));
  }

  /// Longest combo a perfect run reaches (slider ticks and repeats count).
  int get maxCombo {
    if (mode == GameMode.tiles) return judgmentCount;
    return circleObjects.fold(0, (s, o) => s + (o.isSlider ? 2 + o.comboEvents : 1));
  }

  Beatmap copyWith({
    String? id,
    String? name,
    BeatmapMetadata? metadata,
    DifficultyParams? difficulty,
    int? seed,
    double? starRating,
    bool? edited,
    DateTime? createdAt,
    List<TileNote>? tileNotes,
    List<CircleObject>? circleObjects,
    List<TimingPoint>? timing,
    List<TimeSpan>? kiai,
  }) =>
      Beatmap(
        id: id ?? this.id,
        songId: songId,
        mode: mode,
        name: name ?? this.name,
        metadata: metadata ?? this.metadata,
        difficulty: difficulty ?? this.difficulty,
        seed: seed ?? this.seed,
        starRating: starRating ?? this.starRating,
        createdAt: createdAt ?? this.createdAt,
        edited: edited ?? this.edited,
        tileNotes: tileNotes ?? this.tileNotes,
        circleObjects: circleObjects ?? this.circleObjects,
        timing: timing ?? this.timing,
        kiai: kiai ?? this.kiai,
        origin: origin,
      );

  Map<String, dynamic> toJson() => {
        'formatVersion': formatVersion,
        'id': id,
        'songId': songId,
        'mode': mode.name,
        'name': name,
        'metadata': metadata.toJson(),
        'difficulty': difficulty.toJson(),
        'seed': seed,
        'starRating': (starRating * 100).roundToDouble() / 100,
        'edited': edited,
        'createdAt': createdAt.toUtc().toIso8601String(),
        if (timing.isNotEmpty) 'timing': timing.map((t) => t.toJson()).toList(),
        if (kiai.isNotEmpty) 'kiai': kiai.map((k) => k.toJson()).toList(),
        if (origin != null) 'origin': origin,
        'objects': mode == GameMode.tiles
            ? tileNotes.map((n) => n.toJson()).toList()
            : circleObjects.map((o) => o.toJson()).toList(),
      };

  factory Beatmap.fromJson(Map<String, dynamic> j) {
    final version = j['formatVersion'] as int? ?? 1;
    if (version > currentFormatVersion) {
      throw FormatException('beatmap.json formatVersion $version is newer than supported');
    }
    final mode = GameMode.values.byName(j['mode'] as String);
    final objects = (j['objects'] as List).cast<Map<String, dynamic>>();
    return Beatmap(
      formatVersion: version,
      id: j['id'] as String,
      songId: j['songId'] as String,
      mode: mode,
      name: j['name'] as String? ?? 'Untitled',
      metadata: BeatmapMetadata.fromJson((j['metadata'] as Map?)?.cast<String, dynamic>() ?? const {}),
      difficulty: DifficultyParams.fromJson((j['difficulty'] as Map).cast<String, dynamic>()),
      seed: (j['seed'] as num?)?.toInt() ?? 0,
      starRating: (j['starRating'] as num?)?.toDouble() ?? 0,
      edited: j['edited'] as bool? ?? false,
      createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
      tileNotes: mode == GameMode.tiles ? objects.map(TileNote.fromJson).toList() : const [],
      circleObjects: mode == GameMode.circles ? objects.map(CircleObject.fromJson).toList() : const [],
      timing: (j['timing'] as List? ?? const [])
          .map((t) => TimingPoint.fromJson((t as Map).cast<String, dynamic>()))
          .toList(),
      kiai: (j['kiai'] as List? ?? const []).map(TimeSpan.fromJson).toList(),
      origin: j['origin'] as String?,
    );
  }
}

double _r1(double v) => (v * 10).roundToDouble() / 10;
double _r4(double v) => (v * 10000).roundToDouble() / 10000;
