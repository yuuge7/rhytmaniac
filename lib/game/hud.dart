import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/gameplay/session.dart';
import '../core/models/difficulty.dart';
import '../core/models/score.dart';
import '../data/settings.dart';
import '../ui/theme.dart';
import 'fx.dart';

/// Tracks HUD animation state between frames.
class HudController {
  int combo = 0;
  double comboPulseAt = -1e9;
  double health = 1;
  HitFeedback? lastJudgment;

  void reset() {
    combo = 0;
    comboPulseAt = -1e9;
    health = 1;
    lastJudgment = null;
  }

  void observe(GameSession s, double t) {
    final p = s.processor;
    if (p.combo > combo) comboPulseAt = t;
    combo = p.combo;
    // Health eases toward its target so drains read as motion.
    health += (p.health - health) * 0.2;
    if (s.feedback.isNotEmpty) lastJudgment = s.feedback.last;
  }
}

/// Everything the HUD shows, painted in one pass.
///
/// The HUD changes every frame (timers, combo pulse), so it is a painter
/// that reuses laid-out text instead of a widget tree that rebuilds and
/// re-lays out its text 60 times a second.
class HudPainter extends CustomPainter {
  HudPainter({
    required Listenable repaint,
    required this.controller,
    required this.session,
    required this.mode,
    required this.settings,
    required this.mods,
    required this.time,
    required this.songEndMs,
    required this.windows,
    required this.padding,
    required this.text,
    required this.fps,
    required this.drift,
    required this.frameCost,
    this.practiceLoops,
    this.replayOf,
    this.leftHanded = false,
  }) : super(repaint: repaint);

  final HudController controller;
  final GameSession session;
  final GameMode mode;
  final AppSettings settings;
  final Mods mods;
  final double Function() time;
  final double songEndMs;
  final HitWindows windows;
  final EdgeInsets padding;
  final TextCache text;
  final double Function() fps;
  final double Function() drift;
  final (double, double) Function() frameCost;
  final int? Function()? practiceLoops;

  /// Player name when watching a replay.
  final String? replayOf;

  /// Score on the left, pause button on the right, combo bottom-right.
  final bool leftHanded;

  final _fill = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final t = time();
    final p = session.processor;
    final tiles = mode == GameMode.tiles;
    final top = padding.top + 4;

    // Score, accuracy and mods: top right (top left when left-handed).
    final score = text.data(p.score.toString().padLeft(8, '0'), 19, Palette.bone, weight: 600);
    final acc = text.data('${(p.accuracy * 100).toStringAsFixed(2)}%', 12.5, Palette.mist);
    final modsLine = mods.acronyms.where((m) => m != 'AT').join(' ');
    final modsText = modsLine.isEmpty ? null : text.data(modsLine, 10.5, Palette.amber, weight: 600);
    double xFor(TextPainter tp) => leftHanded ? 14 : size.width - 14 - tp.width;
    score.paint(canvas, Offset(xFor(score), top + 6));
    acc.paint(canvas, Offset(xFor(acc), top + 6 + score.height + 2));
    modsText?.paint(canvas, Offset(xFor(modsText), top + 6 + score.height + acc.height + 4));

    // Progress and health bars between the pause button and the score.
    final scoreBlock = math.max(score.width, 92.0) + 16;
    final double barLeft = leftHanded ? 14.0 + scoreBlock : 60.0;
    final double barRight = leftHanded ? size.width - 60 : size.width - 14 - scoreBlock;
    if (barRight > barLeft + 20) {
      _bar(canvas, Rect.fromLTWH(barLeft, top + 16, barRight - barLeft, 2), (t / math.max(1, songEndMs)).clamp(0.0, 1.0), Palette.mist);
      final h = controller.health.clamp(0.0, 1.0);
      _bar(canvas, Rect.fromLTWH(barLeft, top + 24, barRight - barLeft, 5), h,
          h < 0.3 ? Palette.danger : Palette.heat(0.45 + 0.5 * h));
    }

    var infoY = leftHanded ? top + 78 : top + 54;
    if (settings.showFps) {
      final (ui, raster) = frameCost();
      final a = text.data('${fps().round()} fps · drift ${drift().toStringAsFixed(1)} ms', 11, Palette.amber);
      final b = text.data('ui ${ui.toStringAsFixed(1)} ms · raster ${raster.toStringAsFixed(1)} ms', 11, Palette.amber);
      a.paint(canvas, Offset(16, infoY));
      b.paint(canvas, Offset(16, infoY + a.height));
      infoY += a.height * 2 + 4;
    }
    final loops = practiceLoops?.call();
    if (loops != null) {
      text.data('Practice · loop ${loops + 1}', 11.5, Palette.amber).paint(canvas, Offset(16, infoY));
      infoY += 18;
    }
    if (replayOf != null) {
      text.data('Replay · $replayOf', 11.5, Palette.amber, weight: 600).paint(canvas, Offset(16, infoY));
    }

    // Combo.
    if (controller.combo >= 2) {
      final since = (t - controller.comboPulseAt) / (160 * mods.rate);
      final pulse = since < 0 ? 0.0 : (1 - since).clamp(0.0, 1.0);
      final label = text.display(tiles ? '${controller.combo}' : '${controller.combo}×', tiles ? 64 : 40,
          Palette.bone.withValues(alpha: 0.92), width: 110, weight: 850);
      // The display face stretches with each hit: a scale (not a new font
      // instance per frame), in a few steps so glyphs stay cached.
      final step = (pulse * 4).round() / 4;
      final sx = 1 + 0.16 * step, sy = 1 + 0.05 * step;
      final anchor = tiles
          ? Offset(size.width / 2, size.height * 0.30 + label.height / 2)
          : Offset(leftHanded ? size.width - 18 - label.width / 2 : 18 + label.width / 2,
              size.height - padding.bottom - 18 - label.height / 2);
      canvas.save();
      canvas.translate(anchor.dx, anchor.dy);
      canvas.scale(sx, sy);
      label.paint(canvas, Offset(-label.width / 2, -label.height / 2));
      canvas.restore();
    }

    if (tiles && settings.judgmentDisplay != JudgmentDisplay.off) _judgment(canvas, size, t);
    if (settings.showHitErrorBar) {
      final y = tiles ? size.height - size.height * 0.085 - 9 : size.height - padding.bottom - 8 - 18;
      _errorBar(canvas, Rect.fromCenter(center: Offset(size.width / 2, y + 9), width: 180, height: 18), p.errors);
    }
    _break(canvas, size, t);
  }

  void _bar(Canvas canvas, Rect r, double value, Color color) {
    final radius = Radius.circular(r.height);
    _fill.color = Palette.bone.withValues(alpha: 0.12);
    canvas.drawRRect(RRect.fromRectAndRadius(r, radius), _fill);
    if (value <= 0) return;
    _fill.color = color;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(r.left, r.top, r.width * value, r.height), radius), _fill);
  }

  void _judgment(Canvas canvas, Size size, double t) {
    final j = controller.lastJudgment;
    if (j == null) return;
    if (settings.judgmentDisplay == JudgmentDisplay.minimal && j.judgment != Judgment.miss) return;
    final age = t - j.timeMs;
    if (age < 0 || age > 420) return;
    final k = age / 420;
    final scale = 1.0 + 0.18 * ((1 - math.min(1, age / 90)) * 3).round() / 3;
    final tp = text.display(j.judgment.label, 30, Palette.judgment(j.judgment).withValues(alpha: 1 - k * k), width: 130, weight: 820);
    canvas.save();
    canvas.translate(size.width / 2, size.height * 0.56 + tp.height / 2);
    canvas.scale(scale);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  /// Early/late ticks of recent hits over the timing windows.
  void _errorBar(Canvas canvas, Rect r, List errors) {
    final w = windows;
    final cx = r.center.dx;
    final scale = (r.width / 2) / w.good;
    final cy = r.center.dy;
    void zone(double ms, Color c) {
      _fill.color = c.withValues(alpha: 0.35);
      canvas.drawRect(Rect.fromLTRB(cx - ms * scale, cy - 1.5, cx + ms * scale, cy + 1.5), _fill);
    }

    zone(w.good, Palette.judgment(Judgment.good));
    zone(w.great, Palette.judgment(Judgment.great));
    zone(w.perfect, Palette.judgment(Judgment.perfect));
    _fill.color = Palette.bone;
    canvas.drawRect(Rect.fromLTWH(cx - 1, r.top, 2, r.height), _fill);
    final n = errors.length;
    for (var i = math.max(0, n - 24); i < n; i++) {
      final e = (errors[i].errorMs as double).clamp(-w.good, w.good);
      final age = (n - 1 - i) / 24;
      _fill.color = Palette.flare.withValues(alpha: (1 - age) * 0.85);
      canvas.drawRect(Rect.fromLTWH(cx + e * scale - 1, r.top + 2, 2, r.height - 4), _fill);
    }
  }

  /// Break banner: time left, then a heads-up before objects return.
  void _break(Canvas canvas, Size size, double t) {
    final b = session.breakAt(t);
    if (b == null) return;
    final fadeIn = ((t - b.startMs) / (300 * mods.rate)).clamp(0.0, 1.0);
    final leftMs = (b.endMs - t) / mods.rate;
    final soon = leftMs < 1500;
    final title = text.display(soon ? 'Get ready' : 'Break', 34, Palette.bone.withValues(alpha: fadeIn), width: 130, weight: 850);
    final cy = size.height * 0.42;
    title.paint(canvas, Offset((size.width - title.width) / 2, cy - title.height));
    final secs = text.data('${(leftMs / 1000).ceil()}', 15, Palette.mist.withValues(alpha: fadeIn));
    secs.paint(canvas, Offset((size.width - secs.width) / 2, cy + 8));
    final frac = ((b.endMs - t) / math.max(1, b.durationMs)).clamp(0.0, 1.0);
    final w = size.width * 0.5 * frac;
    _fill.color = Palette.amber.withValues(alpha: 0.8 * fadeIn);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(size.width / 2, cy + 36), width: w, height: 3), const Radius.circular(2)),
      _fill,
    );
    // How it's going: health at the break, like osu!'s pass/fail mark.
    final ok = session.processor.health >= 0.5;
    final mood = text.body(ok ? 'Doing well' : 'Hang in there', 13, (ok ? Palette.amber : Palette.rose).withValues(alpha: fadeIn), weight: 600);
    mood.paint(canvas, Offset((size.width - mood.width) / 2, cy + 48));
  }

  @override
  bool shouldRepaint(HudPainter old) => old.session != session || old.settings != settings || old.padding != padding;
}
