import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/timing/song_clock.dart';

/// A position report from the native player: where the audio output was at
/// [wallMicros] on the shared monotonic clock ([monotonicMicros]).
class AudioSample {
  const AudioSample(this.positionMs, this.wallMicros);
  final double positionMs;
  final int wallMicros;
}

enum MusicEventType { playing, completed, interrupted, error }

class MusicEvent {
  const MusicEvent(this.type, [this.message]);
  final MusicEventType type;
  final String? message;
}

/// Dart side of `GameAudio.kt`: the app's single music player.
///
/// While playback is requested the player polls the native position about
/// ten times a second, timing each round trip, so [positionMs] and
/// [samples] follow what is actually coming out of the speaker. Stalls,
/// underruns and speed changes show up within one poll instead of drifting
/// silently.
class MusicPlayer {
  MusicPlayer._() {
    _channel.setMethodCallHandler(_onCall);
  }

  static final instance = MusicPlayer._();
  static const _channel = MethodChannel('rhytmaniac/audio');

  bool _wants = false;
  bool _sounding = false;
  bool _completed = false;
  double _pos = 0;
  int _posWall = 0;
  double _speed = 1;
  double durationMs = 0;
  Timer? _poll;
  bool _polling = false;
  final _events = StreamController<MusicEvent>.broadcast();
  final _samples = StreamController<AudioSample>.broadcast();

  /// Playback was requested (it may still be buffering).
  bool get playing => _wants;

  /// Sound is coming out right now.
  bool get sounding => _sounding;

  /// The end of the file was reached.
  bool get completed => _completed;

  double get speed => _speed;

  /// Current position, extrapolated from the latest native report.
  double get positionMs {
    if (!_sounding) return _pos;
    return _pos + (monotonicMicros() - _posWall) / 1000.0 * _speed;
  }

  Stream<MusicEvent> get events => _events.stream;

  /// Fresh native position reports while playing.
  Stream<AudioSample> get samples => _samples.stream;

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method != 'event') return;
    final m = (call.arguments as Map).cast<String, dynamic>();
    _apply(m, monotonicMicros());
    switch (m['type']) {
      case 'completed':
        _completed = true;
        _wants = false;
        _events.add(const MusicEvent(MusicEventType.completed));
      case 'interrupted':
        _wants = false;
        _events.add(const MusicEvent(MusicEventType.interrupted));
      case 'error':
        _wants = false;
        _events.add(MusicEvent(MusicEventType.error, m['message'] as String?));
      default:
        _events.add(const MusicEvent(MusicEventType.playing));
    }
  }

  void _apply(Map<String, dynamic>? m, int wall) {
    if (m == null) return;
    _pos = (m['pos'] as num).toDouble();
    _posWall = wall;
    _sounding = m['playing'] as bool? ?? false;
    final wants = m['wants'] as bool?;
    if (wants != null) _wants = wants;
  }

  /// Calls the native side and dates the returned state at the middle of
  /// the round trip.
  Future<Map<String, dynamic>?> _call(String method, [Map<String, dynamic>? args]) async {
    final t0 = monotonicMicros();
    final r = await _channel.invokeMapMethod<String, dynamic>(method, args);
    final t1 = monotonicMicros();
    _apply(r, (t0 + t1) ~/ 2);
    return r;
  }

  Future<void> load(String path) async {
    _completed = false;
    _wants = false;
    final r = await _channel
        .invokeMapMethod<String, dynamic>('load', {'path': path})
        .timeout(const Duration(seconds: 15));
    durationMs = ((r?['durationMs'] as num?) ?? 0).toDouble();
    await _call('position');
  }

  Future<void> play() async {
    _completed = false;
    _wants = true;
    await _call('play');
    _startPolling();
  }

  Future<void> pause() async {
    _wants = false;
    await _call('pause');
  }

  Future<void> seek(double ms) async {
    _completed = false;
    _pos = ms;
    _posWall = monotonicMicros();
    await _call('seek', {'ms': ms.round()});
  }

  /// Playback speed. [pitch] 1 keeps the pitch (time-stretch); pass the
  /// speed again for a tape-style change.
  Future<void> setSpeed(double speed, {double pitch = 1.0}) async {
    _speed = speed;
    await _channel.invokeMethod('setSpeed', {'speed': speed, 'pitch': pitch});
  }

  Future<void> setVolume(double v) => _channel.invokeMethod('setVolume', {'volume': v});

  /// One fresh position report.
  Future<AudioSample> sample() async {
    final t0 = monotonicMicros();
    final r = await _channel.invokeMapMethod<String, dynamic>('position');
    final t1 = monotonicMicros();
    final mid = (t0 + t1) ~/ 2;
    _apply(r, mid);
    return AudioSample(_pos, mid);
  }

  void _startPolling() {
    if (_polling) return;
    _polling = true;
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      if (!_wants) {
        _poll?.cancel();
        _polling = false;
        return;
      }
      try {
        final s = await sample();
        if (_sounding) _samples.add(s);
      } catch (e) {
        debugPrint('MusicPlayer poll failed: $e');
      }
    });
  }

  // --- sound effects -----------------------------------------------------------------

  Future<bool> loadEffect(String name, String path) async =>
      await _channel.invokeMethod<bool>('sfxLoad', {'name': name, 'path': path}) ?? false;

  void playEffect(String name, {double volume = 1.0, double rate = 1.0}) {
    _channel.invokeMethod('sfxPlay', {'name': name, 'volume': volume, 'rate': rate});
  }
}

/// One long-lived music player shared by every screen.
///
/// Screens take an [AudioLease]; releasing an old lease never disturbs a
/// screen that took the player later.
class AppAudio {
  AppAudio._();

  static final instance = AppAudio._();

  int _lease = 0;

  MusicPlayer get player => MusicPlayer.instance;

  Future<AudioLease> open(String path) async {
    final lease = ++_lease;
    final p = MusicPlayer.instance;
    await p.pause();
    await p.load(path);
    await p.setSpeed(1.0);
    await p.setVolume(1.0);
    await p.seek(0);
    return AudioLease._(this, lease, p);
  }

  void _release(int lease) {
    if (lease != _lease) return;
    MusicPlayer.instance.pause();
  }
}

class AudioLease {
  AudioLease._(this._owner, this._id, this.player);

  final AppAudio _owner;
  final int _id;
  final MusicPlayer player;

  /// Whether no other screen has taken the player since.
  bool get current => _owner._lease == _id;

  /// Pauses the shared player if no other screen has taken it since.
  void release() => _owner._release(_id);

  /// Takes the player back after another screen used it (e.g. returning
  /// from a test play), so a later [release] pauses it again.
  void reclaim() => _owner._lease = _id;
}
