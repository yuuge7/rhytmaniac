import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/gameplay/circles_session.dart';
import '../core/geometry/slider_curve.dart';
import '../core/models/beatmap.dart';
import '../core/models/score.dart';
import '../ui/theme.dart';

/// Geometry of the Circles playfield: a fixed-aspect rectangle fitted inside
/// the screen, keeping clear of the top ~10% (status bar, notch, thumbs) and
/// the edges.
class CirclesLayout {
  CirclesLayout(Size size, {double topInset = 0}) {
    final avail = Rect.fromLTRB(
      size.width * 0.035,
      topInset + size.height * 0.10,
      size.width * 0.965,
      size.height * 0.975,
    );
    var w = avail.width;
    var h = w * circlesYScale;
    if (h > avail.height) {
      h = avail.height;
      w = h / circlesYScale;
    }
    field = Rect.fromLTWH(avail.center.dx - w / 2, avail.top + (avail.height - h) / 2, w, h);
  }

  late final Rect field;

  Offset toScreen(Point2 p) => Offset(field.left + p.x * field.width, field.top + p.y * field.height);

  Point2 toNorm(Offset o) => Point2((o.dx - field.left) / field.width, (o.dy - field.top) / field.height);

  double px(double widthUnits) => widthUnits * field.width;
}

const comboColors = [Palette.rose, Palette.amber, Color(0xFF8E6CF0), Palette.ember];

class CirclesPainter extends CustomPainter {
  CirclesPainter({
    required this.session,
    required this.time,
    required this.approachMs,
    required this.hidden,
    required Listenable repaint,
    required this.showJudgments,
  }) : super(repaint: repaint);

  final CirclesSession session;
  final double Function() time;

  /// Song milliseconds an approach circle takes to close.
  final double approachMs;
  final bool hidden;
  final bool showJudgments;

  final _fill = Paint();
  final _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  static final Map<String, TextPainter> _textCache = {};

  TextPainter _text(String s, double size, Color raw, {double width = 120, double weight = 800}) {
    // Quantize alpha so fades reuse a handful of laid-out painters.
    final color = raw.withValues(alpha: (raw.a * 12).round() / 12);
    final key = '$s|${size.round()}|${color.toARGB32()}|$width';
    return _textCache.putIfAbsent(key, () {
      if (_textCache.length > 300) _textCache.clear();
      return TextPainter(
        text: TextSpan(text: s, style: AppText.display(size, width: width, weight: weight, color: color)),
        textDirection: TextDirection.ltr,
      )..layout();
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = time();
    final layout = CirclesLayout(size);
    final r = layout.px(session.radius);
    final objects = session.objects;

    // Find the visible window, then draw back-to-front so earlier objects
    // sit on top.
    final visible = <CircleObjectState>[];
    for (final s in objects) {
      final o = s.object;
      if (o.timeMs - t > approachMs) break;
      if (t - o.endMs > 260) continue;
      visible.add(s);
    }
    for (final s in visible.reversed) {
      final o = s.object;
      final color = comboColors[o.comboIndex % comboColors.length];
      if (o.isSpinner) {
        _spinner(canvas, layout, s, t);
        continue;
      }
      final fadeIn = ((t - (o.timeMs - approachMs)) / (approachMs * 0.33)).clamp(0.0, 1.0);
      var alpha = fadeIn;
      if (hidden) {
        final fadeOut = 1 - ((t - (o.timeMs - approachMs * 0.6)) / (approachMs * 0.3)).clamp(0.0, 1.0);
        alpha *= fadeOut;
      }
      if (o.isSlider) _slider(canvas, layout, s, t, r, color, hidden ? alpha.clamp(0.0, 1.0) : fadeIn);

      if (s.head == null) {
        if (alpha > 0.01) _circle(canvas, layout.toScreen(Point2(o.x, o.y)), r, color, alpha, s.comboNumber);
        if (!hidden) {
          final k = ((o.timeMs - t) / approachMs).clamp(0.0, 1.0);
          _stroke
            ..color = color.withValues(alpha: fadeIn * 0.9)
            ..strokeWidth = math.max(2, r * 0.07);
          canvas.drawCircle(layout.toScreen(Point2(o.x, o.y)), r * (1 + 2.3 * k), _stroke);
        }
      } else if (s.hitAt != null) {
        final age = t - s.hitAt!;
        if (age >= 0 && age < 240) {
          final p = age / 240;
          final center = layout.toScreen(Point2(o.x, o.y));
          if (s.head == Judgment.miss) {
            _cross(canvas, center, r * 0.5, Palette.dim.withValues(alpha: 1 - p));
          } else {
            _stroke
              ..color = Palette.judgment(s.head!).withValues(alpha: (1 - p) * 0.85)
              ..strokeWidth = r * 0.12 * (1 - p) + 1;
            canvas.drawCircle(center, r * (1 + 0.45 * p), _stroke);
          }
        }
      }
    }

    // Judgment text (Perfects stay quiet).
    if (showJudgments) {
      for (final fb in session.feedback.reversed) {
        final age = t - fb.timeMs;
        if (age > 520) break;
        if (age < 0 || fb.judgment == Judgment.perfect || fb.position == null) continue;
        final p = age / 520;
        final c = Palette.judgment(fb.judgment).withValues(alpha: 1 - p * p);
        final tp = _text(fb.judgment.label, math.max(13, r * 0.42), c, width: 110, weight: 750);
        final pos = layout.toScreen(fb.position!) - Offset(tp.width / 2, r * 1.15 + tp.height + 10 * p);
        tp.paint(canvas, pos);
      }
    }

    // Touch points and autoplay cursor.
    for (final pt in session.pointerPositions) {
      _stroke
        ..color = Palette.bone.withValues(alpha: 0.35)
        ..strokeWidth = 2;
      canvas.drawCircle(layout.toScreen(pt), r * 0.35, _stroke);
    }
    final cursor = session.autoCursor;
    if (cursor != null && session.mods.autoplay) {
      final c = layout.toScreen(cursor);
      _fill.color = Palette.amber.withValues(alpha: 0.25);
      canvas.drawCircle(c, r * 0.55, _fill);
      _fill.color = Palette.flare;
      canvas.drawCircle(c, r * 0.18, _fill);
    }
  }

  void _circle(Canvas canvas, Offset c, double r, Color color, double alpha, int number) {
    _fill.color = Palette.inkDeep.withValues(alpha: 0.55 * alpha);
    canvas.drawCircle(c, r, _fill);
    _fill.color = color.withValues(alpha: 0.88 * alpha);
    canvas.drawCircle(c, r * 0.86, _fill);
    _stroke
      ..color = Palette.bone.withValues(alpha: alpha)
      ..strokeWidth = r * 0.11;
    canvas.drawCircle(c, r * 0.9, _stroke);
    final tp = _text('$number', r * 0.95, Palette.bone.withValues(alpha: alpha), width: 110, weight: 850);
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }

  void _cross(Canvas canvas, Offset c, double s, Color color) {
    _stroke
      ..color = color
      ..strokeWidth = 4;
    canvas.drawLine(c + Offset(-s, -s), c + Offset(s, s), _stroke);
    canvas.drawLine(c + Offset(-s, s), c + Offset(s, -s), _stroke);
  }

  void _slider(Canvas canvas, CirclesLayout layout, CircleObjectState s, double t, double r, Color color, double alpha) {
    final o = s.object;
    final curve = s.curve;
    if (curve == null || alpha <= 0.01) return;
    final endFade = s.tail != null ? (1 - ((t - o.endMs) / 200).clamp(0.0, 1.0)) : 1.0;
    final a = alpha * endFade;
    if (a <= 0.01) return;
    final path = Path();
    final pts = curve.points;
    final first = layout.toScreen(pts.first);
    path.moveTo(first.dx, first.dy);
    for (var i = 1; i < pts.length; i++) {
      final q = layout.toScreen(pts[i]);
      path.lineTo(q.dx, q.dy);
    }
    _stroke
      ..color = Palette.bone.withValues(alpha: 0.85 * a)
      ..strokeWidth = r * 2;
    canvas.drawPath(path, _stroke);
    _stroke
      ..color = Color.lerp(Palette.inkDeep, color, 0.28)!.withValues(alpha: 0.92 * a)
      ..strokeWidth = r * 1.8;
    canvas.drawPath(path, _stroke);
    // Tail circle.
    final end = layout.toScreen(pts.last);
    _stroke
      ..color = Palette.bone.withValues(alpha: 0.7 * a)
      ..strokeWidth = r * 0.08;
    canvas.drawCircle(end, r * 0.86, _stroke);

    // Ball and follow ring while active.
    if (t >= o.timeMs && t <= o.endMs && s.tail == null) {
      final ball = layout.toScreen(s.ballAt(t));
      if (s.following) {
        _stroke
          ..color = Palette.amber.withValues(alpha: 0.75)
          ..strokeWidth = 3;
        canvas.drawCircle(ball, layout.px(session.followRadius), _stroke);
      }
      _fill.color = color;
      canvas.drawCircle(ball, r * 0.9, _fill);
      _fill.color = Palette.bone;
      canvas.drawCircle(ball, r * 0.55, _fill);
    }
  }

  void _spinner(Canvas canvas, CirclesLayout layout, CircleObjectState s, double t) {
    final o = s.object;
    if (t < o.timeMs - 400 || (s.tail != null && t - o.endMs > 260)) return;
    final appear = ((t - (o.timeMs - 400)) / 400).clamp(0.0, 1.0);
    final fade = s.tail != null ? 1 - ((t - o.endMs) / 260).clamp(0.0, 1.0) : 1.0;
    final a = appear * fade;
    final center = layout.field.center;
    final radius = layout.field.width * 0.4;
    final ratio = (s.spun / (2 * math.pi) / session.requiredSpins(s)).clamp(0.0, 1.0);
    _stroke
      ..color = Palette.line.withValues(alpha: a)
      ..strokeWidth = 10;
    canvas.drawCircle(center, radius, _stroke);
    _stroke
      ..color = Palette.heat(0.4 + 0.6 * ratio).withValues(alpha: a)
      ..strokeWidth = 10;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -math.pi / 2, 2 * math.pi * ratio, false, _stroke);
    // Shrinking time ring.
    final remaining = ((o.endMs - t) / (o.endMs - o.timeMs)).clamp(0.0, 1.0);
    _stroke
      ..color = Palette.bone.withValues(alpha: 0.5 * a)
      ..strokeWidth = 2;
    canvas.drawCircle(center, radius * (0.2 + 0.75 * remaining), _stroke);
    final label = _text(ratio >= 1 ? 'Clear' : 'Spin', 34, Palette.bone.withValues(alpha: a), width: 140, weight: 850);
    label.paint(canvas, center - Offset(label.width / 2, label.height / 2));
  }

  @override
  bool shouldRepaint(CirclesPainter old) => old.session != session || old.hidden != hidden;
}
