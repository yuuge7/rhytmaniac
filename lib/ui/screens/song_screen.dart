import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/beatmap.dart';
import '../../core/models/difficulty.dart';
import '../../core/models/score.dart';
import '../../core/models/song.dart';
import '../../core/rating/star_rating.dart';
import '../../state/providers.dart';
import '../export_flow.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/signal_strip.dart';
import 'analysis_screen.dart';
import 'editor_screen.dart';
import 'generate_sheet.dart';
import 'play_screen.dart';
import 'practice_sheet.dart';

/// Mods chosen on the song screen; kept for the session.
class ModsNotifier extends Notifier<Mods> {
  @override
  Mods build() => const Mods();
  void set(Mods m) => state = m;
}

final modsProvider = NotifierProvider<ModsNotifier, Mods>(ModsNotifier.new);

class SongScreen extends ConsumerStatefulWidget {
  const SongScreen({super.key, required this.songId});
  final String songId;

  @override
  ConsumerState<SongScreen> createState() => _SongScreenState();
}

class _SongScreenState extends ConsumerState<SongScreen> {
  String? _selectedId;

  /// Star ratings recomputed for the current speed mod, keyed "id@rate".
  final Map<String, double> _rated = {};
  String? _ratingFor;

  Future<void> _rateAll(List<BeatmapSummary> maps, double rate, String batch) async {
    _ratingFor = batch;
    final repo = ref.read(servicesProvider).repo;
    for (final b in maps) {
      final key = '${b.id}@$rate';
      if (_rated.containsKey(key)) continue;
      try {
        final map = await repo.loadBeatmap(b.songId, b.id);
        _rated[key] = starRating(map, rate: rate);
      } catch (_) {}
      if (!mounted || _ratingFor != batch) return;
      setState(() {});
    }
  }

  Future<Beatmap?> _load(BeatmapSummary b) async {
    try {
      return await ref.read(servicesProvider).repo.loadBeatmap(b.songId, b.id);
    } catch (e) {
      if (mounted) showMessage(context, 'Could not open this difficulty: $e');
      return null;
    }
  }

  Future<void> _play(Song song, BeatmapSummary b, {(double, double)? loop, double? rate}) async {
    final map = await _load(b);
    if (map == null || !mounted) return;
    var mods = ref.read(modsProvider);
    if (rate != null) {
      mods = mods.copyWith(rate: rate);
    } else if (mods.rate == 1.0 && map.difficulty.playbackRate != 1.0) {
      // Custom difficulties can be built for a specific speed.
      mods = mods.copyWith(rate: map.difficulty.playbackRate);
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayScreen(request: PlayRequest(song: song, map: map, mods: mods, loop: loop)),
    ));
  }

  Future<void> _practice(Song song, BeatmapSummary b) async {
    final analysis = await ref.read(servicesProvider).repo.analysis(song.id);
    if (!mounted) return;
    final r = await showModalBottomSheet<PracticeChoice>(
      context: context,
      isScrollControlled: true,
      builder: (_) => PracticeSheet(song: song, analysis: analysis),
    );
    if (r != null) await _play(song, b, loop: (r.startMs, r.endMs), rate: r.rate);
  }

  Future<void> _edit(Song song, BeatmapSummary b) async {
    final map = await _load(b);
    final analysis = await ref.read(servicesProvider).repo.analysis(song.id);
    if (map == null || analysis == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorScreen(song: song, map: map, analysis: analysis)));
  }

  Future<void> _delete(BeatmapSummary b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete difficulty?'),
        content: Text('“${b.name}” will be removed. Scores you set on it stay in your profile.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(libraryProvider.notifier).deleteBeatmap(b);
      if (_selectedId == b.id) setState(() => _selectedId = null);
    }
  }

  Future<void> _newDifficulty(Song song, GameMode mode) async {
    final analysis = await ref.read(servicesProvider).repo.analysis(song.id);
    if (analysis == null || !mounted) return;
    final map = await showModalBottomSheet<Beatmap>(
      context: context,
      isScrollControlled: true,
      builder: (_) => GenerateSheet(song: song, analysis: analysis, mode: mode),
    );
    if (map != null) {
      await ref.read(libraryProvider.notifier).saveBeatmap(map);
      setState(() => _selectedId = map.id);
    }
  }

  Future<void> _editInfo(Song song) async {
    final title = TextEditingController(text: song.title);
    final artist = TextEditingController(text: song.artist);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Song info'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')),
          const SizedBox(height: 10),
          TextField(controller: artist, decoration: const InputDecoration(labelText: 'Artist')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(libraryProvider.notifier).updateSong(song.copyWith(
            title: title.text.trim().isEmpty ? song.title : title.text.trim(),
            artist: artist.text.trim(),
          ));
    }
  }

  Future<void> _songOffset(Song song) async {
    var value = song.offsetMs;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(builder: (c, set) {
        return AlertDialog(
          title: const Text('Song offset'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Added to your global offset for this song only. Raise it if you keep hitting late.',
                style: AppText.body(13.5, color: Palette.mist)),
            const SizedBox(height: 16),
            Center(child: Text('${value >= 0 ? '+' : ''}${value.round()} ms', style: AppText.data(22, color: Palette.bone))),
            Slider(value: value.clamp(-200, 200), min: -200, max: 200, divisions: 400, onChanged: (v) => set(() => value = v)),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(onPressed: () => set(() => value -= 1), icon: const Icon(Icons.remove_rounded)),
              TextButton(onPressed: () => set(() => value = 0), child: const Text('Reset')),
              IconButton(onPressed: () => set(() => value += 1), icon: const Icon(Icons.add_rounded)),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
          ],
        );
      }),
    );
    if (ok == true) await ref.read(libraryProvider.notifier).updateSong(song.copyWith(offsetMs: value));
  }

  Future<void> _deleteSong(Song song) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete song?'),
        content: Text('“${song.title}” and all its difficulties will be removed from this device. Your scores stay in your profile.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true && mounted) {
      Navigator.of(context).pop();
      await ref.read(libraryProvider.notifier).deleteSong(song.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);
    final song = lib.song(widget.songId);
    if (song == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('This song is no longer in your library.')));
    }
    final mode = ref.watch(modeProvider);
    final maps = lib.mapsFor(song.id, mode);
    final selected = maps.where((m) => m.id == _selectedId).firstOrNull ?? (maps.isEmpty ? null : maps[maps.length ~/ 2]);
    final mods = ref.watch(modsProvider);
    final batch = '${mode.name}@${mods.rate}';
    if (mods.rate != 1.0 && _ratingFor != batch) {
      _ratingFor = batch;
      WidgetsBinding.instance.addPostFrameCallback((_) => _rateAll(maps, mods.rate, batch));
    }
    final scores = ref.watch(scoresProvider);
    final scoresNotifier = ref.read(scoresProvider.notifier);
    final paths = ref.read(servicesProvider).paths;
    final cover = song.coverFile == null ? null : paths.coverFile(song.id, song.coverFile!);

    return Scaffold(
      appBar: AppBar(
        actions: [
          PopupMenuButton<String>(
            color: Palette.raised,
            onSelected: (v) async {
              switch (v) {
                case 'info':
                  await _editInfo(song);
                case 'offset':
                  await _songOffset(song);
                case 'analysis':
                  if (context.mounted) {
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AnalysisScreen(song: song)));
                  }
                case 'reanalyze':
                  await ref.read(importProvider.notifier).reanalyze(song);
                  if (context.mounted) showMessage(context, 'Analysis updated. Generate a new difficulty to use it.');
                case 'export':
                  if (context.mounted) await exportSongPack(context, ref, [song]);
                case 'delete':
                  await _deleteSong(song);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'info', child: Text('Edit title and artist')),
              PopupMenuItem(value: 'offset', child: Text('Song offset')),
              PopupMenuItem(value: 'analysis', child: Text('Beat analysis')),
              PopupMenuItem(value: 'reanalyze', child: Text('Analyze again')),
              PopupMenuItem(value: 'export', child: Text('Export song pack')),
              PopupMenuItem(value: 'delete', child: Text('Delete song')),
            ],
          ),
        ],
      ),
      bottomNavigationBar: selected == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Space.gutter, 8, Space.gutter, 10),
                child: Row(
                  children: [
                    OutlinedButton(
                      onPressed: () async {
                        final m = await showModalBottomSheet<Mods>(
                          context: context,
                          isScrollControlled: true,
                          builder: (_) => _ModsSheet(initial: mods),
                        );
                        if (m != null) ref.read(modsProvider.notifier).set(m);
                      },
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14)),
                      child: Row(children: [
                        const Icon(Icons.auto_awesome_outlined, size: 18),
                        const SizedBox(width: 6),
                        Text(mods.isDefault ? 'Mods' : mods.labels.join(' · '), overflow: TextOverflow.ellipsis),
                      ]),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _play(song, selected),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text('Play ${selected.name}', overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ],
                ),
              ),
            ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SongArt(song: song, coverPath: cover, size: 84, radius: 14),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(song.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.display(26, width: 112, weight: 800, height: 1.05)),
                      const SizedBox(height: 4),
                      Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body(14, color: Palette.mist)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: SignalStrip(fingerprint: song.fingerprint, height: 64),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Row(children: [
              _fact(song.bpm.toStringAsFixed(song.bpm % 1 == 0 ? 0 : 1), 'BPM'),
              _fact(formatDuration(song.durationMs), 'length'),
              _fact('${song.playCount}', song.playCount == 1 ? 'play' : 'plays'),
              if (song.offsetMs != 0) _fact('${song.offsetMs > 0 ? '+' : ''}${song.offsetMs.round()}', 'ms offset'),
            ]),
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Row(children: [
              ModeSwitch(mode: mode, onChanged: (m) {
                ref.read(modeProvider.notifier).set(m);
                setState(() => _selectedId = null);
              }),
            ]),
          ),
          SectionLabel(
            'Difficulties',
            trailing: TextButton.icon(
              onPressed: () => _newDifficulty(song, mode),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('New'),
            ),
            padding: const EdgeInsets.fromLTRB(Space.gutter, 14, 6, 4),
          ),
          if (maps.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Space.gutter),
              child: Text('No ${mode.label} difficulties. Tap New to generate one.', style: AppText.body(14, color: Palette.mist)),
            ),
          for (final b in maps)
            _DifficultyRow(
              summary: b,
              selected: selected?.id == b.id,
              best: scoresNotifier.best(b.id),
              plays: scores.where((s) => s.beatmapId == b.id).length,
              onTap: () => setState(() => _selectedId = b.id),
              onEdit: () => _edit(song, b),
              onPractice: () => _practice(song, b),
              onDelete: () => _delete(b),
              rate: mods.rate,
              ratedStars: mods.rate == 1.0 ? null : _rated['${b.id}@${mods.rate}'],
            ),
        ],
      ),
    );
  }

  Widget _fact(String value, String label) => Padding(
        padding: const EdgeInsets.only(right: 18),
        child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text(value, style: AppText.data(14, weight: 600, color: Palette.bone)),
          const SizedBox(width: 4),
          Text(label, style: AppText.body(12.5, color: Palette.mist)),
        ]),
      );
}

class _DifficultyRow extends StatelessWidget {
  const _DifficultyRow({
    required this.summary,
    required this.selected,
    required this.best,
    required this.plays,
    required this.onTap,
    required this.onEdit,
    required this.onPractice,
    required this.onDelete,
    required this.rate,
    required this.ratedStars,
  });

  final BeatmapSummary summary;
  final bool selected;
  final ScoreRecord? best;
  final int plays;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onPractice;
  final VoidCallback onDelete;
  final double rate;

  /// Stars at the current speed mod, when one is active.
  final double? ratedStars;

  @override
  Widget build(BuildContext context) {
    final b = summary;
    final c = Palette.stars(b.stars);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.gutter, vertical: 4),
      child: Material(
        color: selected ? Palette.raised : Palette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Space.radius),
          side: BorderSide(color: selected ? c.withValues(alpha: 0.8) : Colors.transparent, width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(width: 4, height: 30, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Flexible(child: Text(b.name, overflow: TextOverflow.ellipsis, style: AppText.body(15.5, weight: 650))),
                            if (b.edited) ...[
                              const SizedBox(width: 8),
                              Text('EDITED', style: AppText.data(9.5, weight: 700, color: Palette.amber, letterSpacing: 1)),
                            ],
                          ]),
                          const SizedBox(height: 2),
                          Text(
                            '${b.objectCount} objects${b.mode == GameMode.tiles ? ' · ${b.lanes} lanes' : ''}${plays > 0 ? ' · $plays play${plays == 1 ? '' : 's'}' : ''}',
                            style: AppText.body(12.5, color: Palette.mist),
                          ),
                        ],
                      ),
                    ),
                    if (best != null) ...[GradeMark(best!.grade, size: 20), const SizedBox(width: 10)],
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        StarBadge(ratedStars ?? b.stars),
                        if (ratedStars != null) ...[
                          const SizedBox(height: 3),
                          Text('at ${Mods(rate: rate).labels.first}', style: AppText.data(10, color: Palette.amber)),
                        ],
                      ],
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
                if (selected) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          best == null
                              ? 'Not played yet'
                              : 'Best ${formatScore(best!.score)} · ${(best!.accuracy * 100).toStringAsFixed(2)}%${best!.mods.labels.isEmpty ? '' : ' · ${best!.mods.labels.join(' ')}'}',
                          style: AppText.data(11.5, color: Palette.bone),
                        ),
                      ),
                      IconButton(tooltip: 'Practice', onPressed: onPractice, icon: const Icon(Icons.repeat_rounded, size: 20)),
                      IconButton(tooltip: 'Edit', onPressed: onEdit, icon: const Icon(Icons.edit_outlined, size: 20)),
                      IconButton(tooltip: 'Delete', onPressed: onDelete, icon: const Icon(Icons.delete_outline_rounded, size: 20)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModsSheet extends StatefulWidget {
  const _ModsSheet({required this.initial});
  final Mods initial;

  @override
  State<_ModsSheet> createState() => _ModsSheetState();
}

class _ModsSheetState extends State<_ModsSheet> {
  late Mods m = widget.initial;

  @override
  Widget build(BuildContext context) {
    Widget toggle(String title, String subtitle, bool value, ValueChanged<bool> on) => SwitchListTile(
          value: value,
          onChanged: on,
          title: Text(title, style: AppText.body(15, weight: 600)),
          subtitle: Text(subtitle, style: AppText.body(12.5, color: Palette.mist)),
          contentPadding: const EdgeInsets.symmetric(horizontal: Space.gutter),
        );
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, 4),
              child: Text('Mods', style: AppText.display(22, width: 120, weight: 800)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 8, Space.gutter, 0),
              child: Row(children: [
                Text('Speed', style: AppText.body(15, weight: 600)),
                const Spacer(),
                Text('${m.rate.toStringAsFixed(2)}×', style: AppText.data(14, color: Palette.bone)),
              ]),
            ),
            Slider(
              value: m.rate,
              min: 0.5,
              max: 2.0,
              divisions: 30,
              onChanged: (v) => setState(() => m = m.copyWith(rate: (v * 20).round() / 20)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
              child: Wrap(spacing: 8, children: [
                for (final r in const [0.75, 1.0, 1.25, 1.5])
                  ChoiceChip(
                    label: Text('$r×'),
                    selected: m.rate == r,
                    onSelected: (_) => setState(() => m = m.copyWith(rate: r)),
                  ),
              ]),
            ),
            const SizedBox(height: 8),
            toggle('No-Fail', 'Health never runs out', m.noFail, (v) => setState(() => m = m.copyWith(noFail: v))),
            toggle('Hidden', 'Notes fade out before they reach you', m.hidden, (v) => setState(() => m = m.copyWith(hidden: v))),
            toggle('Mirror', 'Flip lanes or the playfield left to right', m.mirror, (v) => setState(() => m = m.copyWith(mirror: v))),
            toggle('Autoplay', 'Watch a perfect run. Scores aren’t saved.', m.autoplay, (v) => setState(() => m = m.copyWith(autoplay: v))),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 8, Space.gutter, 8),
              child: Row(children: [
                TextButton(onPressed: () => setState(() => m = const Mods()), child: const Text('Reset')),
                const Spacer(),
                FilledButton(onPressed: () => Navigator.pop(context, m), child: const Text('Apply')),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}
