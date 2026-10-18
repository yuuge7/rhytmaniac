import 'package:flutter/material.dart';

import '../../core/medals.dart';
import '../theme.dart';

IconData medalIcon(MedalGroup g) => switch (g) {
      MedalGroup.skill => Icons.star_rounded,
      MedalGroup.accuracy => Icons.gps_fixed_rounded,
      MedalGroup.mods => Icons.auto_awesome_rounded,
      MedalGroup.combo => Icons.bolt_rounded,
      MedalGroup.dedication => Icons.local_fire_department_rounded,
      MedalGroup.explorer => Icons.explore_rounded,
    };

/// Medal colour by group, from the heat ramp (medals are achievement data).
Color medalColor(MedalGroup g) => switch (g) {
      MedalGroup.skill => Palette.amber,
      MedalGroup.accuracy => Palette.flare,
      MedalGroup.mods => Palette.rose,
      MedalGroup.combo => Palette.ember,
      MedalGroup.dedication => Palette.plum,
      MedalGroup.explorer => Palette.early,
    };

/// A round medal: lit when unlocked, an outline when not.
class MedalBadge extends StatelessWidget {
  const MedalBadge({super.key, required this.medal, required this.unlocked, this.size = 44});
  final Medal medal;
  final bool unlocked;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = medalColor(medal.group);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: unlocked ? c.withValues(alpha: 0.18) : Colors.transparent,
        border: Border.all(color: unlocked ? c : Palette.line, width: unlocked ? 2 : 1.2),
      ),
      child: Icon(medalIcon(medal.group), size: size * 0.5, color: unlocked ? c : Palette.dim),
    );
  }
}

/// Tells the player about medals they just unlocked.
void announceMedals(BuildContext context, List<Medal> medals) {
  if (medals.isEmpty || !context.mounted) return;
  // Queued after whatever message is showing (often the reason for the
  // medal, like "Added 2 osu! difficulties"), instead of replacing it.
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(medals.length == 1
        ? 'Medal unlocked: ${medals.first.title}'
        : '${medals.length} medals unlocked: ${medals.map((m) => m.title).join(', ')}'),
  ));
}

/// Every medal, lit or not; tap one to read how to earn it.
class MedalGrid extends StatelessWidget {
  const MedalGrid({super.key, required this.unlocked});
  final Map<String, DateTime> unlocked;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final g in MedalGroup.values) ...[
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 8),
          child: Text(g.label, style: AppText.body(13, weight: 600, color: Palette.mist)),
        ),
        Wrap(spacing: 10, runSpacing: 10, children: [
          for (final m in allMedals.where((m) => m.group == g))
            Tooltip(
              message: m.title,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _details(context, m),
                child: MedalBadge(medal: m, unlocked: unlocked.containsKey(m.id)),
              ),
            ),
        ]),
      ],
    ]);
  }

  void _details(BuildContext context, Medal m) {
    final at = unlocked[m.id];
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        icon: MedalBadge(medal: m, unlocked: at != null, size: 64),
        title: Text(m.title, textAlign: TextAlign.center),
        content: Text(
          at == null ? m.description : '${m.description}\n\nUnlocked ${at.day}.${at.month}.${at.year}.',
          textAlign: TextAlign.center,
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
      ),
    );
  }
}
