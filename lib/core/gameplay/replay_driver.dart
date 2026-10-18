import '../models/beatmap.dart';
import '../models/replay.dart';
import 'circles_session.dart';
import 'session.dart';
import 'tiles_session.dart';

/// Plays recorded inputs into a fresh session.
///
/// Every frame is applied at its own song time, after the session has been
/// advanced to that time, exactly as live input is handled; so the same
/// inputs give the same judgments whatever the frame rate.
class ReplayDriver {
  ReplayDriver(this.frames, this.session);

  final List<ReplayFrame> frames;
  final GameSession session;
  int _cursor = 0;

  /// Called for Circles pointer frames (for the touch trail).
  void Function(int pointer, Point2 position, double timeMs)? onPointer;

  bool get done => _cursor >= frames.length;

  /// Applies every frame up to song time [t].
  void advanceTo(double t) {
    final s = session;
    while (_cursor < frames.length && frames[_cursor].timeMs <= t) {
      final f = frames[_cursor++];
      s.update(f.timeMs);
      if (s is TilesSession) {
        if (f.action == ReplayAction.press) s.press(f.lane, f.timeMs);
        if (f.action == ReplayAction.release) s.release(f.lane, f.timeMs);
      } else if (s is CirclesSession) {
        final p = Point2(f.x, f.y);
        switch (f.action) {
          case ReplayAction.down:
            onPointer?.call(f.id, p, f.timeMs);
            s.pointerDown(f.id, p, f.timeMs);
          case ReplayAction.move:
            onPointer?.call(f.id, p, f.timeMs);
            s.pointerMove(f.id, p, f.timeMs);
          case ReplayAction.up:
            s.pointerUp(f.id, f.timeMs);
          case ReplayAction.press:
          case ReplayAction.release:
            break;
        }
      }
    }
  }

  void reset() => _cursor = 0;
}
