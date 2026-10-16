import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/gameplay/tiles_session.dart';
import '../core/models/score.dart';
import '../ui/theme.dart';

/// Geometry of the Tiles playfield.
class TilesLayout {
  TilesLayout(Size size, this.lanes, {double topInset = 0})
      : field = Rect.fromLTWH(
          (size.width - math.min(size.width, 520)) / 2,
          topInset,
          math.min(size.width, 520),
          size.height - topInset,
        ) {
    laneWidth = field.width / lanes;
    hitY = field.top + field.height * 0.83;
    noteHeight = (laneWidth * 0.3).clamp(16.0, 34.0);
  }

  final Rect field;
  final int lanes;
  late final double laneWidth;
  late final double hitY;
  late final double noteHeight;

  int laneAt(double x) => ((x - field.left) / laneWidth).floor().clamp(0, lanes - 1);

  double laneCenter(int lane) => field.left + laneWidth * (lane + 0.5);

  static Color laneColor(int lane, int lanes) =>
      Palette.heat(0.34 + 0.6 * (lanes <= 1 ? 0.5 : lane / (lanes - 1)));
}

class TilesPainter extends CustomPainter {
  TilesPainter({
    required this.session,
    required this.time,
    required this.visibleSongMs,
    required this.hidden,
    required Listenable repaint,
    this.backgroundAlpha = 0.86,
  }) : super(repaint: repaint);

  final TilesSession session;

  /// Current song time.
  final double Function() time;

  /// Song milliseconds between the top edge and the hit line.
  final double Function() visibleSongMs;
  final bool hidden;
  final double backgroundAlpha;

  final _fill = Paint();
  final _stroke = Paint()..style = PaintingStyle.stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final t = time();
    final lanes = session.lanes;
    final layout = TilesLayout(size, lanes);
    final f = layout.field;
    final lw = layout.laneWidth;
    final hitY = layout.hitY;
    final travel = hitY - f.top;
    final visible = visibleSongMs();
    double yAt(double songMs) => hitY - (songMs - t) / visible * travel;

    // Lanes.
    _fill.color = Palette.inkDeep.withValues(alpha: backgroundAlpha);
    canvas.drawRect(f, _fill);
    _fill.color = Palette.line.withValues(alpha: 0.45);
    for (var l = 1; l < lanes; l++) {
      canvas.drawRect(Rect.fromLTWH(f.left + l * lw - 0.5, f.top, 1, f.height), _fill);
    }

    // Pressed-lane glow.
    for (var l = 0; l < lanes; l++) {
      if (!session.laneDown[l]) continue;
      final c = TilesLayout.laneColor(l, lanes);
      final rect = Rect.fromLTWH(f.left + l * lw, hitY - travel * 0.42, lw, travel * 0.42);
      _fill.shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [c.withValues(alpha: 0), c.withValues(alpha: 0.26)],
      ).createShader(rect);
      canvas.drawRect(rect, _fill);
      _fill.shader = null;
    }

    // Hit line and receptors.
    _fill.color = Palette.bone.withValues(alpha: 0.85);
    canvas.drawRect(Rect.fromLTWH(f.left, hitY - 1, f.width, 2), _fill);
    final inset = lw * 0.1;
    for (var l = 0; l < lanes; l++) {
      final c = TilesLayout.laneColor(l, lanes);
      final r = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(layout.laneCenter(l), hitY), width: lw - inset * 2, height: layout.noteHeight),
        Radius.circular(layout.noteHeight * 0.35),
      );
      _stroke
        ..color = c.withValues(alpha: session.laneDown[l] ? 0.95 : 0.45)
        ..strokeWidth = 2;
      canvas.drawRRect(r, _stroke);
      if (session.laneDown[l]) {
        _fill.color = c.withValues(alpha: 0.35);
        canvas.drawRRect(r, _fill);
      }
    }

    // Hit bursts.
    for (final fb in session.feedback.reversed) {
      final age = t - fb.timeMs;
      if (age > 220) break;
      if (fb.judgment == Judgment.miss || fb.lane == null || age < 0) continue;
      final p = age / 220;
      final c = Palette.judgment(fb.judgment);
      final w = (lw - inset * 2) * (1 + 0.25 * p);
      final h = layout.noteHeight * (1 + 1.2 * p);
      _stroke
        ..color = c.withValues(alpha: (1 - p) * 0.9)
        ..strokeWidth = 3 * (1 - p) + 1;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(layout.laneCenter(fb.lane!), hitY), width: w, height: h),
            Radius.circular(h * 0.35)),
        _stroke,
      );
    }

    // Notes.
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(f.left, f.top, f.right, f.bottom));
    for (final n in session.notes) {
      final note = n.note;
      if (note.timeMs - t > visible * 1.05) break;
      if (n.done && !(n.head == Judgment.miss || n.releasedAt != null)) {
        if (!note.isHold || n.tail != null) continue;
      }
      final endY = yAt(note.endMs);
      if (endY > f.bottom + layout.noteHeight) continue;
      final c = TilesLayout.laneColor(note.lane, lanes);
      final missed = n.head == Judgment.miss || n.releasedAt != null;
      var alpha = missed ? 0.3 : 1.0;
      final x = layout.laneCenter(note.lane);
      var headY = yAt(note.timeMs);
      if (hidden && !missed) {
        alpha *= ((f.top + travel * 0.66 - headY) / (travel * 0.18)).clamp(0.0, 1.0);
      }
      if (alpha <= 0.01) continue;
      final w = lw - inset * 2;

      if (note.isHold) {
        if (n.holding) headY = hitY;
        final top = math.min(endY, headY);
        final bodyRect = Rect.fromLTRB(x - w * 0.34, top, x + w * 0.34, headY);
        _fill.shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [c.withValues(alpha: 0.25 * alpha), c.withValues(alpha: (n.holding ? 0.75 : 0.5) * alpha)],
        ).createShader(bodyRect);
        canvas.drawRRect(RRect.fromRectAndRadius(bodyRect, const Radius.circular(6)), _fill);
        _fill.shader = null;
        // Tail cap.
        _fill.color = c.withValues(alpha: 0.85 * alpha);
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, endY), width: w * 0.68, height: 6), const Radius.circular(3)),
          _fill,
        );
        if (n.head != null && !n.holding && !missed) continue;
      } else if (n.head != null && !missed) {
        continue;
      }
      _drawNote(canvas, Offset(x, headY), w, layout.noteHeight, c, alpha);
    }
    canvas.restore();
  }

  void _drawNote(Canvas canvas, Offset center, double w, double h, Color c, double alpha) {
    final r = RRect.fromRectAndRadius(Rect.fromCenter(center: center, width: w, height: h), Radius.circular(h * 0.35));
    _fill.color = c.withValues(alpha: alpha);
    canvas.drawRRect(r, _fill);
    // Highlight edge reads as a key cap.
    _fill.color = Color.lerp(c, Palette.flare, 0.55)!.withValues(alpha: alpha);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(r.left + 4, r.top + 2, r.width - 8, math.max(2, h * 0.16)), Radius.circular(h * 0.1)),
      _fill,
    );
  }

  @override
  bool shouldRepaint(TilesPainter old) => old.session != session || old.hidden != hidden;
}
