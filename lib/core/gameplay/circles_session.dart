import 'dart:math' as math;

import '../geometry/slider_curve.dart';
import '../models/beatmap.dart';
import '../models/difficulty.dart';
import '../models/score.dart';
import '../models/timing.dart';
import '../scoring/score_processor.dart';
import 'session.dart';

class CircleObjectState {
  CircleObjectState(this.object, this.comboNumber)
      : curve = SliderCurve.of(object),
        ticks = object.tickTimes(),
        repeatTimes = object.repeatTimes() {
    tickHit = List<bool?>.filled(ticks.length, null);
  }

  final CircleObject object;

  /// 1-based number shown inside the circle.
  final int comboNumber;
  final SliderCurve? curve;

  /// Slider tick and repeat times (song ms), and how each went.
  final List<double> ticks;
  late final List<bool?> tickHit;
  final List<double> repeatTimes;
  int nextTick = 0;
  int nextRepeat = 0;

  Judgment? head;
  Judgment? tail;

  /// Slider: milliseconds the ball was followed, and total tracked.
  double followedMs = 0;
  double trackedMs = 0;
  bool following = false;

  /// Spinner: accumulated rotation in radians, rotations past the required
  /// count, and a smoothed spin speed.
  double spun = 0;
  int bonusSpins = 0;
  double rpm = 0;

  /// Song time the head was hit (for fade-out animation).
  double? hitAt;

  bool get done {
    if (object.isSpinner) return tail != null;
    if (object.isSlider) return head != null && tail != null;
    return head != null;
  }

  /// Progress along the path (0..1) at song time [t], turning back at
  /// every repeat.
  double pathProgress(double t) {
    final o = object;
    if (o.endTimeMs == null || o.endTimeMs! <= o.timeMs) return 0;
    final passes = o.repeats + 1;
    final x = ((t - o.timeMs) / (o.endTimeMs! - o.timeMs)).clamp(0.0, 1.0) * passes;
    final pass = math.min(passes - 1, x.floor());
    final f = x - pass;
    return pass.isOdd ? 1 - f : f;
  }

  /// Ball position at song time [t], normalized.
  Point2 ballAt(double t) {
    final c = curve;
    if (c == null || object.endTimeMs == null) return Point2(object.x, object.y);
    return c.at(pathProgress(t));
  }
}

class _Pointer {
  _Pointer(this.pos);
  Point2 pos;
  double? lastAngle;
}

/// Rules for Circles mode. Positions are normalized playfield coordinates.
class CirclesSession extends GameSession {
  CirclesSession({
    required Beatmap map,
    required super.mods,
    required this.windows,
    double startTimeMs = double.negativeInfinity,
  })  : radius = map.difficulty.circleRadius * mods.sizeFactor,
        super(hpDrain: map.difficulty.hpDrain) {
    var number = 0;
    int? lastCombo;
    for (final raw in map.circleObjects) {
      var o = mods.mirror ? raw.mirrored() : raw;
      if (mods.hardRock) o = o.flipped();
      if (o.comboIndex != lastCombo) {
        number = 0;
        lastCombo = o.comboIndex;
      }
      number++;
      if (o.timeMs < startTimeMs) continue;
      objects.add(CircleObjectState(o, number));
    }
    _judge = Judge(windows);
    var end = 0.0;
    for (final o in objects) {
      if (o.object.endMs > end) end = o.object.endMs;
    }
    _endTimeMs = end;
    final spans = objects.map((o) => (o.object.timeMs, o.object.endMs));
    breaks = findMapBreaks(spans, mods.rate);
    final total = objects.fold(0, (s, o) => s + (o.object.isSlider ? 2 : 1));
    final ticks = objects.fold(0, (s, o) => s + o.ticks.length + o.repeatTimes.length);
    processor = GameSession.processorFor(
      judgments: total,
      ticks: ticks,
      hp: hpDrain,
      mods: mods,
      difficultyMultiplier: GameSession.scoreDifficultyFor(map.difficulty, size: map.difficulty.circleSize, spans: spans, breaks: breaks),
    );
  }

  final HitWindows windows;

  /// Circle radius as a fraction of playfield width.
  final double radius;
  final List<CircleObjectState> objects = [];
  @override
  late final ScoreProcessor processor;
  late final Judge _judge;
  final Map<int, _Pointer> _pointers = {};
  @override
  final List<HitFeedback> feedback = [];
  @override
  late final List<TimeSpan> breaks;
  late final double _endTimeMs;
  int _firstActive = 0;

  /// Autoplay cursor position, for drawing.
  Point2? autoCursor;

  double get _rate => mods.rate;
  double get followRadius => radius * 2.4;

  @override
  double get firstObjectMs => objects.isEmpty ? 0 : objects.first.object.timeMs;

  @override
  double get endTimeMs => _endTimeMs;

  Iterable<Point2> get pointerPositions => _pointers.values.map((p) => p.pos);

  void pointerDown(int id, Point2 pos, double timeMs) {
    _pointers[id] = _Pointer(pos);
    if (mods.autoplay) return;
    // Note lock: only the earliest unjudged hittable object may be hit.
    for (var i = _firstActive; i < objects.length; i++) {
      final s = objects[i];
      if (s.object.isSpinner || s.head != null) continue;
      final err = realMs(timeMs - s.object.timeMs, _rate);
      if (err < -windows.miss) return;
      if (playfieldDistance(pos, Point2(s.object.x, s.object.y)) <= radius * 1.08) {
        final j = _judge.judgePress(err);
        if (j != null) _judgeHead(s, j, timeMs, err);
      }
      return;
    }
  }

  void pointerMove(int id, Point2 pos, double timeMs) {
    final p = _pointers[id];
    if (p == null) return;
    p.pos = pos;
    if (mods.autoplay) return;
    _spin(p, timeMs);
  }

  void pointerUp(int id, double timeMs) {
    _pointers.remove(id);
  }

  double _lastSpinAt = double.nan;

  void _spin(_Pointer p, double timeMs) {
    for (var i = _firstActive; i < objects.length; i++) {
      final s = objects[i];
      if (s.object.timeMs > timeMs) break;
      if (!s.object.isSpinner || s.done || timeMs > s.object.endMs) continue;
      final dx = p.pos.x - 0.5;
      final dy = (p.pos.y - 0.5) * circlesYScale;
      final angle = math.atan2(dy, dx);
      final last = p.lastAngle;
      if (last != null) {
        var d = angle - last;
        while (d > math.pi) {
          d -= 2 * math.pi;
        }
        while (d < -math.pi) {
          d += 2 * math.pi;
        }
        _addSpin(s, d.abs(), timeMs);
      }
      p.lastAngle = angle;
      return;
    }
    p.lastAngle = null;
  }

  void _addSpin(CircleObjectState s, double radians, double timeMs) {
    final before = s.spun;
    s.spun += radians;
    final dt = _lastSpinAt.isNaN ? 0.0 : realMs(timeMs - _lastSpinAt, _rate);
    _lastSpinAt = timeMs;
    if (dt > 0 && dt < 250) {
      final rpm = radians / (2 * math.pi) / (dt / 60000);
      final k = math.min(1.0, dt / 300);
      s.rpm = s.rpm + (math.min(rpm, 600) - s.rpm) * k;
    }
    // Every full turn past the requirement is a bonus spin.
    final need = requiredSpins(s) * 2 * math.pi;
    final bonusBefore = math.max(0, ((before - need) / (2 * math.pi)).floor());
    final bonusNow = math.max(0, ((s.spun - need) / (2 * math.pi)).floor());
    if (bonusNow > bonusBefore) {
      s.bonusSpins = bonusNow;
      processor.bonus += 1000 * (bonusNow - bonusBefore);
      onEvent?.call(SessionEvent.spinBonus, null);
    }
  }

  /// Rotations a spinner needs: 1.25 per real second, at least one.
  double requiredSpins(CircleObjectState s) =>
      math.max(1.0, realMs(s.object.endMs - s.object.timeMs, _rate) / 1000 * 1.25);

  void _judgeHead(CircleObjectState s, Judgment j, double timeMs, double? err) {
    s.head = j;
    s.hitAt = timeMs;
    processor.apply(j, errorMs: err, timeMs: s.object.timeMs);
    _emit(HitFeedback(timeMs: timeMs, judgment: j, errorMs: err, position: Point2(s.object.x, s.object.y)));
  }

  void _judgeTail(CircleObjectState s, Judgment j, double timeMs) {
    s.tail = j;
    processor.apply(j);
    _emit(HitFeedback(timeMs: timeMs, judgment: j, position: s.object.endPosition, isRelease: true));
  }

  void _emit(HitFeedback f) {
    feedback.add(f);
    if (feedback.length > 48) feedback.removeRange(0, feedback.length - 48);
    onFeedback?.call(f);
  }

  bool _followed(Point2 ball) =>
      mods.autoplay || _pointers.values.any((p) => playfieldDistance(p.pos, ball) <= followRadius);

  double _lastUpdate = double.negativeInfinity;

  @override
  void update(double timeMs) {
    applyDrain(timeMs);
    final dt = _lastUpdate.isFinite ? math.max(0.0, timeMs - _lastUpdate) : 0.0;
    _lastUpdate = timeMs;
    final goodSong = windows.good * _rate;
    while (_firstActive < objects.length && objects[_firstActive].done) {
      _firstActive++;
    }
    if (mods.autoplay) _updateAutoCursor(timeMs);
    for (var i = _firstActive; i < objects.length; i++) {
      final s = objects[i];
      final o = s.object;
      if (o.timeMs > timeMs + windows.miss * _rate) break;
      if (s.done) continue;

      if (o.isSpinner) {
        if (mods.autoplay && timeMs >= o.timeMs && timeMs <= o.endMs) {
          _addSpin(s, realMs(dt, _rate) / 1000 * 2 * math.pi * 2.5, timeMs);
        }
        if (timeMs >= o.endMs) {
          final ratio = s.spun / (2 * math.pi) / requiredSpins(s);
          final j = ratio >= 1
              ? Judgment.perfect
              : ratio >= 0.75
                  ? Judgment.great
                  : ratio >= 0.5
                      ? Judgment.good
                      : Judgment.miss;
          s.head = j;
          _judgeTail(s, j, timeMs);
        }
        continue;
      }

      if (s.head == null) {
        if (mods.autoplay && timeMs >= o.timeMs) {
          _judgeHead(s, Judgment.perfect, o.timeMs, 0);
        } else if (timeMs - o.timeMs > goodSong) {
          _judgeHead(s, Judgment.miss, timeMs, null);
        }
      }

      if (o.isSlider && s.tail == null && timeMs >= o.timeMs) {
        // Ticks and repeats: the ball must be followed as it passes them.
        while (s.nextTick < s.ticks.length && s.ticks[s.nextTick] <= timeMs) {
          final at = s.ticks[s.nextTick];
          final hit = _followed(s.ballAt(at));
          s.tickHit[s.nextTick] = hit;
          s.nextTick++;
          processor.applyTick(hit);
          onEvent?.call(hit ? SessionEvent.tick : SessionEvent.tickMiss, s.ballAt(at));
        }
        while (s.nextRepeat < s.repeatTimes.length && s.repeatTimes[s.nextRepeat] <= timeMs) {
          final at = s.repeatTimes[s.nextRepeat];
          final hit = _followed(s.ballAt(at));
          s.nextRepeat++;
          processor.applyTick(hit, repeat: true);
          onEvent?.call(hit ? SessionEvent.repeat : SessionEvent.tickMiss, s.ballAt(at));
        }
        if (s.head != null) {
          final followed = _followed(s.ballAt(timeMs));
          s.following = followed;
          final step = math.min(dt, timeMs - o.timeMs);
          s.trackedMs += step;
          if (followed) s.followedMs += step;
        }
        if (timeMs >= o.endMs && s.head != null) {
          final total = math.max(1.0, s.trackedMs);
          final f = s.followedMs / total;
          final j = f >= 0.9
              ? Judgment.perfect
              : f >= 0.7
                  ? Judgment.great
                  : f >= 0.45
                      ? Judgment.good
                      : Judgment.miss;
          s.following = false;
          _judgeTail(s, j, o.endMs);
        }
      }
    }
  }

  void _updateAutoCursor(double t) {
    for (var i = _firstActive; i < objects.length; i++) {
      final s = objects[i];
      final o = s.object;
      if (o.isSpinner) {
        if (t >= o.timeMs && t <= o.endMs) {
          final a = t / 60;
          autoCursor = Point2(0.5 + 0.12 * math.cos(a), 0.5 + 0.12 / circlesYScale * math.sin(a));
          return;
        }
        continue;
      }
      if (t >= o.timeMs && t <= o.endMs) {
        autoCursor = s.ballAt(t);
        return;
      }
      if (t < o.timeMs) {
        // Glide from the previous object's end towards this one.
        final prev = i > 0 ? objects[i - 1].object : null;
        final from = prev?.endPosition ?? Point2(o.x, o.y);
        final start = prev?.endMs ?? (o.timeMs - 500);
        final f = ((t - start) / math.max(1, o.timeMs - start)).clamp(0.0, 1.0);
        final e = f * f * (3 - 2 * f);
        autoCursor = Point2(from.x + (o.x - from.x) * e, from.y + (o.y - from.y) * e);
        return;
      }
    }
  }
}
