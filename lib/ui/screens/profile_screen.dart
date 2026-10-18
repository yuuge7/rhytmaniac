import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/medals.dart';
import '../../core/models/difficulty.dart';
import '../../core/models/score.dart';
import '../../core/profile_stats.dart';
import '../../core/util/rng.dart';
import '../../platform/native_bridge.dart';
import '../../state/providers.dart';
import '../export_flow.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/medals.dart';
import '../widgets/signal_strip.dart';
import 'song_screen.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final profile = ref.read(profileProvider);
    final c = TextEditingController(text: profile.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Player name'),
        content: TextField(controller: c, autofocus: true, maxLength: 24),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) await ref.read(profileProvider.notifier).update(profile.copyWith(name: name));
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    var includeLibrary = false;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Export profile'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Saves your name, scores, play stats and settings to one file you can import on another device.',
                style: AppText.body(14, color: Palette.mist)),
            const SizedBox(height: 10),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: includeLibrary,
              onChanged: (v) => set(() => includeLibrary = v ?? false),
              title: Text('Include songs and maps', style: AppText.body(14.5, weight: 600)),
              subtitle: Text('Full backup. The file can get large.', style: AppText.body(12.5, color: Palette.mist)),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Export')),
          ],
        ),
      ),
    );
    if (go != true || !context.mounted) return;
    showMessage(context, includeLibrary ? 'Packing your profile and library…' : 'Packing your profile…');
    try {
      final services = ref.read(servicesProvider);
      final path = await services.packs.exportProfile(
        profile: ref.read(profileProvider),
        settings: ref.read(settingsProvider),
        scores: ref.read(scoresProvider),
        songs: ref.read(libraryProvider).songs,
        includeLibrary: includeLibrary,
        progress: ref.read(progressProvider),
        collections: ref.read(collectionsProvider),
      );
      if (context.mounted) await saveExport(context, ref, path);
    } catch (e) {
      if (context.mounted) showMessage(context, 'Could not export: $e');
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    try {
      final file = await NativeBridge.instance.pickFile(const ['application/zip', 'application/octet-stream']);
      if (file == null) return;
      final services = ref.read(servicesProvider);
      final tmp = '${services.paths.tmpDir}/profile_${DateTime.now().millisecondsSinceEpoch}.zip';
      await NativeBridge.instance.copyUri(file.uri, tmp);
      final r = await services.packs.importProfile(tmp, current: ref.read(settingsProvider));
      await ref.read(libraryProvider.notifier).refresh();
      await ref.read(scoresProvider.notifier).reload();
      await ref.read(settingsProvider.notifier).reload();
      await ref.read(profileProvider.notifier).reload();
      await ref.read(progressProvider.notifier).reload();
      await ref.read(collectionsProvider.notifier).reload();
      if (context.mounted) {
        showMessage(context,
            'Profile imported: ${r.scoresAdded} new score${r.scoresAdded == 1 ? '' : 's'}${r.songsAdded > 0 ? ', ${r.songsAdded} songs' : ''}');
      }
    } on FormatException catch (e) {
      if (context.mounted) showMessage(context, e.message);
    } catch (e) {
      if (context.mounted) showMessage(context, 'Could not import: $e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    final scores = ref.watch(scoresProvider);
    final lib = ref.watch(libraryProvider);
    final stats = ProfileStats.compute(scores);
    final progress = ref.watch(progressProvider);

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 18, 8, 0),
            child: Row(
              children: [
                _SignalAvatar(name: profile.name, seed: profile.avatarSeed, size: 68),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onTap: () => _rename(context, ref),
                        child: Row(children: [
                          Flexible(
                            child: Text(profile.name, overflow: TextOverflow.ellipsis, style: AppText.display(28, width: 130, weight: 850)),
                          ),
                          const SizedBox(width: 6),
                          const Icon(Icons.edit_outlined, size: 16, color: Palette.mist),
                        ]),
                      ),
                      const SizedBox(height: 2),
                      Text('Playing since ${_month(profile.createdAt)}', style: AppText.body(13, color: Palette.mist)),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  color: Palette.raised,
                  onSelected: (v) {
                    if (v == 'export') _export(context, ref);
                    if (v == 'import') _import(context, ref);
                    if (v == 'avatar') {
                      ref.read(profileProvider.notifier).update(profile.copyWith(avatarSeed: profile.avatarSeed + 1));
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'export', child: Text('Export profile…')),
                    PopupMenuItem(value: 'import', child: Text('Import profile…')),
                    PopupMenuItem(value: 'avatar', child: Text('New avatar pattern')),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 26),
          // Performance hero.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(stats.pp.round().toString(), style: AppText.display(64, width: 150, weight: 900, color: Palette.flare, letterSpacing: -2)),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('PP', style: AppText.label(color: Palette.amber)),
                    const SizedBox(height: 2),
                    Text('performance from your best plays', style: AppText.body(12, color: Palette.mist)),
                  ]),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 6, Space.gutter, 0),
            child: Row(children: [
              for (final m in GameMode.values) ...[
                Text(m.label, style: AppText.body(13, color: Palette.mist)),
                const SizedBox(width: 6),
                Text('${stats.ppByMode[m]!.round()}pp', style: AppText.data(13, weight: 650, color: Palette.bone)),
                const SizedBox(width: 18),
              ],
            ]),
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: _StatGrid(stats: stats),
          ),
          const SectionLabel('Grades'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final g in const [Grade.ss, Grade.s, Grade.a, Grade.b, Grade.c, Grade.d])
                  Column(children: [
                    GradeMark(g, size: 24),
                    const SizedBox(height: 4),
                    Text('${stats.grades[g]}', style: AppText.data(12.5, color: Palette.bone)),
                  ]),
              ],
            ),
          ),
          SectionLabel('Medals · ${progress.medals.length} of ${allMedals.length}'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: MedalGrid(unlocked: progress.medals),
          ),
          if (stats.accuracyTrend.length >= 2) ...[
            const SectionLabel('Accuracy, last plays'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: _AccuracyTrend(values: stats.accuracyTrend),
            ),
          ],
          if (stats.mostPlayed.isNotEmpty) ...[
            const SectionLabel('Your sound'),
            for (final sp in stats.mostPlayed)
              _MostPlayedRow(
                plays: sp,
                fingerprint: lib.song(sp.songId)?.fingerprint ?? const [],
                onTap: lib.song(sp.songId) == null
                    ? null
                    : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SongScreen(songId: sp.songId))),
              ),
          ],
          const SectionLabel('Best plays'),
          if (stats.bestPlays.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: Text('Finish a song to start your list. Autoplay and practice runs don’t count.',
                  style: AppText.body(14, color: Palette.mist)),
            ),
          for (final (i, s) in stats.bestPlays.indexed) _PlayRow(score: s, rank: i + 1, showPp: true),
          if (stats.recent.isNotEmpty) ...[
            const SectionLabel('Recent'),
            for (final s in stats.recent) _PlayRow(score: s),
          ],
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _import(context, ref),
                  icon: const Icon(Icons.file_download_outlined),
                  label: const Text('Import'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _export(context, ref),
                  icon: const Icon(Icons.share_rounded),
                  label: const Text('Export'),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  static String _month(DateTime t) {
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${m[t.month - 1]} ${t.year}';
  }
}

class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.stats});
  final ProfileStats stats;

  @override
  Widget build(BuildContext context) {
    final hours = stats.playMs / 3600000;
    final cells = [
      ('Plays', '${stats.plays}'),
      ('Time played', hours >= 1 ? '${hours.toStringAsFixed(1)} h' : '${(stats.playMs / 60000).round()} min'),
      ('Notes hit', _compact(stats.notesHit)),
      ('Accuracy', stats.plays == 0 ? '—' : '${(stats.averageAccuracy * 100).toStringAsFixed(1)}%'),
      ('Best combo', '${stats.bestCombo}'),
      ('Day streak', '${stats.streakDays}'),
    ];
    return Container(
      decoration: BoxDecoration(color: Palette.surface, borderRadius: BorderRadius.circular(Space.radius)),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(children: [
        for (var r = 0; r < 2; r++)
          Row(children: [
            for (var c = 0; c < 3; c++)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(cells[r * 3 + c].$1, style: AppText.body(12, color: Palette.mist)),
                    const SizedBox(height: 3),
                    Text(cells[r * 3 + c].$2, style: AppText.data(16, weight: 650, color: Palette.bone)),
                  ]),
                ),
              ),
          ]),
      ]),
    );
  }

  static String _compact(int n) => n >= 10000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';
}

/// Single-series line of recent accuracies with the latest value labelled.
/// Tap or drag to read any play.
class _AccuracyTrend extends StatefulWidget {
  const _AccuracyTrend({required this.values});
  final List<double> values;

  @override
  State<_AccuracyTrend> createState() => _AccuracyTrendState();
}

class _AccuracyTrendState extends State<_AccuracyTrend> {
  int? _sel;

  @override
  Widget build(BuildContext context) {
    final v = widget.values;
    final i = _sel ?? v.length - 1;
    return LayoutBuilder(builder: (context, c) {
      void pick(Offset o) => setState(() => _sel = (o.dx / c.maxWidth * (v.length - 1)).round().clamp(0, v.length - 1));
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(_sel == null ? 'Latest' : 'Play ${i + 1} of ${v.length}', style: AppText.body(12, color: Palette.mist)),
          const Spacer(),
          Text('${(v[i] * 100).toStringAsFixed(2)}%', style: AppText.data(12.5, color: Palette.bone)),
        ]),
        const SizedBox(height: 6),
        GestureDetector(
          onTapDown: (d) => pick(d.localPosition),
          onHorizontalDragUpdate: (d) => pick(d.localPosition),
          onHorizontalDragEnd: (_) => setState(() => _sel = null),
          child: SizedBox(height: 90, width: c.maxWidth, child: CustomPaint(painter: _TrendPainter(v, i))),
        ),
      ]);
    });
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.v, this.sel);
  final List<double> v;
  final int sel;

  @override
  void paint(Canvas canvas, Size size) {
    final lo = math.max(0.0, v.reduce(math.min) - 0.02);
    final hi = math.min(1.0, v.reduce(math.max) + 0.01);
    final span = math.max(0.01, hi - lo);
    Offset pt(int i) => Offset(i / (v.length - 1) * (size.width - 8) + 4, 6 + (1 - (v[i] - lo) / span) * (size.height - 12));
    final grid = Paint()..color = Palette.line.withValues(alpha: 0.6);
    for (final f in [0.0, 0.5, 1.0]) {
      canvas.drawRect(Rect.fromLTWH(0, 6 + f * (size.height - 12), size.width, 1), grid);
    }
    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < v.length; i++) {
      path.lineTo(pt(i).dx, pt(i).dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = Palette.amber,
    );
    final p = pt(sel);
    canvas.drawRect(Rect.fromLTWH(p.dx - 0.5, 0, 1, size.height), Paint()..color = Palette.bone.withValues(alpha: 0.3));
    canvas.drawCircle(p, 6, Paint()..color = Palette.surface);
    canvas.drawCircle(p, 4.5, Paint()..color = Palette.amber);
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.v != v || old.sel != sel;
}

class _MostPlayedRow extends StatelessWidget {
  const _MostPlayedRow({required this.plays, required this.fingerprint, this.onTap});
  final SongPlays plays;
  final List<List<double>> fingerprint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(plays.title.isEmpty ? 'Unknown song' : plays.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body(14.5, weight: 600)),
            ),
            Text('${plays.plays} play${plays.plays == 1 ? '' : 's'}', style: AppText.data(12, color: Palette.mist)),
          ]),
          const SizedBox(height: 6),
          SignalStrip(fingerprint: fingerprint, height: 18, opacity: onTap == null ? 0.4 : 1),
        ]),
      ),
    );
  }
}

class _PlayRow extends StatelessWidget {
  const _PlayRow({required this.score, this.rank, this.showPp = false});
  final ScoreRecord score;
  final int? rank;
  final bool showPp;

  @override
  Widget build(BuildContext context) {
    final s = score;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 6),
      child: Row(
        children: [
          if (rank != null)
            SizedBox(width: 26, child: Text('$rank', style: AppText.data(12.5, color: Palette.dim))),
          SizedBox(width: 38, child: s.failed ? Text('F', style: AppText.display(20, width: 140, weight: 900, color: Palette.dim)) : GradeMark(s.grade, size: 20)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.songTitle.isEmpty ? 'Unknown song' : s.songTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body(14, weight: 600)),
                const SizedBox(height: 1),
                Text(
                  '${s.mode.label} · ${s.beatmapName} · ${(s.accuracy * 100).toStringAsFixed(2)}%${s.mods.labels.isEmpty ? '' : ' · ${s.mods.labels.join(' ')}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body(12, color: Palette.mist),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            StarBadge(s.stars, compact: true),
            const SizedBox(height: 3),
            Text(showPp ? '${s.performance.round()} pp' : formatAgo(s.timestamp), style: AppText.data(10.5)),
          ]),
        ],
      ),
    );
  }
}

/// Generated avatar: concentric arcs from the heat ramp, seeded by the
/// player's name, with their initial in the middle.
class _SignalAvatar extends StatelessWidget {
  const _SignalAvatar({required this.name, required this.seed, required this.size});
  final String name;
  final int seed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _AvatarPainter(name.hashCode ^ (seed * 7919)),
        child: Center(
          child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
              style: AppText.display(size * 0.38, width: 120, weight: 900, color: Palette.ink)),
        ),
      ),
    );
  }
}

class _AvatarPainter extends CustomPainter {
  _AvatarPainter(this.seed);
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final rng = Rng(seed);
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawCircle(c, r, Paint()..color = Palette.raised);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (var ring = 0; ring < 5; ring++) {
      final rr = r * (0.95 - ring * 0.14);
      p
        ..strokeWidth = r * 0.09
        ..color = Palette.heat(0.25 + 0.15 * ring + rng.range(0, 0.1));
      final start = rng.range(0, 2 * math.pi);
      final sweep = rng.range(math.pi * 0.6, math.pi * 1.7);
      canvas.drawArc(Rect.fromCircle(center: c, radius: rr), start, sweep, false, p);
    }
    canvas.drawCircle(c, r * 0.3, Paint()..color = Palette.flare);
  }

  @override
  bool shouldRepaint(_AvatarPainter old) => old.seed != seed;
}
