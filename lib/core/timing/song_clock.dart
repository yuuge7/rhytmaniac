/// Song clock driven by the audio position.
///
/// Audio players report position in coarse, jittery steps. Between reports
/// the clock extrapolates with a monotonic stopwatch at the playback rate,
/// and each report nudges it back toward the audio (big jumps snap). The
/// audio stays the master; frames never drive time.
class SongClock {
  SongClock({this.rate = 1.0, this.offsetMs = 0, int Function()? wallMicros})
      : _wallMicros = wallMicros ?? _defaultWall();

  /// Playback rate of the music.
  double rate;

  /// Audio offset: positive when sound reaches the ear late. Subtracted from
  /// the audio time so judgments line up with what the player hears.
  double offsetMs;

  final int Function() _wallMicros;

  double _anchorSong = 0;
  int _anchorWall = 0;
  bool _running = false;
  double _lastReturned = double.negativeInfinity;

  static const snapThresholdMs = 120.0;
  static const correctionFactor = 0.12;

  bool get running => _running;

  static int Function() _defaultWall() {
    final sw = Stopwatch()..start();
    return () => sw.elapsedMicroseconds;
  }

  /// Raw audio-domain time (before the offset).
  double get audioTimeMs {
    if (!_running) return _anchorSong;
    return _anchorSong + (_wallMicros() - _anchorWall) / 1000.0 * rate;
  }

  /// Song time used for gameplay and rendering. Never goes backwards while
  /// running, except after an explicit [seek].
  double get timeMs {
    final t = audioTimeMs - offsetMs;
    if (_running && t < _lastReturned) return _lastReturned;
    _lastReturned = t;
    return t;
  }

  /// Starts or restarts running from audio time [audioMs].
  void start(double audioMs) {
    _anchorSong = audioMs;
    _anchorWall = _wallMicros();
    _running = true;
    _lastReturned = double.negativeInfinity;
  }

  void pause() {
    if (!_running) return;
    _anchorSong = audioTimeMs;
    _running = false;
  }

  void resume() {
    if (_running) return;
    _anchorWall = _wallMicros();
    _running = true;
  }

  /// Jumps to [audioMs] (keeps running state).
  void seek(double audioMs) {
    _anchorSong = audioMs;
    _anchorWall = _wallMicros();
    _lastReturned = double.negativeInfinity;
  }

  /// Feeds a fresh audio position report. Returns the drift that was seen.
  double sync(double reportedAudioMs) {
    if (!_running) {
      _anchorSong = reportedAudioMs;
      return 0;
    }
    final now = _wallMicros();
    final predicted = _anchorSong + (now - _anchorWall) / 1000.0 * rate;
    final drift = reportedAudioMs - predicted;
    _anchorWall = now;
    if (drift.abs() > snapThresholdMs) {
      _anchorSong = reportedAudioMs;
      _lastReturned = double.negativeInfinity;
    } else {
      _anchorSong = predicted + drift * correctionFactor;
    }
    return drift;
  }
}
