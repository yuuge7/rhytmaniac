import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/generator/beatmap_generator.dart';
import '../../core/models/analysis.dart';
import '../../core/models/beatmap.dart';
import '../../core/models/difficulty.dart';
import '../../core/models/score.dart';
import '../../core/models/song.dart';
import '../../core/rating/star_rating.dart';
import '../../core/timing/song_clock.dart';
import '../../core/util/ids.dart';
import '../../audio/app_audio.dart';
import '../../state/providers.dart';
import '../editor/circles_editor_view.dart';
import '../editor/editor_state.dart';
import '../editor/tiles_editor_view.dart';
import '../../core/medals.dart';
import '../theme.dart';
import '../widgets/medals.dart';
import '../widgets/common.dart';
import 'play_screen.dart';

class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({super.key, required this.song, required this.map, required this.analysis});
  final Song song;
  final Beatmap map;
  final SongAnalysis analysis;

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> with SingleTickerProviderStateMixin {
  late final EditorState ed;
  AudioLease? _lease;
  MusicPlayer get _player => _lease!.player;
  late final Ticker _ticker;
  SongClock? _clock;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    ed = EditorState(map: widget.map, analysis: widget.analysis);
    ed.addListener(_onChange);
    _ticker = createTicker(_tick);
    _init();
  }

  Future<void> _init() async {
    final paths = ref.read(servicesProvider).paths;
    final AudioLease lease;
    try {
      lease = await AppAudio.instance.open(paths.sourceFile(widget.song.id, widget.song.sourceFile));
    } catch (e) {
      if (mounted) showMessage(context, 'Could not load the audio: $e');
      return;
    }
    if (!mounted) {
      lease.release();
      return;
    }
    _lease = lease;
    final first = ed.map.firstObjectMs;
    ed.seek(math.max(0, first - 1000));
    await _player.seek(ed.timeMs);
    if (mounted) setState(() => _ready = true);
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    _lease?.release();
    ed.removeListener(_onChange);
    ed.dispose();
    super.dispose();
  }

  void _tick(Duration _) {
    final c = _clock;
    if (c == null) return;
    if (_player.playing) c.sync(_player.positionMs);
    ed.setTimeFromPlayback(c.timeMs);
    if (ed.timeMs >= widget.analysis.durationMs) _togglePlay();
  }

  Future<void> _togglePlay() async {
    if (_player.playing) {
      await _player.pause();
      _ticker.stop();
      _clock = null;
      ed.playing = false;
      ed.seek(ed.timeMs);
    } else {
      _lease!.reclaim();
      await _player.setSpeed(ed.playbackRate);
      await _player.seek(ed.timeMs);
      _clock = SongClock(rate: ed.playbackRate)..start(ed.timeMs);
      ed.playing = true;
      _player.play();
      _ticker.start();
    }
    setState(() {});
  }

  Future<void> _scrubEnd() async {
    if (!_player.playing) await _player.seek(ed.timeMs);
  }

  Future<bool> _confirmLeave() async {
    if (!ed.dirty) return true;
    final r = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: const Text('Save your edits as a separate difficulty before leaving?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, 'discard'), child: const Text('Discard')),
          TextButton(onPressed: () => Navigator.pop(c, 'cancel'), child: const Text('Keep editing')),
          TextButton(onPressed: () => Navigator.pop(c, 'save'), child: const Text('Save')),
        ],
      ),
    );
    if (r == 'save') {
      await _save();
      return true;
    }
    return r == 'discard';
  }

  Future<void> _save() async {
    final m = ed.map;
    final firstSave = !m.edited && ed.savedId == null;
    final id = ed.savedId ?? (m.edited ? m.id : newId());
    final saved = m.copyWith(
      id: id,
      name: firstSave ? '${m.name} (edited)' : m.name,
      edited: true,
      createdAt: DateTime.now(),
      metadata: BeatmapMetadata(title: widget.song.title, artist: widget.song.artist, creator: 'Edited by you'),
      circleObjects: m.mode == GameMode.circles ? BeatmapGenerator.renumberCombos(m.circleObjects) : null,
    );
    final rated = saved.copyWith(starRating: starRating(saved));
    await ref.read(libraryProvider.notifier).saveBeatmap(rated);
    ed.markSaved(rated);
    final medals = await ref.read(progressProvider.notifier).bump(Counters.mapsEdited);
    if (!mounted) return;
    showMessage(context, 'Saved “${rated.name}” · ${rated.starRating.toStringAsFixed(2)}★');
    announceMedals(context, medals);
  }

  Future<void> _regenerate() async {
    final a = ed.rangeA, b = ed.rangeB;
    if (a == null || b == null || b - a < 200) {
      showMessage(context, 'Set a start (A) and end (B) first.');
      return;
    }
    if (ed.map.edited || ed.dirty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Regenerate this section?'),
          content: Text('Everything between ${formatDuration(a)} and ${formatDuration(b)} is replaced by new generated notes. You can undo it.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Regenerate')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final out = BeatmapGenerator.regenerateSection(
      map: ed.map, analysis: widget.analysis, startMs: a, endMs: b, seed: newSeed());
    ed.apply(out);
  }

  Future<void> _testPlay() async {
    if (_player.playing) await _togglePlay();
    if (!mounted) return;
    final map = ed.map.copyWith(
      circleObjects: ed.map.mode == GameMode.circles ? BeatmapGenerator.renumberCombos(ed.map.circleObjects) : null,
    );
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayScreen(
        request: PlayRequest(song: widget.song, map: map, mods: const Mods(), startMs: ed.timeMs, saveScore: false),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final tiles = ed.map.mode == GameMode.tiles;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ed.map.name, style: AppText.display(17, width: 110, weight: 750), overflow: TextOverflow.ellipsis),
            Text('${ed.objectCount} objects${ed.dirty ? ' · unsaved' : ''}', style: AppText.body(12, color: Palette.mist)),
          ]),
          actions: [
            IconButton(tooltip: 'Undo', onPressed: ed.canUndo ? ed.undo : null, icon: const Icon(Icons.undo_rounded)),
            IconButton(tooltip: 'Redo', onPressed: ed.canRedo ? ed.redo : null, icon: const Icon(Icons.redo_rounded)),
            IconButton(tooltip: 'Test play from here', onPressed: _testPlay, icon: const Icon(Icons.sports_esports_outlined)),
            IconButton(tooltip: 'Save', onPressed: ed.dirty ? _save : null, icon: const Icon(Icons.save_outlined)),
          ],
        ),
        body: !_ready
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  _toolbar(tiles),
                  Expanded(
                    child: tiles
                        ? TilesEditorView(state: ed, onScrubEnd: _scrubEnd)
                        : CirclesEditorView(state: ed, onScrubEnd: _scrubEnd),
                  ),
                  _transport(),
                ],
              ),
      ),
    );
  }

  Widget _toolbar(bool tiles) {
    return Container(
      color: Palette.inkDeep,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          Text('Snap', style: AppText.body(12.5, color: Palette.mist)),
          const SizedBox(width: 6),
          for (final d in const [1, 2, 3, 4, 6, 8])
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ChoiceChip(
                label: Text('1/$d'),
                selected: ed.snapDivisor == d,
                onSelected: (_) => ed.setSnap(d),
                visualDensity: VisualDensity.compact,
              ),
            ),
          const SizedBox(width: 8),
          if (!tiles) ...[
            for (final tool in CircleTool.values)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: ChoiceChip(
                  avatar: Icon(tool.icon, size: 16),
                  label: Text(tool.label),
                  selected: ed.circleTool == tool,
                  onSelected: (_) => ed.setCircleTool(tool),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            if (ed.circleTool == CircleTool.slider)
              PopupMenuButton<double>(
                tooltip: 'Slider length',
                color: Palette.raised,
                initialValue: ed.sliderBeats,
                onSelected: ed.setSliderBeats,
                itemBuilder: (_) => [for (final b in const [0.5, 1.0, 2.0, 4.0]) PopupMenuItem(value: b, child: Text('$b beats'))],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text('${ed.sliderBeats} beats ▾', style: AppText.body(13, color: Palette.bone)),
                ),
              ),
          ],
          if (!tiles)
            TextButton(
              onPressed: () {
                final i = ed.circleAtPlayhead();
                if (i == null || i == 0) {
                  showMessage(context, 'Move the playhead onto an object first.');
                } else {
                  ed.toggleNewCombo(i);
                }
              },
              child: const Text('New combo'),
            ),
          const SizedBox(width: 6),
          TextButton(onPressed: () => ed.setRangeA(ed.timeMs), child: Text(ed.rangeA == null ? 'Set A' : 'A ${formatDuration(ed.rangeA!)}')),
          TextButton(onPressed: () => ed.setRangeB(ed.timeMs), child: Text(ed.rangeB == null ? 'Set B' : 'B ${formatDuration(ed.rangeB!)}')),
          TextButton.icon(onPressed: _regenerate, icon: const Icon(Icons.auto_fix_high_rounded, size: 18), label: const Text('Regenerate A–B')),
          if (ed.rangeA != null || ed.rangeB != null)
            IconButton(tooltip: 'Clear range', onPressed: ed.clearRange, icon: const Icon(Icons.close_rounded, size: 18)),
        ]),
      ),
    );
  }

  Widget _transport() {
    return SafeArea(
      top: false,
      child: Container(
        color: Palette.inkDeep,
        padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
        child: Row(children: [
          IconButton.filled(
            style: IconButton.styleFrom(backgroundColor: Palette.action, foregroundColor: Palette.onAction),
            tooltip: _player.playing ? 'Pause' : 'Play',
            onPressed: _togglePlay,
            icon: Icon(_player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
          ),
          const SizedBox(width: 10),
          Text(_fmtTime(ed.timeMs), style: AppText.data(13, color: Palette.bone)),
          const Spacer(),
          for (final r in const [0.25, 0.5, 0.75, 1.0])
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: ChoiceChip(
                label: Text('$r×'),
                selected: ed.playbackRate == r,
                visualDensity: VisualDensity.compact,
                onSelected: (_) async {
                  ed.setRate(r);
                  if (_player.playing) {
                    await _player.setSpeed(r);
                    _clock?.rate = r;
                  }
                },
              ),
            ),
        ]),
      ),
    );
  }

  String _fmtTime(double ms) {
    final total = ms.clamp(0, double.infinity);
    final m = total ~/ 60000;
    final s = (total % 60000) / 1000;
    return '$m:${s.toStringAsFixed(2).padLeft(5, '0')}';
  }
}
