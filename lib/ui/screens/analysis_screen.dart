import 'dart:async';
import 'dart:math' as math;

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
  List<TimeRange> _breaks = const [];
  AudioLease? _lease;
  MusicPlayer get _player => _lease!.player;
  final _scroll = ScrollController();
  double _pxPerSec = 160;
  Timer? _posTimer;
  double _posMs = 0;
  bool _follow = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final services = ref.read(servicesProvider);
    final a = await services.repo.analysis(widget.song.id);
    _lease = await AppAudio.instance.open(services.paths.sourceFile(widget.song.id, widget.song.sourceFile));
    _posTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted || (!_player.playing && _player.positionMs == _posMs)) return;
      setState(() => _posMs = _player.positionMs);
      if (_follow && _player.playing && _scroll.hasClients) {
        final x = _posMs / 1000 * _pxPerSec - MediaQuery.sizeOf(context).width * 0.3;
        _scroll.jumpTo(x.clamp(0.0, _scroll.position.maxScrollExtent));
      }
    });
    if (!mounted) return;
    setState(() {
      _a = a;
      _breaks = a == null ? const [] : findBreaks(a);
    });
  }

  @override
  void dispose() {
    _posTimer?.cancel();
    _lease?.release();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = _a;
    return Scaffold(
      appBar: AppBar(title: const Text('Beat analysis')),
      body: a == null
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
                  child: NotificationListener<ScrollStartNotification>(
                    onNotification: (n) {
                      if (n.dragDetails != null) _follow = false;
                      return false;
                    },
                    child: SingleChildScrollView(
                      controller: _scroll,
                      scrollDirection: Axis.horizontal,
                      child: GestureDetector(
                        onTapUp: (d) {
                          final ms = d.localPosition.dx / _pxPerSec * 1000;
                          _player.seek(ms);
                        },
                        child: CustomPaint(
                          size: Size(a.durationMs / 1000 * _pxPerSec, double.infinity),
                          painter: _AnalysisPainter(a, _breaks, _pxPerSec, _posMs),
                        ),
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, Space.gutter, 8),
                    child: Row(children: [
                      IconButton.filled(
                        style: IconButton.styleFrom(backgroundColor: Palette.action, foregroundColor: Palette.onAction),
                        onPressed: () {
                          if (_player.playing) {
                            _player.pause();
                          } else {
                            _follow = true;
                            _lease!.reclaim();
                            _player.play();
                          }
                          setState(() {});
                        },
                        icon: Icon(_player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                      ),
                      const SizedBox(width: 8),
                      Text(formatDuration(_posMs), style: AppText.data(12.5, color: Palette.bone)),
                      const SizedBox(width: 8),
                      const Icon(Icons.zoom_out_rounded, size: 18, color: Palette.mist),
                      Expanded(
                        child: Slider(
                          value: _pxPerSec,
                          min: 40,
                          max: 600,
                          onChanged: (v) => setState(() => _pxPerSec = v),
                        ),
                      ),
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

class _AnalysisPainter extends CustomPainter {
  _AnalysisPainter(this.a, this.breaks, this.pxPerSec, this.posMs) : grid = a.grid;
  final SongAnalysis a;
  final BeatGrid grid;
  final List<TimeRange> breaks;
  final double pxPerSec;
  final double posMs;

  double x(double ms) => ms / 1000 * pxPerSec;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint();
    final h = size.height;
    final waveTop = h * 0.08, waveH = h * 0.5;
    final mid = waveTop + waveH / 2;
    final visible = canvas.getLocalClipBounds();
    final startMs = math.max(0.0, visible.left / pxPerSec * 1000 - 500);
    final endMs = visible.right / pxPerSec * 1000 + 500;

    for (final b in breaks) {
      p.color = Palette.bone.withValues(alpha: 0.05);
      canvas.drawRect(Rect.fromLTRB(x(b.startMs), 0, x(b.endMs), h), p);
    }

    // Beat grid (each tempo section on its own beats).
    for (final l in grid.lines(math.max(0.0, startMs), endMs, 1)) {
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

    // Waveform.
    p.color = Palette.mist.withValues(alpha: 0.55);
    final res = a.waveformResolutionMs;
    final step = math.max(1, (res / 1000 * pxPerSec < 1) ? (1 / (res / 1000 * pxPerSec)).ceil() : 1);
    for (var i = (startMs / res).floor(); i < math.min(a.waveform.length, endMs / res); i += step) {
      if (i < 0) continue;
      final v = a.waveform[i] * waveH / 2;
      canvas.drawRect(Rect.fromLTRB(x(i * res), mid - v, x((i + step) * res) + 0.5, mid + v), p);
    }

    // Energy curve.
    final energy = Path();
    var started = false;
    for (var i = 0; i < a.energy.length; i++) {
      final t = i * a.energyResolutionMs;
      if (t < startMs - 200 || t > endMs + 200) continue;
      final y = waveTop + waveH - a.energy[i] * waveH;
      if (!started) {
        energy.moveTo(x(t), y);
        started = true;
      } else {
        energy.lineTo(x(t), y);
      }
    }
    canvas.drawPath(energy, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Palette.early);

    // Onsets.
    final onsetBase = h * 0.86;
    for (final o in a.onsets) {
      if (o.timeMs < startMs || o.timeMs > endMs) continue;
      p.color = Palette.heat(0.5 + 0.5 * o.brightness);
      final len = 6 + o.strength * h * 0.18;
      canvas.drawRect(Rect.fromLTWH(x(o.timeMs) - 1, onsetBase - len, 2, len), p);
    }

    // Sustains.
    for (final s in a.sustains) {
      if (s.endMs < startMs || s.startMs > endMs) continue;
      final y = s.band == Band.low ? h * 0.9 : h * 0.94;
      p.color = (s.band == Band.low ? Palette.rose : Palette.ember).withValues(alpha: 0.8);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(x(s.startMs), y, x(s.endMs), y + 4), const Radius.circular(2)), p);
    }

    // Playhead.
    p.color = Palette.amber;
    canvas.drawRect(Rect.fromLTWH(x(posMs) - 1, 0, 2, h), p);
  }

  @override
  bool shouldRepaint(_AnalysisPainter old) => old.pxPerSec != pxPerSec || old.posMs != posMs || old.a != a;
}
