import '../models/beatmap.dart';
import '../models/difficulty.dart';
import '../models/score.dart';
import '../models/timing.dart';
import '../scoring/score_processor.dart';
import 'session.dart';

class TileNoteState {
  TileNoteState(this.note);
  final TileNote note;
  Judgment? head;
  Judgment? tail;
  bool holding = false;

  /// Song time the hold was released early (for drawing a broken hold).
  double? releasedAt;

  bool get done => head != null && (!note.isHold || tail != null);
}

/// Rules for Tiles mode. All times are song milliseconds; windows are scaled
/// by the playback rate so they stay constant in real time.
class TilesSession extends GameSession {
  TilesSession({
    required Beatmap map,
    required super.mods,
    required this.windows,
    double startTimeMs = double.negativeInfinity,
  })  : lanes = map.difficulty.lanes.clamp(1, 10),
        super(hpDrain: map.difficulty.hpDrain) {
    final source = mods.mirror
        ? map.tileNotes.map((n) => n.copyWith(lane: lanes - 1 - n.lane)).toList()
        : map.tileNotes;
    for (final n in source) {
      if (n.timeMs < startTimeMs || n.lane < 0 || n.lane >= lanes) continue;
      notes.add(TileNoteState(n));
    }
    notes.sort((a, b) => a.note.timeMs.compareTo(b.note.timeMs));
    _judge = Judge(windows);
    _laneNotes = List.generate(lanes, (l) => [for (final n in notes) if (n.note.lane == l) n]);
    _laneCursor = List.filled(lanes, 0);
    laneDown = List.filled(lanes, false);
    var end = 0.0;
    for (final n in notes) {
      if (n.note.endMs > end) end = n.note.endMs;
    }
    _endTimeMs = end;
    final spans = notes.map((n) => (n.note.timeMs, n.note.endMs));
    breaks = findMapBreaks(spans, mods.rate);
    final total = notes.fold(0, (s, n) => s + (n.note.isHold ? 2 : 1));
    processor = GameSession.processorFor(
      judgments: total,
      hp: hpDrain,
      mods: mods,
      difficultyMultiplier: GameSession.scoreDifficultyFor(map.difficulty, size: lanes.toDouble(), spans: spans, breaks: breaks),
    );
  }

  final int lanes;
  final HitWindows windows;
  final List<TileNoteState> notes = [];
  @override
  late final ScoreProcessor processor;
  late final Judge _judge;
  late final List<List<TileNoteState>> _laneNotes;
  late final List<int> _laneCursor;
  late final List<bool> laneDown;
  @override
  final List<HitFeedback> feedback = [];
  @override
  late final List<TimeSpan> breaks;
  late final double _endTimeMs;
  int _firstActive = 0;

  double get _rate => mods.rate;

  /// Index of the first note that still needs drawing or judging.
  int get firstActive => _firstActive;

  @override
  double get firstObjectMs => notes.isEmpty ? 0 : notes.first.note.timeMs;

  @override
  double get endTimeMs => _endTimeMs;

  /// Next note in [lane] whose head hasn't been judged.
  TileNoteState? _nextInLane(int lane) {
    final list = _laneNotes[lane];
    var i = _laneCursor[lane];
    while (i < list.length && list[i].head != null) {
      i++;
    }
    _laneCursor[lane] = i;
    return i < list.length ? list[i] : null;
  }

  /// The lane a touch [x] lanes across the field means (0 is the left edge
  /// of lane 0). Normally the lane under the finger. Near the edge it
  /// shares with another lane, a finger that would hit nothing in its own
  /// lane counts for the neighbour when a note there can be hit right now:
  /// in fast stairs and chords, thumbs rarely land dead centre.
  int laneFor(double x, double timeMs) {
    final lane = x.floor().clamp(0, lanes - 1);
    if (mods.autoplay) return lane;
    final frac = x - lane;
    const edge = 0.3;
    final neighbour = frac < edge ? lane - 1 : (frac > 1 - edge ? lane + 1 : -1);
    if (neighbour < 0 || neighbour >= lanes) return lane;
    if (_hittable(lane, timeMs)) return lane;
    return _hittable(neighbour, timeMs) ? neighbour : lane;
  }

  /// Whether a press in [lane] at [timeMs] would hit its next note.
  bool _hittable(int lane, double timeMs) {
    final n = _nextInLane(lane);
    if (n == null) return false;
    return realMs(timeMs - n.note.timeMs, _rate).abs() <= windows.good;
  }

  void press(int lane, double timeMs) {
    if (lane < 0 || lane >= lanes) return;
    laneDown[lane] = true;
    if (mods.autoplay) return;
    final n = _nextInLane(lane);
    if (n == null) return;
    final err = realMs(timeMs - n.note.timeMs, _rate);
    final j = _judge.judgePress(err);
    if (j == null) return;
    _judgeHead(n, j, timeMs, err);
  }

  void release(int lane, double timeMs) {
    if (lane < 0 || lane >= lanes) return;
    laneDown[lane] = false;
    if (mods.autoplay) return;
    for (final n in _laneNotes[lane]) {
      if (n.holding) {
        _releaseHold(n, timeMs);
        break;
      }
    }
  }

  void _judgeHead(TileNoteState n, Judgment j, double timeMs, double? err) {
    n.head = j;
    processor.apply(j, errorMs: err, timeMs: n.note.timeMs);
    _emit(HitFeedback(timeMs: timeMs, judgment: j, errorMs: err, lane: n.note.lane));
    if (n.note.isHold) {
      if (j == Judgment.miss) {
        _judgeTail(n, Judgment.miss, timeMs);
      } else {
        n.holding = true;
      }
    }
  }

  void _releaseHold(TileNoteState n, double timeMs) {
    n.holding = false;
    final err = realMs(timeMs - n.note.endMs, _rate);
    if (err < -windows.good * 1.5) {
      n.releasedAt = timeMs;
      _judgeTail(n, Judgment.miss, timeMs);
    } else {
      _judgeTail(n, _judge.judgeRelease(err), timeMs, err);
    }
  }

  void _judgeTail(TileNoteState n, Judgment j, double timeMs, [double? err]) {
    n.tail = j;
    n.holding = false;
    processor.apply(j);
    _emit(HitFeedback(timeMs: timeMs, judgment: j, errorMs: err, lane: n.note.lane, isRelease: true));
  }

  void _emit(HitFeedback f) {
    feedback.add(f);
    if (feedback.length > 48) feedback.removeRange(0, feedback.length - 48);
    onFeedback?.call(f);
  }

  @override
  void update(double timeMs) {
    applyDrain(timeMs);
    final goodSong = windows.good * _rate;
    while (_firstActive < notes.length && notes[_firstActive].done) {
      _firstActive++;
    }
    for (var i = _firstActive; i < notes.length; i++) {
      final n = notes[i];
      if (n.note.timeMs > timeMs + windows.miss * _rate) break;
      if (n.done) continue;
      if (mods.autoplay) {
        if (n.head == null && timeMs >= n.note.timeMs) {
          laneDown[n.note.lane] = true;
          _judgeHead(n, Judgment.perfect, n.note.timeMs, 0);
          if (!n.note.isHold) laneDown[n.note.lane] = false;
        }
        if (n.holding && timeMs >= n.note.endMs) {
          laneDown[n.note.lane] = false;
          n.holding = false;
          _judgeTail(n, Judgment.perfect, n.note.endMs, 0);
        }
        continue;
      }
      if (n.head == null && timeMs - n.note.timeMs > goodSong) {
        _judgeHead(n, Judgment.miss, timeMs, null);
        continue;
      }
      // Held far past the tail: the hold ends without a timed release.
      if (n.holding && timeMs - n.note.endMs > goodSong * 1.5) {
        _judgeTail(n, Judgment.good, timeMs);
      }
    }
  }
}
