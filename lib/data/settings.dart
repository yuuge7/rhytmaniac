enum JudgmentDisplay {
  full('Full'),
  minimal('Minimal'),
  off('Off');

  const JudgmentDisplay(this.label);
  final String label;
}

/// Global, persisted player settings.
class AppSettings {
  const AppSettings({
    this.globalOffsetMs = 0,
    this.scrollSpeed = 1.0,
    this.hitSounds = true,
    this.hitSoundVolume = 0.6,
    this.musicVolume = 1.0,
    this.haptics = true,
    this.defaultLanes = 4,
    this.judgmentDisplay = JudgmentDisplay.full,
    this.showHitErrorBar = true,
    this.showFps = false,
    this.exportFolderUri,
    this.exportFolderName,
    this.demoInstalled = false,
    this.previewMusic = true,
  });

  /// Audio latency compensation in ms (positive: sound reaches you late).
  final double globalOffsetMs;

  /// Tiles: personal multiplier on each map's scroll speed. Applied in real
  /// time, so it is independent of the song speed.
  final double scrollSpeed;
  final bool hitSounds;
  final double hitSoundVolume;
  final double musicVolume;
  final bool haptics;
  final int defaultLanes;
  final JudgmentDisplay judgmentDisplay;
  final bool showHitErrorBar;
  final bool showFps;

  /// Folder chosen for exports (SAF tree URI). Null = Download/Rhytmaniac.
  final String? exportFolderUri;
  final String? exportFolderName;
  final bool demoInstalled;

  /// Play the song (from its preview point) on the song screen.
  final bool previewMusic;

  /// Visible time window (real ms) of the Tiles lane for a map's speed.
  double tilesVisibleMs(double mapScrollSpeed) => 2600 / (mapScrollSpeed * scrollSpeed).clamp(0.4, 12.0);

  AppSettings copyWith({
    double? globalOffsetMs,
    double? scrollSpeed,
    bool? hitSounds,
    double? hitSoundVolume,
    double? musicVolume,
    bool? haptics,
    int? defaultLanes,
    JudgmentDisplay? judgmentDisplay,
    bool? showHitErrorBar,
    bool? showFps,
    String? exportFolderUri,
    String? exportFolderName,
    bool clearExportFolder = false,
    bool? demoInstalled,
    bool? previewMusic,
  }) =>
      AppSettings(
        globalOffsetMs: globalOffsetMs ?? this.globalOffsetMs,
        scrollSpeed: scrollSpeed ?? this.scrollSpeed,
        hitSounds: hitSounds ?? this.hitSounds,
        hitSoundVolume: hitSoundVolume ?? this.hitSoundVolume,
        musicVolume: musicVolume ?? this.musicVolume,
        haptics: haptics ?? this.haptics,
        defaultLanes: defaultLanes ?? this.defaultLanes,
        judgmentDisplay: judgmentDisplay ?? this.judgmentDisplay,
        showHitErrorBar: showHitErrorBar ?? this.showHitErrorBar,
        showFps: showFps ?? this.showFps,
        exportFolderUri: clearExportFolder ? null : (exportFolderUri ?? this.exportFolderUri),
        exportFolderName: clearExportFolder ? null : (exportFolderName ?? this.exportFolderName),
        demoInstalled: demoInstalled ?? this.demoInstalled,
        previewMusic: previewMusic ?? this.previewMusic,
      );

  Map<String, dynamic> toJson() => {
        'formatVersion': 1,
        'globalOffsetMs': globalOffsetMs,
        'scrollSpeed': scrollSpeed,
        'hitSounds': hitSounds,
        'hitSoundVolume': hitSoundVolume,
        'musicVolume': musicVolume,
        'haptics': haptics,
        'defaultLanes': defaultLanes,
        'judgmentDisplay': judgmentDisplay.name,
        'showHitErrorBar': showHitErrorBar,
        'showFps': showFps,
        'exportFolderUri': exportFolderUri,
        'exportFolderName': exportFolderName,
        'demoInstalled': demoInstalled,
        'previewMusic': previewMusic,
      };

  /// Settings that travel with a profile export (device-specific ones don't).
  Map<String, dynamic> portableJson() => toJson()
    ..remove('exportFolderUri')
    ..remove('exportFolderName')
    ..remove('demoInstalled');

  factory AppSettings.fromJson(Map<String, dynamic>? j, {AppSettings? base}) {
    final b = base ?? const AppSettings();
    if (j == null) return b;
    double d(String k, double f) => (j[k] as num?)?.toDouble() ?? f;
    return AppSettings(
      globalOffsetMs: d('globalOffsetMs', b.globalOffsetMs),
      scrollSpeed: d('scrollSpeed', b.scrollSpeed),
      hitSounds: j['hitSounds'] as bool? ?? b.hitSounds,
      hitSoundVolume: d('hitSoundVolume', b.hitSoundVolume),
      musicVolume: d('musicVolume', b.musicVolume),
      haptics: j['haptics'] as bool? ?? b.haptics,
      defaultLanes: (j['defaultLanes'] as num?)?.toInt() ?? b.defaultLanes,
      judgmentDisplay: JudgmentDisplay.values.asNameMap()[j['judgmentDisplay']] ?? b.judgmentDisplay,
      showHitErrorBar: j['showHitErrorBar'] as bool? ?? b.showHitErrorBar,
      showFps: j['showFps'] as bool? ?? b.showFps,
      exportFolderUri: j.containsKey('exportFolderUri') ? j['exportFolderUri'] as String? : b.exportFolderUri,
      exportFolderName: j.containsKey('exportFolderName') ? j['exportFolderName'] as String? : b.exportFolderName,
      demoInstalled: j['demoInstalled'] as bool? ?? b.demoInstalled,
      previewMusic: j['previewMusic'] as bool? ?? b.previewMusic,
    );
  }
}

/// The player's identity on this device.
class PlayerProfile {
  const PlayerProfile({required this.name, required this.createdAt, required this.avatarSeed});

  final String name;
  final DateTime createdAt;
  final int avatarSeed;

  PlayerProfile copyWith({String? name, int? avatarSeed}) =>
      PlayerProfile(name: name ?? this.name, createdAt: createdAt, avatarSeed: avatarSeed ?? this.avatarSeed);

  Map<String, dynamic> toJson() => {
        'name': name,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'avatarSeed': avatarSeed,
      };

  factory PlayerProfile.fromJson(Map<String, dynamic>? j) => PlayerProfile(
        name: j?['name'] as String? ?? 'Player',
        createdAt: DateTime.tryParse(j?['createdAt'] as String? ?? '')?.toLocal() ?? DateTime.now(),
        avatarSeed: (j?['avatarSeed'] as num?)?.toInt() ?? 7,
      );
}
