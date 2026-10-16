import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/gameplay/session.dart';
import '../core/models/difficulty.dart';
import '../core/models/score.dart';
import '../data/settings.dart';
import '../ui/theme.dart';

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

class Hud extends StatelessWidget {
  const Hud({
    super.key,
    required this.frame,
    required this.controller,
    required this.session,
    required this.mode,
    required this.settings,
    required this.time,
    required this.songEndMs,
    required this.windows,
    required this.fps,
    required this.drift,
    required this.frameCost,
    required this.onPause,
    required this.skipIntro,
    required this.onSkipIntro,
    this.practiceLoops,
  });

  final ValueNotifier<int> frame;
  final HudController controller;
  final GameSession session;
  final GameMode mode;
  final AppSettings settings;
  final double Function() time;
  final double songEndMs;
  final HitWindows windows;
  final double Function() fps;

  /// Mean absolute audio-vs-clock drift in ms (debug readout).
  final double Function() drift;

  /// Average (build, raster) milliseconds per frame.
  final (double, double) Function() frameCost;
  final VoidCallback onPause;
  final bool Function() skipIntro;
  final VoidCallback onSkipIntro;
  final int? practiceLoops;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return AnimatedBuilder(
      animation: frame,
      builder: (context, _) {
        final t = time();
        final p = session.processor;
        final size = MediaQuery.sizeOf(context);
        final tiles = mode == GameMode.tiles;
        return Stack(
          children: [
            // Top bar.
            Positioned(
              left: 4,
              right: 14,
              top: padding.top + 4,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconButton(
                    tooltip: 'Pause',
                    onPressed: onPause,
                    icon: const Icon(Icons.pause_rounded, color: Palette.bone),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 14, right: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Bar(value: (t / math.max(1, songEndMs)).clamp(0.0, 1.0), color: Palette.mist, height: 2),
                          const SizedBox(height: 6),
                          _Bar(
                            value: controller.health.clamp(0.0, 1.0),
                            color: controller.health < 0.3 ? Palette.danger : Palette.heat(0.45 + 0.5 * controller.health),
                            height: 5,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(p.score.toString().padLeft(7, '0'), style: AppText.data(19, weight: 600, color: Palette.bone, letterSpacing: 0.5)),
                      const SizedBox(height: 2),
                      Text('${(p.accuracy * 100).toStringAsFixed(2)}%', style: AppText.data(12.5, color: Palette.mist)),
                    ],
                  ),
                ],
              ),
            ),
            if (settings.showFps)
              Positioned(
                left: 16,
                top: padding.top + 54,
                child: Text(
                  '${fps().round()} fps · drift ${drift().toStringAsFixed(1)} ms\n'
                  'ui ${frameCost().$1.toStringAsFixed(1)} ms · raster ${frameCost().$2.toStringAsFixed(1)} ms',
                  style: AppText.data(11, color: Palette.amber),
                ),
              ),
            if (practiceLoops != null)
              Positioned(
                left: 16,
                top: padding.top + (settings.showFps ? 90 : 54),
                child: Text('Practice · loop ${practiceLoops! + 1}', style: AppText.data(11.5, color: Palette.amber)),
              ),
            // Combo.
            if (controller.combo >= 2)
              tiles
                  ? Positioned(
                      left: 0,
                      right: 0,
                      top: size.height * 0.30,
                      child: IgnorePointer(child: Center(child: _combo(t, 64))),
                    )
                  : Positioned(left: 18, bottom: padding.bottom + 18, child: IgnorePointer(child: _combo(t, 40, suffix: '×'))),
            // Judgment (Tiles; Circles draws its own at the circle).
            if (tiles && settings.judgmentDisplay != JudgmentDisplay.off) _judgment(t, size),
            if (settings.showHitErrorBar)
              Positioned(
                left: 0,
                right: 0,
                bottom: tiles ? size.height * 0.085 : padding.bottom + 8,
                child: IgnorePointer(child: Center(child: _ErrorBar(errors: p.errors, windows: windows, now: t))),
              ),
            if (skipIntro())
              Positioned(
                right: 16,
                bottom: padding.bottom + (tiles ? size.height * 0.2 : 70),
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(backgroundColor: Palette.raised, foregroundColor: Palette.bone),
                  onPressed: onSkipIntro,
                  icon: const Icon(Icons.fast_forward_rounded),
                  label: const Text('Skip intro'),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _combo(double t, double size, {String suffix = ''}) {
    final since = (t - controller.comboPulseAt) / 160;
    final pulse = since < 0 ? 0.0 : (1 - since).clamp(0.0, 1.0);
    // The display face's width axis breathes with every hit.
    final width = 100 + 50 * pulse;
    return Text(
      '${controller.combo}$suffix',
      style: AppText.display(size, width: width, weight: 850, color: Palette.bone.withValues(alpha: 0.92), letterSpacing: -1),
    );
  }

  Widget _judgment(double t, Size size) {
    final j = controller.lastJudgment;
    if (j == null) return const SizedBox.shrink();
    if (settings.judgmentDisplay == JudgmentDisplay.minimal && j.judgment != Judgment.miss) return const SizedBox.shrink();
    final age = t - j.timeMs;
    if (age < 0 || age > 420) return const SizedBox.shrink();
    final k = age / 420;
    final scale = 1.0 + 0.18 * (1 - math.min(1, age / 90));
    return Positioned(
      left: 0,
      right: 0,
      top: size.height * 0.56,
      child: IgnorePointer(
        child: Center(
          child: Transform.scale(
            scale: scale,
            child: Text(
              j.judgment.label,
              style: AppText.display(30, width: 130, weight: 820, color: Palette.judgment(j.judgment).withValues(alpha: 1 - k * k)),
            ),
          ),
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.value, required this.color, required this.height});
  final double value;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: SizedBox(
          height: height,
          child: Stack(fit: StackFit.expand, children: [
            ColoredBox(color: Palette.bone.withValues(alpha: 0.12)),
            FractionallySizedBox(alignment: Alignment.centerLeft, widthFactor: value, child: ColoredBox(color: color)),
          ]),
        ),
      );
}

/// Early/late ticks of recent hits over the timing windows.
class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.errors, required this.windows, required this.now});
  final List errors;
  final HitWindows windows;
  final double now;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 180,
      height: 18,
      child: CustomPaint(painter: _ErrorBarPainter(errors, windows)),
    );
  }
}

class _ErrorBarPainter extends CustomPainter {
  _ErrorBarPainter(this.errors, this.w);
  final List errors;
  final HitWindows w;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final scale = (size.width / 2) / w.good;
    final p = Paint();
    final cy = size.height / 2;
    void zone(double ms, Color c) {
      p.color = c.withValues(alpha: 0.35);
      canvas.drawRect(Rect.fromLTRB(cx - ms * scale, cy - 1.5, cx + ms * scale, cy + 1.5), p);
    }

    zone(w.good, Palette.rose);
    zone(w.great, Palette.amber);
    zone(w.perfect, Palette.flare);
    p.color = Palette.bone;
    canvas.drawRect(Rect.fromLTWH(cx - 1, 0, 2, size.height), p);
    final n = errors.length;
    for (var i = math.max(0, n - 24); i < n; i++) {
      final e = (errors[i].errorMs as double).clamp(-w.good, w.good);
      final age = (n - 1 - i) / 24;
      p.color = Palette.flare.withValues(alpha: (1 - age) * 0.85);
      canvas.drawRect(Rect.fromLTWH(cx + e * scale - 1, 2, 2, size.height - 4), p);
    }
  }

  @override
  bool shouldRepaint(_ErrorBarPainter old) => true;
}
