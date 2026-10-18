import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio/app_audio.dart';
import '../../core/audio/pcm.dart';
import '../../core/timing/calibration.dart';
import '../../core/timing/song_clock.dart';
import '../../state/providers.dart';
import '../../core/medals.dart';
import '../theme.dart';
import '../widgets/medals.dart';

/// Tap along to a metronome played through the same audio path as songs;
/// the average lateness becomes the global offset.
class CalibrationScreen extends ConsumerStatefulWidget {
  const CalibrationScreen({super.key});

  @override
  ConsumerState<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends ConsumerState<CalibrationScreen> with SingleTickerProviderStateMixin {
  static const bpm = 100.0;
  static const firstBeatMs = 500.0;
  static const beats = 120;
  double get beatMs => 60000 / bpm;

  AudioLease? _lease;
  MusicPlayer get _player => _lease!.player;
  MusicPlayer? get _audio => _lease?.player;
  late final Ticker _ticker;
  final _clock = SongClock();
  final List<double> _taps = [];
  bool _running = false;
  bool _showPulse = true;
  OffsetEstimate? _estimate;
  double _now = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      if (_audio?.playing ?? false) _clock.sync(_player.positionMs);
      setState(() => _now = _clock.audioTimeMs);
      if (_now > firstBeatMs + beats * beatMs + 500) _stop();
    });
    _prepare();
  }

  Future<void> _prepare() async {
    final path = '${ref.read(servicesProvider).paths.tmpDir}/metronome.wav';
    final f = File(path);
    if (!await f.exists()) {
      const sr = 22050;
      final total = ((firstBeatMs + beats * beatMs + 1000) / 1000 * sr).round();
      final s = Float32List(total);
      for (var k = 0; k < beats; k++) {
        final start = ((firstBeatMs + k * beatMs) / 1000 * sr).round();
        final freq = k % 4 == 0 ? 1760.0 : 1320.0;
        for (var i = 0; i < sr * 0.05 && start + i < total; i++) {
          s[start + i] = (math.sin(2 * math.pi * freq * i / sr) * math.exp(-i / (sr * 0.008)) * 0.9);
        }
      }
      await f.parent.create(recursive: true);
      await f.writeAsBytes(encodeWav16(s, sr));
    }
    _lease = await AppAudio.instance.open(path);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    _lease?.release();
    super.dispose();
  }

  Future<void> _start() async {
    if (_audio == null) return;
    _lease!.reclaim();
    _taps.clear();
    _estimate = null;
    await _player.seek(0);
    _clock.start(0);
    _player.play();
    _ticker.start();
    setState(() => _running = true);
  }

  Future<void> _stop() async {
    await _audio?.pause();
    _ticker.stop();
    if (mounted) setState(() => _running = false);
  }

  void _tap() {
    if (!_running) return;
    HapticFeedback.selectionClick();
    _taps.add(_clock.audioTimeMs);
    setState(() => _estimate = estimateOffset(_taps, firstBeatMs: firstBeatMs, beatMs: beatMs));
  }

  @override
  Widget build(BuildContext context) {
    final est = _estimate;
    final sinceBeat = ((_now - firstBeatMs) % beatMs + beatMs) % beatMs;
    final pulse = _running && _now >= firstBeatMs ? (1 - sinceBeat / 220).clamp(0.0, 1.0) : 0.0;
    final errors = _taps.skip(4).map((t) => errorToNearestBeat(t, firstBeatMs, beatMs)).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Calibrate offset')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, 8),
            child: Text(
              'Use the headphones or speaker you play with. Press Start and tap the pad on every click — listen, don’t watch. After 20 or so taps, save.',
              style: AppText.body(14, color: Palette.mist),
            ),
          ),
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            title: Text('Show the beat', style: AppText.body(14.5, weight: 600)),
            subtitle: Text('Turn off for a purely audio calibration', style: AppText.body(12.5, color: Palette.mist)),
            value: _showPulse,
            onChanged: (v) => setState(() => _showPulse = v),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(Space.gutter),
              child: Listener(
                onPointerDown: (_) => _tap(),
                child: Container(
                  decoration: BoxDecoration(
                    color: Color.lerp(Palette.surface, Palette.raised, _showPulse ? pulse : 0),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: _showPulse ? Palette.amber.withValues(alpha: 0.25 + 0.6 * pulse) : Palette.line, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                      est == null ? (_running ? 'Tap' : 'Ready') : '${est.offsetMs >= 0 ? '+' : ''}${est.offsetMs.round()} ms',
                      style: AppText.display(56, width: 140, weight: 880, color: est == null ? Palette.bone : Palette.flare),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      est == null
                          ? '${_taps.length} taps'
                          : '${est.samples} taps · ±${est.deviationMs.round()} ms spread${est.offsetMs > 0 ? ' · you hear it late' : ''}',
                      style: AppText.body(13.5, color: Palette.mist),
                    ),
                    const SizedBox(height: 18),
                    if (errors.isNotEmpty) SizedBox(width: 220, height: 22, child: CustomPaint(painter: _TapErrors(errors))),
                  ]),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, 12),
              child: Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _running ? _stop : _start,
                    child: Text(_running ? 'Stop' : (_taps.isEmpty ? 'Start' : 'Start over')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: est == null
                        ? null
                        : () async {
                            final s = ref.read(settingsProvider);
                            await ref.read(settingsProvider.notifier).update(s.copyWith(globalOffsetMs: est.offsetMs.roundToDouble()));
                            final medals = await ref.read(progressProvider.notifier).bump(Counters.calibrations);
                            await _stop();
                            if (!context.mounted) return;
                            announceMedals(context, medals);
                            Navigator.of(context).pop();
                          },
                    child: Text(est == null ? 'Save offset' : 'Save ${est.offsetMs >= 0 ? '+' : ''}${est.offsetMs.round()} ms'),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _TapErrors extends CustomPainter {
  _TapErrors(this.errors);
  final List<double> errors;

  @override
  void paint(Canvas canvas, Size size) {
    const range = 150.0;
    final cx = size.width / 2;
    final p = Paint()..color = Palette.line;
    canvas.drawRect(Rect.fromLTWH(0, size.height / 2 - 1, size.width, 2), p);
    p.color = Palette.bone;
    canvas.drawRect(Rect.fromLTWH(cx - 1, 0, 2, size.height), p);
    for (var i = 0; i < errors.length; i++) {
      final e = errors[i].clamp(-range, range);
      final x = cx + e / range * cx;
      final age = (errors.length - 1 - i) / math.max(1, errors.length);
      p.color = (e < 0 ? Palette.early : Palette.late).withValues(alpha: 1 - age * 0.7);
      canvas.drawRect(Rect.fromLTWH(x - 1.5, 3, 3, size.height - 6), p);
    }
  }

  @override
  bool shouldRepaint(_TapErrors old) => true;
}
