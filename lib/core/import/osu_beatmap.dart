import 'dart:math' as math;

/// A parsed `.osu` difficulty (file format v3–v14). Only what Rhytmaniac
/// plays is kept: metadata, difficulty settings, timing, breaks and hit
/// objects.
class OsuBeatmap {
  OsuBeatmap({
    required this.formatVersion,
    required this.audioFilename,
    required this.audioLeadIn,
    required this.previewTime,
    required this.mode,
    required this.title,
    required this.titleUnicode,
    required this.artist,
    required this.artistUnicode,
    required this.creator,
    required this.version,
    required this.hp,
    required this.cs,
    required this.od,
    required this.ar,
    required this.sliderMultiplier,
    required this.sliderTickRate,
    required this.background,
    required this.breaks,
    required this.timingPoints,
    required this.hitObjects,
  });

  final int formatVersion;
  final String audioFilename;
  final int audioLeadIn;

  /// Song ms where the song-select preview starts (-1: not set).
  final int previewTime;

  /// 0 osu!, 1 taiko, 2 catch, 3 mania.
  final int mode;
  final String title;
  final String titleUnicode;
  final String artist;
  final String artistUnicode;
  final String creator;
  final String version;
  final double hp;
  final double cs;
  final double od;
  final double ar;
  final double sliderMultiplier;
  final double sliderTickRate;

  /// Background image file name inside the beatmap folder, if any.
  final String? background;
  final List<(double, double)> breaks;
  final List<OsuTimingPoint> timingPoints;
  final List<OsuHitObject> hitObjects;

  String get displayTitle => titleUnicode.isNotEmpty ? titleUnicode : title;
  String get displayArtist => artistUnicode.isNotEmpty ? artistUnicode : artist;

  /// Uninherited (red) timing points only.
  List<OsuTimingPoint> get redPoints => timingPoints.where((p) => p.uninherited).toList();

  /// The red point in effect at [t].
  OsuTimingPoint redAt(double t) {
    final reds = redPoints;
    if (reds.isEmpty) return const OsuTimingPoint(time: 0, beatLength: 500, meter: 4, uninherited: true, kiai: false);
    var current = reds.first;
    for (final p in reds) {
      if (p.time > t + 0.5) break;
      current = p;
    }
    return current;
  }

  /// Slider velocity multiplier at [t] (green points; 1 when none).
  double velocityAt(double t) {
    var sv = 1.0;
    for (final p in timingPoints) {
      if (p.time > t + 0.5) break;
      if (p.uninherited) {
        sv = 1.0;
      } else if (p.beatLength < 0) {
        sv = (-100 / p.beatLength).clamp(0.1, 10.0);
      }
    }
    return sv;
  }

  /// Song ms ranges where kiai is on.
  List<(double, double)> kiaiRanges(double endMs) {
    final out = <(double, double)>[];
    double? start;
    for (final p in timingPoints) {
      if (p.kiai && start == null) {
        start = p.time;
      } else if (!p.kiai && start != null) {
        if (p.time > start) out.add((start, p.time));
        start = null;
      }
    }
    if (start != null && endMs > start) out.add((start, endMs));
    return out;
  }
}

class OsuTimingPoint {
  const OsuTimingPoint({
    required this.time,
    required this.beatLength,
    required this.meter,
    required this.uninherited,
    required this.kiai,
  });

  final double time;

  /// Red points: ms per beat. Green points: negative, -100 / velocity.
  final double beatLength;
  final int meter;
  final bool uninherited;
  final bool kiai;
}

enum OsuObjectKind { circle, slider, spinner, hold }

class OsuHitObject {
  const OsuHitObject({
    required this.kind,
    required this.x,
    required this.y,
    required this.time,
    required this.newCombo,
    required this.comboSkip,
    this.curveType = 'B',
    this.curvePoints = const [],
    this.slides = 1,
    this.length = 0,
    this.endTime,
  });

  final OsuObjectKind kind;
  final double x;
  final double y;
  final double time;
  final bool newCombo;
  final int comboSkip;

  /// Slider: B (Bezier), L (linear), P (perfect circle), C (Catmull).
  final String curveType;

  /// Slider control points after the head, in osu! pixels.
  final List<(double, double)> curvePoints;

  /// Slider: passes along the path (1 = no repeat).
  final int slides;

  /// Slider: path length in osu! pixels.
  final double length;

  /// Spinner and hold end.
  final double? endTime;
}

/// Parses `.osu` text. Throws [FormatException] for files that aren't
/// osu! beatmaps.
OsuBeatmap parseOsu(String text) {
  final lines = text.replaceAll('\r', '').split('\n');
  if (lines.isEmpty) throw const FormatException('Empty .osu file');
  final header = lines.first.replaceAll('﻿', '').trim();
  final versionMatch = RegExp(r'osu file format v(\d+)').firstMatch(header);
  if (versionMatch == null) throw const FormatException('Not an osu! beatmap file');
  final formatVersion = int.parse(versionMatch.group(1)!);

  var section = '';
  final kv = <String, Map<String, String>>{};
  final events = <String>[];
  final timing = <String>[];
  final objects = <String>[];
  for (final raw in lines.skip(1)) {
    final line = raw.trimRight();
    if (line.isEmpty || line.startsWith('//')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      section = line.substring(1, line.length - 1);
      continue;
    }
    switch (section) {
      case 'General':
      case 'Metadata':
      case 'Difficulty':
        final i = line.indexOf(':');
        if (i > 0) (kv[section] ??= {})[line.substring(0, i).trim()] = line.substring(i + 1).trim();
      case 'Events':
        events.add(line);
      case 'TimingPoints':
        timing.add(line);
      case 'HitObjects':
        objects.add(line);
    }
  }

  String g(String s, String k, [String d = '']) => kv[s]?[k] ?? d;
  double n(String s, String k, double d) => double.tryParse(g(s, k)) ?? d;

  String? background;
  final breaks = <(double, double)>[];
  for (final e in events) {
    final parts = _csv(e);
    if (parts.isEmpty) continue;
    if ((parts[0] == '0' || parts[0] == 'Background') && parts.length >= 3) {
      background ??= _unquote(parts[2]);
    } else if ((parts[0] == '2' || parts[0] == 'Break') && parts.length >= 3) {
      final s = double.tryParse(parts[1]), en = double.tryParse(parts[2]);
      if (s != null && en != null && en > s) breaks.add((s, en));
    }
  }

  final points = <OsuTimingPoint>[];
  for (final t in timing) {
    final p = t.split(',');
    if (p.length < 2) continue;
    final time = double.tryParse(p[0].trim());
    final beatLength = double.tryParse(p[1].trim());
    if (time == null || beatLength == null || beatLength.isNaN) continue;
    final meter = p.length > 2 ? int.tryParse(p[2].trim()) ?? 4 : 4;
    final uninherited = p.length > 6 ? p[6].trim() == '1' : beatLength > 0;
    final effects = p.length > 7 ? int.tryParse(p[7].trim()) ?? 0 : 0;
    points.add(OsuTimingPoint(
      time: time,
      beatLength: beatLength,
      meter: meter <= 0 ? 4 : meter,
      uninherited: uninherited && beatLength > 0,
      kiai: effects & 1 == 1,
    ));
  }
  points.sort((a, b) => a.time.compareTo(b.time));

  final hits = <OsuHitObject>[];
  for (final o in objects) {
    final p = o.split(',');
    if (p.length < 4) continue;
    final x = double.tryParse(p[0]) ?? 256, y = double.tryParse(p[1]) ?? 192;
    final time = double.tryParse(p[2]);
    final type = int.tryParse(p[3]) ?? 1;
    if (time == null) continue;
    final newCombo = type & 4 != 0;
    final skip = (type >> 4) & 7;
    if (type & 2 != 0 && p.length >= 8) {
      final curve = p[5].split('|');
      final pts = <(double, double)>[];
      for (final c in curve.skip(1)) {
        final xy = c.split(':');
        if (xy.length == 2) pts.add((double.tryParse(xy[0]) ?? x, double.tryParse(xy[1]) ?? y));
      }
      hits.add(OsuHitObject(
        kind: OsuObjectKind.slider,
        x: x,
        y: y,
        time: time,
        newCombo: newCombo,
        comboSkip: skip,
        curveType: curve.first.isEmpty ? 'B' : curve.first,
        curvePoints: pts,
        slides: math.max(1, int.tryParse(p[6]) ?? 1),
        length: double.tryParse(p[7]) ?? 0,
      ));
    } else if (type & 8 != 0 && p.length >= 6) {
      hits.add(OsuHitObject(
        kind: OsuObjectKind.spinner,
        x: 256,
        y: 192,
        time: time,
        newCombo: true,
        comboSkip: skip,
        endTime: double.tryParse(p[5]),
      ));
    } else if (type & 128 != 0 && p.length >= 6) {
      hits.add(OsuHitObject(
        kind: OsuObjectKind.hold,
        x: x,
        y: y,
        time: time,
        newCombo: newCombo,
        comboSkip: skip,
        endTime: double.tryParse(p[5].split(':').first),
      ));
    } else {
      hits.add(OsuHitObject(kind: OsuObjectKind.circle, x: x, y: y, time: time, newCombo: newCombo, comboSkip: skip));
    }
  }
  hits.sort((a, b) => a.time.compareTo(b.time));

  return OsuBeatmap(
    formatVersion: formatVersion,
    audioFilename: g('General', 'AudioFilename'),
    audioLeadIn: n('General', 'AudioLeadIn', 0).round(),
    previewTime: n('General', 'PreviewTime', -1).round(),
    mode: n('General', 'Mode', 0).round(),
    title: g('Metadata', 'Title', 'Untitled'),
    titleUnicode: g('Metadata', 'TitleUnicode'),
    artist: g('Metadata', 'Artist'),
    artistUnicode: g('Metadata', 'ArtistUnicode'),
    creator: g('Metadata', 'Creator'),
    version: g('Metadata', 'Version', 'Normal'),
    hp: n('Difficulty', 'HPDrainRate', 5),
    cs: n('Difficulty', 'CircleSize', 4),
    od: n('Difficulty', 'OverallDifficulty', 5),
    // Old maps without ApproachRate used OD for it.
    ar: n('Difficulty', 'ApproachRate', n('Difficulty', 'OverallDifficulty', 5)),
    sliderMultiplier: n('Difficulty', 'SliderMultiplier', 1.4).clamp(0.4, 3.6),
    sliderTickRate: n('Difficulty', 'SliderTickRate', 1).clamp(0.5, 8),
    background: background,
    breaks: breaks,
    timingPoints: points,
    hitObjects: hits,
  );
}

List<String> _csv(String line) {
  final out = <String>[];
  final b = StringBuffer();
  var quoted = false;
  for (final ch in line.split('')) {
    if (ch == '"') {
      quoted = !quoted;
      b.write(ch);
    } else if (ch == ',' && !quoted) {
      out.add(b.toString().trim());
      b.clear();
    } else {
      b.write(ch);
    }
  }
  out.add(b.toString().trim());
  return out;
}

String _unquote(String s) => s.length >= 2 && s.startsWith('"') && s.endsWith('"') ? s.substring(1, s.length - 1) : s;

// --- slider paths ------------------------------------------------------------------------

/// The slider's path in osu! pixels, cut (or extended in a straight line) to
/// [OsuHitObject.length], as a polyline.
List<(double, double)> osuSliderPath(OsuHitObject o) {
  final ctrl = [(o.x, o.y), ...o.curvePoints];
  List<(double, double)> raw;
  switch (o.curveType) {
    case 'L':
      raw = ctrl;
    case 'P':
      raw = ctrl.length == 3 ? (_circleArc(ctrl[0], ctrl[1], ctrl[2]) ?? _bezierSegments(ctrl)) : _bezierSegments(ctrl);
    case 'C':
      raw = _catmull(ctrl);
    default:
      raw = _bezierSegments(ctrl);
  }
  return _fitLength(raw, o.length);
}

/// osu! Bezier: a repeated control point splits the curve into segments.
List<(double, double)> _bezierSegments(List<(double, double)> ctrl) {
  final out = <(double, double)>[];
  var seg = <(double, double)>[ctrl.first];
  for (var i = 1; i < ctrl.length; i++) {
    final p = ctrl[i];
    if (p == seg.last && seg.length > 1) {
      out.addAll(_bezier(seg, out.isEmpty));
      seg = [p];
    } else {
      seg.add(p);
    }
  }
  if (seg.length > 1) out.addAll(_bezier(seg, out.isEmpty));
  return out.isEmpty ? ctrl : out;
}

List<(double, double)> _bezier(List<(double, double)> c, bool includeFirst) {
  if (c.length == 2) return includeFirst ? c : [c[1]];
  var approxLen = 0.0;
  for (var i = 1; i < c.length; i++) {
    approxLen += _dist(c[i - 1], c[i]);
  }
  final steps = (approxLen / 4).clamp(8, 200).round();
  final out = <(double, double)>[];
  for (var s = includeFirst ? 0 : 1; s <= steps; s++) {
    final t = s / steps;
    var pts = List<(double, double)>.of(c);
    while (pts.length > 1) {
      pts = [
        for (var i = 0; i < pts.length - 1; i++)
          (pts[i].$1 + (pts[i + 1].$1 - pts[i].$1) * t, pts[i].$2 + (pts[i + 1].$2 - pts[i].$2) * t),
      ];
    }
    out.add(pts.first);
  }
  return out;
}

/// Arc through three points, or null when they are (nearly) collinear.
List<(double, double)>? _circleArc((double, double) a, (double, double) b, (double, double) c) {
  final d = 2 * (a.$1 * (b.$2 - c.$2) + b.$1 * (c.$2 - a.$2) + c.$1 * (a.$2 - b.$2));
  if (d.abs() < 1e-3) return null;
  final a2 = a.$1 * a.$1 + a.$2 * a.$2, b2 = b.$1 * b.$1 + b.$2 * b.$2, c2 = c.$1 * c.$1 + c.$2 * c.$2;
  final cx = (a2 * (b.$2 - c.$2) + b2 * (c.$2 - a.$2) + c2 * (a.$2 - b.$2)) / d;
  final cy = (a2 * (c.$1 - b.$1) + b2 * (a.$1 - c.$1) + c2 * (b.$1 - a.$1)) / d;
  final r = _dist(a, (cx, cy));
  if (r > 10000) return null;
  final t0 = math.atan2(a.$2 - cy, a.$1 - cx);
  var t1 = math.atan2(c.$2 - cy, c.$1 - cx);
  // Direction: the middle point decides which way round.
  final cross = (b.$1 - a.$1) * (c.$2 - a.$2) - (b.$2 - a.$2) * (c.$1 - a.$1);
  if (cross < 0) {
    while (t1 > t0) {
      t1 -= 2 * math.pi;
    }
  } else {
    while (t1 < t0) {
      t1 += 2 * math.pi;
    }
  }
  final steps = ((t1 - t0).abs() * r / 4).clamp(8, 240).round();
  return [
    for (var i = 0; i <= steps; i++) (cx + r * math.cos(t0 + (t1 - t0) * i / steps), cy + r * math.sin(t0 + (t1 - t0) * i / steps)),
  ];
}

List<(double, double)> _catmull(List<(double, double)> p) {
  if (p.length < 2) return p;
  final out = <(double, double)>[p.first];
  for (var i = 0; i < p.length - 1; i++) {
    final p0 = i > 0 ? p[i - 1] : p[i];
    final p1 = p[i], p2 = p[i + 1];
    final p3 = i + 2 < p.length ? p[i + 2] : (2 * p2.$1 - p1.$1, 2 * p2.$2 - p1.$2);
    for (var s = 1; s <= 20; s++) {
      final t = s / 20, t2 = t * t, t3 = t2 * t;
      double f(double a, double b, double c, double d) =>
          0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3);
      out.add((f(p0.$1, p1.$1, p2.$1, p3.$1), f(p0.$2, p1.$2, p2.$2, p3.$2)));
    }
  }
  return out;
}

List<(double, double)> _fitLength(List<(double, double)> pts, double length) {
  if (pts.length < 2 || length <= 0) return pts;
  final out = <(double, double)>[pts.first];
  var travelled = 0.0;
  for (var i = 1; i < pts.length; i++) {
    final d = _dist(pts[i - 1], pts[i]);
    if (travelled + d >= length) {
      final f = d <= 0 ? 0.0 : (length - travelled) / d;
      out.add((pts[i - 1].$1 + (pts[i].$1 - pts[i - 1].$1) * f, pts[i - 1].$2 + (pts[i].$2 - pts[i - 1].$2) * f));
      return out;
    }
    travelled += d;
    out.add(pts[i]);
  }
  // Shorter than its declared length: extend the last segment.
  final a = pts[pts.length - 2], b = pts.last;
  final d = _dist(a, b);
  if (d > 0) {
    final f = (length - travelled) / d;
    out.add((b.$1 + (b.$1 - a.$1) * f, b.$2 + (b.$2 - a.$2) * f));
  }
  return out;
}

double _dist((double, double) a, (double, double) b) {
  final dx = a.$1 - b.$1, dy = a.$2 - b.$2;
  return math.sqrt(dx * dx + dy * dy);
}

/// Thins a polyline to points at least [minStep] apart (keeps both ends).
List<(double, double)> simplifyPath(List<(double, double)> pts, double minStep) {
  if (pts.length <= 2) return pts;
  final out = <(double, double)>[pts.first];
  for (var i = 1; i < pts.length - 1; i++) {
    if (_dist(out.last, pts[i]) >= minStep) out.add(pts[i]);
  }
  out.add(pts.last);
  return out;
}
