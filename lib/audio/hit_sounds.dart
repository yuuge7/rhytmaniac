import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_audio.dart';

/// Gameplay sound effects, played through the native SoundPool (low
/// latency, never takes audio focus from the music). One platform message
/// per sound.
class HitSounds {
  HitSounds._();

  static const _assets = {
    'hit': 'assets/sfx/hit.wav',
    'hit_soft': 'assets/sfx/hit_soft.wav',
    'miss': 'assets/sfx/miss.wav',
    'tick': 'assets/sfx/tick.wav',
    'spin': 'assets/sfx/spin.wav',
  };

  static bool _loaded = false;
  double volume = 0.6;

  /// Copies the bundled samples to disk once per launch and loads them.
  static Future<HitSounds> load({double volume = 0.6}) async {
    if (!_loaded) {
      final dir = Directory('${(await getTemporaryDirectory()).path}/sfx');
      await dir.create(recursive: true);
      for (final e in _assets.entries) {
        final f = File('${dir.path}/${e.key}.wav');
        try {
          final data = await rootBundle.load(e.value);
          await f.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
          await MusicPlayer.instance.loadEffect(e.key, f.path);
        } catch (_) {
          // A missing optional sample just stays silent.
        }
      }
      _loaded = true;
    }
    return HitSounds._()..volume = volume;
  }

  void _play(String name, double v, [double rate = 1.0]) {
    if (volume <= 0) return;
    MusicPlayer.instance.playEffect(name, volume: volume * v, rate: rate);
  }

  void hit({bool soft = false}) => _play(soft ? 'hit_soft' : 'hit', 1.0);

  void miss() => _play('miss', 0.7);

  void tick() => _play('tick', 0.55);

  /// Spinner bonus: pitch climbs with the spin count.
  void spin(int count) => _play('spin', 0.5, (1.0 + count * 0.04).clamp(1.0, 1.6));

  Future<void> dispose() async {}
}
