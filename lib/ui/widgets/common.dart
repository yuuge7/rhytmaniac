import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/models/difficulty.dart';
import '../../core/models/score.dart';
import '../../core/models/song.dart';
import '../theme.dart';
import 'signal_strip.dart';

/// Star rating as a heat-coloured numeric pill.
class StarBadge extends StatelessWidget {
  const StarBadge(this.stars, {super.key, this.compact = false});
  final double stars;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = Palette.stars(stars);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8, vertical: compact ? 2 : 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        border: Border.all(color: c.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${stars.toStringAsFixed(stars >= 10 ? 1 : 2)}★',
        style: AppText.data(compact ? 10.5 : 12, weight: 650, color: c),
      ),
    );
  }
}

/// Uppercase section label.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing, this.padding = const EdgeInsets.fromLTRB(Space.gutter, 20, Space.gutter, 8)});
  final String text;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Row(
          children: [
            Text(text.toUpperCase(), style: AppText.label()),
            const Spacer(),
            ?trailing,
          ],
        ),
      );
}

/// Cover art when the song has one, otherwise its signal strip on ink.
class SongArt extends StatelessWidget {
  const SongArt({super.key, required this.song, required this.coverPath, this.size = 56, this.radius = 10});
  final Song song;
  final String? coverPath;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final path = coverPath;
    Widget child;
    if (path != null && File(path).existsSync()) {
      child = Image.file(File(path), fit: BoxFit.cover, width: size, height: size, cacheWidth: (size * 3).round());
    } else {
      child = Container(
        color: Palette.inkDeep,
        padding: EdgeInsets.symmetric(horizontal: size * 0.08),
        alignment: Alignment.center,
        child: SignalStrip(fingerprint: _downsample(song.fingerprint, 16), height: size * 0.7),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(width: size, height: size, child: child),
    );
  }

  static List<List<double>> _downsample(List<List<double>> fp, int n) {
    if (fp.length <= n) return fp;
    final out = <List<double>>[];
    final per = fp.length / n;
    for (var i = 0; i < n; i++) {
      final a = (i * per).floor(), b = ((i + 1) * per).floor().clamp(a + 1, fp.length);
      final acc = [0.0, 0.0, 0.0];
      for (var j = a; j < b; j++) {
        for (var k = 0; k < 3; k++) {
          acc[k] += fp[j][k];
        }
      }
      out.add(acc.map((v) => v / (b - a)).toList());
    }
    return out;
  }
}

class GradeMark extends StatelessWidget {
  const GradeMark(this.grade, {super.key, this.size = 18});
  final Grade grade;
  final double size;

  @override
  Widget build(BuildContext context) =>
      Text(grade.label, style: AppText.display(size, width: 140, weight: 900, color: Palette.grade(grade)));
}

/// Two-option segmented control for Tiles / Circles.
class ModeSwitch extends StatelessWidget {
  const ModeSwitch({super.key, required this.mode, required this.onChanged});
  final GameMode mode;
  final ValueChanged<GameMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: Palette.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: Palette.line)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in GameMode.values)
            Semantics(
              selected: m == mode,
              button: true,
              child: GestureDetector(
                onTap: () => onChanged(m),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: m == mode ? Palette.raised : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Row(
                    children: [
                      Icon(m == GameMode.tiles ? Icons.view_week_rounded : Icons.radio_button_checked_rounded,
                          size: 16, color: m == mode ? Palette.amber : Palette.mist),
                      const SizedBox(width: 6),
                      Text(m.label, style: AppText.body(13.5, weight: m == mode ? 650 : 500, color: m == mode ? Palette.bone : Palette.mist)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String formatDuration(double ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String formatScore(int score) {
  final s = score.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

String formatAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  if (d.inDays < 30) return '${d.inDays}d ago';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

void showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}
