import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../audio/app_audio.dart';
import '../../audio/hit_sounds.dart';
import '../../core/gameplay/circles_session.dart';
import '../../core/gameplay/replay_driver.dart';
import '../../core/gameplay/session.dart';
import '../../core/gameplay/tiles_session.dart';
import '../../core/generator/note_selection.dart';
import '../../core/medals.dart';
import '../../core/models/beatmap.dart';
import '../../core/models/difficulty.dart';
import '../../core/models/replay.dart';
import '../../core/models/score.dart';
import '../../core/models/song.dart';
import '../../core/models/timing.dart';
import '../../core/rating/performance.dart';
import '../../core/rating/star_rating.dart';
import '../../core/timing/song_clock.dart';
import '../../core/util/ids.dart';
import '../../data/settings.dart';
import '../../game/circles_painter.dart';
import '../../game/fx.dart';
import '../../game/hud.dart';
import '../../game/tiles_painter.dart';
import '../../state/providers.dart';
import '../theme.dart';
import '../widgets/medals.dart';
import 'results_screen.dart';

class PlayRequest {
  const PlayRequest({
    required this.song,
    required this.map,
    required this.mods,
    this.startMs,
    this.loop,
    this.saveScore = true,
    this.replay,
  });

  final Song song;
  final Beatmap map;
  final Mods mods;

  /// Start from this song time (editor test-play).
  final double? startMs;

  /// Practice: loop this range (song ms).
  final (double, double)? loop;
  final bool saveScore;

  /// Watch this replay instead of playing.
  final Replay? replay;

  bool get isPractice => loop != null;
  bool get isReplay => replay != null;
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
  MusicPlayer get _player => _lease!.player;
  StreamSubscription<AudioSample>? _sampleSub;
  StreamSubscription<MusicEvent>? _eventSub;
  HitSounds? _sfx;
  late AppSettings _settings;
  SongClock _clock = SongClock();
  GameSession? _session;
  late final Ticker _ticker;
  final _frame = ValueNotifier<int>(0);
  final _skipVisible = ValueNotifier<bool>(false);
  final _hud = HudController();
  final _text = TextCache();
  final _trails = TrailSet();
  final _recorder = ReplayRecorder();
  final List<RunSample> _timeline = [];
  _Phase _phase = _Phase.loading;
  String? _error;
  bool _audioStarted = false;
  bool _hardSync = true;
  bool _musicEnded = false;
  double _audioStartMs = 0;
  int _countdown = 0;
  int _loops = 0;
  Size _size = Size.zero;
  final Map<int, int> _pointerLane = {};
  final List<int> _laneHolds = List.filled(10, 0);
  double _fps = 0;
  double _drift = 0;

  Duration _lastFrame = Duration.zero;
  BeatGrid? _grid;
  List<TimeSpan> _kiai = const [];
  ReplayDriver? _replayDriver;

  PlayRequest get req => widget.request;
  Mods get mods => req.replay?.mods ?? req.mods;
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
    _sampleSub?.cancel();
    _eventSub?.cancel();
    _lease?.release();
    _sfx?.dispose();
    _text.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _pause();
      // Whatever the phase, nothing keeps playing behind the home screen.
      if (_lease?.current ?? false) _player.pause();
    }
  }

  Future<void> _load() async {
    try {
      _settings = ref.read(settingsProvider);
      final services = ref.read(servicesProvider);
      final source = services.paths.sourceFile(req.song.id, req.song.sourceFile);
      final lease = await AppAudio.instance.open(source);
      if (!mounted) {
        lease.release();
        return;
      }
      _lease = lease;
      await _player.setSpeed(mods.rate, pitch: mods.pitch);
      await _player.setVolume(_settings.musicVolume);
      _sampleSub = _player.samples.listen(_onSample);
      _eventSub = _player.events.listen(_onMusicEvent);
      if (_settings.hitSounds) {
        try {
          _sfx = await HitSounds.load(volume: _settings.hitSoundVolume);
        } catch (_) {}
      }
      // Beat grid and kiai for the playfield pulse.
      _grid = req.map.grid;
      _kiai = req.map.kiai;
      if (_grid == null || _kiai.isEmpty) {
        try {
          final a = await services.repo.analysis(req.song.id);
          if (a != null) {
            _grid ??= a.grid;
            if (_kiai.isEmpty && req.map.origin == null) _kiai = findKiai(a);
          }
        } catch (_) {}
      }
      if (!mounted) return;
      await _startRun();
    } catch (e) {
      if (!mounted) return;
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

  HitWindows get _windows {
    final w = req.map.difficulty.windows;
    final k = mods.windowFactor;
    return HitWindows(perfect: w.perfect * k, great: w.great * k, good: w.good * k, miss: w.miss * k);
  }

  void _buildSession() {
    final loop = req.loop;
    final map = loop != null ? _rangeMap(loop.$1, loop.$2) : req.map;
    final start = loop?.$1 ?? req.startMs ?? double.negativeInfinity;
    final s = _tiles
        ? TilesSession(map: map, mods: mods, windows: _windows, startTimeMs: start)
        : CirclesSession(map: map, mods: mods, windows: _windows, startTimeMs: start);
    s.onFeedback = _onFeedback;
    s.onEvent = _onSessionEvent;
    _session = s;
    _updatedTo = double.negativeInfinity;
    _hud.reset();
    _trails.clear();
    _recorder.clear();
    _timeline.clear();
    final replay = req.replay;
    _replayDriver = replay == null
        ? null
        : (ReplayDriver(replay.frames, s)..onPointer = (id, p, t) => _trails.add(id, p, t));
  }

  double get _firstObjectMs => _session?.firstObjectMs ?? 0;

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
    await _player.setSpeed(mods.rate, pitch: mods.pitch);
    await _player.setVolume(_settings.musicVolume);
    await _player.seek(_audioStartMs);
    _clock = SongClock(rate: mods.rate, offsetMs: _settings.globalOffsetMs + req.song.offsetMs)..start(clockStart);
    _audioStarted = false;
    _musicEnded = false;
    _hardSync = true;
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

  /// A fresh native position report: steer the song clock towards it.
  void _onSample(AudioSample s) {
    if (!_audioStarted || _phase != _Phase.playing || !(_lease?.current ?? false)) return;
    if (s.positionMs < _audioStartMs + 20) return;
    if (_hardSync) {
      // First report after starting or resuming: lock on exactly.
      _clock.syncAt(s.positionMs, s.wallMicros, force: true);
      _hardSync = false;
      return;
    }
    final drift = _clock.syncAt(s.positionMs, s.wallMicros);
    _drift = _drift * 0.8 + drift.abs() * 0.2;
  }

  void _onMusicEvent(MusicEvent e) {
    if (!(_lease?.current ?? false)) return;
    switch (e.type) {
      case MusicEventType.completed:
        _musicEnded = true;
      case MusicEventType.interrupted:
        // Audio focus lost or the app left the foreground.
        _pause();
      case MusicEventType.error:
      case MusicEventType.playing:
        // The player stopped making sound on its own (focus loss, a call).
        if (_audioStarted && _phase == _Phase.playing && !_player.playing && !_musicEnded) _pause();
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
        _hardSync = true;
        _player.play();
      }
      final t = _clock.timeMs;
      _replayDriver?.advanceTo(t);
      session.update(t);
      if (t > _updatedTo) _updatedTo = t;
      if (_timeline.isEmpty || t - _timeline.last.timeMs >= 250 * mods.rate) {
        if (t >= session.firstObjectMs) _timeline.add(RunSample(t, session.processor.health, session.processor.accuracy));
      }
      final loop = req.loop;
      if (loop != null && t > loop.$2 + 600) {
        _restartLoop();
      } else if (session.processor.failed && !req.isPractice) {
        _fail();
      } else if ((session.complete && t > session.endTimeMs + 1400) || (_musicEnded && t > session.endTimeMs)) {
        if (!req.isPractice) _finish();
      }
      _skipVisible.value = (_firstObjectMs - t) / mods.rate > 5000;
    }
    _hud.observe(session, _clock.timeMs);
    _frame.value++;
  }

  /// Practice loops and Circles beat pulses read the grid.
  double _beatPulse() {
    final g = _grid;
    if (g == null || _kiai.isEmpty) return 0;
    final t = _clock.timeMs;
    var inKiai = false;
    for (final k in _kiai) {
      if (t >= k.startMs && t <= k.endMs) {
        inKiai = true;
        break;
      }
    }
    if (!inKiai) return 0;
    final p = g.at(t);
    final beats = (t - p.timeMs) / p.beatLengthMs;
    final since = (beats - beats.floor()) * p.beatLengthMs;
    final k = (1 - since / (p.beatLengthMs * 0.55)).clamp(0.0, 1.0);
    return k * k;
  }

  bool _inBreak() => _session?.breakAt(_clock.timeMs) != null;

  Future<void> _restartLoop() async {
    _loops++;
    // Medals from practice show up on the profile; no pop-ups mid-song.
    ref.read(progressProvider.notifier).bump(Counters.practiceLoops);
    _buildSession();
    final from = req.loop!.$1;
    final start = math.max(0.0, from - 1500 * mods.rate);
    _audioStartMs = start;
    _hardSync = true;
    await _player.seek(start);
    _clock.seek(start);
  }

  void _onFeedback(HitFeedback f) {
    if (f.judgment == Judgment.miss) {
      if (_hud.combo >= 20) _sfx?.miss();
      return;
    }
    if (!f.isRelease) {
      if (_settings.haptics && !req.isReplay) HapticFeedback.lightImpact();
      _sfx?.hit();
    }
  }

  void _onSessionEvent(SessionEvent e, Point2? _) {
    switch (e) {
      case SessionEvent.tick:
      case SessionEvent.repeat:
        _sfx?.tick();
      case SessionEvent.tickMiss:
        if (_hud.combo >= 20) _sfx?.miss();
      case SessionEvent.spinBonus:
        final s = _session;
        var count = 0;
        if (s is CirclesSession) {
          for (final o in s.objects) {
            if (o.object.isSpinner && o.bonusSpins > count) count = o.bonusSpins;
          }
        }
        _sfx?.spin(count);
    }
  }

  // --- input ------------------------------------------------------------------------

  bool get _acceptsInput => _phase == _Phase.playing && _size != Size.zero && !req.isReplay;

  /// Song time the session was last advanced to.
  double _updatedTo = double.negativeInfinity;

  /// Song time when the finger actually touched, not when the event reached
  /// this handler (a frame or more later when the phone is busy). Touch
  /// timestamps and [Timeline.now] share the system's monotonic clock; if
  /// the gap looks implausible, the current time is used instead.
  double _eventTime(PointerEvent e) {
    final now = _clock.timeMs;
    final ageMicros = Timeline.now - e.timeStamp.inMicroseconds;
    if (ageMicros <= 0 || ageMicros > 100000) return now;
    return now - ageMicros / 1000 * mods.rate;
  }

  /// Advances the session to an input's time first, so judgments don't
  /// depend on when frames happen to land (replays rely on this too).
  void _advanceTo(double t) {
    if (t <= _updatedTo) return;
    _session?.update(t);
    _updatedTo = t;
  }

  void _down(PointerDownEvent e) {
    if (!_acceptsInput) return;
    final t = _eventTime(e);
    final s = _session;
    _advanceTo(t);
    if (s is TilesSession) {
      final lane = TilesLayout(_size, s.lanes).laneAt(e.localPosition.dx);
      _pointerLane[e.pointer] = lane;
      if (_laneHolds[lane]++ == 0) _recorder.add(ReplayFrame(t, ReplayAction.press, lane));
      s.press(lane, t);
    } else if (s is CirclesSession) {
      final p = CirclesLayout(_size).toNorm(e.localPosition);
      _recorder.add(ReplayFrame(t, ReplayAction.down, e.pointer, p.x, p.y));
      _trails.add(e.pointer, p, t);
      s.pointerDown(e.pointer, p, t);
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_acceptsInput) return;
    final s = _session;
    if (s is CirclesSession) {
      final t = _eventTime(e);
      _advanceTo(t);
      final p = CirclesLayout(_size).toNorm(e.localPosition);
      _recorder.add(ReplayFrame(t, ReplayAction.move, e.pointer, p.x, p.y));
      _trails.add(e.pointer, p, t);
      s.pointerMove(e.pointer, p, t);
    }
  }

  void _up(int pointer, [PointerEvent? e]) {
    final t = e == null ? _clock.timeMs : _eventTime(e);
    final s = _session;
    if (req.isReplay) return;
    if (_phase == _Phase.playing) _advanceTo(t);
    if (s is TilesSession) {
      final lane = _pointerLane.remove(pointer);
      if (lane == null) return;
      _laneHolds[lane] = math.max(0, _laneHolds[lane] - 1);
      if (_laneHolds[lane] == 0) {
        _recorder.add(ReplayFrame(t, ReplayAction.release, lane));
        s.release(lane, t);
      }
    } else if (s is CirclesSession) {
      _recorder.add(ReplayFrame(t, ReplayAction.up, pointer));
      s.pointerUp(pointer, t);
    }
  }

  // --- flow ---------------------------------------------------------------------------

  void _pause() {
    if (_phase != _Phase.playing && _phase != _Phase.countdown) return;
    _clock.pause();
    if (_lease?.current ?? false) _player.pause();
    // Lift every finger: holds can't survive a pause.
    for (final p in _pointerLane.keys.toList()) {
      _up(p);
    }
    _ticker.stop();
    if (mounted) setState(() => _phase = _Phase.paused);
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
    _lease?.reclaim();
    if (_audioStarted) {
      _hardSync = true;
      _player.play();
    }
    _clock.resume();
    _lastFrame = Duration.zero;
    setState(() => _phase = _Phase.playing);
    if (!_ticker.isActive) _ticker.start();
  }

  Future<void> _retry() async {
    setState(() => _phase = _Phase.loading);
    _lease?.reclaim();
    await _startRun();
  }

  Future<void> _quit() async {
    _clock.pause();
    if (_lease?.current ?? false) await _player.pause();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _skipIntro() async {
    final target = _firstObjectMs - 2200 * mods.rate;
    if (target <= _clock.audioTimeMs) return;
    _audioStartMs = math.max(_audioStartMs, target);
    _hardSync = true;
    await _player.seek(target);
    _clock.seek(target);
  }

  void _fail() {
    setState(() => _phase = _Phase.failed);
    _ticker.stop();
    // Wind the music down.
    () async {
      for (var i = 1; i <= 6; i++) {
        await Future.delayed(const Duration(milliseconds: 90));
        if (!mounted || !(_lease?.current ?? false)) return;
        await _player.setSpeed(math.max(0.3, mods.rate * (1 - i * 0.12)), pitch: math.max(0.3, 1 - i * 0.12));
        await _player.setVolume(_settings.musicVolume * (1 - i / 7));
      }
      if (_lease?.current ?? false) await _player.pause();
    }();
    () async {
      await _saveScore(failed: true);
      if (mounted) announceMedals(context, _newMedals);
    }();
  }

  Future<void> _finish() async {
    if (_phase == _Phase.finished) return;
    setState(() => _phase = _Phase.finished);
    _ticker.stop();
    final record = await _saveScore(failed: false);
    if (req.isReplay) {
      _newMedals = await ref.read(progressProvider.notifier).bump(Counters.replaysWatched);
    }
    if (!mounted) return;
    final prevBest = _previousBest;
    // The music plays on under the results, as in osu!; the results screen
    // takes over the player and stops it when it closes.
    final lease = _lease;
    _lease = null;
    // This screen is gone once the results replace it; capture what the
    // results' buttons need now.
    final repo = ref.read(servicesProvider).repo;
    _sampleSub?.cancel();
    _eventSub?.cancel();
    if (!mounted) return;
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
          windows: _windows,
          timeline: List.of(_timeline),
          replayOf: req.replay?.player,
          pp: record?.pp ?? (req.isReplay || mods.autoplay ? 0 : _performance(failed: false)),
          newMedals: _newMedals,
        ),
        music: lease,
        onRetry: (ctx) => Navigator.of(ctx).pushReplacement(MaterialPageRoute(
          builder: (_) => PlayScreen(request: req.isReplay ? PlayRequest(song: req.song, map: req.map, mods: req.mods) : req),
        )),
        onWatchReplay: record == null || !record.hasReplay
            ? (req.isReplay ? (ctx) => Navigator.of(ctx).pushReplacement(MaterialPageRoute(builder: (_) => PlayScreen(request: req))) : null)
            : (ctx) async {
                final replay = await repo.loadReplay(record.id);
                if (replay == null || !ctx.mounted) return;
                Navigator.of(ctx).pushReplacement(MaterialPageRoute(
                  builder: (_) => PlayScreen(
                    request: PlayRequest(song: req.song, map: req.map, mods: replay.mods, replay: replay, saveScore: false),
                  ),
                ));
              },
      ),
    ));
  }

  ScoreRecord? _previousBest;
  List<Medal> _newMedals = const [];

  /// pp for the run so far (the whole run once it's over).
  double _performance({required bool failed}) {
    final p = _session!.processor;
    return performancePoints(PlayFacts(
      mode: req.map.mode,
      stars: starRating(req.map, rate: mods.rate),
      accuracy: p.accuracy,
      misses: p.counts[Judgment.miss] ?? 0,
      maxCombo: p.maxCombo,
      mapMaxCombo: p.maxPossibleCombo,
      objectCount: req.map.objectCount,
      strictness: effectiveStrictness(req.map.difficulty.hitWindow, mods),
      mods: mods,
      failed: failed,
    ));
  }

  Future<ScoreRecord?> _saveScore({required bool failed}) async {
    final s = _session;
    if (s == null || !req.saveScore || req.isReplay || mods.autoplay || req.isPractice || req.startMs != null) return null;
    final p = s.processor;
    if (p.judged == 0) return null;
    _previousBest = ref.read(scoresProvider.notifier).best(req.map.id);
    final id = newId();
    var hasReplay = false;
    if (!failed && _recorder.frames.isNotEmpty) {
      try {
        await ref.read(servicesProvider).repo.saveReplay(Replay(
              scoreId: id,
              beatmapId: req.map.id,
              mode: req.map.mode,
              mods: mods,
              player: ref.read(profileProvider).name,
              createdAt: DateTime.now(),
              frames: List.of(_recorder.frames),
            ));
        hasReplay = true;
      } catch (_) {}
    }
    final record = ScoreRecord(
      id: id,
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
      hasReplay: hasReplay,
      pp: _performance(failed: failed),
      mapMaxCombo: p.maxPossibleCombo,
      objectCount: req.map.objectCount,
      strictness: effectiveStrictness(req.map.difficulty.hitWindow, mods),
      lanes: _tiles ? req.map.difficulty.lanes : null,
      origin: req.map.origin,
    );
    await ref.read(scoresProvider.notifier).add(record);
    await ref.read(libraryProvider.notifier).recordPlay(req.song.id);
    _newMedals = await ref.read(progressProvider.notifier).check();
    return record;
  }

  // --- build ----------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_phase == _Phase.playing || _phase == _Phase.countdown) {
          _pause();
        } else if (_phase == _Phase.paused) {
          _resume();
        } else {
          _quit();
        }
      },
      child: Scaffold(
        // Plain black behind the notes: nothing to distract from them.
        backgroundColor: Colors.black,
        body: LayoutBuilder(builder: (context, c) {
          _size = c.biggest;
          final s = _session;
          return Stack(
            fit: StackFit.expand,
            children: [
              if (s != null) _game(s),
              if (s != null)
                IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: HudPainter(
                        repaint: _frame,
                        controller: _hud,
                        session: s,
                        mode: req.map.mode,
                        settings: _settings,
                        mods: mods,
                        time: () => _clock.timeMs,
                        songEndMs: math.max(req.song.durationMs, s.endTimeMs),
                        windows: _windows,
                        padding: padding,
                        text: _text,
                        fps: () => _fps,
                        drift: () => _drift,
                        frameCost: () => (_uiMs, _rasterMs),
                        practiceLoops: req.isPractice ? () => _loops : null,
                        replayOf: req.replay?.player,
                        leftHanded: _settings.leftHanded,
                      ),
                    ),
                  ),
                ),
              if (s != null)
                Positioned(
                  left: _settings.leftHanded ? null : 4,
                  right: _settings.leftHanded ? 4 : null,
                  top: padding.top + 4,
                  child: IconButton(
                    tooltip: 'Pause',
                    onPressed: _pause,
                    icon: const Icon(Icons.pause_rounded, color: Palette.bone),
                  ),
                ),
              if (s != null)
                Positioned(
                  right: _settings.leftHanded ? null : 16,
                  left: _settings.leftHanded ? 16 : null,
                  bottom: padding.bottom + (_tiles ? _size.height * 0.2 : 70),
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _skipVisible,
                    builder: (context, visible, _) => !visible || _phase != _Phase.playing
                        ? const SizedBox.shrink()
                        : FilledButton.tonalIcon(
                            style: FilledButton.styleFrom(backgroundColor: Palette.raised, foregroundColor: Palette.bone),
                            onPressed: _skipIntro,
                            icon: const Icon(Icons.fast_forward_rounded),
                            label: const Text('Skip intro'),
                          ),
                  ),
                ),
              ..._overlays(),
            ],
          );
        }),
      ),
    );
  }


  Widget _game(GameSession s) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: (e) => _up(e.pointer, e),
      onPointerCancel: (e) => _up(e.pointer, e),
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: s is TilesSession
              ? TilesPainter(
                  session: s,
                  time: () => _clock.timeMs,
                  visibleSongMs: () => _settings.tilesVisibleMs(req.map.difficulty.scrollSpeed) * mods.rate,
                  hidden: mods.hidden,
                  flashlight: mods.flashlight,
                  repaint: _frame,
                  beatPulse: _settings.reducedEffects ? () => 0 : _beatPulse,
                  reducedEffects: _settings.reducedEffects,
                  inBreak: _inBreak,
                )
              : CirclesPainter(
                  session: s as CirclesSession,
                  time: () => _clock.timeMs,
                  approachMs: req.map.difficulty.approachMs * mods.rate * mods.approachFactor,
                  hidden: mods.hidden,
                  flashlight: mods.flashlight,
                  repaint: _frame,
                  showJudgments: _settings.judgmentDisplay != JudgmentDisplay.off,
                  trails: _trails,
                  beatPulse: _settings.reducedEffects ? () => 0 : _beatPulse,
                  reducedEffects: _settings.reducedEffects,
                  inBreak: _inBreak,
                  text: _text,
                  pixelRatio: MediaQuery.devicePixelRatioOf(context),
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
              OutlinedButton.icon(onPressed: _retry, icon: const Icon(Icons.replay_rounded), label: Text(req.isReplay ? 'Restart replay' : 'Retry')),
              OutlinedButton.icon(onPressed: _quit, icon: const Icon(Icons.close_rounded), label: const Text('Quit')),
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
        final p = _session!.processor;
        final why = mods.perfect
            ? 'Perfect mod: only Perfects allowed.'
            : mods.suddenDeath
                ? 'Sudden Death: the first miss ends the run.'
                : 'Health ran out at ${(p.judged / math.max(1, p.totalJudgments) * 100).round()}% of the map. Turn on No-Fail to play through.';
        return [
          _Panel(
            title: 'Failed',
            subtitle: why,
            accent: Palette.danger,
            actions: [
              FilledButton.icon(onPressed: _retry, icon: const Icon(Icons.replay_rounded), label: const Text('Retry')),
              OutlinedButton.icon(onPressed: _quit, icon: const Icon(Icons.close_rounded), label: const Text('Quit')),
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
