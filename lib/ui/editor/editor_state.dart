import 'package:flutter/material.dart';

import '../../core/generator/beatmap_generator.dart';
import '../../core/models/analysis.dart';
import '../../core/models/beatmap.dart';
import '../../core/models/difficulty.dart';

enum CircleTool {
  circle('Circle', Icons.radio_button_unchecked_rounded),
  slider('Slider', Icons.timeline_rounded),
  move('Move', Icons.open_with_rounded);

  const CircleTool(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Editing model shared by the Tiles and Circles editor views: the working
/// map, the playhead, snapping, selection range and an undo history of
/// whole-map snapshots (maps are small, so snapshots stay cheap and simple).
class EditorState extends ChangeNotifier {
  // ignore: prefer_initializing_formals
  EditorState({required Beatmap map, required this.analysis}) : _map = map;

  final SongAnalysis analysis;
  Beatmap _map;
  final List<Beatmap> _undo = [];
  final List<Beatmap> _redo = [];
  double timeMs = 0;
  bool playing = false;
  int snapDivisor = 4;
  double playbackRate = 1.0;
  double zoom = 0.25; // px per song ms (Tiles)
  CircleTool circleTool = CircleTool.circle;
  double sliderBeats = 1.0;
  double? rangeA;
  double? rangeB;
  bool dirty = false;
  String? savedId;

  Beatmap get map => _map;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get objectCount => _map.objectCount;
  double get beatMs => analysis.beatLengthMs;

  double snap(double t) => analysis.snap(t, snapDivisor).clamp(0.0, analysis.durationMs);

  void seek(double t) {
    timeMs = t.clamp(0.0, analysis.durationMs);
    notifyListeners();
  }

  void setTimeFromPlayback(double t) {
    timeMs = t.clamp(0.0, analysis.durationMs);
    notifyListeners();
  }

  void setSnap(int d) {
    snapDivisor = d;
    notifyListeners();
  }

  void setRate(double r) {
    playbackRate = r;
    notifyListeners();
  }

  void setZoom(double z) {
    zoom = z.clamp(0.06, 1.2);
    notifyListeners();
  }

  void setCircleTool(CircleTool t) {
    circleTool = t;
    notifyListeners();
  }

  void setSliderBeats(double b) {
    sliderBeats = b;
    notifyListeners();
  }

  void setRangeA(double t) {
    rangeA = t;
    if (rangeB != null && rangeB! < t) rangeB = null;
    notifyListeners();
  }

  void setRangeB(double t) {
    rangeB = t;
    if (rangeA != null && rangeA! > t) rangeA = null;
    notifyListeners();
  }

  void clearRange() {
    rangeA = null;
    rangeB = null;
    notifyListeners();
  }

  /// Replaces the map, recording the previous state for undo.
  void apply(Beatmap next) {
    _undo.add(_map);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
    _map = next;
    dirty = true;
    notifyListeners();
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_map);
    _map = _undo.removeLast();
    dirty = true;
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_map);
    _map = _redo.removeLast();
    dirty = true;
    notifyListeners();
  }

  void markSaved(Beatmap saved) {
    _map = saved;
    savedId = saved.id;
    dirty = false;
    notifyListeners();
  }

  // --- Tiles operations -----------------------------------------------------------

  static int _cmpTile(TileNote a, TileNote b) =>
      a.timeMs != b.timeMs ? a.timeMs.compareTo(b.timeMs) : a.lane.compareTo(b.lane);

  TileNote? tileAt(int lane, double t, double toleranceMs) {
    TileNote? best;
    for (final n in _map.tileNotes) {
      if (n.lane != lane) continue;
      final inside = n.isHold && t >= n.timeMs && t <= n.endMs;
      final d = (n.timeMs - t).abs();
      if (inside || d <= toleranceMs) {
        if (best == null || d < (best.timeMs - t).abs()) best = n;
      }
    }
    return best;
  }

  /// Adds a tap (or hold when [endMs] is later) unless it would overlap.
  bool addTile(int lane, double startMs, [double? endMs]) {
    final s = snap(startMs);
    var e = endMs == null ? null : snap(endMs);
    if (e != null && e - s < beatMs / snapDivisor * 0.99) e = null;
    final end = e ?? s;
    for (final n in _map.tileNotes) {
      if (n.lane == lane && n.timeMs <= end + 1 && n.endMs >= s - 1) return false;
    }
    final notes = [..._map.tileNotes, TileNote(timeMs: s, lane: lane, endTimeMs: e)]..sort(_cmpTile);
    apply(_map.copyWith(tileNotes: notes));
    return true;
  }

  void removeTile(TileNote note) {
    apply(_map.copyWith(tileNotes: _map.tileNotes.where((n) => !identical(n, note)).toList()));
  }

  // --- Circles operations ---------------------------------------------------------

  /// Objects drawn at the playhead (approaching or just passed).
  List<int> visibleCircleIndices() {
    final approach = _map.difficulty.approachMs;
    final out = <int>[];
    for (var i = 0; i < _map.circleObjects.length; i++) {
      final o = _map.circleObjects[i];
      if (o.timeMs - timeMs > approach) break;
      if (timeMs - o.endMs > 200) continue;
      out.add(i);
    }
    return out;
  }

  int _comboFor(double t) {
    var combo = 0;
    for (final o in _map.circleObjects) {
      if (o.timeMs > t) break;
      combo = o.comboIndex;
    }
    return combo;
  }

  void addCircle(Point2 p) {
    final t = snap(timeMs);
    final existing = _map.circleObjects.indexWhere((o) => (o.timeMs - t).abs() < 1);
    final obj = CircleObject(type: CircleObjectType.circle, timeMs: t, x: p.x, y: p.y, comboIndex: _comboFor(t));
    final list = [..._map.circleObjects];
    if (existing >= 0) {
      list[existing] = list[existing].copyWith(x: p.x, y: p.y);
    } else {
      list.add(obj);
    }
    list.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    apply(_map.copyWith(circleObjects: list));
  }

  void addSlider(Point2 from, Point2 to) {
    final t = snap(timeMs);
    final end = t + beatMs * sliderBeats;
    final mid = Point2((from.x + to.x) / 2, (from.y + to.y) / 2);
    final list = _map.circleObjects.where((o) => o.endMs < t - 1 || o.timeMs > end + 1).toList()
      ..add(CircleObject(
        type: CircleObjectType.slider,
        timeMs: t,
        x: from.x,
        y: from.y,
        comboIndex: _comboFor(t),
        path: [from, mid, to],
        endTimeMs: end,
      ))
      ..sort((a, b) => a.timeMs.compareTo(b.timeMs));
    apply(_map.copyWith(circleObjects: list));
  }

  void replaceCircle(int index, CircleObject o, {bool record = true}) {
    final list = [..._map.circleObjects];
    list[index] = o;
    if (record) {
      apply(_map.copyWith(circleObjects: list));
    } else {
      _map = _map.copyWith(circleObjects: list);
      dirty = true;
      notifyListeners();
    }
  }

  /// Starts a drag gesture: snapshot once so the whole drag is one undo step.
  void beginGesture() {
    _undo.add(_map);
    _redo.clear();
  }

  void removeCircle(int index) {
    final list = [..._map.circleObjects]..removeAt(index);
    apply(_map.copyWith(circleObjects: BeatmapGenerator.renumberCombos(list)));
  }

  /// Toggles "new combo" on an object by shifting following combo indices.
  void toggleNewCombo(int index) {
    final list = [..._map.circleObjects];
    if (index == 0) return;
    final starts = list[index].comboIndex != list[index - 1].comboIndex;
    final delta = starts ? -1 : 1;
    for (var i = index; i < list.length; i++) {
      list[i] = list[i].copyWith(comboIndex: list[i].comboIndex + delta);
    }
    apply(_map.copyWith(circleObjects: list));
  }

  /// Index of the circle object at the playhead, if any.
  int? circleAtPlayhead() {
    final objs = _map.circleObjects;
    for (var i = 0; i < objs.length; i++) {
      if ((objs[i].timeMs - timeMs).abs() < 2) return i;
    }
    return null;
  }

  GameMode get mode => _map.mode;
}
