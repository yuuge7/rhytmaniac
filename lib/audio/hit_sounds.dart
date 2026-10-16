import 'package:audioplayers/audioplayers.dart';

/// Low-latency hit sounds (Android SoundPool) that never steal audio focus
/// from the music player.
class HitSounds {
  HitSounds._(this._hit, this._miss);

  final List<AudioPlayer> _hit;
  final List<AudioPlayer> _miss;
  int _next = 0;
  double volume = 0.6;

  static final _context = AudioContext(
    android: AudioContextAndroid(
      audioFocus: AndroidAudioFocus.none,
      usageType: AndroidUsageType.game,
      contentType: AndroidContentType.sonification,
    ),
  );

  static Future<HitSounds> load({double volume = 0.6}) async {
    Future<AudioPlayer> make(String asset) async {
      final p = AudioPlayer();
      await p.setAudioContext(_context);
      await p.setPlayerMode(PlayerMode.lowLatency);
      await p.setReleaseMode(ReleaseMode.stop);
      await p.setSource(AssetSource(asset));
      return p;
    }

    final hit = [for (var i = 0; i < 4; i++) await make('sfx/hit.wav')];
    final miss = [await make('sfx/miss.wav')];
    return HitSounds._(hit, miss)..volume = volume;
  }

  void hit() {
    final p = _hit[_next];
    _next = (_next + 1) % _hit.length;
    p.setVolume(volume);
    p.resume();
  }

  void miss() {
    final p = _miss.first;
    p.setVolume(volume * 0.7);
    p.resume();
  }

  Future<void> dispose() async {
    for (final p in [..._hit, ..._miss]) {
      await p.dispose();
    }
  }
}
