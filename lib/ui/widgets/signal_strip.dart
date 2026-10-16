import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// A song's fingerprint: its 3-band loudness over time, drawn as mirrored
/// columns coloured by the heat ramp. Every song gets distinct artwork from
/// its own analysis — this is the app's signature element.
class SignalStrip extends StatelessWidget {
  const SignalStrip({
    super.key,
    required this.fingerprint,
    this.height = 40,
    this.progress,
    this.highlight,
    this.opacity = 1.0,
    this.mirrored = true,
  });

  /// Columns of [low, mid, high], each 0..1.
  final List<List<double>> fingerprint;
  final double height;

  /// Optional 0..1 playhead; columns after it are dimmed.
  final double? progress;

  /// Optional highlighted range (0..1, 0..1).
  final (double, double)? highlight;
  final double opacity;
  final bool mirrored;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SignalPainter(fingerprint, progress, highlight, opacity, mirrored),
      ),
    );
  }
}

class _SignalPainter extends CustomPainter {
  _SignalPainter(this.fp, this.progress, this.highlight, this.opacity, this.mirrored);

  final List<List<double>> fp;
  final double? progress;
  final (double, double)? highlight;
  final double opacity;
  final bool mirrored;

  @override
  void paint(Canvas canvas, Size size) {
    if (fp.isEmpty) {
      final p = Paint()..color = Palette.line.withValues(alpha: 0.6 * opacity);
      canvas.drawRect(Rect.fromLTWH(0, size.height / 2 - 0.5, size.width, 1), p);
      return;
    }
    final n = fp.length;
    final colW = size.width / n;
    final barW = math.max(1.0, colW * 0.62);
    final mid = mirrored ? size.height / 2 : size.height;
    final paint = Paint()..strokeCap = StrokeCap.round;
    final hl = highlight;
    if (hl != null) {
      canvas.drawRect(
        Rect.fromLTRB(hl.$1 * size.width, 0, hl.$2 * size.width, size.height),
        Paint()..color = Palette.amber.withValues(alpha: 0.10 * opacity),
      );
    }
    // Normalize to the song's own range so quiet intros, drops and breaks
    // read even on heavily compressed masters.
    double energyOf(List<double> c) => (c[0] * 0.42 + c[1] * 0.38 + c[2] * 0.2).clamp(0.0, 1.0);
    var lo = 1.0, hi = 0.0;
    for (final c in fp) {
      final e = energyOf(c);
      lo = math.min(lo, e);
      hi = math.max(hi, e);
    }
    final span = math.max(0.08, hi - lo);
    for (var i = 0; i < n; i++) {
      final c = fp[i];
      final low = c[0], midE = c[1], high = c[2];
      final energy = ((energyOf(c) - lo) / span).clamp(0.0, 1.0);
      final sum = low + midE + high;
      final bright = sum > 1e-6 ? ((midE * 0.5 + high) / sum) : 0.0;
      final h = math.max(1.0, (0.18 + 0.82 * math.pow(energy, 1.3)) * (mirrored ? mid * 0.96 : mid));
      final x = i * colW + colW / 2;
      final heat = (0.08 + 0.6 * energy + 0.32 * bright).clamp(0.0, 1.0);
      final color = Palette.heat(heat);
      final past = progress == null || i / n <= progress!;
      final alpha = (past ? 1.0 : 0.32) * opacity;
      paint
        ..color = color.withValues(alpha: alpha)
        ..strokeWidth = barW;
      if (mirrored) {
        canvas.drawLine(Offset(x, mid - h), Offset(x, mid + h), paint);
      } else {
        canvas.drawLine(Offset(x, mid), Offset(x, mid - h), paint);
      }
    }
    if (progress != null) {
      final x = progress!.clamp(0.0, 1.0) * size.width;
      canvas.drawRect(Rect.fromLTWH(x - 1, 0, 2, size.height), Paint()..color = Palette.bone.withValues(alpha: opacity));
    }
  }

  @override
  bool shouldRepaint(_SignalPainter old) =>
      old.fp != fp || old.progress != progress || old.highlight != highlight || old.opacity != opacity;
}
