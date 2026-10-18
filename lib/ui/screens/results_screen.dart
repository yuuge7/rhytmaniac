import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/app_audio.dart';
import '../../core/models/beatmap.dart';
import '../../core/models/difficulty.dart';
import '../../core/models/score.dart';
import '../../core/models/song.dart';
import '../../core/scoring/score_processor.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// One sample of how the run was going, for the results graph.
class RunSample {
  const RunSample(this.timeMs, this.health, this.accuracy);
  final double timeMs;
  final double health;
  final double accuracy;
}

class RunResult {
  const RunResult({
    required this.song,
    required this.map,
    required this.mods,
    required this.processor,
    required this.stars,
    required this.windows,
    this.record,
    this.previousBest,
    this.timeline = const [],
    this.replayOf,
  });

  final Song song;
  final Beatmap map;
  final Mods mods;
  final ScoreProcessor processor;
  final double stars;
  final HitWindows windows;
  final ScoreRecord? record;
  final ScoreRecord? previousBest;
  final List<RunSample> timeline;

  /// Set when this was a replay: whose run it was.
  final String? replayOf;

  bool get isNewBest => record != null && (previousBest == null || record!.score > previousBest!.score);
}

class ResultsScreen extends ConsumerStatefulWidget {
  const ResultsScreen({super.key, required this.result, required this.onRetry, this.music, this.onWatchReplay});
  final RunResult result;
  final void Function(BuildContext) onRetry;

  /// The song keeps playing under the results; released when they close.
  final AudioLease? music;
  final void Function(BuildContext)? onWatchReplay;

  @override
  ConsumerState<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends ConsumerState<ResultsScreen> {
  bool _offsetApplied = false;

  RunResult get r => widget.result;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
  }

  @override
  void dispose() {
    widget.music?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = r.processor;
    final grade = p.grade;
    final total = p.maxPossibleCombo;
    final fc = p.counts[Judgment.miss] == 0 && p.ticksMissed == 0 && p.judged >= p.totalJudgments;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close_rounded), tooltip: 'Close', onPressed: () => Navigator.of(context).pop()),
        title: Text(r.replayOf != null ? 'Replay · ${r.replayOf}' : 'Results'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Space.gutter, 4, Space.gutter, 24),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(grade.label, style: AppText.display(112, width: 150, weight: 900, color: Palette.grade(grade), letterSpacing: -4)),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (r.isNewBest && r.replayOf == null) _tag('New best', Palette.amber),
                      if (fc) _tag(p.counts[Judgment.perfect] == p.judged ? 'All perfect' : 'Full combo', Palette.flare),
                      const SizedBox(height: 6),
                      Text(r.song.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.display(19, width: 110, weight: 750)),
                      const SizedBox(height: 4),
                      Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        Text('${r.map.mode.label} · ${r.map.name}', style: AppText.body(13, color: Palette.mist)),
                        StarBadge(r.stars, compact: true),
                        for (final m in r.mods.labels) Text(m, style: AppText.data(11, color: Palette.amber)),
                      ]),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Palette.surface, borderRadius: BorderRadius.circular(Space.radius)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('SCORE', style: AppText.label()),
                const SizedBox(height: 4),
                Text(formatScore(p.score), style: AppText.data(34, weight: 650, color: Palette.bone)),
                if (r.previousBest != null && !r.isNewBest)
                  Text('Best ${formatScore(r.previousBest!.score)}', style: AppText.body(12.5, color: Palette.mist)),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(child: _stat('Accuracy', '${(p.accuracy * 100).toStringAsFixed(2)}%')),
                  Expanded(child: _stat('Max combo', '${p.maxCombo} / $total')),
                ]),
              ],
            ),
          ),
          const SectionLabel('Judgments', padding: EdgeInsets.fromLTRB(0, 22, 0, 10)),
          _JudgmentBars(counts: p.counts),
          if (p.ticksHit + p.ticksMissed > 0) ...[
            const SizedBox(height: 6),
            Text('Slider ticks ${p.ticksHit} / ${p.ticksHit + p.ticksMissed}${p.bonus > 0 ? ' · spinner bonus +${formatScore(p.bonus)}' : ''}',
                style: AppText.data(12, color: Palette.mist)),
          ] else if (p.bonus > 0) ...[
            const SizedBox(height: 6),
            Text('Spinner bonus +${formatScore(p.bonus)}', style: AppText.data(12, color: Palette.mist)),
          ],
          if (r.timeline.length >= 4) ...[
            const SectionLabel('Performance', padding: EdgeInsets.fromLTRB(0, 22, 0, 10)),
            _PerformanceGraph(samples: r.timeline),
          ],
          const SectionLabel('Timing', padding: EdgeInsets.fromLTRB(0, 22, 0, 10)),
          if (p.errors.length < 5)
            Text('Not enough hits to chart timing.', style: AppText.body(14, color: Palette.mist))
          else ...[
            HitErrorHistogram(errors: p.errors.map((e) => e.errorMs).toList(), windows: r.windows),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _stat('Average', _signed(p.meanError))),
              Expanded(child: _stat('Unstable rate', p.unstableRate.toStringAsFixed(0))),
              Expanded(child: _stat('Early / late', '${p.errors.where((e) => e.errorMs < 0).length} / ${p.errors.where((e) => e.errorMs > 0).length}')),
            ]),
            if (p.errors.length >= 20 && p.meanError.abs() >= 8 && !r.mods.autoplay) ...[
              const SizedBox(height: 14),
              _offsetHint(p.meanError),
            ],
          ],
          const SizedBox(height: 26),
          if (widget.onWatchReplay != null) ...[
            OutlinedButton.icon(
              onPressed: () => widget.onWatchReplay!(context),
              icon: const Icon(Icons.slideshow_rounded),
              label: Text(r.replayOf != null ? 'Watch again' : 'Watch replay'),
            ),
            const SizedBox(height: 10),
          ],
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back_rounded),
                label: const Text('Song'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => widget.onRetry(context),
                icon: const Icon(Icons.replay_rounded),
                label: const Text('Retry'),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  String _signed(double v) => '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(1)} ms';

  Widget _offsetHint(double mean) {
    final late = mean > 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        border: Border.all(color: Palette.line),
        borderRadius: BorderRadius.circular(Space.radiusSmall),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _offsetApplied
                  ? 'Song offset adjusted by ${_signed(mean)}.'
                  : 'You hit ${mean.abs().round()} ms ${late ? 'late' : 'early'} on average.',
              style: AppText.body(13.5, color: Palette.mist),
            ),
          ),
          if (!_offsetApplied)
            TextButton(
              onPressed: () async {
                final lib = ref.read(libraryProvider.notifier);
                final song = ref.read(libraryProvider).song(r.song.id);
                if (song == null) return;
                await lib.updateSong(song.copyWith(offsetMs: song.offsetMs + mean));
                setState(() => _offsetApplied = true);
              },
              child: const Text('Apply to song'),
            ),
        ],
      ),
    );
  }

  Widget _tag(String text, Color c) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text.toUpperCase(), style: AppText.data(11, weight: 700, color: c, letterSpacing: 1.2)),
      );

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.body(12, color: Palette.mist)),
          const SizedBox(height: 2),
          Text(value, style: AppText.data(15, weight: 600, color: Palette.bone)),
        ],
      );
}

/// Health (amber) and accuracy (bone) across the run, like osu!'s ranking
/// graph.
class _PerformanceGraph extends StatelessWidget {
  const _PerformanceGraph({required this.samples});
  final List<RunSample> samples;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(height: 96, child: CustomPaint(painter: _GraphPainter(samples))),
      const SizedBox(height: 6),
      Row(children: [
        Container(width: 14, height: 3, color: Palette.amber),
        const SizedBox(width: 6),
        Text('Health', style: AppText.body(12, color: Palette.mist)),
        const SizedBox(width: 16),
        Container(width: 14, height: 1.5, color: Palette.bone),
        const SizedBox(width: 6),
        Text('Accuracy (70–100%)', style: AppText.body(12, color: Palette.mist)),
      ]),
    ]);
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter(this.samples);
  final List<RunSample> samples;

  @override
  void paint(Canvas canvas, Size size) {
    final t0 = samples.first.timeMs, t1 = samples.last.timeMs;
    final span = math.max(1.0, t1 - t0);
    double x(double t) => (t - t0) / span * size.width;
    final bg = Paint()..color = Palette.surface;
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)), bg);
    final grid = Paint()..color = Palette.line.withValues(alpha: 0.6);
    canvas.drawRect(Rect.fromLTWH(0, size.height * 0.5, size.width, 1), grid);

    final health = Path(), acc = Path();
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      final hy = size.height - 4 - s.health.clamp(0.0, 1.0) * (size.height - 8);
      // Accuracy from 70% to 100% fills the height.
      final ay = size.height - 4 - ((s.accuracy - 0.7) / 0.3).clamp(0.0, 1.0) * (size.height - 8);
      if (i == 0) {
        health.moveTo(x(s.timeMs), hy);
        acc.moveTo(x(s.timeMs), ay);
      } else {
        health.lineTo(x(s.timeMs), hy);
        acc.lineTo(x(s.timeMs), ay);
      }
    }
    canvas.drawPath(
      health,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round
        ..color = Palette.amber,
    );
    canvas.drawPath(
      acc,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Palette.bone.withValues(alpha: 0.8),
    );
  }

  @override
  bool shouldRepaint(_GraphPainter old) => old.samples != samples;
}

class _JudgmentBars extends StatelessWidget {
  const _JudgmentBars({required this.counts});
  final Map<Judgment, int> counts;

  @override
  Widget build(BuildContext context) {
    final maxCount = math.max(1, counts.values.fold(0, math.max));
    return Column(
      children: [
        for (final j in Judgment.values)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(width: 72, child: Text(j.label, style: AppText.body(13.5, weight: 550))),
                Expanded(
                  child: LayoutBuilder(builder: (context, c) {
                    final w = c.maxWidth * (counts[j] ?? 0) / maxCount;
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: math.max(2, w),
                        height: 12,
                        decoration: BoxDecoration(
                          color: Palette.judgment(j),
                          borderRadius: const BorderRadius.horizontal(right: Radius.circular(4)),
                        ),
                      ),
                    );
                  }),
                ),
                SizedBox(
                  width: 52,
                  child: Text('${counts[j] ?? 0}', textAlign: TextAlign.right, style: AppText.data(13, color: Palette.bone)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Distribution of hit errors: early (cool) left of zero, late (warm) right,
/// over the timing windows. Tap or drag across to read a bin.
class HitErrorHistogram extends StatefulWidget {
  const HitErrorHistogram({super.key, required this.errors, required this.windows, this.height = 140});
  final List<double> errors;
  final HitWindows windows;
  final double height;

  @override
  State<HitErrorHistogram> createState() => _HitErrorHistogramState();
}

class _HitErrorHistogramState extends State<HitErrorHistogram> {
  int? _selected;

  static const binMs = 5.0;

  List<int> get _bins {
    final half = (widget.windows.good / binMs).ceil();
    final bins = List.filled(half * 2 + 1, 0);
    for (final e in widget.errors) {
      final i = (e / binMs).round().clamp(-half, half) + half;
      bins[i]++;
    }
    return bins;
  }

  @override
  Widget build(BuildContext context) {
    final bins = _bins;
    final half = bins.length ~/ 2;
    final mean = widget.errors.isEmpty ? 0.0 : widget.errors.reduce((a, b) => a + b) / widget.errors.length;
    void select(Offset local, double width) {
      final i = (local.dx / width * bins.length).floor().clamp(0, bins.length - 1);
      setState(() => _selected = i);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 18,
          child: _selected == null
              ? Row(children: [
                  Text('Early', style: AppText.body(12, color: Palette.mist)),
                  const Spacer(),
                  Text('Late', style: AppText.body(12, color: Palette.mist)),
                ])
              : Text(
                  '${((_selected! - half) * binMs).round()} ms · ${bins[_selected!]} hit${bins[_selected!] == 1 ? '' : 's'}',
                  textAlign: TextAlign.center,
                  style: AppText.data(12, color: Palette.bone),
                ),
        ),
        const SizedBox(height: 6),
        LayoutBuilder(builder: (context, c) {
          return GestureDetector(
            onTapDown: (d) => select(d.localPosition, c.maxWidth),
            onHorizontalDragUpdate: (d) => select(d.localPosition, c.maxWidth),
            onHorizontalDragEnd: (_) => setState(() => _selected = null),
            onTapUp: (_) => Future.delayed(const Duration(seconds: 2), () {
              if (mounted) setState(() => _selected = null);
            }),
            child: SizedBox(
              height: widget.height,
              width: c.maxWidth,
              child: CustomPaint(painter: _HistogramPainter(bins, mean, widget.windows, _selected)),
            ),
          );
        }),
        const SizedBox(height: 4),
        Row(children: [
          Text('−${widget.windows.good.round()} ms', style: AppText.data(10.5)),
          const Spacer(),
          Text('0', style: AppText.data(10.5)),
          const Spacer(),
          Text('+${widget.windows.good.round()} ms', style: AppText.data(10.5)),
        ]),
      ],
    );
  }
}

class _HistogramPainter extends CustomPainter {
  _HistogramPainter(this.bins, this.mean, this.windows, this.selected);
  final List<int> bins;
  final double mean;
  final HitWindows windows;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final n = bins.length;
    final half = n ~/ 2;
    final maxV = math.max(1, bins.reduce(math.max));
    final colW = size.width / n;
    final p = Paint();
    final pxPerMs = size.width / (n * _HitErrorHistogramState.binMs);
    final cx = size.width / 2;

    // Window bands, recessive.
    for (final (ms, alpha) in [(windows.good, 0.04), (windows.great, 0.05), (windows.perfect, 0.07)]) {
      p.color = Palette.bone.withValues(alpha: alpha);
      canvas.drawRect(Rect.fromLTRB(cx - ms * pxPerMs, 0, cx + ms * pxPerMs, size.height), p);
    }
    // Baseline.
    p.color = Palette.line;
    canvas.drawRect(Rect.fromLTWH(0, size.height - 1, size.width, 1), p);

    for (var i = 0; i < n; i++) {
      final v = bins[i];
      if (v == 0) continue;
      final h = (size.height - 4) * v / maxV;
      final offset = i - half;
      final color = offset == 0 ? Palette.mist : (offset < 0 ? Palette.early : Palette.late);
      p.color = selected == null || selected == i ? color : color.withValues(alpha: 0.35);
      final barW = math.max(1.0, colW - 2);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(i * colW + (colW - barW) / 2, size.height - 1 - h, barW, h),
          topLeft: Radius.circular(math.min(4, barW / 2)),
          topRight: Radius.circular(math.min(4, barW / 2)),
        ),
        p,
      );
    }
    // Zero and mean markers.
    p.color = Palette.bone.withValues(alpha: 0.5);
    canvas.drawRect(Rect.fromLTWH(cx - 0.5, 0, 1, size.height), p);
    final mx = cx + mean * pxPerMs;
    p.color = Palette.bone;
    for (var y = 0.0; y < size.height; y += 6) {
      canvas.drawRect(Rect.fromLTWH(mx - 1, y, 2, 3), p);
    }
  }

  @override
  bool shouldRepaint(_HistogramPainter old) => old.bins != bins || old.selected != selected;
}
