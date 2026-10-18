import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/models/beatmap.dart';
import '../ui/theme.dart';

/// Laid-out text reused across frames.
///
/// Gameplay text animates every frame, but laying out a paragraph (and, for
/// the variable display face, building a font instance per distinct axis
/// value) is far too slow to repeat at 60 fps. Painters ask for text by
/// value; alpha is quantized so fades reuse a few painters, and variable
/// axes only ever take values from a short fixed list.
class TextCache {
  TextCache({this.capacity = 240});

  final int capacity;
  final Map<String, TextPainter> _cache = {};

  TextPainter display(String text, double size, Color color, {double width = 120, double weight = 800}) =>
      _get('d|$text|$size|$width|$weight', color, () => AppText.display(size, width: width, weight: weight, color: Palette.bone), text);

  TextPainter data(String text, double size, Color color, {double weight = 500}) =>
      _get('m|$text|$size|$weight', color, () => AppText.data(size, weight: weight, color: Palette.bone), text);

  TextPainter body(String text, double size, Color color, {double weight = 500}) =>
      _get('b|$text|$size|$weight', color, () => AppText.body(size, weight: weight, color: Palette.bone, height: 1.2), text);

  TextPainter _get(String base, Color raw, TextStyle Function() style, String text) {
    final a = (raw.a * 16).round() / 16;
    final color = raw.withValues(alpha: a);
    final key = '$base|${color.toARGB32()}';
    final hit = _cache[key];
    if (hit != null) return hit;
    if (_cache.length >= capacity) {
      for (final p in _cache.values) {
        p.dispose();
      }
      _cache.clear();
    }
    return _cache[key] = TextPainter(
      text: TextSpan(text: text, style: style().copyWith(color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  void dispose() {
    for (final p in _cache.values) {
      p.dispose();
    }
    _cache.clear();
  }
}

/// A finger's recent path, for the touch trail.
class Trail {
  final List<(Offset, double)> points = [];

  void add(Offset p, double timeMs) {
    points.add((p, timeMs));
    if (points.length > 24) points.removeAt(0);
  }

  void prune(double nowMs, double keepMs) {
    while (points.isNotEmpty && nowMs - points.first.$2 > keepMs) {
      points.removeAt(0);
    }
  }
}

/// Recent pointer paths in normalized playfield coordinates, keyed by
/// pointer (the autoplay cursor uses -1).
class TrailSet {
  final Map<int, Trail> trails = {};

  void add(int pointer, Point2 p, double timeMs) =>
      (trails[pointer] ??= Trail()).add(Offset(p.x, p.y), timeMs);

  void end(int pointer) {}

  void clear() => trails.clear();
}

/// Darkness everywhere except a soft circle of [radius] around [center]
/// (Flashlight). One gradient-filled rect, so it costs a single draw.
void paintFlashlight(Canvas canvas, Size size, Offset center, double radius, {double strength = 1.0}) {
  final paint = Paint()
    ..shader = ui.Gradient.radial(
      center,
      radius,
      [
        Colors.black.withValues(alpha: 0),
        Colors.black.withValues(alpha: 0),
        Colors.black.withValues(alpha: 0.97 * strength),
      ],
      const [0.0, 0.62, 1.0],
      TileMode.clamp,
    );
  canvas.drawRect(Offset.zero & size, paint);
}

/// Soft glow for hit lighting.
void paintGlow(Canvas canvas, Offset center, double radius, Color color, double alpha) {
  if (alpha <= 0.01) return;
  final paint = Paint()
    ..shader = ui.Gradient.radial(
      center,
      radius,
      [color.withValues(alpha: 0.55 * alpha), color.withValues(alpha: 0)],
      const [0.0, 1.0],
    );
  canvas.drawCircle(center, radius, paint);
}
