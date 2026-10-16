import 'dart:math' as math;

import '../geometry/slider_curve.dart';
import '../models/beatmap.dart';
import '../models/difficulty.dart';

/// Simplified strain-based star rating in the spirit of osu!'s difficulty
/// calculation. Each object adds strain that decays over time; the peak strain
/// of every 400 ms section is collected, and the sorted peaks are summed with
/// geometric weights so sustained hard parts count more than a single spike.
///
/// Times are divided by the playback rate first, so speed mods raise stars.
double starRating(Beatmap map, {double? rate}) {
  final r = rate ?? map.difficulty.playbackRate;
  return map.mode == GameMode.tiles
      ? tilesStarRating(map.tileNotes, map.difficulty.lanes, rate: r)
      : circlesStarRating(map.circleObjects, map.difficulty, rate: r);
}

const _sectionMs = 400.0;
const _peakWeight = 0.9;

/// Calibration: raw strain is scaled, then bent by a power curve so the
/// preset ladder lands near 1, 2, 3, 4, 5 stars across varied test songs
/// (fitted in log space; see the rating calibration test).
const tilesStarScale = 0.0195;
const circlesStarScale = 0.84;

double _calibrate(double raw, double k, double gamma) => raw <= 0 ? 0 : k * math.pow(raw, gamma);

double _weightedPeaks(List<double> peaks) {
  final sorted = List<double>.of(peaks)..sort((a, b) => b.compareTo(a));
  var total = 0.0;
  var w = 1.0;
  for (final p in sorted) {
    total += p * w;
    w *= _peakWeight;
  }
  return total;
}

/// Tiles: per-lane strain (jacks), overall strain (density, chords) and a
/// hold bonus when notes land inside or across other holds.
double tilesStarRating(List<TileNote> notes, int lanes, {double rate = 1.0}) {
  if (notes.isEmpty) return 0;
  final sorted = List<TileNote>.of(notes)..sort((a, b) => a.timeMs.compareTo(b.timeMs));
  final laneCount = math.max(lanes, sorted.map((n) => n.lane).reduce(math.max) + 1);
  final individual = List<double>.filled(laneCount, 0);
  final holdEnds = List<double>.filled(laneCount, -1e9);
  var overall = 0.0;
  var prevTime = sorted.first.timeMs / rate;
  final peaks = <double>[];
  var sectionEnd = (prevTime / _sectionMs).floor() * _sectionMs + _sectionMs;
  var currentPeak = 0.0;

  for (final n in sorted) {
    final t = n.timeMs / rate;
    final end = n.endMs / rate;
    while (t > sectionEnd) {
      peaks.add(currentPeak);
      currentPeak = 0;
      sectionEnd += _sectionMs;
    }
    final dt = t - prevTime;
    var holdFactor = 1.0;
    var holdAddition = 0.0;
    for (var l = 0; l < laneCount; l++) {
      if (holdEnds[l] > t + 1 && holdEnds[l] < end - 1) holdAddition = 1.0;
      if (holdEnds[l] > end + 1) holdFactor = 1.25;
    }
    final indDecay = math.pow(0.125, dt / 1000).toDouble();
    for (var l = 0; l < laneCount; l++) {
      individual[l] *= indDecay;
    }
    individual[n.lane] += 2.0 * holdFactor;
    overall = overall * math.pow(0.30, dt / 1000) + (1 + holdAddition) * holdFactor;
    holdEnds[n.lane] = end;
    final strain = individual[n.lane] + overall;
    currentPeak = math.max(currentPeak, strain);
    prevTime = t;
  }
  peaks.add(currentPeak);
  return _calibrate(_weightedPeaks(peaks) * tilesStarScale, 1.39, 1.152);
}

/// Circles: aim strain (distance over time, including slider travel) and
/// speed strain (tapping rate, boosted by spacing). Distances are normalized
/// to the circle radius, so smaller circles rate harder.
double circlesStarRating(List<CircleObject> objects, DifficultyParams p, {double rate = 1.0}) {
  final hittable = objects.where((o) => !o.isSpinner).toList()
    ..sort((a, b) => a.timeMs.compareTo(b.timeMs));
  if (hittable.length < 2) return hittable.isEmpty ? 0 : 0.3;
  final radius = p.circleRadius;
  double norm(double widthUnits) => widthUnits / radius * 52;

  var aim = 0.0, speed = 0.0;
  final aimPeaks = <double>[], speedPeaks = <double>[];
  var prev = hittable.first;
  var prevTime = prev.timeMs / rate;
  var sectionEnd = (prevTime / _sectionMs).floor() * _sectionMs + _sectionMs;
  var aimPeak = 0.0, speedPeak = 0.0;

  for (var i = 1; i < hittable.length; i++) {
    final o = hittable[i];
    final t = o.timeMs / rate;
    while (t > sectionEnd) {
      aimPeaks.add(aimPeak);
      speedPeaks.add(speedPeak);
      aimPeak = 0;
      speedPeak = 0;
      sectionEnd += _sectionMs;
    }
    final strainTime = math.max(50.0, t - prevTime);
    final travel = prev.isSlider && prev.path != null ? norm(SliderCurve(prev.path!, samples: 16).length) : 0.0;
    final jump = norm(playfieldDistance(prev.endPosition, Point2(o.x, o.y)));
    final aimValue = (math.pow(travel, 0.99) + math.pow(jump, 0.99)) / strainTime;
    final spacing = math.min(125.0, travel + jump);
    final speedValue = (0.95 + math.pow(spacing / 125, 4)) / strainTime;

    final dt = t - prevTime;
    aim = aim * math.pow(0.15, dt / 1000) + aimValue * 26.25;
    speed = speed * math.pow(0.30, dt / 1000) + speedValue * 1400;
    aimPeak = math.max(aimPeak, aim);
    speedPeak = math.max(speedPeak, speed);
    prev = o;
    prevTime = t;
  }
  aimPeaks.add(aimPeak);
  speedPeaks.add(speedPeak);

  final aimRating = math.sqrt(_weightedPeaks(aimPeaks)) * 0.0675;
  final speedRating = math.sqrt(_weightedPeaks(speedPeaks)) * 0.0675;
  final stars = aimRating + speedRating + (aimRating - speedRating).abs() / 2;
  return _calibrate(stars * circlesStarScale, 1.04, 1.274);
}
