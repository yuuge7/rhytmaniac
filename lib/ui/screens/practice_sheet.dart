import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/models/analysis.dart';
import '../../core/models/timing.dart';
import '../../core/models/song.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/signal_strip.dart';

class PracticeChoice {
  const PracticeChoice(this.startMs, this.endMs, this.rate);
  final double startMs;
  final double endMs;
  final double rate;
}

/// Pick a section to loop and how slow to play it.
class PracticeSheet extends StatefulWidget {
  const PracticeSheet({super.key, required this.song, required this.analysis});
  final Song song;
  final SongAnalysis? analysis;

  @override
  State<PracticeSheet> createState() => _PracticeSheetState();
}

class _PracticeSheetState extends State<PracticeSheet> {
  late RangeValues _range;
  double _rate = 0.75;

  double get _duration => widget.song.durationMs;

  @override
  void initState() {
    super.initState();
    final d = _duration;
    _range = RangeValues(d * 0.3, math.min(d, d * 0.3 + 15000));
  }

  /// Snaps to the nearest downbeat so loops start on the bar.
  double _snap(double ms) {
    final a = widget.analysis;
    if (a == null) return ms;
    final grid = a.grid;
    final bar = grid.beatLengthAt(ms) * 4;
    var best = ms, bestD = double.infinity;
    for (final l in grid.lines(math.max(0.0, ms - bar), ms + bar, 1)) {
      if (l.kind != GridLineKind.downbeat) continue;
      final d = (l.timeMs - ms).abs();
      if (d < bestD) {
        bestD = d;
        best = l.timeMs;
      }
    }
    return best.clamp(0.0, _duration);
  }

  @override
  Widget build(BuildContext context) {
    final d = _duration;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Practice a section', style: AppText.display(22, width: 118, weight: 800)),
            const SizedBox(height: 6),
            Text('The section loops until you leave. Scores aren’t saved.', style: AppText.body(13.5, color: Palette.mist)),
            const SizedBox(height: 18),
            SignalStrip(
              fingerprint: widget.song.fingerprint,
              height: 56,
              highlight: (_range.start / d, _range.end / d),
            ),
            RangeSlider(
              values: _range,
              min: 0,
              max: d,
              onChanged: (v) {
                if (v.end - v.start < 2000) return;
                setState(() => _range = v);
              },
              onChangeEnd: (v) => setState(() {
                final s = _snap(v.start), e = _snap(v.end);
                _range = RangeValues(s, e - s >= 2000 ? e : math.min(d, s + 2000));
              }),
            ),
            Row(children: [
              Text(formatDuration(_range.start), style: AppText.data(12.5, color: Palette.bone)),
              const Spacer(),
              Text('${((_range.end - _range.start) / 1000).toStringAsFixed(1)} s', style: AppText.data(12.5)),
              const Spacer(),
              Text(formatDuration(_range.end), style: AppText.data(12.5, color: Palette.bone)),
            ]),
            const SizedBox(height: 18),
            Row(children: [
              Text('Speed', style: AppText.body(15, weight: 600)),
              const Spacer(),
              Text('${_rate.toStringAsFixed(2)}×', style: AppText.data(14, color: Palette.bone)),
            ]),
            Wrap(spacing: 8, children: [
              for (final r in const [0.5, 0.6, 0.75, 0.9, 1.0])
                ChoiceChip(label: Text('$r×'), selected: _rate == r, onSelected: (_) => setState(() => _rate = r)),
            ]),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, PracticeChoice(_range.start, _range.end, _rate)),
              icon: const Icon(Icons.repeat_rounded),
              label: const Text('Start practice'),
            ),
          ],
        ),
      ),
    );
  }
}
