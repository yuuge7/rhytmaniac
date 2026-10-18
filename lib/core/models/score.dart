import 'dart:math' as math;

import 'difficulty.dart';

enum Judgment {
  perfect('Perfect', 1.0, 0.012, 300),
  great('Great', 0.8, 0.008, 100),
  good('Good', 0.5, 0.002, 50),
  miss('Miss', 0.0, -0.07, 0);

  const Judgment(this.label, this.accuracyWeight, this.healthDelta, this.scoreValue);

  final String label;
  final double accuracyWeight;
  final double healthDelta;

  /// Points before the combo bonus (osu!'s 300 / 100 / 50).
  final int scoreValue;

  bool get breaksCombo => this == miss;
}

enum Grade {
  ss('SS'),
  s('S'),
  a('A'),
  b('B'),
  c('C'),
  d('D'),
  f('F');

  const Grade(this.label);
  final String label;

  /// Accuracy (0..1) to grade. A failed run is always F.
  static Grade fromAccuracy(double acc, {bool failed = false}) {
    if (failed) return Grade.f;
    if (acc >= 0.98) return Grade.ss;
    if (acc >= 0.94) return Grade.s;
    if (acc >= 0.88) return Grade.a;
    if (acc >= 0.80) return Grade.b;
    if (acc >= 0.70) return Grade.c;
    return Grade.d;
  }
}

/// Gameplay modifiers chosen before a run, modelled on osu!'s.
class Mods {
  const Mods({
    this.rate = 1.0,
    this.noFail = false,
    this.hidden = false,
    this.mirror = false,
    this.autoplay = false,
    this.easy = false,
    this.hardRock = false,
    this.suddenDeath = false,
    this.perfect = false,
    this.flashlight = false,
    this.nightcore = false,
  });

  /// Music speed, 0.5..2.0. Pitch is kept unless [nightcore] is on.
  final double rate;
  final bool noFail;
  final bool hidden;
  final bool mirror;
  final bool autoplay;

  /// Bigger circles, slower approach, wider windows, gentler health.
  final bool easy;

  /// Smaller circles, faster approach, tighter windows, harsher health;
  /// Circles are flipped top to bottom.
  final bool hardRock;

  /// The first miss fails the run.
  final bool suddenDeath;

  /// Anything less than Perfect fails the run.
  final bool perfect;

  /// Only the area around your finger (Circles) or near the hit line (Tiles)
  /// is visible.
  final bool flashlight;

  /// The pitch rises and falls with the speed, like a tape.
  final bool nightcore;

  bool get isDefault =>
      rate == 1.0 &&
      !noFail &&
      !hidden &&
      !mirror &&
      !autoplay &&
      !easy &&
      !hardRock &&
      !suddenDeath &&
      !perfect &&
      !flashlight &&
      !nightcore;

  /// Pitch multiplier for the music player.
  double get pitch => nightcore ? rate : 1.0;

  /// Hit windows are multiplied by this (real milliseconds).
  double get windowFactor => easy ? 1.4 : (hardRock ? 0.72 : 1.0);

  /// Circle radius multiplier.
  double get sizeFactor => easy ? 1.3 : (hardRock ? 0.8 : 1.0);

  /// Approach time / scroll window multiplier.
  double get approachFactor => easy ? 1.25 : (hardRock ? 0.8 : 1.0);

  /// Health loss multiplier (misses and passive drain).
  double get drainFactor => easy ? 0.5 : (hardRock ? 1.4 : 1.0);

  /// Run ends on the first judgment that isn't good enough.
  bool get failsOnMistake => suddenDeath || perfect;

  /// osu!-style score multiplier.
  double get scoreMultiplier {
    if (autoplay) return 1.0;
    var m = 1.0;
    if (rate > 1.0) m *= 1 + 0.24 * (rate - 1);
    if (rate < 1.0) m *= math.max(0.3, 1 - 1.4 * (1 - rate));
    if (easy) m *= 0.5;
    if (noFail) m *= 0.5;
    if (hidden) m *= 1.06;
    if (hardRock) m *= 1.06;
    if (flashlight) m *= 1.12;
    return m;
  }

  Mods copyWith({
    double? rate,
    bool? noFail,
    bool? hidden,
    bool? mirror,
    bool? autoplay,
    bool? easy,
    bool? hardRock,
    bool? suddenDeath,
    bool? perfect,
    bool? flashlight,
    bool? nightcore,
  }) =>
      Mods(
        rate: rate ?? this.rate,
        noFail: noFail ?? this.noFail,
        hidden: hidden ?? this.hidden,
        mirror: mirror ?? this.mirror,
        autoplay: autoplay ?? this.autoplay,
        easy: easy ?? this.easy,
        hardRock: hardRock ?? this.hardRock,
        suddenDeath: suddenDeath ?? this.suddenDeath,
        perfect: perfect ?? this.perfect,
        flashlight: flashlight ?? this.flashlight,
        nightcore: nightcore ?? this.nightcore,
      );

  /// Short labels like "1.5×", "Hidden", "No-Fail".
  List<String> get labels => [
        if (rate != 1.0) '${_trim(rate)}×',
        if (nightcore) 'Nightcore',
        if (easy) 'Easy',
        if (hardRock) 'Hard Rock',
        if (hidden) 'Hidden',
        if (flashlight) 'Flashlight',
        if (mirror) 'Mirror',
        if (suddenDeath) 'Sudden Death',
        if (perfect) 'Perfect',
        if (noFail) 'No-Fail',
        if (autoplay) 'Auto',
      ];

  /// Two-letter osu!-style acronyms for tight spaces.
  List<String> get acronyms => [
        if (rate > 1.0) nightcore ? 'NC' : 'DT',
        if (rate < 1.0) 'HT',
        if (easy) 'EZ',
        if (hardRock) 'HR',
        if (hidden) 'HD',
        if (flashlight) 'FL',
        if (mirror) 'MR',
        if (suddenDeath) 'SD',
        if (perfect) 'PF',
        if (noFail) 'NF',
        if (autoplay) 'AT',
      ];

  static String _trim(double v) {
    final s = v.toStringAsFixed(2);
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  Map<String, dynamic> toJson() => {
        'rate': rate,
        'noFail': noFail,
        'hidden': hidden,
        'mirror': mirror,
        'autoplay': autoplay,
        if (easy) 'easy': true,
        if (hardRock) 'hardRock': true,
        if (suddenDeath) 'suddenDeath': true,
        if (perfect) 'perfect': true,
        if (flashlight) 'flashlight': true,
        if (nightcore) 'nightcore': true,
      };

  factory Mods.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const Mods();
    bool b(String k) => j[k] as bool? ?? false;
    return Mods(
      rate: (j['rate'] as num?)?.toDouble() ?? 1.0,
      noFail: b('noFail'),
      hidden: b('hidden'),
      mirror: b('mirror'),
      autoplay: b('autoplay'),
      easy: b('easy'),
      hardRock: b('hardRock'),
      suddenDeath: b('suddenDeath'),
      perfect: b('perfect'),
      flashlight: b('flashlight'),
      nightcore: b('nightcore'),
    );
  }
}

/// A finished (or failed) run, as stored in the scores database.
class ScoreRecord {
  const ScoreRecord({
    required this.id,
    required this.songId,
    required this.songHash,
    required this.beatmapId,
    required this.beatmapName,
    required this.mode,
    required this.stars,
    required this.score,
    required this.accuracy,
    required this.maxCombo,
    required this.counts,
    required this.mods,
    required this.grade,
    required this.failed,
    required this.timestamp,
    required this.durationMs,
    required this.meanErrorMs,
    required this.unstableRate,
    this.songTitle = '',
    this.songArtist = '',
    this.practice = false,
    this.hasReplay = false,
    this.formatVersion = currentFormatVersion,
  });

  /// 2: osu!-style mods, mod score multipliers, replays.
  /// 3: osu!-style classic score (combo bonus, no 1,000,000 cap).
  static const currentFormatVersion = 3;

  final int formatVersion;
  final String id;
  final String songId;

  /// Content hash of the song audio, so scores follow songs across devices.
  final String songHash;
  final String beatmapId;
  final String beatmapName;
  final GameMode mode;

  /// Star rating including the speed mod.
  final double stars;
  final int score;
  final double accuracy;
  final int maxCombo;
  final Map<Judgment, int> counts;
  final Mods mods;
  final Grade grade;
  final bool failed;
  final DateTime timestamp;
  final double durationMs;
  final double meanErrorMs;
  final double unstableRate;

  /// Copied at play time so the profile can show plays of songs that are
  /// not on this device.
  final String songTitle;
  final String songArtist;
  final bool practice;

  /// A replay file was saved next to the scores (`replays/<id>.json.gz`).
  final bool hasReplay;

  int count(Judgment j) => counts[j] ?? 0;

  bool get fullCombo => count(Judgment.miss) == 0 && !failed;

  /// "Pulse": a performance value used to rank plays on the profile.
  double get pulse {
    if (failed || practice || mods.autoplay) return 0;
    final accFactor = accuracy * accuracy * accuracy * accuracy;
    final fc = fullCombo ? 1.08 : 1.0;
    final nf = mods.noFail ? 0.9 : 1.0;
    final ez = mods.easy ? 0.5 : 1.0;
    final bonus = (mods.hidden ? 1.04 : 1.0) * (mods.hardRock ? 1.06 : 1.0) * (mods.flashlight ? 1.1 : 1.0);
    return 10 * stars * stars * accFactor * fc * nf * ez * bonus;
  }

  Map<String, dynamic> toJson() => {
        'formatVersion': formatVersion,
        'id': id,
        'songId': songId,
        'songHash': songHash,
        'beatmapId': beatmapId,
        'beatmapName': beatmapName,
        'mode': mode.name,
        'stars': stars,
        'score': score,
        'accuracy': accuracy,
        'maxCombo': maxCombo,
        'judgments': {for (final j in Judgment.values) j.name: count(j)},
        'mods': mods.toJson(),
        'grade': grade.name,
        'failed': failed,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'durationMs': durationMs,
        'meanErrorMs': meanErrorMs,
        'unstableRate': unstableRate,
        'songTitle': songTitle,
        'songArtist': songArtist,
        'practice': practice,
        if (hasReplay) 'hasReplay': true,
      };

  factory ScoreRecord.fromJson(Map<String, dynamic> j) {
    final js = (j['judgments'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ScoreRecord(
      formatVersion: j['formatVersion'] as int? ?? 1,
      id: j['id'] as String,
      songId: j['songId'] as String? ?? '',
      songHash: j['songHash'] as String? ?? '',
      beatmapId: j['beatmapId'] as String? ?? '',
      beatmapName: j['beatmapName'] as String? ?? '',
      mode: GameMode.values.asNameMap()[j['mode']] ?? GameMode.tiles,
      stars: (j['stars'] as num?)?.toDouble() ?? 0,
      score: (j['score'] as num?)?.toInt() ?? 0,
      accuracy: (j['accuracy'] as num?)?.toDouble() ?? 0,
      maxCombo: (j['maxCombo'] as num?)?.toInt() ?? 0,
      counts: {for (final jd in Judgment.values) jd: (js[jd.name] as num?)?.toInt() ?? 0},
      mods: Mods.fromJson((j['mods'] as Map?)?.cast<String, dynamic>()),
      grade: Grade.values.asNameMap()[j['grade']] ?? Grade.d,
      failed: j['failed'] as bool? ?? false,
      timestamp: DateTime.tryParse(j['timestamp'] as String? ?? '')?.toLocal() ?? DateTime.now(),
      durationMs: (j['durationMs'] as num?)?.toDouble() ?? 0,
      meanErrorMs: (j['meanErrorMs'] as num?)?.toDouble() ?? 0,
      unstableRate: (j['unstableRate'] as num?)?.toDouble() ?? 0,
      songTitle: j['songTitle'] as String? ?? '',
      songArtist: j['songArtist'] as String? ?? '',
      practice: j['practice'] as bool? ?? false,
      hasReplay: j['hasReplay'] as bool? ?? false,
    );
  }
}
