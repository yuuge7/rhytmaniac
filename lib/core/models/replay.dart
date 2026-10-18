import 'difficulty.dart';
import 'score.dart';

/// What a replay frame records.
enum ReplayAction {
  /// Circles: a finger touched down at (x, y).
  down,

  /// Circles: a finger moved to (x, y).
  move,

  /// Circles: a finger lifted.
  up,

  /// Tiles: lane [ReplayFrame.lane] went down.
  press,

  /// Tiles: lane [ReplayFrame.lane] came up.
  release,
}

class ReplayFrame {
  const ReplayFrame(this.timeMs, this.action, this.id, [this.x = 0, this.y = 0]);

  /// Song time of the input.
  final double timeMs;
  final ReplayAction action;

  /// Pointer id (Circles) or lane (Tiles).
  final int id;
  final double x;
  final double y;

  int get lane => id;
}

/// The inputs of one run. Playing them back through a fresh session gives
/// the same judgments, so a replay is just inputs plus what they were for.
///
/// Stored as `replays/<scoreId>.json.gz`:
/// `{ formatVersion, scoreId, beatmapId, mode, mods, player, createdAt, frames: [t, action, id, x, y, ...] }`
class Replay {
  Replay({
    required this.scoreId,
    required this.beatmapId,
    required this.mode,
    required this.mods,
    required this.player,
    required this.createdAt,
    required this.frames,
    this.formatVersion = currentFormatVersion,
  });

  static const currentFormatVersion = 1;

  final int formatVersion;
  final String scoreId;
  final String beatmapId;
  final GameMode mode;
  final Mods mods;
  final String player;
  final DateTime createdAt;
  final List<ReplayFrame> frames;

  Map<String, dynamic> toJson() {
    final flat = <num>[];
    for (final f in frames) {
      flat
        ..add((f.timeMs * 10).roundToDouble() / 10)
        ..add(f.action.index)
        ..add(f.id);
      if (f.action == ReplayAction.down || f.action == ReplayAction.move) {
        flat
          ..add((f.x * 10000).round() / 10000)
          ..add((f.y * 10000).round() / 10000);
      } else {
        flat
          ..add(0)
          ..add(0);
      }
    }
    return {
      'formatVersion': formatVersion,
      'scoreId': scoreId,
      'beatmapId': beatmapId,
      'mode': mode.name,
      'mods': mods.toJson(),
      'player': player,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'frames': flat,
    };
  }

  factory Replay.fromJson(Map<String, dynamic> j) {
    final version = j['formatVersion'] as int? ?? 1;
    if (version > currentFormatVersion) {
      throw FormatException('replay formatVersion $version is newer than supported');
    }
    final flat = (j['frames'] as List).cast<num>();
    final frames = <ReplayFrame>[];
    for (var i = 0; i + 4 < flat.length; i += 5) {
      final action = ReplayAction.values[flat[i + 1].toInt().clamp(0, ReplayAction.values.length - 1)];
      frames.add(ReplayFrame(flat[i].toDouble(), action, flat[i + 2].toInt(), flat[i + 3].toDouble(), flat[i + 4].toDouble()));
    }
    return Replay(
      formatVersion: version,
      scoreId: j['scoreId'] as String? ?? '',
      beatmapId: j['beatmapId'] as String? ?? '',
      mode: GameMode.values.asNameMap()[j['mode']] ?? GameMode.tiles,
      mods: Mods.fromJson((j['mods'] as Map?)?.cast<String, dynamic>()),
      player: j['player'] as String? ?? '',
      createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '')?.toLocal() ?? DateTime.now(),
      frames: frames,
    );
  }
}

/// Collects frames during a run. Moves are thinned to one per pointer every
/// [moveIntervalMs] unless the finger travelled far, which keeps replays
/// small without losing slider and spinner paths.
class ReplayRecorder {
  ReplayRecorder({this.moveIntervalMs = 12});

  final double moveIntervalMs;
  final List<ReplayFrame> frames = [];
  final Map<int, ReplayFrame> _lastMove = {};

  void add(ReplayFrame f) {
    if (f.action == ReplayAction.move) {
      final last = _lastMove[f.id];
      if (last != null) {
        final dx = f.x - last.x, dy = f.y - last.y;
        if (f.timeMs - last.timeMs < moveIntervalMs && dx * dx + dy * dy < 0.0004) return;
      }
      _lastMove[f.id] = f;
    } else if (f.action == ReplayAction.up) {
      _lastMove.remove(f.id);
    } else if (f.action == ReplayAction.down) {
      _lastMove[f.id] = f;
    }
    frames.add(f);
  }

  void clear() {
    frames.clear();
    _lastMove.clear();
  }
}
