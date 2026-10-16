import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/models/beatmap.dart';
import '../../game/tiles_painter.dart';
import '../theme.dart';
import 'editor_state.dart';

/// Vertical timeline: time flows upward like the game. Drag the waveform
/// gutter to scrub; in the lanes, tap to add, drag to draw a hold, long-press
/// to delete.
class TilesEditorView extends StatefulWidget {
  const TilesEditorView({super.key, required this.state, required this.onScrubEnd});
  final EditorState state;
  final VoidCallback onScrubEnd;

  @override
  State<TilesEditorView> createState() => _TilesEditorViewState();
}

class _TilesEditorViewState extends State<TilesEditorView> {
  static const gutter = 58.0;
  int? _dragLane;
  double? _dragStart;
  double? _dragEnd;

  EditorState get ed => widget.state;

  double _playheadY(Size s) => s.height * 0.78;
  double _timeAt(Size s, double y) => ed.timeMs + (_playheadY(s) - y) / ed.zoom;
  int _laneAt(Size s, double x) {
    final lanes = ed.map.difficulty.lanes;
    return (((x - gutter) / (s.width - gutter)) * lanes).floor().clamp(0, lanes - 1);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = c.biggest;
      return Stack(children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _TilesEditorPainter(ed, gutter, _dragLane, _dragStart, _dragEnd),
          ),
        ),
        // Scrub gutter.
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: gutter,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (d) => ed.seek(ed.timeMs + d.delta.dy / ed.zoom),
            onVerticalDragEnd: (_) => widget.onScrubEnd(),
          ),
        ),
        // Lanes.
        Positioned(
          left: gutter,
          top: 0,
          right: 0,
          bottom: 0,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              final p = d.localPosition + const Offset(gutter, 0);
              final lane = _laneAt(size, p.dx);
              final t = _timeAt(size, p.dy);
              if (ed.tileAt(lane, t, 10 / ed.zoom) == null) ed.addTile(lane, t);
            },
            onLongPressStart: (d) {
              final p = d.localPosition + const Offset(gutter, 0);
              final note = ed.tileAt(_laneAt(size, p.dx), _timeAt(size, p.dy), 16 / ed.zoom);
              if (note != null) ed.removeTile(note);
            },
            onVerticalDragStart: (d) {
              final p = d.localPosition + const Offset(gutter, 0);
              setState(() {
                _dragLane = _laneAt(size, p.dx);
                _dragStart = ed.snap(_timeAt(size, p.dy));
                _dragEnd = _dragStart;
              });
            },
            onVerticalDragUpdate: (d) {
              final p = d.localPosition + const Offset(gutter, 0);
              setState(() => _dragEnd = ed.snap(_timeAt(size, p.dy)));
            },
            onVerticalDragEnd: (_) {
              final lane = _dragLane, s = _dragStart, e = _dragEnd;
              setState(() {
                _dragLane = null;
                _dragStart = null;
                _dragEnd = null;
              });
              if (lane == null || s == null || e == null) return;
              final a = math.min(s, e), b = math.max(s, e);
              ed.addTile(lane, a, b > a ? b : null);
            },
          ),
        ),
        Positioned(
          right: 8,
          top: 8,
          child: Column(children: [
            _zoomButton(Icons.add_rounded, () => ed.setZoom(ed.zoom * 1.35)),
            const SizedBox(height: 6),
            _zoomButton(Icons.remove_rounded, () => ed.setZoom(ed.zoom / 1.35)),
          ]),
        ),
      ]);
    });
  }

  Widget _zoomButton(IconData icon, VoidCallback on) => Material(
        color: Palette.raised,
        shape: const CircleBorder(),
        child: InkWell(customBorder: const CircleBorder(), onTap: on, child: Padding(padding: const EdgeInsets.all(8), child: Icon(icon, size: 20))),
      );
}

/// Beat-line colours by division, as editors conventionally draw them.
Color beatLineColor(int index, int divisor, int barOffset) {
  final perBeat = divisor;
  final inBeat = index % perBeat;
  if (inBeat == 0) {
    final beatIndex = index ~/ perBeat;
    return ((beatIndex - barOffset) % 4 + 4) % 4 == 0 ? Palette.bone.withValues(alpha: 0.55) : Palette.bone.withValues(alpha: 0.22);
  }
  if (perBeat >= 2 && inBeat * 2 == perBeat) return Palette.rose.withValues(alpha: 0.45);
  if (perBeat >= 4 && (inBeat * 4) % perBeat == 0) return Palette.early.withValues(alpha: 0.45);
  return Palette.amber.withValues(alpha: 0.25);
}

class _TilesEditorPainter extends CustomPainter {
  _TilesEditorPainter(this.ed, this.gutter, this.dragLane, this.dragStart, this.dragEnd) : super(repaint: ed);
  final EditorState ed;
  final double gutter;
  final int? dragLane;
  final double? dragStart;
  final double? dragEnd;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint();
    final lanes = ed.map.difficulty.lanes;
    final laneW = (size.width - gutter) / lanes;
    final playY = size.height * 0.78;
    double y(double t) => playY - (t - ed.timeMs) * ed.zoom;
    final tTop = ed.timeMs + playY / ed.zoom;
    final tBottom = ed.timeMs - (size.height - playY) / ed.zoom;
    final a = ed.analysis;

    p.color = Palette.inkDeep;
    canvas.drawRect(Offset.zero & size, p);

    // Range.
    if (ed.rangeA != null || ed.rangeB != null) {
      final ra = ed.rangeA ?? tBottom, rb = ed.rangeB ?? tTop;
      p.color = Palette.amber.withValues(alpha: 0.08);
      canvas.drawRect(Rect.fromLTRB(gutter, y(rb), size.width, y(ra)), p);
    }

    // Lane separators.
    p.color = Palette.line.withValues(alpha: 0.6);
    for (var l = 0; l <= lanes; l++) {
      canvas.drawRect(Rect.fromLTWH(gutter + l * laneW - 0.5, 0, 1, size.height), p);
    }

    // Beat grid at the snap resolution.
    final step = a.beatLengthMs / ed.snapDivisor;
    var k = ((tBottom - a.beatOffsetMs) / step).floor();
    for (var t = a.beatOffsetMs + k * step; t <= tTop; t += step, k++) {
      if (t < 0) continue;
      p.color = beatLineColor(k, ed.snapDivisor, a.barOffsetBeats);
      canvas.drawRect(Rect.fromLTWH(gutter, y(t) - 0.5, size.width - gutter, 1), p);
    }

    // Waveform in the gutter (time runs upward).
    final res = a.waveformResolutionMs;
    final cx = gutter / 2;
    p.color = Palette.mist.withValues(alpha: 0.5);
    final i0 = math.max(0, (tBottom / res).floor());
    final i1 = math.min(a.waveform.length - 1, (tTop / res).ceil());
    final rowH = math.max(1.0, res * ed.zoom);
    for (var i = i0; i <= i1; i++) {
      final w = a.waveform[i] * (gutter / 2 - 4);
      canvas.drawRect(Rect.fromLTRB(cx - w, y(i * res) - rowH, cx + w, y(i * res)), p);
    }
    // Time labels each 2 bars.
    final bar = a.beatLengthMs * 4;
    for (var t = a.firstDownbeatMs + ((tBottom - a.firstDownbeatMs) / bar).floor() * bar; t <= tTop; t += bar * 2) {
      if (t < 0) continue;
      final s = (t / 1000);
      final tp = TextPainter(
        text: TextSpan(text: '${(s ~/ 60)}:${(s % 60).floor().toString().padLeft(2, '0')}', style: AppText.data(9.5)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(4, y(t) - tp.height - 1));
    }

    // Notes.
    final noteH = (laneW * 0.28).clamp(12.0, 28.0);
    for (final n in ed.map.tileNotes) {
      if (n.endMs < tBottom - 200) continue;
      if (n.timeMs > tTop + 200) break;
      _note(canvas, n, laneW, noteH, y, lanes);
    }
    if (dragLane != null && dragStart != null && dragEnd != null) {
      final s = math.min(dragStart!, dragEnd!), e = math.max(dragStart!, dragEnd!);
      _note(canvas, TileNote(timeMs: s, lane: dragLane!, endTimeMs: e > s ? e : null), laneW, noteH, y, lanes, ghost: true);
    }

    // Playhead.
    p.color = Palette.amber;
    canvas.drawRect(Rect.fromLTWH(0, playY - 1, size.width, 2), p);
  }

  void _note(Canvas canvas, TileNote n, double laneW, double noteH, double Function(double) y, int lanes, {bool ghost = false}) {
    final p = Paint();
    final c = TilesLayout.laneColor(n.lane, lanes);
    final alpha = ghost ? 0.5 : 1.0;
    final left = gutter + n.lane * laneW + laneW * 0.1;
    final w = laneW * 0.8;
    if (n.isHold) {
      p.color = c.withValues(alpha: 0.45 * alpha);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTRB(left + w * 0.16, y(n.endMs), left + w * 0.84, y(n.timeMs)), const Radius.circular(5)),
        p,
      );
    }
    p.color = c.withValues(alpha: alpha);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(left, y(n.timeMs) - noteH / 2, w, noteH), Radius.circular(noteH * 0.35)),
      p,
    );
  }

  @override
  bool shouldRepaint(_TilesEditorPainter old) =>
      old.dragLane != dragLane || old.dragStart != dragStart || old.dragEnd != dragEnd;
}
