/// Medals unlocked (with when) and counters for medal goals that scores
/// don't record. Stored in the key-value store as `progress`, and travels
/// with profile exports.
///
/// `{ formatVersion, medals: { id: iso time }, counters: { name: count } }`
class Progress {
  const Progress({this.medals = const {}, this.counters = const {}});

  static const formatVersion = 1;

  final Map<String, DateTime> medals;
  final Map<String, int> counters;

  Progress copyWith({Map<String, DateTime>? medals, Map<String, int>? counters}) =>
      Progress(medals: medals ?? this.medals, counters: counters ?? this.counters);

  /// Combines two devices' progress: every medal (earliest date wins) and
  /// the higher of each counter.
  Progress merge(Progress other) {
    final medals = Map.of(this.medals);
    other.medals.forEach((id, at) {
      final mine = medals[id];
      if (mine == null || at.isBefore(mine)) medals[id] = at;
    });
    final counters = Map.of(this.counters);
    other.counters.forEach((k, v) {
      if (v > (counters[k] ?? 0)) counters[k] = v;
    });
    return Progress(medals: medals, counters: counters);
  }

  Map<String, dynamic> toJson() => {
        'formatVersion': formatVersion,
        'medals': medals.map((k, v) => MapEntry(k, v.toUtc().toIso8601String())),
        'counters': counters,
      };

  factory Progress.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const Progress();
    final medals = <String, DateTime>{};
    ((j['medals'] as Map?) ?? const {}).forEach((k, v) {
      final at = DateTime.tryParse(v as String? ?? '');
      if (at != null) medals[k as String] = at.toLocal();
    });
    final counters = <String, int>{};
    ((j['counters'] as Map?) ?? const {}).forEach((k, v) {
      if (v is num) counters[k as String] = v.toInt();
    });
    return Progress(medals: medals, counters: counters);
  }
}
