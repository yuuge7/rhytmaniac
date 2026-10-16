import 'difficulty.dart';

enum Judgment {
  perfect('Perfect', 1.0, 0.012),
  great('Great', 0.8, 0.008),
  good('Good', 0.5, 0.002),
  miss('Miss', 0.0, -0.07);

  const Judgment(this.label, this.accuracyWeight, this.healthDelta);

  final String label;
  final double accuracyWeight;
  final double healthDelta;

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

/// Gameplay modifiers chosen before a run.
class Mods {
  const Mods({
    this.rate = 1.0,
    this.noFail = false,
    this.hidden = false,
    this.mirror = false,
    this.autoplay = false,
  });

  /// Music speed, 0.5..2.0 (pitch preserved).
  final double rate;
  final bool noFail;
  final bool hidden;
  final bool mirror;
  final bool autoplay;

  bool get isDefault => rate == 1.0 && !noFail && !hidden && !mirror && !autoplay;

  Mods copyWith({double? rate, bool? noFail, bool? hidden, bool? mirror, bool? autoplay}) => Mods(
        rate: rate ?? this.rate,
        noFail: noFail ?? this.noFail,
        hidden: hidden ?? this.hidden,
        mirror: mirror ?? this.mirror,
        autoplay: autoplay ?? this.autoplay,
      );

  /// Short labels like "1.5× · HD · NF".
  List<String> get labels => [
        if (rate != 1.0) '${_trim(rate)}×',
        if (hidden) 'Hidden',
        if (mirror) 'Mirror',
        if (noFail) 'No-Fail',
        if (autoplay) 'Auto',
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
      };

  factory Mods.fromJson(Map<String, dynamic>? j) => j == null
      ? const Mods()
      : Mods(
          rate: (j['rate'] as num?)?.toDouble() ?? 1.0,
          noFail: j['noFail'] as bool? ?? false,
          hidden: j['hidden'] as bool? ?? false,
          mirror: j['mirror'] as bool? ?? false,
          autoplay: j['autoplay'] as bool? ?? false,
        );
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
    this.formatVersion = 1,
  });

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

  int count(Judgment j) => counts[j] ?? 0;

  bool get fullCombo => count(Judgment.miss) == 0 && !failed;

  /// "Pulse": a performance value used to rank plays on the profile.
  double get pulse {
    if (failed || practice || mods.autoplay) return 0;
    final accFactor = accuracy * accuracy * accuracy * accuracy;
    final fc = fullCombo ? 1.08 : 1.0;
    final nf = mods.noFail ? 0.9 : 1.0;
    return 10 * stars * stars * accFactor * fc * nf;
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
    );
  }
}
