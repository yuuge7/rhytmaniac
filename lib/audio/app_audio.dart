import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// One long-lived music player shared by every screen.
///
/// On Android, players created after an earlier one finished and was disposed
/// can stall forever while loading. Reusing a single instance (and only
/// swapping its source) avoids that entirely. Screens take a [AudioLease];
/// releasing an old lease never disturbs a screen that took the player later.
class AppAudio {
  AppAudio._();

  static final instance = AppAudio._();

  AudioPlayer? _player;
  String? _path;
  int _lease = 0;

  Future<AudioLease> open(String path) async {
    final lease = ++_lease;
    for (var attempt = 0; attempt < 2; attempt++) {
      final p = _player ??= AudioPlayer();
      try {
        await p.pause();
        if (_path != path || p.processingState == ProcessingState.idle) {
          await p.setFilePath(path).timeout(const Duration(seconds: 10));
          _path = path;
        }
        await p.setSpeed(1.0);
        await p.setVolume(1.0);
        await p.seek(Duration.zero);
        return AudioLease._(this, lease, p);
      } catch (e) {
        debugPrint('AppAudio.open attempt ${attempt + 1} failed: $e');
        // Last resort: start over with a fresh player.
        _path = null;
        final old = _player;
        _player = null;
        unawaited(old?.dispose().catchError((_) {}));
      }
    }
    throw Exception('Could not open the audio file');
  }

  void _release(int lease) {
    if (lease != _lease) return;
    _player?.pause();
  }
}

class AudioLease {
  AudioLease._(this._owner, this._id, this.player);

  final AppAudio _owner;
  final int _id;
  final AudioPlayer player;

  /// Pauses the shared player if no other screen has taken it since.
  void release() => _owner._release(_id);

  /// Takes the player back after another screen used it (e.g. returning
  /// from a test play), so a later [release] pauses it again.
  void reclaim() => _owner._lease = _id;
}
