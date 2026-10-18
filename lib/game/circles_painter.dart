import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/gameplay/circles_session.dart';
import '../core/geometry/slider_curve.dart';
import '../core/models/beatmap.dart';
import '../core/models/score.dart';
import '../ui/theme.dart';
import 'fx.dart';

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

/// Screen-space slider body, cached per object and playfield size. The
/// thick round-capped strokes are drawn once into an image, so each frame
/// only blits a texture instead of re-tessellating the path.
class _SliderBody {
  _SliderBody(this.size, this.path, this.points, this.image, this.rect);
  final Size size;
  final Path path;
  final List<Offset> points;
  final ui.Image? image;
  final Rect rect;

  void dispose() => image?.dispose();
}

final Map<CircleObjectState, _SliderBody> _bodies = {};
CirclesSession? _bodiesOwner;

class CirclesPainter extends CustomPainter {
  CirclesPainter({
    required this.session,
    required this.time,
    required this.approachMs,
    required this.hidden,
    required this.flashlight,
    required Listenable repaint,
    required this.showJudgments,
    required this.trails,
    required this.beatPulse,
    required this.text,
    this.inBreak,
    this.pixelRatio = 2.0,
  }) : super(repaint: repaint);

  final CirclesSession session;
  final double Function() time;

  /// Song milliseconds an approach circle takes to close.
  final double approachMs;
  final bool hidden;
  final bool flashlight;
  final bool showJudgments;
  final TrailSet trails;

  /// 0..1: how strongly to pulse on this beat (kiai sections).
  final double Function() beatPulse;
  final bool Function()? inBreak;
  final TextCache text;

  /// Device pixels per logical pixel, for sharp cached slider bodies.
  final double pixelRatio;

  final _fill = Paint();
  final _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final _image = Paint()..filterQuality = FilterQuality.medium;

  int _start = 0;
  double _lastT = double.negativeInfinity;

  @override
  void paint(Canvas canvas, Size size) {
    final t = time();
    final layout = CirclesLayout(size);
    final r = layout.px(session.radius);
    final objects = session.objects;

    // Objects that ended a while ago never come back: start past them.
    if (t < _lastT - 1) _start = 0;
    _lastT = t;
    while (_start < objects.length && objects[_start].object.endMs + 700 < t) {
      _start++;
    }
    var end = _start;
    while (end < objects.length && objects[end].object.timeMs - t <= approachMs) {
      end++;
    }
    _pruneBodies(t);

    _kiai(canvas, layout);
    _followPoints(canvas, layout, t, r, end);

    // Back to front so earlier objects sit on top.
    for (var i = end - 1; i >= _start; i--) {
      final s = objects[i];
      final o = s.object;
      if (t - o.endMs > 260 && !(o.isSpinner && t - o.endMs < 300)) continue;
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
      if (o.isSlider) _slider(canvas, layout, s, t, r, color, hidden ? math.max(alpha, 0.0) : fadeIn);

      final center = layout.toScreen(Point2(o.x, o.y));
      if (s.head == null) {
        if (alpha > 0.01) _circle(canvas, center, r, color, alpha, s.comboNumber);
        if (!hidden && t < o.timeMs + 40) {
          final k = ((o.timeMs - t) / approachMs).clamp(0.0, 1.0);
          _stroke
            ..color = color.withValues(alpha: fadeIn * 0.9)
            ..strokeWidth = math.max(2, r * 0.07);
          canvas.drawCircle(center, r * (1 + 2.3 * k), _stroke);
        }
      } else if (s.hitAt != null) {
        final age = t - s.hitAt!;
        if (age >= 0 && age < 240) {
          final p = age / 240;
          if (s.head == Judgment.miss) {
            _cross(canvas, center, r * 0.5, Palette.miss.withValues(alpha: 1 - p));
          } else {
            // The circle swells and fades out, like osu!'s hit animation.
            if (!o.isSlider) _circle(canvas, center, r * (1 + 0.35 * p), color, (1 - p) * 0.8, s.comboNumber, showNumber: false);
            _stroke
              ..color = Palette.judgment(s.head!).withValues(alpha: (1 - p) * 0.85)
              ..strokeWidth = r * 0.12 * (1 - p) + 1;
            canvas.drawCircle(center, r * (1 + 0.45 * p), _stroke);
          }
        }
      }
    }

    _hitLighting(canvas, layout, t, r);
    if (showJudgments) _judgments(canvas, layout, t, r);
    _trails(canvas, layout, t, r);
    if (flashlight) _flashlight(canvas, size, layout, t, r);
  }

  // --- pieces ------------------------------------------------------------------------

  void _kiai(Canvas canvas, CirclesLayout layout) {
    final pulse = beatPulse();
    if (pulse <= 0.01) return;
    _stroke
      ..color = Palette.amber.withValues(alpha: 0.06 + 0.3 * pulse)
      ..strokeWidth = 2 + 5 * pulse;
    canvas.drawRRect(RRect.fromRectAndRadius(layout.field.inflate(10 + 4 * pulse), const Radius.circular(18)), _stroke);
  }

  /// Dotted guides from one object to the next within a combo.
  void _followPoints(Canvas canvas, CirclesLayout layout, double t, double r, int end) {
    final objects = session.objects;
    for (var i = math.max(_start, 1); i < end; i++) {
      final a = objects[i - 1].object, b = objects[i].object;
      if (a.isSpinner || b.isSpinner || a.comboIndex != b.comboIndex) continue;
      final gap = b.timeMs - a.endMs;
      if (gap <= 0 || t > b.timeMs || t < b.timeMs - approachMs) continue;
      final from = layout.toScreen(a.endPosition), to = layout.toScreen(Point2(b.x, b.y));
      final d = (to - from).distance;
      if (d < r * 3) continue;
      final dir = (to - from) / d;
      final spacing = r * 0.85;
      final count = ((d - 2 * r) / spacing).floor();
      _stroke.strokeWidth = math.max(2, r * 0.09);
      for (var k = 1; k <= count; k++) {
        final f = (r + k * spacing - spacing / 2) / d;
        if (f <= 0 || f >= 1) continue;
        final appear = b.timeMs - approachMs + f * approachMs * 0.35;
        final gone = a.endMs + f * gap;
        final alpha = ((t - appear) / 120).clamp(0.0, 1.0) * (1 - ((t - gone) / 150).clamp(0.0, 1.0));
        if (alpha <= 0.02) continue;
        final p = from + (to - from) * f;
        _stroke.color = Palette.bone.withValues(alpha: 0.55 * alpha);
        canvas.drawLine(p - dir * (r * 0.16), p + dir * (r * 0.16), _stroke);
      }
    }
  }

  void _circle(Canvas canvas, Offset c, double r, Color color, double alpha, int number, {bool showNumber = true}) {
    _fill.color = Palette.inkDeep.withValues(alpha: 0.55 * alpha);
    canvas.drawCircle(c, r, _fill);
    _fill.color = color.withValues(alpha: 0.88 * alpha);
    canvas.drawCircle(c, r * 0.86, _fill);
    _stroke
      ..color = Palette.bone.withValues(alpha: alpha)
      ..strokeWidth = r * 0.11;
    canvas.drawCircle(c, r * 0.9, _stroke);
    if (!showNumber) return;
    final tp = text.display('$number', (r * 0.95).roundToDouble(), Palette.bone.withValues(alpha: alpha), width: 110, weight: 850);
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }

  void _cross(Canvas canvas, Offset c, double s, Color color) {
    _stroke
      ..color = color
      ..strokeWidth = 4;
    canvas.drawLine(c + Offset(-s, -s), c + Offset(s, s), _stroke);
    canvas.drawLine(c + Offset(-s, s), c + Offset(s, -s), _stroke);
  }

  /// Drops cached bodies of sliders that are over (or of another run).
  void _pruneBodies(double t) {
    if (_bodiesOwner != session) {
      for (final b in _bodies.values) {
        b.dispose();
      }
      _bodies.clear();
      _bodiesOwner = session;
      return;
    }
    if (_bodies.length < 8) return;
    _bodies.removeWhere((s, b) {
      final over = s.object.endMs + 1000 < t;
      if (over) b.dispose();
      return over;
    });
  }

  _SliderBody _bodyFor(CircleObjectState s, CirclesLayout layout, double r, Color color) {
    final size = Size(layout.field.width, layout.field.height);
    final cached = _bodies[s];
    if (cached != null && cached.size == size) return cached;
    cached?.dispose();
    final pts = s.curve!.points.map(layout.toScreen).toList();
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    final rect = path.getBounds().inflate(r * 1.08);
    final scale = math.min(pixelRatio, 2.0);
    ui.Image? image;
    final w = (rect.width * scale).ceil(), h = (rect.height * scale).ceil();
    if (w > 0 && h > 0 && w * h <= 2400 * 2400) {
      final recorder = ui.PictureRecorder();
      final c = Canvas(recorder);
      c.scale(scale);
      c.translate(-rect.left, -rect.top);
      _strokeBody(c, path, r, color, 1);
      final picture = recorder.endRecording();
      image = picture.toImageSync(w, h);
      picture.dispose();
    }
    final body = _SliderBody(size, path, pts, image, rect);
    _bodies[s] = body;
    return body;
  }

  void _strokeBody(Canvas canvas, Path path, double r, Color color, double a) {
    _stroke
      ..color = Palette.bone.withValues(alpha: 0.85 * a)
      ..strokeWidth = r * 2;
    canvas.drawPath(path, _stroke);
    _stroke
      ..color = Color.lerp(Palette.inkDeep, color, 0.28)!.withValues(alpha: 0.92 * a)
      ..strokeWidth = r * 1.8;
    canvas.drawPath(path, _stroke);
  }

  void _slider(Canvas canvas, CirclesLayout layout, CircleObjectState s, double t, double r, Color color, double alpha) {
    final o = s.object;
    final curve = s.curve;
    if (curve == null || alpha <= 0.01) return;
    final endFade = s.tail != null ? (1 - ((t - o.endMs) / 200).clamp(0.0, 1.0)) : 1.0;
    final a = alpha * endFade;
    if (a <= 0.01) return;
    final cached = _bodyFor(s, layout, r, color);
    final image = cached.image;
    if (image != null) {
      _image.color = Color.fromRGBO(255, 255, 255, a.clamp(0.0, 1.0));
      canvas.drawImageRect(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), cached.rect, _image);
    } else {
      _strokeBody(canvas, cached.path, r, color, a);
    }

    // Tail circle.
    final endPt = cached.points.last;
    _stroke
      ..color = Palette.bone.withValues(alpha: 0.7 * a)
      ..strokeWidth = r * 0.08;
    canvas.drawCircle(endPt, r * 0.86, _stroke);

    // Ticks of the pass in progress (or the first one before the start).
    final span = o.spanMs;
    if (s.ticks.isNotEmpty && span > 0) {
      final pass = t < o.timeMs ? 0 : ((t - o.timeMs) / span).floor();
      final passStart = o.timeMs + pass * span, passEnd = passStart + span;
      _fill.color = Palette.bone.withValues(alpha: 0.9 * a);
      for (var k = s.nextTick; k < s.ticks.length; k++) {
        final tt = s.ticks[k];
        if (tt > passEnd) break;
        if (tt < passStart || tt <= t) continue;
        canvas.drawCircle(layout.toScreen(curve.at(s.pathProgress(tt))), math.max(2.5, r * 0.11), _fill);
      }
    }

    // Reverse arrow where the ball turns next.
    if (s.nextRepeat < s.repeatTimes.length) {
      final turnAtEnd = s.nextRepeat.isEven;
      final at = turnAtEnd ? cached.points.last : cached.points.first;
      final near = turnAtEnd ? curve.at(0.96) : curve.at(0.04);
      final dir = at - layout.toScreen(near);
      final len = dir.distance;
      if (len > 0.01) {
        final back = -dir / len;
        final pulse = 1 + 0.12 * beatPulse();
        final side = Offset(-back.dy, back.dx);
        final tip = at + back * (r * 0.38 * pulse);
        _stroke
          ..color = Palette.bone.withValues(alpha: a)
          ..strokeWidth = r * 0.13;
        canvas.drawLine(tip, tip - back * (r * 0.42) + side * (r * 0.36 * pulse), _stroke);
        canvas.drawLine(tip, tip - back * (r * 0.42) - side * (r * 0.36 * pulse), _stroke);
      }
    }

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
    final label = text.display(ratio >= 1 ? 'Clear' : 'Spin', 34, Palette.bone.withValues(alpha: a), width: 140, weight: 850);
    label.paint(canvas, center - Offset(label.width / 2, label.height / 2));
    final rpm = text.data('${(s.rpm / 10).round() * 10} RPM', 14, Palette.mist.withValues(alpha: a));
    rpm.paint(canvas, center + Offset(-rpm.width / 2, label.height / 2 + 6));
    if (s.bonusSpins > 0) {
      final bonus = text.data('+${s.bonusSpins * 1000}', 18, Palette.amber.withValues(alpha: a), weight: 650);
      bonus.paint(canvas, center - Offset(bonus.width / 2, label.height / 2 + bonus.height + 8));
    }
  }

  void _hitLighting(Canvas canvas, CirclesLayout layout, double t, double r) {
    for (final fb in session.feedback.reversed) {
      final age = t - fb.timeMs;
      if (age > 220) break;
      if (age < 0 || fb.judgment == Judgment.miss || fb.position == null) continue;
      paintGlow(canvas, layout.toScreen(fb.position!), r * 2.1, Palette.judgment(fb.judgment), 1 - age / 220);
    }
  }

  void _judgments(Canvas canvas, CirclesLayout layout, double t, double r) {
    for (final fb in session.feedback.reversed) {
      final age = t - fb.timeMs;
      if (age > 520) break;
      if (age < 0 || fb.judgment == Judgment.perfect || fb.position == null) continue;
      final p = age / 520;
      final c = Palette.judgment(fb.judgment).withValues(alpha: 1 - p * p);
      final tp = text.display(fb.judgment.label, math.max(13, r * 0.42).roundToDouble(), c, width: 110, weight: 750);
      final pos = layout.toScreen(fb.position!) - Offset(tp.width / 2, r * 1.15 + tp.height + 10 * p);
      tp.paint(canvas, pos);
    }
  }

  void _trails(Canvas canvas, CirclesLayout layout, double t, double r) {
    final cursor = session.autoCursor;
    if (cursor != null && session.mods.autoplay) trails.add(-1, cursor, t);
    final keep = 140 * session.mods.rate;
    trails.trails.removeWhere((_, tr) {
      tr.prune(t, keep);
      return tr.points.isEmpty;
    });
    for (final tr in trails.trails.values) {
      final pts = tr.points;
      for (var i = 1; i < pts.length; i++) {
        final k = 1 - (t - pts[i].$2) / keep;
        if (k <= 0) continue;
        _stroke
          ..color = Palette.flare.withValues(alpha: 0.45 * k)
          ..strokeWidth = math.max(1.5, r * 0.32 * k);
        canvas.drawLine(_toScreen(layout, pts[i - 1].$1), _toScreen(layout, pts[i].$1), _stroke);
      }
    }
    for (final pt in session.pointerPositions) {
      _stroke
        ..color = Palette.bone.withValues(alpha: 0.4)
        ..strokeWidth = 2;
      canvas.drawCircle(layout.toScreen(pt), r * 0.35, _stroke);
    }
    if (cursor != null && session.mods.autoplay) {
      final c = layout.toScreen(cursor);
      _fill.color = Palette.amber.withValues(alpha: 0.25);
      canvas.drawCircle(c, r * 0.55, _fill);
      _fill.color = Palette.flare;
      canvas.drawCircle(c, r * 0.18, _fill);
    }
  }

  Offset _toScreen(CirclesLayout layout, Offset norm) =>
      Offset(layout.field.left + norm.dx * layout.field.width, layout.field.top + norm.dy * layout.field.height);

  void _flashlight(Canvas canvas, Size size, CirclesLayout layout, double t, double r) {
    Point2? focus;
    for (final p in session.pointerPositions) {
      focus = p;
    }
    focus ??= session.autoCursor;
    if (focus == null) {
      for (final fb in session.feedback.reversed) {
        if (fb.position != null) {
          focus = fb.position;
          break;
        }
      }
    }
    final center = focus == null ? layout.field.center : layout.toScreen(focus);
    final combo = session.processor.combo;
    var radius = layout.field.width * (combo >= 200 ? 0.36 : (combo >= 100 ? 0.43 : 0.5));
    final spinning = session.objects.any((s) => s.object.isSpinner && t >= s.object.timeMs - 300 && t <= s.object.endMs);
    if (spinning || (inBreak?.call() ?? false)) radius = layout.field.height;
    paintFlashlight(canvas, size, center, radius);
  }

  @override
  bool shouldRepaint(CirclesPainter old) => old.session != session || old.hidden != hidden || old.flashlight != flashlight;
}
