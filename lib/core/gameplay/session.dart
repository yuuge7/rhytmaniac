import '../models/beatmap.dart';
import '../models/score.dart';
import '../scoring/score_processor.dart';

/// Something the renderer and feedback layer (haptics, sounds) react to.
class HitFeedback {
  const HitFeedback({
    required this.timeMs,
    required this.judgment,
    this.errorMs,
    this.lane,
    this.position,
    this.isRelease = false,
  });

  /// Song time when the judgment happened.
  final double timeMs;
  final Judgment judgment;
  final double? errorMs;
  final int? lane;
  final Point2? position;
  final bool isRelease;
}

/// Shared interface of the per-mode gameplay rules.
abstract class GameSession {
  ScoreProcessor get processor;

  /// Advances to song time [timeMs]: detects misses, finishes holds and
  /// sliders, and plays objects when autoplay is on.
  void update(double timeMs);

  /// Song time after which nothing is left to judge.
  double get endTimeMs;

  /// Recent feedback, newest last. The renderer prunes old entries.
  List<HitFeedback> get feedback;

  /// Called for each judgment as it happens.
  void Function(HitFeedback)? onFeedback;

  bool get complete => processor.finished;
}

/// Converts a song-time delta into real milliseconds at a playback rate.
double realMs(double songDeltaMs, double rate) => songDeltaMs / rate;
