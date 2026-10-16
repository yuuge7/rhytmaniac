import 'dart:math' as math;

import '../models/beatmap.dart';

/// Width / height of the Circles playfield. Normalized y spans a taller
/// distance than normalized x, so geometry is done in "width units" where
/// x ∈ [0, 1] and y ∈ [0, 1 / aspect].
const circlesPlayfieldAspect = 0.62;
const circlesYScale = 1 / circlesPlayfieldAspect;

/// Distance between two normalized points, in playfield-width units.
double playfieldDistance(Point2 a, Point2 b) {
  final dx = a.x - b.x;
  final dy = (a.y - b.y) * circlesYScale;
  return math.sqrt(dx * dx + dy * dy);
}

/// Bezier curve through a control polygon (normalized coordinates) with an
/// arc-length lookup so a slider ball moves at constant speed.
class SliderCurve {
  SliderCurve(List<Point2> control, {int samples = 48})
      : _points = List.generate(samples + 1, (i) => _bezier(control, i / samples)) {
    _cumulative.add(0);
    for (var i = 1; i < _points.length; i++) {
      _cumulative.add(_cumulative.last + playfieldDistance(_points[i - 1], _points[i]));
    }
  }

  final List<Point2> _points;
  final List<double> _cumulative = [];

  /// Length in playfield-width units.
  double get length => _cumulative.last;

  List<Point2> get points => _points;

  /// Point at [progress] (0..1) of the arc length.
  Point2 at(double progress) {
    final target = progress.clamp(0.0, 1.0) * length;
    if (length <= 0) return _points.first;
    var lo = 0, hi = _cumulative.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_cumulative[mid] < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo == 0) return _points.first;
    final a = _cumulative[lo - 1], b = _cumulative[lo];
    final f = b > a ? (target - a) / (b - a) : 0.0;
    final p = _points[lo - 1], q = _points[lo];
    return Point2(p.x + (q.x - p.x) * f, p.y + (q.y - p.y) * f);
  }

  static Point2 _bezier(List<Point2> c, double t) {
    if (c.length == 1) return c.first;
    var pts = List<Point2>.of(c);
    while (pts.length > 1) {
      pts = [
        for (var i = 0; i < pts.length - 1; i++)
          Point2(pts[i].x + (pts[i + 1].x - pts[i].x) * t, pts[i].y + (pts[i + 1].y - pts[i].y) * t),
      ];
    }
    return pts.first;
  }
}
