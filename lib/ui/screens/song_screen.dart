import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/app_audio.dart';
import '../../core/models/beatmap.dart';
import '../../core/models/difficulty.dart';
import '../../core/models/score.dart';
import '../../core/models/song.dart';
import '../../core/rating/star_rating.dart';
import '../../state/providers.dart';
import '../export_flow.dart';
import '../routes.dart';
import '../../core/medals.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/medals.dart';
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

class _SongScreenState extends ConsumerState<SongScreen> with RouteAware {
  String? _selectedId;
  AudioLease? _preview;
  StreamSubscription<MusicEvent>? _previewEvents;
  Timer? _fade;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startPreview());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _stopPreview();
    super.dispose();
  }

  /// Back on this page (a game, its results or the editor closed).
  @override
  void didPopNext() => _startPreview();

  bool get _onTop => mounted && (ModalRoute.of(context)?.isCurrent ?? false);

  /// Plays the song from its preview point, fading in, and loops it.
  Future<void> _startPreview() async {
    if (!ref.read(settingsProvider).previewMusic || _preview != null || _starting || !_onTop) return;
    final song = ref.read(libraryProvider).song(widget.songId);
    if (song == null) return;
    _starting = true;
    try {
      final lease = await AppAudio.instance.open(ref.read(servicesProvider).paths.sourceFile(song.id, song.sourceFile));
      if (!_onTop || _preview != null) {
        lease.release();
        return;
      }
      _preview = lease;
      final p = lease.player;
      final start = song.previewStartMs.clamp(0.0, math.max(0.0, song.durationMs - 8000)).toDouble();
      await p.seek(start);
      await p.setVolume(0);
      await p.play();
      final target = ref.read(settingsProvider).musicVolume * 0.8;
      var step = 0;
      _fade?.cancel();
      _fade = Timer.periodic(const Duration(milliseconds: 60), (t) {
        step++;
        if (!lease.current || step > 14) {
          t.cancel();
          return;
        }
        p.setVolume(target * step / 14);
      });
      _previewEvents = p.events.listen((e) {
        if (e.type == MusicEventType.completed && lease.current && _preview == lease) {
          p.seek(start).then((_) => p.play());
        }
      });
    } catch (_) {
      // A preview is a nicety; the screen works without it.
    } finally {
      _starting = false;
    }
  }

  void _stopPreview() {
    _fade?.cancel();
    _previewEvents?.cancel();
    _previewEvents = null;
    _preview?.release();
    _preview = null;
  }

  /// Opens another screen with the preview stopped; [didPopNext] brings it
  /// back once this page is on top again (after results, too).
  Future<T?> _open<T>(Route<T> route) {
    _stopPreview();
    return Navigator.of(context).push(route);
  }

  Future<void> _watchReplay(Song song, ScoreRecord s) async {
    final b = ref.read(libraryProvider).beatmaps.where((m) => m.id == s.beatmapId).firstOrNull;
    if (b == null) return;
    final map = await _load(b);
    final replay = await ref.read(servicesProvider).repo.loadReplay(s.id);
    if (map == null || !mounted) return;
    if (replay == null) {
      showMessage(context, 'This replay is no longer on the device.');
      return;
    }
    await _open(MaterialPageRoute<void>(
      builder: (_) => PlayScreen(request: PlayRequest(song: song, map: map, mods: replay.mods, replay: replay, saveScore: false)),
    ));
  }

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
    await _open(MaterialPageRoute<void>(
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
    await _open(MaterialPageRoute<void>(builder: (_) => EditorScreen(song: song, map: map, analysis: analysis)));
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
      final medals = await ref.read(progressProvider.notifier).bump(Counters.mapsGenerated);
      if (mounted) announceMedals(context, medals);
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

  /// Pick which collections hold this song; new ones can be made here.
  Future<void> _collections(Song song) async {
    final all = ref.read(collectionsProvider);
    final names = all.keys.toList()..sort();
    final chosen = {for (final n in names) if (all[n]!.contains(song.id)) n};
    final newName = TextEditingController();
    final r = await showDialog<Set<String>>(
      context: context,
      builder: (c) => StatefulBuilder(builder: (c, set) {
        return AlertDialog(
          title: const Text('Collections'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (names.isEmpty)
                Text('No collections yet. Name one below.', style: AppText.body(13.5, color: Palette.mist)),
              for (final n in names)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: chosen.contains(n),
                  onChanged: (v) => set(() => v == true ? chosen.add(n) : chosen.remove(n)),
                  title: Text(n),
                ),
              TextField(
                controller: newName,
                decoration: const InputDecoration(hintText: 'New collection'),
                onSubmitted: (v) {
                  final n = v.trim();
                  if (n.isEmpty) return;
                  set(() {
                    if (!names.contains(n)) names.add(n);
                    chosen.add(n);
                    newName.clear();
                  });
                },
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                final n = newName.text.trim();
                if (n.isNotEmpty) chosen.add(n);
                Navigator.pop(c, chosen);
              },
              child: const Text('Save'),
            ),
          ],
        );
      }),
    );
    if (r != null) await ref.read(collectionsProvider.notifier).setMembership(song.id, r);
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
      _stopPreview();
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
          IconButton(
            tooltip: song.favorite ? 'Remove from favorites' : 'Add to favorites',
            onPressed: () => ref.read(libraryProvider.notifier).toggleFavorite(song.id),
            icon: Icon(song.favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                color: song.favorite ? Palette.amber : null),
          ),
          PopupMenuButton<String>(
            color: Palette.raised,
            onSelected: (v) async {
              switch (v) {
                case 'info':
                  await _editInfo(song);
                case 'collections':
                  await _collections(song);
                case 'offset':
                  await _songOffset(song);
                case 'analysis':
                  if (context.mounted) {
                    await _open(MaterialPageRoute<void>(builder: (_) => AnalysisScreen(song: song)));
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
              PopupMenuItem(value: 'collections', child: Text('Add to collection…')),
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
              top: (scores.where((s) => s.beatmapId == b.id && !s.failed && !s.practice && !s.mods.autoplay).toList()
                    ..sort((x, y) => y.score.compareTo(x.score)))
                  .take(5)
                  .toList(),
              onReplay: (s) => _watchReplay(song, s),
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
    required this.top,
    required this.onReplay,
  });

  final BeatmapSummary summary;
  final bool selected;
  final ScoreRecord? best;
  final int plays;

  /// Best local scores on this difficulty, highest first.
  final List<ScoreRecord> top;
  final void Function(ScoreRecord) onReplay;
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
                            if (b.origin == 'osu') ...[
                              const SizedBox(width: 8),
                              Text('OSU!', style: AppText.data(9.5, weight: 700, color: Palette.rose, letterSpacing: 1)),
                            ],
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
                              : 'Best ${formatScore(best!.score)} · ${(best!.accuracy * 100).toStringAsFixed(2)}%${best!.mods.acronyms.isEmpty ? '' : ' · ${best!.mods.acronyms.join('')}'}',
                          style: AppText.data(11.5, color: Palette.bone),
                        ),
                      ),
                      IconButton(tooltip: 'Practice', onPressed: onPractice, icon: const Icon(Icons.repeat_rounded, size: 20)),
                      IconButton(tooltip: 'Edit', onPressed: onEdit, icon: const Icon(Icons.edit_outlined, size: 20)),
                      IconButton(tooltip: 'Delete', onPressed: onDelete, icon: const Icon(Icons.delete_outline_rounded, size: 20)),
                    ],
                  ),
                  if (top.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                      child: Text('LOCAL RANKING', style: AppText.label()),
                    ),
                    for (var i = 0; i < top.length; i++) _scoreLine(i + 1, top[i]),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

extension on _DifficultyRow {
  Widget _scoreLine(int rank, ScoreRecord s) {
    final d = s.timestamp;
    final date = '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: Row(children: [
        SizedBox(width: 22, child: Text('$rank', style: AppText.data(11.5, color: Palette.mist))),
        GradeMark(s.grade, size: 15),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${formatScore(s.score)} · ${(s.accuracy * 100).toStringAsFixed(2)}% · ${s.maxCombo}× · ${s.performance.round()}pp${s.mods.acronyms.isEmpty ? '' : ' · ${s.mods.acronyms.join('')}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.data(11, color: Palette.bone),
          ),
        ),
        Text(date, style: AppText.data(10.5, color: Palette.dim)),
        SizedBox(
          width: 40,
          height: 34,
          child: s.hasReplay
              ? IconButton(
                  tooltip: 'Watch replay',
                  padding: EdgeInsets.zero,
                  onPressed: () => onReplay(s),
                  icon: const Icon(Icons.slideshow_rounded, size: 18, color: Palette.amber),
                )
              : null,
        ),
      ]),
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

  /// osu!'s pairs that can't be on together: turning one on turns the
  /// others off.
  Mods _set(Mods next, String changed, bool on) {
    if (!on) return next;
    switch (changed) {
      case 'easy':
        return next.copyWith(hardRock: false);
      case 'hardRock':
        return next.copyWith(easy: false);
      case 'noFail':
        return next.copyWith(suddenDeath: false, perfect: false);
      case 'suddenDeath':
        return next.copyWith(noFail: false, perfect: false, autoplay: false);
      case 'perfect':
        return next.copyWith(noFail: false, suddenDeath: false, autoplay: false);
      case 'autoplay':
        return next.copyWith(suddenDeath: false, perfect: false);
    }
    return next;
  }

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, String code, String tip, bool value, Mods Function(bool) apply, String key) => Tooltip(
          message: tip,
          child: FilterChip(
            label: Text(label),
            avatar: Text(code, style: AppText.data(10.5, weight: 700, color: value ? Palette.amber : Palette.mist)),
            showCheckmark: false,
            selected: value,
            onSelected: (v) => setState(() => m = _set(apply(v), key, v)),
          ),
        );
    Widget group(String title, List<Widget> chips) => Padding(
          padding: const EdgeInsets.fromLTRB(Space.gutter, 14, Space.gutter, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title.toUpperCase(), style: AppText.label()),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: chips),
          ]),
        );
    final mult = m.scoreMultiplier;
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, 4),
              child: Row(children: [
                Text('Mods', style: AppText.display(22, width: 120, weight: 800)),
                const Spacer(),
                Text('Score ×${mult.toStringAsFixed(2)}', style: AppText.data(13, weight: 600, color: mult >= 1 ? Palette.amber : Palette.mist)),
              ]),
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
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final (label, r) in const [('Half time 0.75×', 0.75), ('1×', 1.0), ('1.25×', 1.25), ('Double time 1.5×', 1.5)])
                  ChoiceChip(
                    label: Text(label),
                    selected: m.rate == r,
                    onSelected: (_) => setState(() => m = m.copyWith(rate: r)),
                  ),
                FilterChip(
                  label: const Text('Nightcore'),
                  tooltip: 'Pitch rises and falls with the speed',
                  selected: m.nightcore,
                  onSelected: (v) => setState(() => m = m.copyWith(nightcore: v)),
                ),
              ]),
            ),
            group('Easier', [
              chip('Easy', 'EZ', 'Bigger circles, slower approach, wider timing, gentler health', m.easy, (v) => m.copyWith(easy: v), 'easy'),
              chip('No-Fail', 'NF', 'Health never runs out', m.noFail, (v) => m.copyWith(noFail: v), 'noFail'),
            ]),
            group('Harder', [
              chip('Hard Rock', 'HR', 'Smaller circles, faster approach, tighter timing; Circles flip upside down', m.hardRock,
                  (v) => m.copyWith(hardRock: v), 'hardRock'),
              chip('Hidden', 'HD', 'Notes fade out before they reach you', m.hidden, (v) => m.copyWith(hidden: v), 'hidden'),
              chip('Flashlight', 'FL', 'Only the area around your finger or the hit line is lit', m.flashlight,
                  (v) => m.copyWith(flashlight: v), 'flashlight'),
              chip('Sudden Death', 'SD', 'The first miss ends the run', m.suddenDeath, (v) => m.copyWith(suddenDeath: v), 'suddenDeath'),
              chip('Perfect', 'PF', 'Anything less than Perfect ends the run', m.perfect, (v) => m.copyWith(perfect: v), 'perfect'),
            ]),
            group('Other', [
              chip('Mirror', 'MR', 'Flip lanes or the playfield left to right', m.mirror, (v) => m.copyWith(mirror: v), 'mirror'),
              chip('Autoplay', 'AT', 'Watch a perfect run. Scores aren’t saved.', m.autoplay, (v) => m.copyWith(autoplay: v), 'autoplay'),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 16, Space.gutter, 8),
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
