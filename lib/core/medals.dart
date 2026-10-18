import 'models/difficulty.dart';
import 'models/score.dart';
import 'profile_stats.dart';

enum MedalGroup {
  skill('Skill'),
  accuracy('Accuracy'),
  mods('Mods'),
  combo('Combo'),
  dedication('Dedication'),
  explorer('Explorer');

  const MedalGroup(this.label);
  final String label;
}

/// Counted moments that scores alone don't show.
abstract final class Counters {
  static const replaysWatched = 'replaysWatched';
  static const practiceLoops = 'practiceLoops';
  static const calibrations = 'calibrations';
  static const mapsEdited = 'mapsEdited';
  static const osuImports = 'osuImports';
  static const mapsGenerated = 'mapsGenerated';
}

/// What medal conditions can look at.
class MedalContext {
  MedalContext({
    required List<ScoreRecord> scores,
    required this.songCount,
    required this.counters,
    DateTime? now,
  })  : scores = scores.where((s) => !s.mods.autoplay && !s.practice).toList(),
        stats = ProfileStats.compute(scores, now: now);

  /// Real plays (no autoplay, no practice).
  final List<ScoreRecord> scores;
  final int songCount;
  final Map<String, int> counters;
  final ProfileStats stats;

  int counter(String k) => counters[k] ?? 0;

  /// Finished without No-Fail.
  Iterable<ScoreRecord> get passes => scores.where((s) => !s.failed && !s.mods.noFail);

  bool any(bool Function(ScoreRecord s) test) => passes.any(test);
}

class Medal {
  const Medal(this.id, this.group, this.title, this.description, this.earned);

  final String id;
  final MedalGroup group;
  final String title;
  final String description;
  final bool Function(MedalContext c) earned;
}

const _starNames = ['First Steps', 'Finding the Beat', 'In the Groove', 'Heat Rising', 'Ember', 'Wildfire', 'Supernova'];

/// Every medal, in display order.
final List<Medal> allMedals = [
  // Skill: clears and full combos by star rating.
  for (var n = 1; n <= 7; n++)
    Medal('pass-$n', MedalGroup.skill, _starNames[n - 1], 'Clear a $n★ map without No-Fail.',
        (c) => c.any((s) => s.stars >= n)),
  for (var n = 1; n <= 6; n++)
    Medal('fc-$n', MedalGroup.skill, 'Unbroken ${_roman(n)}', 'Full combo a $n★ map.',
        (c) => c.any((s) => s.stars >= n && s.fullCombo)),

  // Accuracy.
  Medal('ss', MedalGroup.accuracy, 'Spotless', 'Get an SS.', (c) => c.any((s) => s.grade == Grade.ss)),
  Medal('ss-4', MedalGroup.accuracy, 'Flawless Fire', 'Get an SS on a 4★ map.',
      (c) => c.any((s) => s.grade == Grade.ss && s.stars >= 4)),
  Medal('acc-99', MedalGroup.accuracy, 'Precision', 'Clear a 3★ map with 99% accuracy.',
      (c) => c.any((s) => s.stars >= 3 && s.accuracy >= 0.99)),
  Medal('ur-100', MedalGroup.accuracy, 'Steady Hands', 'Finish 200+ hits with an unstable rate under 100.',
      (c) => c.any((s) => s.unstableRate > 0 && s.unstableRate < 100 && s.judgedTotal >= 200)),

  // Mods.
  Medal('mod-hd', MedalGroup.mods, 'Out of Sight', 'Clear a 2★ map with Hidden.', (c) => c.any((s) => s.mods.hidden && s.stars >= 2)),
  Medal('mod-hr', MedalGroup.mods, 'Hard Rocker', 'Clear a 2★ map with Hard Rock.', (c) => c.any((s) => s.mods.hardRock && s.stars >= 2)),
  Medal('mod-fl', MedalGroup.mods, 'In the Dark', 'Clear a map with Flashlight.', (c) => c.any((s) => s.mods.flashlight)),
  Medal('mod-dt', MedalGroup.mods, 'Double Time', 'Clear a 2★ map at 1.5× speed or faster.',
      (c) => c.any((s) => s.mods.rate >= 1.5 && s.stars >= 2)),
  Medal('mod-nc', MedalGroup.mods, 'Nightcore', 'Clear a map with Nightcore.', (c) => c.any((s) => s.mods.nightcore && s.mods.rate > 1)),
  Medal('mod-ht', MedalGroup.mods, 'Slow Burn', 'Clear a map at Half Time.', (c) => c.any((s) => s.mods.rate < 1)),
  Medal('mod-ez', MedalGroup.mods, 'Easy Does It', 'Full combo a map with Easy.', (c) => c.any((s) => s.mods.easy && s.fullCombo)),
  Medal('mod-sd', MedalGroup.mods, 'Sudden Death', 'Full combo a 3★ map with Sudden Death.',
      (c) => c.any((s) => s.mods.suddenDeath && s.stars >= 3 && s.fullCombo)),
  Medal('mod-pf', MedalGroup.mods, 'Perfectionist', 'Get an SS with Perfect.', (c) => c.any((s) => s.mods.perfect && s.grade == Grade.ss)),
  Medal('mod-hdhr', MedalGroup.mods, 'Both Barrels', 'Clear a 3★ map with Hidden and Hard Rock.',
      (c) => c.any((s) => s.mods.hidden && s.mods.hardRock && s.stars >= 3)),

  // Combo.
  for (final n in const [100, 250, 500, 1000])
    Medal('combo-$n', MedalGroup.combo, '$n Combo', 'Reach a $n combo.', (c) => c.scores.any((s) => s.maxCombo >= n)),

  // Dedication.
  for (final n in const [10, 100, 500, 1000])
    Medal('plays-$n', MedalGroup.dedication, '$n Plays', 'Play $n times.', (c) => c.scores.length >= n),
  for (final n in const [10000, 100000])
    Medal('hits-$n', MedalGroup.dedication, '${n ~/ 1000}k Hits', 'Hit $n notes in total.', (c) => c.stats.notesHit >= n),
  Medal('streak-7', MedalGroup.dedication, 'Every Day', 'Play 7 days in a row.', (c) => c.stats.streakDays >= 7),
  for (final n in const [100, 500, 1000, 2000])
    Medal('pp-$n', MedalGroup.dedication, '$n pp', 'Reach $n performance points.', (c) => c.stats.pp >= n),

  // Explorer.
  Medal('both-modes', MedalGroup.explorer, 'Two Worlds', 'Clear a map in Tiles and one in Circles.',
      (c) => c.any((s) => s.mode == GameMode.tiles) && c.any((s) => s.mode == GameMode.circles)),
  Medal('library-10', MedalGroup.explorer, 'Crate Digger', 'Have 10 songs in your library.', (c) => c.songCount >= 10),
  Medal('osu-import', MedalGroup.explorer, 'Crossing Over', 'Import an osu! beatmap.', (c) => c.counter(Counters.osuImports) > 0),
  Medal('osu-clear', MedalGroup.explorer, 'Visitor', 'Clear an osu! difficulty.', (c) => c.any((s) => s.origin == 'osu')),
  Medal('mania-7k', MedalGroup.explorer, 'Seven Keys', 'Clear a Tiles map with 7 or more lanes.',
      (c) => c.any((s) => s.mode == GameMode.tiles && (s.lanes ?? 4) >= 7)),
  Medal('generator', MedalGroup.explorer, 'Map Maker', 'Generate a new difficulty.', (c) => c.counter(Counters.mapsGenerated) > 0),
  Medal('editor', MedalGroup.explorer, 'Hands On', 'Save a difficulty from the editor.', (c) => c.counter(Counters.mapsEdited) > 0),
  Medal('replay', MedalGroup.explorer, 'Instant Replay', 'Watch a replay to the end.', (c) => c.counter(Counters.replaysWatched) > 0),
  Medal('practice', MedalGroup.explorer, 'Again and Again', 'Loop a section 5 times in practice.',
      (c) => c.counter(Counters.practiceLoops) >= 5),
  Medal('calibrate', MedalGroup.explorer, 'Tuned In', 'Calibrate your audio offset.', (c) => c.counter(Counters.calibrations) > 0),
];

Medal? medalById(String id) {
  for (final m in allMedals) {
    if (m.id == id) return m;
  }
  return null;
}

/// Medals earned in [c] that aren't in [unlocked] yet, in display order.
List<Medal> newlyEarned(MedalContext c, Set<String> unlocked) =>
    [for (final m in allMedals) if (!unlocked.contains(m.id) && m.earned(c)) m];

String _roman(int n) => const ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII'][n - 1];
