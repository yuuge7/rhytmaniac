import 'difficulty.dart';

enum AnalysisStatus { pending, ready, failed }

/// Library entry for an imported song. Big blobs (audio, analysis, maps) live
/// as files in the song's folder; this record is the index.
class Song {
  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.durationMs,
    required this.bpm,
    required this.addedAt,
    required this.sourceFile,
    required this.contentHash,
    this.hasVideo = false,
    this.coverFile,
    this.offsetMs = 0,
    this.playCount = 0,
    this.lastPlayedAt,
    this.status = AnalysisStatus.pending,
    this.fingerprint = const [],
    this.isDemo = false,
  });

  final String id;
  final String title;
  final String artist;
  final double durationMs;
  final double bpm;
  final DateTime addedAt;

  /// File name of the imported media inside the song folder.
  final String sourceFile;
  final String contentHash;
  final bool hasVideo;
  final String? coverFile;

  /// Per-song audio offset in ms, added to the global offset.
  final double offsetMs;
  final int playCount;
  final DateTime? lastPlayedAt;
  final AnalysisStatus status;

  /// 3-band loudness columns for the signal strip artwork.
  final List<List<double>> fingerprint;
  final bool isDemo;

  Song copyWith({
    String? title,
    String? artist,
    double? durationMs,
    double? bpm,
    bool? hasVideo,
    String? coverFile,
    double? offsetMs,
    int? playCount,
    DateTime? lastPlayedAt,
    AnalysisStatus? status,
    List<List<double>>? fingerprint,
  }) =>
      Song(
        id: id,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        durationMs: durationMs ?? this.durationMs,
        bpm: bpm ?? this.bpm,
        addedAt: addedAt,
        sourceFile: sourceFile,
        contentHash: contentHash,
        hasVideo: hasVideo ?? this.hasVideo,
        coverFile: coverFile ?? this.coverFile,
        offsetMs: offsetMs ?? this.offsetMs,
        playCount: playCount ?? this.playCount,
        lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
        status: status ?? this.status,
        fingerprint: fingerprint ?? this.fingerprint,
        isDemo: isDemo,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'durationMs': durationMs,
        'bpm': bpm,
        'addedAt': addedAt.toUtc().toIso8601String(),
        'sourceFile': sourceFile,
        'contentHash': contentHash,
        'hasVideo': hasVideo,
        'coverFile': coverFile,
        'offsetMs': offsetMs,
        'playCount': playCount,
        'lastPlayedAt': lastPlayedAt?.toUtc().toIso8601String(),
        'status': status.name,
        'fingerprint': fingerprint,
        'isDemo': isDemo,
      };

  factory Song.fromJson(Map<String, dynamic> j) => Song(
        id: j['id'] as String,
        title: j['title'] as String? ?? 'Untitled',
        artist: j['artist'] as String? ?? '',
        durationMs: (j['durationMs'] as num?)?.toDouble() ?? 0,
        bpm: (j['bpm'] as num?)?.toDouble() ?? 0,
        addedAt: DateTime.tryParse(j['addedAt'] as String? ?? '')?.toLocal() ?? DateTime.now(),
        sourceFile: j['sourceFile'] as String,
        contentHash: j['contentHash'] as String? ?? '',
        hasVideo: j['hasVideo'] as bool? ?? false,
        coverFile: j['coverFile'] as String?,
        offsetMs: (j['offsetMs'] as num?)?.toDouble() ?? 0,
        playCount: (j['playCount'] as num?)?.toInt() ?? 0,
        lastPlayedAt: DateTime.tryParse(j['lastPlayedAt'] as String? ?? '')?.toLocal(),
        status: AnalysisStatus.values.asNameMap()[j['status']] ?? AnalysisStatus.pending,
        fingerprint: (j['fingerprint'] as List? ?? const [])
            .map((c) => (c as List).map((v) => (v as num).toDouble()).toList())
            .toList(),
        isDemo: j['isDemo'] as bool? ?? false,
      );
}

/// Library index entry for one difficulty file.
class BeatmapSummary {
  const BeatmapSummary({
    required this.id,
    required this.songId,
    required this.mode,
    required this.name,
    required this.stars,
    required this.preset,
    required this.edited,
    required this.objectCount,
    required this.createdAt,
    required this.lanes,
  });

  final String id;
  final String songId;
  final GameMode mode;
  final String name;
  final double stars;
  final DifficultyPreset preset;
  final bool edited;
  final int objectCount;
  final DateTime createdAt;
  final int lanes;

  Map<String, dynamic> toJson() => {
        'id': id,
        'songId': songId,
        'mode': mode.name,
        'name': name,
        'stars': stars,
        'preset': preset.name,
        'edited': edited,
        'objectCount': objectCount,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'lanes': lanes,
      };

  factory BeatmapSummary.fromJson(Map<String, dynamic> j) => BeatmapSummary(
        id: j['id'] as String,
        songId: j['songId'] as String,
        mode: GameMode.values.asNameMap()[j['mode']] ?? GameMode.tiles,
        name: j['name'] as String? ?? '',
        stars: (j['stars'] as num?)?.toDouble() ?? 0,
        preset: DifficultyPreset.values.asNameMap()[j['preset']] ?? DifficultyPreset.custom,
        edited: j['edited'] as bool? ?? false,
        objectCount: (j['objectCount'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '')?.toLocal() ?? DateTime.now(),
        lanes: (j['lanes'] as num?)?.toInt() ?? 4,
      );
}
