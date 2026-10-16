import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../audio/hit_sounds.dart';
import '../../audio/app_audio.dart';
import '../../core/gameplay/circles_session.dart';
import '../../core/gameplay/session.dart';
import '../../core/gameplay/tiles_session.dart';
import '../../core/models/beatmap.dart';
import '../../core/models/difficulty.dart';
import '../../core/models/score.dart';
import '../../core/models/song.dart';
import '../../core/rating/star_rating.dart';
import '../../core/timing/song_clock.dart';
import '../../core/util/ids.dart';
import '../../data/settings.dart';
import '../../game/circles_painter.dart';
import '../../game/hud.dart';
import '../../game/tiles_painter.dart';
import '../../state/providers.dart';
import '../theme.dart';
import 'results_screen.dart';

class PlayRequest {
  const PlayRequest({
    required this.song,
    required this.map,
    required this.mods,
    this.startMs,
    this.loop,
    this.saveScore = true,
  });

  final Song song;
  final Beatmap map;
  final Mods mods;

  /// Start from this song time (editor test-play).
  final double? startMs;

  /// Practice: loop this range (song ms).
  final (double, double)? loop;
  final bool saveScore;

  bool get isPractice => loop != null;
}

enum _Phase { loading, playing, paused, countdown, failed, finished, error }

class PlayScreen extends ConsumerStatefulWidget {
  const PlayScreen({super.key, required this.request});
  final PlayRequest request;

  @override
  ConsumerState<PlayScreen> createState() => _PlayScreenState();
}

class _PlayScreenState extends ConsumerState<PlayScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  AudioLease? _lease;
  AudioPlayer get _player => _lease!.player;
  VideoPlayerController? _video;
  HitSounds? _sfx;
  late AppSettings _settings;
  SongClock _clock = SongClock();
  GameSession? _session;
  late final Ticker _ticker;
  final _frame = ValueNotifier<int>(0);
  final _hud = HudController();
  _Phase _phase = _Phase.loading;
  String? _error;
  bool _audioStarted = false;
  double _audioStartMs = 0;
  int _countdown = 0;
  int _loops = 0;
  double _lastVideoSync = 0;
  Size _size = Size.zero;
  final Map<int, int> _pointerLane = {};
  final List<int> _laneHolds = List.filled(6, 0);
  double _fps = 0;
  double _drift = 0;
  Duration _lastFrame = Duration.zero;

  PlayRequest get req => widget.request;
  Mods get mods => req.mods;
  bool get _tiles => req.map.mode == GameMode.tiles;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_tick);
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _ticker.dispose();
    _lease?.release();
    _video?.dispose();
    _sfx?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _pause();
  }

  Future<void> _load() async {
    try {
      _settings = ref.read(settingsProvider);
      final paths = ref.read(servicesProvider).paths;
      final source = paths.sourceFile(req.song.id, req.song.sourceFile);
      _lease = await AppAudio.instance.open(source);
      await _player.setSpeed(mods.rate);
      await _player.setVolume(_settings.musicVolume);
      if (_settings.hitSounds) {
        try {
          _sfx = await HitSounds.load(volume: _settings.hitSoundVolume);
        } catch (_) {}
      }
      if (req.song.hasVideo && _settings.backgroundVideo) {
        try {
          final v = VideoPlayerController.file(File(source));
          await v.initialize();
          await v.setVolume(0);
          await v.setPlaybackSpeed(mods.rate);
          _video = v;
        } catch (_) {
          _video = null;
        }
      }
      if (!mounted) return;
      await _startRun();
    } catch (e) {
      setState(() {
        _phase = _Phase.error;
        _error = 'Could not load this song: $e';
      });
    }
  }

  Beatmap _rangeMap(double from, double to) {
    final m = req.map;
    return m.copyWith(
      tileNotes: m.tileNotes.where((n) => n.timeMs >= from && n.endMs <= to).toList(),
      circleObjects: m.circleObjects.where((o) => o.timeMs >= from && o.endMs <= to).toList(),
    );
  }

  void _buildSession() {
    final loop = req.loop;
    final map = loop != null ? _rangeMap(loop.$1, loop.$2) : req.map;
    final start = loop?.$1 ?? req.startMs ?? double.negativeInfinity;
    final windows = req.map.difficulty.windows;
    final s = _tiles
        ? TilesSession(map: map, mods: mods, windows: windows, startTimeMs: start)
        : CirclesSession(map: map, mods: mods, windows: windows, startTimeMs: start);
    s.onFeedback = _onFeedback;
    _session = s;
    _hud.reset();
  }

  double get _firstObjectMs {
    final s = _session;
    if (s is TilesSession) return s.notes.isEmpty ? 0 : s.notes.first.note.timeMs;
    if (s is CirclesSession) return s.objects.isEmpty ? 0 : s.objects.first.object.timeMs;
    return 0;
  }

  Future<void> _startRun() async {
    _ticker.stop();
    _buildSession();
    final from = req.loop?.$1 ?? req.startMs ?? 0;
    final first = _firstObjectMs;
    final leadSong = 2000 * mods.rate;
    _audioStartMs = math.max(0, math.min(from, first - leadSong));
    if (req.startMs != null || req.loop != null) _audioStartMs = math.max(0, math.min(from, first) - leadSong);
    final clockStart = math.min(_audioStartMs, first - leadSong);
    await _player.pause();
    await _player.seek(Duration(milliseconds: _audioStartMs.round()));
    await _video?.pause();
    await _video?.seekTo(Duration(milliseconds: _audioStartMs.round()));
    _clock = SongClock(rate: mods.rate, offsetMs: _settings.globalOffsetMs + req.song.offsetMs)..start(clockStart);
    _audioStarted = false;
    _laneHolds.fillRange(0, _laneHolds.length, 0);
    _pointerLane.clear();
    if (!mounted) return;
    setState(() => _phase = _Phase.playing);
    _lastFrame = Duration.zero;
    _ticker.start();
  }

  double _uiMs = 0, _rasterMs = 0;

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _uiMs = _uiMs * 0.9 + t.buildDuration.inMicroseconds / 1000 * 0.1;
      _rasterMs = _rasterMs * 0.9 + t.rasterDuration.inMicroseconds / 1000 * 0.1;
    }
  }

  void _tick(Duration elapsed) {
    if (_lastFrame != Duration.zero) {
      final dt = (elapsed - _lastFrame).inMicroseconds / 1e6;
      if (dt > 0) _fps = _fps * 0.9 + (1 / dt) * 0.1;
    }
    _lastFrame = elapsed;
    final session = _session;
    if (session == null) return;
    if (_phase == _Phase.playing) {
      final audioT = _clock.audioTimeMs;
      if (!_audioStarted && audioT >= _audioStartMs) {
        _audioStarted = true;
        _player.play();
        _video?.play();
      } else if (_audioStarted && _player.playing && _player.processingState != ProcessingState.completed) {
        final pos = _player.position.inMicroseconds / 1000.0;
        if (pos > _audioStartMs + 30) {
          final drift = _clock.sync(pos);
          _drift = _drift * 0.95 + drift.abs() * 0.05;
        }
        final v = _video;
        if (v != null && audioT - _lastVideoSync > 1500 * mods.rate) {
          _lastVideoSync = audioT;
          final drift = v.value.position.inMilliseconds - pos;
          if (drift.abs() > 180) v.seekTo(Duration(milliseconds: (pos + 60).round()));
        }
      }
      final t = _clock.timeMs;
      session.update(t);
      final loop = req.loop;
      if (loop != null && t > loop.$2 + 600) {
        _restartLoop();
      } else if (session.processor.failed && !req.isPractice) {
        _fail();
      } else if ((session.complete && t > session.endTimeMs + 1400) ||
          (_player.processingState == ProcessingState.completed && t > session.endTimeMs)) {
        if (!req.isPractice) _finish();
      }
    }
    _hud.observe(session, _clock.timeMs);
    _frame.value++;
  }

  Future<void> _restartLoop() async {
    _loops++;
    _buildSession();
    final from = req.loop!.$1;
    final start = math.max(0.0, from - 1500 * mods.rate);
    _audioStartMs = start;
    await _player.seek(Duration(milliseconds: start.round()));
    _clock.seek(start);
    await _video?.seekTo(Duration(milliseconds: start.round()));
  }

  void _onFeedback(HitFeedback f) {
    if (f.judgment == Judgment.miss) {
      if (_hud.combo >= 20) _sfx?.miss();
      return;
    }
    if (!f.isRelease) {
      if (_settings.haptics) HapticFeedback.lightImpact();
      _sfx?.hit();
    }
  }

  // --- input ------------------------------------------------------------------------

  void _down(PointerDownEvent e) {
    if (_phase != _Phase.playing || _size == Size.zero) return;
    final t = _clock.timeMs;
    final s = _session;
    if (s is TilesSession) {
      final lane = TilesLayout(_size, s.lanes).laneAt(e.localPosition.dx);
      _pointerLane[e.pointer] = lane;
      _laneHolds[lane]++;
      s.press(lane, t);
    } else if (s is CirclesSession) {
      s.pointerDown(e.pointer, CirclesLayout(_size).toNorm(e.localPosition), t);
    }
  }

  void _move(PointerMoveEvent e) {
    if (_phase != _Phase.playing) return;
    final s = _session;
    if (s is CirclesSession) s.pointerMove(e.pointer, CirclesLayout(_size).toNorm(e.localPosition), _clock.timeMs);
  }

  void _up(int pointer) {
    final t = _clock.timeMs;
    final s = _session;
    if (s is TilesSession) {
      final lane = _pointerLane.remove(pointer);
      if (lane == null) return;
      _laneHolds[lane] = math.max(0, _laneHolds[lane] - 1);
      if (_laneHolds[lane] == 0) s.release(lane, t);
    } else if (s is CirclesSession) {
      s.pointerUp(pointer, t);
    }
  }

  // --- flow ---------------------------------------------------------------------------

  void _pause() {
    if (_phase != _Phase.playing && _phase != _Phase.countdown) return;
    _clock.pause();
    _player.pause();
    _video?.pause();
    // Lift every finger: holds can't survive a pause.
    for (final p in _pointerLane.keys.toList()) {
      _up(p);
    }
    setState(() => _phase = _Phase.paused);
  }

  Future<void> _resume() async {
    setState(() {
      _phase = _Phase.countdown;
      _countdown = 3;
    });
    for (var i = 3; i > 0; i--) {
      if (!mounted || _phase != _Phase.countdown) return;
      setState(() => _countdown = i);
      await Future.delayed(const Duration(milliseconds: 550));
    }
    if (!mounted || _phase != _Phase.countdown) return;
    if (_audioStarted) {
      _player.play();
      _video?.play();
    }
    _clock.resume();
    setState(() => _phase = _Phase.playing);
  }

  Future<void> _retry() async {
    setState(() => _phase = _Phase.loading);
    await _player.setSpeed(mods.rate);
    await _startRun();
  }

  Future<void> _skipIntro() async {
    final target = _firstObjectMs - 2200 * mods.rate;
    if (target <= _clock.audioTimeMs) return;
    _audioStartMs = math.max(_audioStartMs, target);
    await _player.seek(Duration(milliseconds: target.round()));
    await _video?.seekTo(Duration(milliseconds: target.round()));
    _clock.seek(target);
  }

  void _fail() {
    setState(() => _phase = _Phase.failed);
    _ticker.stop();
    // Wind the music down.
    () async {
      for (var i = 1; i <= 6; i++) {
        await Future.delayed(const Duration(milliseconds: 90));
        if (!mounted) return;
        await _player.setSpeed(math.max(0.3, mods.rate * (1 - i * 0.12)));
        await _player.setVolume(_settings.musicVolume * (1 - i / 7));
      }
      await _player.pause();
      await _video?.pause();
    }();
    _saveScore(failed: true);
  }

  Future<void> _finish() async {
    if (_phase == _Phase.finished) return;
    setState(() => _phase = _Phase.finished);
    _ticker.stop();
    final record = await _saveScore(failed: false);
    if (!mounted) return;
    final prevBest = _previousBest;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => ResultsScreen(
        result: RunResult(
          song: req.song,
          map: req.map,
          mods: mods,
          processor: _session!.processor,
          stars: starRating(req.map, rate: mods.rate),
          record: record,
          previousBest: prevBest,
          windows: req.map.difficulty.windows,
        ),
        onRetry: (ctx) => Navigator.of(ctx).pushReplacement(MaterialPageRoute(builder: (_) => PlayScreen(request: req))),
      ),
    ));
  }

  ScoreRecord? _previousBest;

  Future<ScoreRecord?> _saveScore({required bool failed}) async {
    final s = _session;
    if (s == null || !req.saveScore || mods.autoplay || req.isPractice || req.startMs != null) return null;
    final p = s.processor;
    if (p.judged == 0) return null;
    _previousBest = ref.read(scoresProvider.notifier).best(req.map.id);
    final record = ScoreRecord(
      id: newId(),
      songId: req.song.id,
      songHash: req.song.contentHash,
      beatmapId: req.map.id,
      beatmapName: req.map.name,
      mode: req.map.mode,
      stars: starRating(req.map, rate: mods.rate),
      score: p.score,
      accuracy: p.accuracy,
      maxCombo: p.maxCombo,
      counts: Map.of(p.counts),
      mods: mods,
      grade: p.grade,
      failed: failed,
      timestamp: DateTime.now(),
      durationMs: _clock.timeMs - (_audioStartMs),
      meanErrorMs: p.meanError,
      unstableRate: p.unstableRate,
      songTitle: req.song.title,
      songArtist: req.song.artist,
    );
    await ref.read(scoresProvider.notifier).add(record);
    await ref.read(libraryProvider.notifier).recordPlay(req.song.id);
    return record;
  }

  // --- build ----------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_phase == _Phase.playing || _phase == _Phase.countdown) {
          _pause();
        } else if (_phase == _Phase.paused) {
          _resume();
        } else {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: Palette.inkDeep,
        body: LayoutBuilder(builder: (context, c) {
          _size = c.biggest;
          return Stack(
            fit: StackFit.expand,
            children: [
              _background(),
              if (_session != null) _game(),
              if (_session != null)
                Hud(
                  frame: _frame,
                  controller: _hud,
                  session: _session!,
                  mode: req.map.mode,
                  settings: _settings,
                  time: () => _clock.timeMs,
                  songEndMs: math.max(req.song.durationMs, _session!.endTimeMs),
                  windows: req.map.difficulty.windows,
                  fps: () => _fps,
                  drift: () => _drift,
                  frameCost: () => (_uiMs, _rasterMs),
                  onPause: _pause,
                  practiceLoops: req.isPractice ? _loops : null,
                  skipIntro: _skipIntroVisible,
                  onSkipIntro: _skipIntro,
                ),
              ..._overlays(),
            ],
          );
        }),
      ),
    );
  }

  bool _skipIntroVisible() =>
      _phase == _Phase.playing && (_firstObjectMs - _clock.timeMs) / mods.rate > 5000;

  Widget _background() {
    final v = _video;
    final dim = _settings.backgroundDim;
    final cover = req.song.coverFile == null ? null : ref.read(servicesProvider).paths.coverFile(req.song.id, req.song.coverFile!);
    Widget bg;
    if (v != null && v.value.isInitialized) {
      bg = FittedBox(fit: BoxFit.cover, child: SizedBox(width: v.value.size.width, height: v.value.size.height, child: VideoPlayer(v)));
    } else if (cover != null && File(cover).existsSync()) {
      bg = Image.file(File(cover), fit: BoxFit.cover);
    } else {
      bg = const ColoredBox(color: Palette.ink);
    }
    return Stack(fit: StackFit.expand, children: [
      bg,
      ColoredBox(color: Colors.black.withValues(alpha: dim)),
    ]);
  }

  Widget _game() {
    final s = _session!;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: (e) => _up(e.pointer),
      onPointerCancel: (e) => _up(e.pointer),
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: s is TilesSession
              ? TilesPainter(
                  session: s,
                  time: () => _clock.timeMs,
                  visibleSongMs: () => _settings.tilesVisibleMs(req.map.difficulty.scrollSpeed) * mods.rate,
                  hidden: mods.hidden,
                  repaint: _frame,
                  backgroundAlpha: _video != null ? 0.55 : 0.8,
                )
              : CirclesPainter(
                  session: s as CirclesSession,
                  time: () => _clock.timeMs,
                  approachMs: req.map.difficulty.approachMs * mods.rate,
                  hidden: mods.hidden,
                  repaint: _frame,
                  showJudgments: _settings.judgmentDisplay != JudgmentDisplay.off,
                ),
        ),
      ),
    );
  }

  List<Widget> _overlays() {
    switch (_phase) {
      case _Phase.loading:
        return [const Center(child: CircularProgressIndicator())];
      case _Phase.error:
        return [
          _Panel(
            title: 'Can’t play this song',
            subtitle: _error,
            actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Back'))],
          ),
        ];
      case _Phase.paused:
        return [
          _Panel(
            title: 'Paused',
            subtitle: '${req.song.title} · ${req.map.name}',
            actions: [
              FilledButton.icon(onPressed: _resume, icon: const Icon(Icons.play_arrow_rounded), label: const Text('Resume')),
              OutlinedButton.icon(onPressed: _retry, icon: const Icon(Icons.replay_rounded), label: const Text('Retry')),
              OutlinedButton.icon(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close_rounded), label: const Text('Quit')),
            ],
          ),
        ];
      case _Phase.countdown:
        return [
          IgnorePointer(
            child: Center(
              child: Text('$_countdown', style: AppText.display(120, width: 150, weight: 900, color: Palette.flare)),
            ),
          ),
        ];
      case _Phase.failed:
        return [
          _Panel(
            title: 'Failed',
            subtitle: 'Health ran out at ${(_session!.processor.judged / math.max(1, _session!.processor.totalJudgments) * 100).round()}% of the map. Turn on No-Fail to play through.',
            accent: Palette.danger,
            actions: [
              FilledButton.icon(onPressed: _retry, icon: const Icon(Icons.replay_rounded), label: const Text('Retry')),
              OutlinedButton.icon(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close_rounded), label: const Text('Quit')),
            ],
          ),
        ];
      case _Phase.playing:
      case _Phase.finished:
        return const [];
    }
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, this.subtitle, required this.actions, this.accent});
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.6),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 28),
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
          decoration: BoxDecoration(
            color: Palette.surface,
            borderRadius: BorderRadius.circular(Space.radius),
            border: Border.all(color: accent?.withValues(alpha: 0.6) ?? Palette.line),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: AppText.display(34, width: 140, weight: 850, color: accent ?? Palette.bone)),
              if (subtitle != null) ...[
                const SizedBox(height: 8),
                Text(subtitle!, style: AppText.body(14, color: Palette.mist)),
              ],
              const SizedBox(height: 20),
              for (final a in actions) Padding(padding: const EdgeInsets.only(top: 8), child: a),
            ],
          ),
        ),
      ),
    );
  }
}
