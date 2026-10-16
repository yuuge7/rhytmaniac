import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/geometry/slider_curve.dart';
import '../../core/models/beatmap.dart';
import '../../game/circles_painter.dart';
import '../theme.dart';
import 'editor_state.dart';
import 'tiles_editor_view.dart' show beatLineColor;

/// Playfield preview at the playhead plus a horizontal timeline to scrub.
/// Circle tool: tap to place. Slider tool: drag from start to end, then bend
/// it with the amber handle. Move tool: drag objects. Long-press deletes.
/// "New combo" in the toolbar toggles a combo break at the playhead.
class CirclesEditorView extends StatefulWidget {
  const CirclesEditorView({super.key, required this.state, required this.onScrubEnd});
  final EditorState state;
  final VoidCallback onScrubEnd;

  @override
  State<CirclesEditorView> createState() => _CirclesEditorViewState();
}

enum _DragKind { none, move, handle, newSlider }

class _CirclesEditorViewState extends State<CirclesEditorView> {
  _DragKind _drag = _DragKind.none;
  int? _dragIndex;
  Point2? _sliderFrom;
  Point2? _sliderTo;
  Point2? _lastPos;
  double _timelineZoom = 0.18; // px per ms

  EditorState get ed => widget.state;

  Point2 _clampNorm(Point2 p) => Point2(p.x.clamp(0.02, 0.98), p.y.clamp(0.02, 0.98));

  /// Topmost visible object under [p] (earliest first, like the game).
  int? _hit(Point2 p) {
    final r = ed.map.difficulty.circleRadius;
    for (final i in ed.visibleCircleIndices()) {
      final o = ed.map.circleObjects[i];
      if (o.isSpinner) continue;
      if (playfieldDistance(p, Point2(o.x, o.y)) <= r * 1.1) return i;
      if (o.isSlider && playfieldDistance(p, o.endPosition) <= r * 1.1) return i;
    }
    return null;
  }

  int? _hitHandle(Point2 p) {
    final r = ed.map.difficulty.circleRadius;
    for (final i in ed.visibleCircleIndices()) {
      final o = ed.map.circleObjects[i];
      if (!o.isSlider || o.path == null || o.path!.length < 3) continue;
      if (playfieldDistance(p, o.path![1]) <= r * 0.8) return i;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: LayoutBuilder(builder: (context, c) {
          final layout = CirclesLayout(c.biggest);
          Point2 norm(Offset o) => _clampNorm(layout.toNorm(o));
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              if (ed.circleTool != CircleTool.circle) return;
              final p = norm(d.localPosition);
              if (_hit(p) == null) ed.addCircle(p);
            },
            onLongPressStart: (d) {
              final i = _hit(norm(d.localPosition));
              if (i != null) ed.removeCircle(i);
            },
            onPanStart: (d) {
              final p = norm(d.localPosition);
              final handle = _hitHandle(p);
              final hit = _hit(p);
              if (handle != null) {
                ed.beginGesture();
                setState(() {
                  _drag = _DragKind.handle;
                  _dragIndex = handle;
                });
              } else if (hit != null && ed.circleTool != CircleTool.slider) {
                ed.beginGesture();
                setState(() {
                  _drag = _DragKind.move;
                  _dragIndex = hit;
                  _lastPos = p;
                });
              } else if (ed.circleTool == CircleTool.slider) {
                setState(() {
                  _drag = _DragKind.newSlider;
                  _sliderFrom = p;
                  _sliderTo = p;
                });
              }
            },
            onPanUpdate: (d) {
              final p = norm(d.localPosition);
              final i = _dragIndex;
              switch (_drag) {
                case _DragKind.move:
                  if (i == null || _lastPos == null) return;
                  final o = ed.map.circleObjects[i];
                  ed.replaceCircle(i, o.translated(p.x - _lastPos!.x, p.y - _lastPos!.y), record: false);
                  _lastPos = p;
                case _DragKind.handle:
                  if (i == null) return;
                  final o = ed.map.circleObjects[i];
                  final path = [...o.path!];
                  path[1] = p;
                  ed.replaceCircle(i, o.copyWith(path: path), record: false);
                case _DragKind.newSlider:
                  setState(() => _sliderTo = p);
                case _DragKind.none:
                  break;
              }
            },
            onPanEnd: (_) {
              if (_drag == _DragKind.newSlider && _sliderFrom != null && _sliderTo != null) {
                if (playfieldDistance(_sliderFrom!, _sliderTo!) > ed.map.difficulty.circleRadius) {
                  ed.addSlider(_sliderFrom!, _sliderTo!);
                }
              }
              setState(() {
                _drag = _DragKind.none;
                _dragIndex = null;
                _sliderFrom = null;
                _sliderTo = null;
              });
            },
            child: CustomPaint(
              size: Size.infinite,
              painter: _PlayfieldPainter(ed, _sliderFrom, _sliderTo),
            ),
          );
        }),
      ),
      SizedBox(
        height: 104,
        child: LayoutBuilder(builder: (context, c) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) => ed.seek(ed.timeMs - d.delta.dx / _timelineZoom),
            onHorizontalDragEnd: (_) => widget.onScrubEnd(),
            onTapUp: (d) {
              final t = ed.timeMs + (d.localPosition.dx - c.maxWidth / 2) / _timelineZoom;
              ed.seek(ed.snap(t));
              widget.onScrubEnd();
            },
            child: Stack(children: [
              Positioned.fill(child: CustomPaint(painter: _TimelinePainter(ed, _timelineZoom))),
              Positioned(
                right: 4,
                top: 4,
                child: Row(children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() => _timelineZoom = (_timelineZoom / 1.4).clamp(0.04, 1.0)),
                    icon: const Icon(Icons.zoom_out_rounded, size: 18),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() => _timelineZoom = (_timelineZoom * 1.4).clamp(0.04, 1.0)),
                    icon: const Icon(Icons.zoom_in_rounded, size: 18),
                  ),
                ]),
              ),
            ]),
          );
        }),
      ),
    ]);
  }
}

class _PlayfieldPainter extends CustomPainter {
  _PlayfieldPainter(this.ed, this.from, this.to) : super(repaint: ed);
  final EditorState ed;
  final Point2? from;
  final Point2? to;

  @override
  void paint(Canvas canvas, Size size) {
    final layout = CirclesLayout(size);
    final f = layout.field;
    final p = Paint();
    final stroke = Paint()..style = PaintingStyle.stroke;
    p.color = Palette.inkDeep;
    canvas.drawRect(Offset.zero & size, p);
    stroke
      ..color = Palette.line
      ..strokeWidth = 1;
    canvas.drawRRect(RRect.fromRectAndRadius(f, const Radius.circular(8)), stroke);
    // Light grid to help line things up.
    p.color = Palette.line.withValues(alpha: 0.35);
    for (var i = 1; i < 4; i++) {
      canvas.drawRect(Rect.fromLTWH(f.left + f.width * i / 4 - 0.5, f.top, 1, f.height), p);
    }
    for (var i = 1; i < 6; i++) {
      canvas.drawRect(Rect.fromLTWH(f.left, f.top + f.height * i / 6 - 0.5, f.width, 1), p);
    }

    final r = layout.px(ed.map.difficulty.circleRadius);
    final approach = ed.map.difficulty.approachMs;
    final objects = ed.map.circleObjects;
    final visible = ed.visibleCircleIndices();
    // Combo numbers.
    final numbers = <int, int>{};
    var n = 0;
    int? last;
    for (var i = 0; i < objects.length; i++) {
      if (objects[i].comboIndex != last) {
        n = 0;
        last = objects[i].comboIndex;
      }
      n++;
      numbers[i] = n;
    }
    for (final i in visible.reversed) {
      final o = objects[i];
      final color = comboColors[o.comboIndex % comboColors.length];
      final dt = o.timeMs - ed.timeMs;
      final current = dt.abs() < 2 || (ed.timeMs >= o.timeMs && ed.timeMs <= o.endMs);
      final alpha = dt > 0 ? (1 - dt / approach).clamp(0.25, 1.0) : (current ? 1.0 : 0.4);
      if (o.isSpinner) {
        stroke
          ..color = Palette.bone.withValues(alpha: alpha * 0.6)
          ..strokeWidth = 6;
        canvas.drawCircle(f.center, f.width * 0.4, stroke);
        continue;
      }
      if (o.isSlider && o.path != null) {
        final curve = SliderCurve(o.path!, samples: 32);
        final path = Path();
        final pts = curve.points.map(layout.toScreen).toList();
        path.moveTo(pts.first.dx, pts.first.dy);
        for (final q in pts.skip(1)) {
          path.lineTo(q.dx, q.dy);
        }
        stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = Palette.bone.withValues(alpha: 0.7 * alpha)
          ..strokeWidth = r * 2;
        canvas.drawPath(path, stroke);
        stroke
          ..color = Color.lerp(Palette.inkDeep, color, 0.3)!.withValues(alpha: alpha)
          ..strokeWidth = r * 1.8;
        canvas.drawPath(path, stroke);
        // Bend handle.
        if (o.path!.length >= 3) {
          final h = layout.toScreen(o.path![1]);
          p.color = Palette.amber.withValues(alpha: alpha);
          canvas.drawCircle(h, 9, p);
          stroke
            ..color = Palette.amber.withValues(alpha: 0.5 * alpha)
            ..strokeWidth = 1.5
            ..strokeCap = StrokeCap.butt;
          canvas.drawLine(layout.toScreen(o.path!.first), h, stroke);
          canvas.drawLine(h, layout.toScreen(o.path!.last), stroke);
        }
      }
      final c = layout.toScreen(Point2(o.x, o.y));
      p.color = color.withValues(alpha: 0.85 * alpha);
      canvas.drawCircle(c, r * 0.86, p);
      stroke
        ..color = (current ? Palette.amber : Palette.bone).withValues(alpha: alpha)
        ..strokeWidth = current ? r * 0.16 : r * 0.1
        ..strokeCap = StrokeCap.butt;
      canvas.drawCircle(c, r * 0.9, stroke);
      final tp = TextPainter(
        text: TextSpan(text: '${numbers[i]}', style: AppText.display(r * 0.9, width: 110, weight: 850, color: Palette.bone.withValues(alpha: alpha))),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
      if (dt > 0) {
        stroke
          ..color = color.withValues(alpha: alpha * 0.8)
          ..strokeWidth = 2;
        canvas.drawCircle(c, r * (1 + 2.3 * (dt / approach).clamp(0.0, 1.0)), stroke);
      }
    }
    if (from != null && to != null) {
      stroke
        ..color = Palette.amber
        ..strokeWidth = r * 1.6
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(layout.toScreen(from!), layout.toScreen(to!), stroke..color = Palette.amber.withValues(alpha: 0.35));
    }
  }

  @override
  bool shouldRepaint(_PlayfieldPainter old) => old.from != from || old.to != to;
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter(this.ed, this.zoom) : super(repaint: ed);
  final EditorState ed;
  final double zoom;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint();
    final a = ed.analysis;
    final cx = size.width / 2;
    double x(double t) => cx + (t - ed.timeMs) * zoom;
    final t0 = ed.timeMs - cx / zoom, t1 = ed.timeMs + cx / zoom;
    p.color = Palette.surface;
    canvas.drawRect(Offset.zero & size, p);
    if (ed.rangeA != null || ed.rangeB != null) {
      p.color = Palette.amber.withValues(alpha: 0.1);
      canvas.drawRect(Rect.fromLTRB(x(ed.rangeA ?? t0), 0, x(ed.rangeB ?? t1), size.height), p);
    }
    // Waveform.
    final res = a.waveformResolutionMs;
    final mid = size.height * 0.42;
    p.color = Palette.mist.withValues(alpha: 0.45);
    for (var i = math.max(0, (t0 / res).floor()); i < math.min(a.waveform.length, (t1 / res).ceil()); i++) {
      final h = a.waveform[i] * size.height * 0.3;
      canvas.drawRect(Rect.fromLTRB(x(i * res), mid - h, x((i + 1) * res) + 0.4, mid + h), p);
    }
    // Beat ticks.
    final step = a.beatLengthMs / ed.snapDivisor;
    var k = ((t0 - a.beatOffsetMs) / step).floor();
    for (var t = a.beatOffsetMs + k * step; t <= t1; t += step, k++) {
      if (t < 0) continue;
      p.color = beatLineColor(k, ed.snapDivisor, a.barOffsetBeats);
      final major = k % ed.snapDivisor == 0;
      canvas.drawRect(Rect.fromLTWH(x(t) - 0.5, size.height - (major ? 22 : 12), 1, major ? 22 : 12), p);
    }
    // Objects.
    final y = size.height * 0.78;
    for (final o in ed.map.circleObjects) {
      if (o.endMs < t0) continue;
      if (o.timeMs > t1) break;
      final c = comboColors[o.comboIndex % comboColors.length];
      p.color = c;
      if (o.isSlider || o.isSpinner) {
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(x(o.timeMs), y - 4, x(o.endMs), y + 4), const Radius.circular(4)), p);
      }
      canvas.drawCircle(Offset(x(o.timeMs), y), 6, p);
    }
    p.color = Palette.amber;
    canvas.drawRect(Rect.fromLTWH(cx - 1, 0, 2, size.height), p);
  }

  @override
  bool shouldRepaint(_TimelinePainter old) => old.zoom != zoom;
}
