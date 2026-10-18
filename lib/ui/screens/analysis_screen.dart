import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/app_audio.dart';
import '../../core/generator/note_selection.dart';
import '../../core/models/analysis.dart';
import '../../core/models/timing.dart';
import '../../core/models/song.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Debug view of the analysis: waveform, beat grid, onsets, sustains,
/// energy and breaks, with playback to check them by ear.
class AnalysisScreen extends ConsumerStatefulWidget {
  const AnalysisScreen({super.key, required this.song});
  final Song song;

  @override
  ConsumerState<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends ConsumerState<AnalysisScreen> {
  SongAnalysis? _a;
  BeatGrid? _grid;
  List<TimeRange> _breaks = const [];
  AudioLease? _lease;
  MusicPlayer get _player => _lease!.player;
  final _scroll = ScrollController();
  double _pxPerSec = 160;
  Timer? _posTimer;

  /// Playhead and play state change many times a second; only the painter
  /// and the small widgets that show them listen, so the screen itself
  /// never rebuilds while the song plays.
  final _pos = ValueNotifier<double>(0);
  final _playing = ValueNotifier<bool>(false);
  bool _follow = true;
  double _viewWidth = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final services = ref.read(servicesProvider);
    final a = await services.repo.analysis(widget.song.id);
    _lease = await AppAudio.instance.open(services.paths.sourceFile(widget.song.id, widget.song.sourceFile));
    _posTimer = Timer.periodic(const Duration(milliseconds: 33), (_) => _poll());
    if (!mounted) return;
    setState(() {
      _a = a;
      _grid = a?.grid;
      _breaks = a == null ? const [] : findBreaks(a);
    });
  }

  void _poll() {
    if (!mounted || _lease == null) return;
    final playing = _player.playing;
    _playing.value = playing;
    if (!playing && _player.positionMs == _pos.value) return;
    _pos.value = _player.positionMs;
    if (_follow && playing && _scroll.hasClients) {
      final x = _pos.value / 1000 * _pxPerSec - _viewWidth * 0.3;
      _scroll.jumpTo(x.clamp(0.0, _scroll.position.maxScrollExtent));
    }
  }

  /// Zooms around the middle of the view, so what was there stays there.
  void _zoom(double pxPerSec) {
    final centerMs = _scroll.hasClients ? (_scroll.offset + _viewWidth / 2) / _pxPerSec * 1000 : 0.0;
    setState(() => _pxPerSec = pxPerSec);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final x = centerMs / 1000 * pxPerSec - _viewWidth / 2;
      _scroll.jumpTo(x.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  @override
  void dispose() {
    _posTimer?.cancel();
    _lease?.release();
    _scroll.dispose();
    _pos.dispose();
    _playing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = _a;
    final grid = _grid;
    return Scaffold(
      appBar: AppBar(title: const Text('Beat analysis')),
      body: a == null || grid == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                  child: Wrap(spacing: 18, runSpacing: 8, children: [
                    if (a.timingPoints.length > 1)
                      _fact('BPM', _bpmRange(a))
                    else
                      _fact('BPM', a.bpm.toStringAsFixed(2)),
                    if (a.timingPoints.length > 1) _fact('Sections', '${a.timingPoints.length}'),
                    if (a.timingPoints.any((t) => t.triplet)) _fact('Feel', 'Triplets in places'),
                    _fact('First beat', '${a.beatOffsetMs.toStringAsFixed(1)} ms'),
                    _fact('Confidence', '${(a.tempoConfidence * 100).round()}%'),
                    _fact('Onsets', '${a.onsets.length}'),
                    _fact('Sustains', '${a.sustains.length}'),
                    _fact('Breaks', '${_breaks.length}'),
                  ]),
                ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                  child: Wrap(spacing: 14, runSpacing: 6, children: [
                    _legend(Palette.bone.withValues(alpha: 0.5), 'Downbeat'),
                    _legend(Palette.line, 'Beat'),
                    _legend(Palette.amber, 'Onset (height = strength)'),
                    _legend(Palette.rose, 'Sustain'),
                    _legend(Palette.early, 'Energy'),
                  ]),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: LayoutBuilder(builder: (context, box) {
                    _viewWidth = box.maxWidth;
                    return Stack(children: [
                      // Only the stretch on screen is drawn; the scroll view on
                      // top holds nothing and just does the scrolling.
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: _AnalysisPainter(a, grid, _breaks, _pxPerSec, scroll: _scroll, position: _pos),
                          ),
                        ),
                      ),
                      NotificationListener<ScrollStartNotification>(
                        onNotification: (n) {
                          if (n.dragDetails != null) _follow = false;
                          return false;
                        },
                        child: SingleChildScrollView(
                          controller: _scroll,
                          scrollDirection: Axis.horizontal,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: (d) => _player.seek(d.localPosition.dx / _pxPerSec * 1000),
                            child: SizedBox(width: a.durationMs / 1000 * _pxPerSec, height: box.maxHeight),
                          ),
                        ),
                      ),
                    ]);
                  }),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, Space.gutter, 8),
                    child: Row(children: [
                      ValueListenableBuilder<bool>(
                        valueListenable: _playing,
                        builder: (context, playing, _) => IconButton.filled(
                          style: IconButton.styleFrom(backgroundColor: Palette.action, foregroundColor: Palette.onAction),
                          onPressed: () {
                            if (_player.playing) {
                              _player.pause();
                              _playing.value = false;
                            } else {
                              _follow = true;
                              _lease!.reclaim();
                              _player.play();
                              _playing.value = true;
                            }
                          },
                          icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ValueListenableBuilder<double>(
                        valueListenable: _pos,
                        builder: (context, ms, _) => Text(formatDuration(ms), style: AppText.data(12.5, color: Palette.bone)),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.zoom_out_rounded, size: 18, color: Palette.mist),
                      Expanded(child: Slider(value: _pxPerSec, min: 40, max: 600, onChanged: _zoom)),
                      const Icon(Icons.zoom_in_rounded, size: 18, color: Palette.mist),
                    ]),
                  ),
                ),
              ],
            ),
    );
  }

  String _bpmRange(SongAnalysis a) {
    final bpms = a.timingPoints.map((t) => t.bpm).toList()..sort();
    String f(double v) => v.toStringAsFixed(v % 1 == 0 ? 0 : 1);
    return bpms.first.round() == bpms.last.round() ? f(bpms.first) : '${f(bpms.first)}–${f(bpms.last)}';
  }

  Widget _fact(String k, String v) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k, style: AppText.body(11.5, color: Palette.mist)),
        Text(v, style: AppText.data(14, weight: 600, color: Palette.bone)),
      ]);

  Widget _legend(Color c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 6),
        Text(label, style: AppText.body(12, color: Palette.mist)),
      ]);
}

/// Draws the part of the timeline that is on screen, in view coordinates.
/// It used to paint the whole song into one canvas tens of thousands of
/// pixels wide, which stalled the raster thread for seconds.
class _AnalysisPainter extends CustomPainter {
  _AnalysisPainter(this.a, this.grid, this.breaks, this.pxPerSec, {required this.scroll, required this.position})
      : super(repaint: Listenable.merge([scroll, position]));
  final SongAnalysis a;
  final BeatGrid grid;
  final List<TimeRange> breaks;
  final double pxPerSec;
  final ScrollController scroll;
  final ValueListenable<double> position;

  final _fill = Paint();
  final _energyStroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..color = Palette.early;

  @override
  void paint(Canvas canvas, Size size) {
    final p = _fill;
    final h = size.height;
    final left = scroll.hasClients ? scroll.offset : 0.0;
    double x(double ms) => ms / 1000 * pxPerSec - left;
    final waveTop = h * 0.08, waveH = h * 0.5;
    final mid = waveTop + waveH / 2;
    final startMs = math.max(0.0, left / pxPerSec * 1000 - 200);
    final endMs = (left + size.width) / pxPerSec * 1000 + 200;
    canvas.clipRect(Offset.zero & size);

    for (final b in breaks) {
      if (b.endMs < startMs || b.startMs > endMs) continue;
      p.color = Palette.bone.withValues(alpha: 0.05);
      canvas.drawRect(Rect.fromLTRB(math.max(-1.0, x(b.startMs)), 0, math.min(size.width + 1, x(b.endMs)), h), p);
    }

    // Beat grid (each tempo section on its own beats).
    for (final l in grid.lines(startMs, endMs, 1)) {
      final downbeat = l.kind == GridLineKind.downbeat;
      p.color = downbeat ? Palette.bone.withValues(alpha: 0.5) : Palette.line;
      canvas.drawRect(Rect.fromLTWH(x(l.timeMs) - 0.5, 0, downbeat ? 1.5 : 1, h), p);
    }
    // Section starts: tempo changes (amber) and triplet parts (rose).
    for (final s in grid.points.skip(1)) {
      if (s.timeMs < startMs || s.timeMs > endMs) continue;
      p.color = (s.triplet ? Palette.rose : Palette.amber).withValues(alpha: 0.8);
      canvas.drawRect(Rect.fromLTWH(x(s.timeMs) - 1, 0, 2, h), p);
    }

    // Waveform: one bar per pixel at most.
    p.color = Palette.mist.withValues(alpha: 0.55);
    final res = a.waveformResolutionMs;
    final pxPerBucket = res / 1000 * pxPerSec;
    final step = pxPerBucket < 1 ? (1 / pxPerBucket).ceil() : 1;
    final last = math.min(a.waveform.length, (endMs / res).ceil());
    for (var i = (startMs / res).floor() ~/ step * step; i < last; i += step) {
      var v = 0.0;
      for (var j = i; j < math.min(last, i + step); j++) {
        v = math.max(v, a.waveform[j]);
      }
      v *= waveH / 2;
      canvas.drawRect(Rect.fromLTRB(x(i * res), mid - v, x((i + step) * res) + 0.5, mid + v), p);
    }

    // Energy curve.
    final eRes = a.energyResolutionMs;
    final e0 = math.max(0, (startMs / eRes).floor() - 1);
    final e1 = math.min(a.energy.length, (endMs / eRes).ceil() + 2);
    if (e1 - e0 >= 2) {
      final energy = Path()..moveTo(x(e0 * eRes), waveTop + waveH - a.energy[e0] * waveH);
      for (var i = e0 + 1; i < e1; i++) {
        energy.lineTo(x(i * eRes), waveTop + waveH - a.energy[i] * waveH);
      }
      canvas.drawPath(energy, _energyStroke);
    }

    // Onsets, sorted by time: find the first visible one by bisection.
    final onsetBase = h * 0.86;
    final onsets = a.onsets;
    var lo = 0, hi = onsets.length;
    while (lo < hi) {
      final m = (lo + hi) >> 1;
      if (onsets[m].timeMs < startMs) {
        lo = m + 1;
      } else {
        hi = m;
      }
    }
    for (var i = lo; i < onsets.length && onsets[i].timeMs <= endMs; i++) {
      final o = onsets[i];
      p.color = Palette.heat(0.5 + 0.5 * o.height);
      final len = 6 + o.strength * h * 0.18;
      canvas.drawRect(Rect.fromLTWH(x(o.timeMs) - 1, onsetBase - len, 2, len), p);
    }

    // Sustains.
    for (final s in a.sustains) {
      if (s.endMs < startMs || s.startMs > endMs) continue;
      final y = s.band == Band.low ? h * 0.9 : h * 0.94;
      p.color = (s.band == Band.low ? Palette.rose : Palette.ember).withValues(alpha: 0.8);
      final r = Rect.fromLTRB(math.max(-4.0, x(s.startMs)), y, math.min(size.width + 4, x(s.endMs)), y + 4);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(2)), p);
    }

    // Playhead.
    p.color = Palette.amber;
    canvas.drawRect(Rect.fromLTWH(x(position.value) - 1, 0, 2, h), p);
  }

  @override
  bool shouldRepaint(_AnalysisPainter old) =>
      old.pxPerSec != pxPerSec || old.a != a || old.grid != grid || old.breaks != breaks;
}
