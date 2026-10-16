import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/generator/beatmap_generator.dart';
import '../../core/models/analysis.dart';
import '../../core/models/beatmap.dart';
import '../../core/models/difficulty.dart';
import '../../core/models/song.dart';
import '../../core/util/ids.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

// Top-level so the isolate closures capture only their arguments (a closure
// created inside State methods would drag the widget tree along).
Future<Beatmap> _generateInBackground(
  SongAnalysis analysis,
  String songId,
  GameMode mode,
  DifficultyParams params,
  int seed,
  BeatmapMetadata meta,
) =>
    Isolate.run(() => BeatmapGenerator.generate(
        analysis: analysis, songId: songId, mode: mode, params: params, seed: seed, metadata: meta));

Future<({DifficultyParams params, double stars})> _targetInBackground(
  SongAnalysis analysis,
  GameMode mode,
  double target,
  int seed,
  int lanes,
  double rate,
) =>
    Isolate.run(() => BeatmapGenerator.paramsForTargetStars(
        analysis: analysis, mode: mode, targetStars: target, seed: seed, lanes: lanes, rate: rate));

/// Builds a new difficulty: pick a preset, aim for a star rating, or open
/// the sliders. The map regenerates live (off the UI thread) as you adjust.
class GenerateSheet extends ConsumerStatefulWidget {
  const GenerateSheet({super.key, required this.song, required this.analysis, required this.mode});
  final Song song;
  final SongAnalysis analysis;
  final GameMode mode;

  @override
  ConsumerState<GenerateSheet> createState() => _GenerateSheetState();
}

enum _Tab { preset, target, custom }

class _GenerateSheetState extends ConsumerState<GenerateSheet> {
  _Tab _tab = _Tab.preset;
  late DifficultyParams _params;
  DifficultyPreset _preset = DifficultyPreset.normal;
  double _target = 3.0;
  int _seed = newSeed();
  Beatmap? _preview;
  bool _busy = false;
  Timer? _debounce;
  int _requestId = 0;

  GameMode get mode => widget.mode;

  @override
  void initState() {
    super.initState();
    _params = DifficultyParams.preset(mode, _preset, lanes: ref.read(settingsProvider).defaultLanes);
    _regenerate();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), _regenerate);
  }

  Future<void> _regenerate() async {
    final id = ++_requestId;
    setState(() => _busy = true);
    final analysis = widget.analysis;
    final songId = widget.song.id;
    final meta = BeatmapMetadata(title: widget.song.title, artist: widget.song.artist, creator: 'Rhytmaniac generator');
    final seed = _seed;
    final m = mode;
    try {
      if (_tab == _Tab.target) {
        final target = _target;
        final lanes = _params.lanes;
        final rate = _params.playbackRate;
        final found = await _targetInBackground(analysis, m, target, seed, lanes, rate);
        if (id != _requestId) return;
        _params = found.params;
      }
      final params = _params;
      final map = await _generateInBackground(analysis, songId, m, params, seed, meta);
      if (!mounted || id != _requestId) return;
      setState(() {
        _preview = map;
        _busy = false;
      });
    } catch (e) {
      if (mounted && id == _requestId) {
        setState(() => _busy = false);
        showMessage(context, 'Could not generate: $e');
      }
    }
  }

  String get _name {
    if (_tab == _Tab.preset) return _preset.label;
    final stars = _preview?.starRating ?? 0;
    return '${_tab == _Tab.target ? 'Target' : 'Custom'} ${stars.toStringAsFixed(1)}★';
  }

  void _set(DifficultyParams p) {
    setState(() => _params = p.copyWith(preset: DifficultyPreset.custom));
    _schedule();
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final seconds = widget.analysis.durationMs / 1000;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.86,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, 16),
              children: [
                Text('New ${mode.label} difficulty', style: AppText.display(22, width: 118, weight: 800)),
                const SizedBox(height: 14),
                SegmentedButton<_Tab>(
                  segments: const [
                    ButtonSegment(value: _Tab.preset, label: Text('Preset')),
                    ButtonSegment(value: _Tab.target, label: Text('Target ★')),
                    ButtonSegment(value: _Tab.custom, label: Text('Custom')),
                  ],
                  selected: {_tab},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) {
                    setState(() => _tab = s.first);
                    if (_tab == _Tab.preset) {
                      _params = DifficultyParams.preset(mode, _preset, lanes: _params.lanes);
                    }
                    _regenerate();
                  },
                ),
                const SizedBox(height: 16),
                // Live result.
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Palette.raised, borderRadius: BorderRadius.circular(Space.radius)),
                  child: Row(
                    children: [
                      if (preview != null) StarBadge(preview.starRating) else const SizedBox(width: 56),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          preview == null
                              ? 'Generating…'
                              : '${preview.objectCount} objects · ${(preview.objectCount / math.max(1, seconds)).toStringAsFixed(1)} per second'
                                  '${_params.playbackRate != 1 ? ' · at ${_params.playbackRate.toStringAsFixed(2)}×' : ''}',
                          style: AppText.body(13.5, color: Palette.mist),
                        ),
                      ),
                      if (_busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    ],
                  ),
                ),
                if (preview != null) ...[
                  const SizedBox(height: 10),
                  _DensityStrip(map: preview, durationMs: widget.analysis.durationMs),
                ],
                const SizedBox(height: 8),
                ..._controls(),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 8, Space.gutter, 12),
              child: Row(children: [
                IconButton(
                  tooltip: 'New variation',
                  onPressed: () {
                    setState(() => _seed = newSeed());
                    _regenerate();
                  },
                  icon: const Icon(Icons.casino_outlined),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: preview == null || _busy
                        ? null
                        : () => Navigator.pop(context, preview.copyWith(id: newId(), name: _name, createdAt: DateTime.now())),
                    child: Text('Add “$_name”'),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _controls() {
    switch (_tab) {
      case _Tab.preset:
        return [
          const SectionLabel('Preset', padding: EdgeInsets.fromLTRB(0, 12, 0, 8)),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in DifficultyPreset.ladder)
              ChoiceChip(
                label: Text(p.label),
                selected: _preset == p,
                onSelected: (_) {
                  setState(() {
                    _preset = p;
                    _params = DifficultyParams.preset(mode, p, lanes: _params.lanes);
                  });
                  _regenerate();
                },
              ),
          ]),
          if (mode == GameMode.tiles) ..._lanes(),
        ];
      case _Tab.target:
        return [
          const SectionLabel('Target rating', padding: EdgeInsets.fromLTRB(0, 12, 0, 0)),
          _slider('Stars', _target, 0.5, 7.5, (v) {
            setState(() => _target = v);
            _schedule();
          }, label: '${_target.toStringAsFixed(1)}★', divisions: 70),
          Text('The generator searches its difficulty curve for a map near this rating.', style: AppText.body(12.5, color: Palette.mist)),
          if (mode == GameMode.tiles) ..._lanes(),
          _rate(),
        ];
      case _Tab.custom:
        final p = _params;
        final tiles = mode == GameMode.tiles;
        return [
          const SectionLabel('Density', padding: EdgeInsets.fromLTRB(0, 12, 0, 0)),
          _slider('Note density', 1 - p.strengthThreshold, 0.05, 1.0, (v) => _set(p.copyWith(strengthThreshold: 1 - v)),
              label: '${((1 - p.strengthThreshold) * 100).round()}%'),
          _slider('Minimum gap', p.minGapMs, 50, 800, (v) => _set(p.copyWith(minGapMs: v)), label: '${p.minGapMs.round()} ms'),
          _slider('Density cap', p.maxNotesPerSecond.clamp(0.5, 12), 0.5, 12, (v) => _set(p.copyWith(maxNotesPerSecond: v)),
              label: '${p.maxNotesPerSecond.clamp(0.5, 12).toStringAsFixed(1)}/s'),
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Row(children: [
              Text('Snap', style: AppText.body(14, weight: 550)),
              const Spacer(),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 1, label: Text('1/1')),
                  ButtonSegment(value: 2, label: Text('1/2')),
                  ButtonSegment(value: 4, label: Text('1/4')),
                ],
                selected: {p.snapDivisor},
                showSelectedIcon: false,
                onSelectionChanged: (s) => _set(p.copyWith(snapDivisor: s.first)),
              ),
            ]),
          ),
          const SectionLabel('Feel', padding: EdgeInsets.fromLTRB(0, 16, 0, 0)),
          _slider('Hit window strictness', p.hitWindow, 0, 10, (v) => _set(p.copyWith(hitWindow: v)),
              label: '±${p.windows.great.round()} ms great'),
          if (tiles)
            _slider('Scroll speed', p.scrollSpeed, 1, 5, (v) => _set(p.copyWith(scrollSpeed: v)), label: p.scrollSpeed.toStringAsFixed(1))
          else
            _slider('Approach time', p.approachMs, 300, 2000, (v) => _set(p.copyWith(approachMs: v)), label: '${p.approachMs.round()} ms'),
          if (tiles) ..._lanes() else _slider('Circle size', p.circleSize, 0, 10, (v) => _set(p.copyWith(circleSize: v)), label: p.circleSize.toStringAsFixed(1)),
          const SectionLabel('Patterns', padding: EdgeInsets.fromLTRB(0, 16, 0, 0)),
          if (tiles) ...[
            _slider('Chords', p.chordAllowance, 0, 1, (v) => _set(p.copyWith(chordAllowance: v)), label: '${(p.chordAllowance * 100).round()}%'),
            _slider('Jacks', p.jackAllowance, 0, 1, (v) => _set(p.copyWith(jackAllowance: v)), label: '${(p.jackAllowance * 100).round()}%'),
          ] else
            _slider('Spacing', p.spacing, 0.3, 3.5, (v) => _set(p.copyWith(spacing: v)), label: '${p.spacing.toStringAsFixed(2)}×'),
          _slider(tiles ? 'Holds' : 'Sliders', p.holdFrequency, 0, 1, (v) => _set(p.copyWith(holdFrequency: v)),
              label: '${(p.holdFrequency * 100).round()}%'),
          if (!tiles)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Spinners', style: AppText.body(14, weight: 550)),
              value: p.spinners,
              onChanged: (v) => _set(p.copyWith(spinners: v)),
            ),
          _rate(),
        ];
    }
  }

  List<Widget> _lanes() => [
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Row(children: [
            Text('Lanes', style: AppText.body(14, weight: 550)),
            const Spacer(),
            SegmentedButton<int>(
              segments: [for (var l = 3; l <= 6; l++) ButtonSegment(value: l, label: Text('$l'))],
              selected: {_params.lanes},
              showSelectedIcon: false,
              onSelectionChanged: (s) {
                setState(() => _params = _params.copyWith(lanes: s.first));
                _schedule();
              },
            ),
          ]),
        ),
      ];

  Widget _rate() => _slider('Playback speed', _params.playbackRate, 0.5, 2.0, (v) {
        setState(() => _params = _params.copyWith(playbackRate: (v * 20).round() / 20));
        _schedule();
      }, label: '${_params.playbackRate.toStringAsFixed(2)}×', divisions: 30);

  Widget _slider(String title, double value, double min, double max, ValueChanged<double> on, {required String label, int? divisions}) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Text(title, style: AppText.body(14, weight: 550)),
            const Spacer(),
            Text(label, style: AppText.data(12.5, color: Palette.bone)),
          ]),
          Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: on),
        ],
      ),
    );
  }
}

/// Notes per second across the song, as a single-hue area so dense parts
/// stand out (magnitude → one hue).
class _DensityStrip extends StatelessWidget {
  const _DensityStrip({required this.map, required this.durationMs});
  final Beatmap map;
  final double durationMs;

  @override
  Widget build(BuildContext context) {
    const buckets = 60;
    final counts = List.filled(buckets, 0);
    final times = map.mode == GameMode.tiles ? map.tileNotes.map((n) => n.timeMs) : map.circleObjects.map((o) => o.timeMs);
    for (final t in times) {
      counts[(t / durationMs * buckets).floor().clamp(0, buckets - 1)]++;
    }
    final maxC = math.max(1, counts.reduce(math.max));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Text('Density over the song', style: AppText.body(12, color: Palette.mist)),
          const Spacer(),
          Text('peak ${(maxC / (durationMs / 1000 / buckets)).toStringAsFixed(1)}/s', style: AppText.data(11)),
        ]),
        const SizedBox(height: 6),
        SizedBox(
          height: 36,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final c in counts)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Container(
                      height: math.max(1.5, 36.0 * c / maxC),
                      decoration: BoxDecoration(
                        color: Palette.amber.withValues(alpha: 0.35 + 0.65 * c / maxC),
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
