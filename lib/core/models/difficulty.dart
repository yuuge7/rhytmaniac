import 'dart:math' as math;

enum GameMode {
  tiles('Tiles'),
  circles('Circles');

  const GameMode(this.label);
  final String label;
}

enum DifficultyPreset {
  easy('Easy'),
  normal('Normal'),
  hard('Hard'),
  insane('Insane'),
  expert('Expert'),
  custom('Custom');

  const DifficultyPreset(this.label);
  final String label;

  static const ladder = [easy, normal, hard, insane, expert];
}

/// Every knob the generator, rating and gameplay read. Presets are just
/// bundles of these values; "Custom" exposes them as sliders.
class DifficultyParams {
  const DifficultyParams({
    required this.preset,
    required this.strengthThreshold,
    required this.minGapMs,
    required this.snapDivisor,
    required this.hitWindow,
    required this.approachMs,
    required this.scrollSpeed,
    required this.circleSize,
    required this.lanes,
    required this.spacing,
    required this.chordAllowance,
    required this.jackAllowance,
    required this.holdFrequency,
    required this.playbackRate,
    required this.spinners,
    this.maxNotesPerSecond = 99,
    this.hpDrain = 5,
  });

  final DifficultyPreset preset;

  /// Minimum onset score (0..1) for a note to be placed.
  final double strengthThreshold;

  /// Minimum time between consecutive notes, in song milliseconds.
  final double minGapMs;

  /// 1, 2 or 4: finest beat division notes may land on.
  final int snapDivisor;

  /// Strictness 0 (lenient) .. 10 (strict). 5 gives the default windows.
  final double hitWindow;

  /// Circles: how long an approach circle takes to close, in ms.
  final double approachMs;

  /// Tiles: suggested scroll speed for this map.
  final double scrollSpeed;

  /// Circles: 0 (huge) .. 10 (tiny).
  final double circleSize;

  /// Tiles: lane count, 3..6.
  final int lanes;

  /// Circles: distance multiplier between consecutive notes.
  final double spacing;

  /// Tiles: 0..1 how often chords appear.
  final double chordAllowance;

  /// Tiles: 0..1 how often the same lane repeats quickly.
  final double jackAllowance;

  /// 0..1 how often sustained sounds become holds (Tiles) or sliders (Circles).
  final double holdFrequency;

  /// Music speed the map is meant to be played at, 0.5..2.0.
  final double playbackRate;

  /// Circles: whether spinners may be generated.
  final bool spinners;

  /// Density cap: weakest notes are dropped until the map is under this.
  final double maxNotesPerSecond;

  /// Health drain 0 (gentle) .. 10 (harsh): passive drain over time and how
  /// much a miss costs, like osu!'s HP setting.
  final double hpDrain;

  /// Perfect / Great / Good windows in real milliseconds.
  double get windowScale => 1.4 - 0.08 * hitWindow;

  /// Circle radius as a fraction of playfield width.
  double get circleRadius => 0.115 - 0.0055 * circleSize;

  DifficultyParams copyWith({
    DifficultyPreset? preset,
    double? strengthThreshold,
    double? minGapMs,
    int? snapDivisor,
    double? hitWindow,
    double? approachMs,
    double? scrollSpeed,
    double? circleSize,
    int? lanes,
    double? spacing,
    double? chordAllowance,
    double? jackAllowance,
    double? holdFrequency,
    double? playbackRate,
    bool? spinners,
    double? maxNotesPerSecond,
    double? hpDrain,
  }) =>
      DifficultyParams(
        preset: preset ?? this.preset,
        strengthThreshold: strengthThreshold ?? this.strengthThreshold,
        minGapMs: minGapMs ?? this.minGapMs,
        snapDivisor: snapDivisor ?? this.snapDivisor,
        hitWindow: hitWindow ?? this.hitWindow,
        approachMs: approachMs ?? this.approachMs,
        scrollSpeed: scrollSpeed ?? this.scrollSpeed,
        circleSize: circleSize ?? this.circleSize,
        lanes: lanes ?? this.lanes,
        spacing: spacing ?? this.spacing,
        chordAllowance: chordAllowance ?? this.chordAllowance,
        jackAllowance: jackAllowance ?? this.jackAllowance,
        holdFrequency: holdFrequency ?? this.holdFrequency,
        playbackRate: playbackRate ?? this.playbackRate,
        spinners: spinners ?? this.spinners,
        maxNotesPerSecond: maxNotesPerSecond ?? this.maxNotesPerSecond,
        hpDrain: hpDrain ?? this.hpDrain,
      );

  Map<String, dynamic> toJson() => {
        'preset': preset.name,
        'strengthThreshold': strengthThreshold,
        'minGapMs': minGapMs,
        'snapDivisor': snapDivisor,
        'hitWindow': hitWindow,
        'approachMs': approachMs,
        'scrollSpeed': scrollSpeed,
        'circleSize': circleSize,
        'lanes': lanes,
        'spacing': spacing,
        'chordAllowance': chordAllowance,
        'jackAllowance': jackAllowance,
        'holdFrequency': holdFrequency,
        'playbackRate': playbackRate,
        'spinners': spinners,
        'maxNotesPerSecond': maxNotesPerSecond,
        'hpDrain': hpDrain,
      };

  factory DifficultyParams.fromJson(Map<String, dynamic> j) {
    final base = DifficultyParams.preset(GameMode.tiles, DifficultyPreset.normal);
    double d(String k, double fallback) => (j[k] as num?)?.toDouble() ?? fallback;
    final preset = DifficultyPreset.values.asNameMap()[j['preset']] ?? DifficultyPreset.custom;
    // Maps saved before hpDrain existed get their preset's value.
    final presetLevel = DifficultyPreset.ladder.indexOf(preset);
    final defaultHp = presetLevel < 0 ? base.hpDrain : DifficultyParams.level(GameMode.tiles, presetLevel.toDouble()).hpDrain;
    return DifficultyParams(
      preset: preset,
      strengthThreshold: d('strengthThreshold', base.strengthThreshold),
      minGapMs: d('minGapMs', base.minGapMs),
      snapDivisor: (j['snapDivisor'] as num?)?.toInt() ?? base.snapDivisor,
      hitWindow: d('hitWindow', base.hitWindow),
      approachMs: d('approachMs', base.approachMs),
      scrollSpeed: d('scrollSpeed', base.scrollSpeed),
      circleSize: d('circleSize', base.circleSize),
      lanes: (j['lanes'] as num?)?.toInt() ?? base.lanes,
      spacing: d('spacing', base.spacing),
      chordAllowance: d('chordAllowance', base.chordAllowance),
      jackAllowance: d('jackAllowance', base.jackAllowance),
      holdFrequency: d('holdFrequency', base.holdFrequency),
      playbackRate: d('playbackRate', 1.0),
      spinners: j['spinners'] as bool? ?? true,
      maxNotesPerSecond: d('maxNotesPerSecond', 99),
      hpDrain: d('hpDrain', defaultHp),
    );
  }

  /// Preset bundles. Values were tuned with the rating calibration test so the
  /// ladder lands near 1, 2, 3, 4 and 5 stars on typical songs.
  factory DifficultyParams.preset(GameMode mode, DifficultyPreset preset, {int lanes = 4}) {
    final level = DifficultyPreset.ladder.indexOf(preset);
    return DifficultyParams.level(mode, level < 0 ? 1.0 : level.toDouble(), lanes: lanes)
        .copyWith(preset: preset);
  }

  /// Continuous difficulty: 0 = Easy, 1 = Normal ... 4 = Expert, up to 5 for
  /// beyond-Expert. Used by presets and by the "target stars" search.
  factory DifficultyParams.level(GameMode mode, double level, {int lanes = 4}) {
    final l = level.clamp(-0.5, 5.0);
    double lerp(List<double> stops) {
      // stops are values at levels 0..4; extrapolate linearly outside.
      if (l <= 0) return stops[0] + (stops[1] - stops[0]) * l;
      if (l >= 4) return stops[4] + (stops[4] - stops[3]) * (l - 4);
      final i = l.floor();
      final f = l - i;
      return stops[i] + (stops[i + 1] - stops[i]) * f;
    }

    final tiles = mode == GameMode.tiles;
    final threshold = lerp(tiles ? [0.50, 0.23, 0.16, 0.10, 0.045] : [0.50, 0.22, 0.17, 0.12, 0.06]);
    final minGap = lerp(tiles ? [520, 200, 150, 105, 72] : [540, 215, 165, 125, 90]);
    final divisor = l < 0.75 ? 1 : (l < 1.9 ? 2 : 4);
    return DifficultyParams(
      preset: DifficultyPreset.custom,
      strengthThreshold: threshold.clamp(0.0, 0.95),
      minGapMs: minGap.clamp(50.0, 1200.0),
      snapDivisor: divisor,
      hitWindow: lerp([3, 5, 6, 7, 8]).clamp(0.0, 10.0),
      approachMs: lerp([1500, 1200, 950, 750, 600]).clamp(300.0, 2400.0),
      scrollSpeed: lerp([1.6, 2.0, 2.4, 2.8, 3.2]).clamp(1.0, 5.0),
      circleSize: lerp([2.0, 3.0, 4.0, 4.5, 5.0]).clamp(0.0, 10.0),
      lanes: lanes,
      spacing: lerp([0.9, 1.1, 1.4, 1.95, 2.25]).clamp(0.3, 3.5),
      chordAllowance: lerp([0.0, 0.06, 0.22, 0.38, 0.6]).clamp(0.0, 1.0),
      jackAllowance: lerp([0.0, 0.0, 0.1, 0.25, 0.45]).clamp(0.0, 1.0),
      holdFrequency: lerp([0.30, 0.38, 0.42, 0.42, 0.40]).clamp(0.0, 1.0),
      playbackRate: 1.0,
      spinners: l >= 0.5,
      maxNotesPerSecond: lerp(tiles ? [1.3, 2.4, 3.6, 5.2, 7.5] : [1.2, 2.2, 3.2, 4.4, 6.0]).clamp(0.5, 20.0),
      hpDrain: lerp([2, 3.5, 5, 6, 7]).clamp(0.0, 10.0),
    );
  }

  /// Hit windows in real (unscaled) milliseconds.
  HitWindows get windows => HitWindows.fromScale(windowScale);
}

class HitWindows {
  const HitWindows({
    required this.perfect,
    required this.great,
    required this.good,
    required this.miss,
  });

  factory HitWindows.fromScale(double scale) {
    final s = math.max(0.3, scale);
    return HitWindows(perfect: 40 * s, great: 80 * s, good: 120 * s, miss: 160 * s);
  }

  final double perfect;
  final double great;
  final double good;

  /// Presses earlier than this are ignored; within it they count as a miss.
  final double miss;
}
