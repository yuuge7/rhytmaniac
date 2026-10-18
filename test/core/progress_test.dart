import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhytmaniac/core/medals.dart';
import 'package:rhytmaniac/core/models/difficulty.dart';
import 'package:rhytmaniac/core/models/progress.dart';
import 'package:rhytmaniac/core/models/score.dart';
import 'package:rhytmaniac/core/profile_stats.dart';
import 'package:rhytmaniac/core/rating/performance.dart';

PlayFacts facts({
  GameMode mode = GameMode.circles,
  double stars = 5,
  double acc = 1,
  int misses = 0,
  int combo = 800,
  int maxCombo = 800,
  int objects = 600,
  double strictness = 8,
  Mods mods = const Mods(),
  bool failed = false,
}) =>
    PlayFacts(
      mode: mode,
      stars: stars,
      accuracy: acc,
      misses: misses,
      maxCombo: combo,
      mapMaxCombo: maxCombo,
      objectCount: objects,
      strictness: strictness,
      mods: mods,
      failed: failed,
    );

ScoreRecord play(
  String id, {
  double stars = 3,
  double acc = 0.97,
  int misses = 0,
  int combo = 300,
  Mods mods = const Mods(),
  bool failed = false,
  GameMode mode = GameMode.circles,
  String? origin,
  int? lanes,
  String map = 'm',
}) =>
    ScoreRecord(
      id: id,
      songId: 's',
      songHash: 'h',
      beatmapId: map,
      beatmapName: 'Hard',
      mode: mode,
      stars: stars,
      score: 100000,
      accuracy: acc,
      maxCombo: combo,
      counts: {Judgment.perfect: 280, Judgment.great: 15, Judgment.good: 5, Judgment.miss: misses},
      mods: mods,
      grade: Grade.fromAccuracy(acc, failed: failed),
      failed: failed,
      timestamp: DateTime(2026, 10, 18),
      durationMs: 90000,
      meanErrorMs: 0,
      unstableRate: 120,
      origin: origin,
      lanes: lanes,
    );

void main() {
  group('performance points', () {
    test('grow with stars and fall with misses, mistakes in accuracy and No-Fail', () {
      final ss5 = performancePoints(facts());
      expect(ss5, inInclusiveRange(150, 400));
      // A Hard-preset 3★ map (strictness 6) against an Expert-like 5★ one.
      expect(performancePoints(facts(stars: 3, strictness: 6)), lessThan(ss5 / 2));
      expect(performancePoints(facts(misses: 5, combo: 400)), lessThan(ss5));
      expect(performancePoints(facts(acc: 0.95)), lessThan(ss5));
      expect(performancePoints(facts(mods: const Mods(noFail: true))), closeTo(ss5 * 0.9, 1e-6));
      expect(performancePoints(facts(mods: const Mods(hidden: true, hardRock: true))), greaterThan(ss5));
    });

    test('failed and autoplay runs are worth nothing', () {
      expect(performancePoints(facts(failed: true)), 0);
      expect(performancePoints(facts(mods: const Mods(autoplay: true))), 0);
    });

    test('tiles pp follows stars and drops to nothing at 80% accuracy', () {
      final hi = performancePoints(facts(mode: GameMode.tiles, stars: 5));
      final lo = performancePoints(facts(mode: GameMode.tiles, stars: 2));
      expect(hi, greaterThan(lo * 3));
      expect(performancePoints(facts(mode: GameMode.tiles, acc: 0.8)), 0);
    });

    test('profile total weights best plays 0.95 apart, plus a play-count bonus', () {
      final total = totalPerformance([100, 100, 100]);
      expect(total, greaterThan(100 + 95 + 90.25));
      expect(total, lessThan(100 + 95 + 90.25 + 5));
    });

    test('easy and hard rock move the timing strictness', () {
      expect(effectiveStrictness(5, const Mods()), closeTo(5, 1e-9));
      expect(effectiveStrictness(5, const Mods(hardRock: true)), greaterThan(5));
      expect(effectiveStrictness(5, const Mods(easy: true)), lessThan(5));
    });

    test('scores keep their pp; older records get an estimate', () {
      final stored = ScoreRecord.fromJson({...play('a').toJson(), 'pp': 123.4});
      expect(stored.performance, 123.4);
      final estimated = play('b', stars: 4);
      expect(estimated.pp, isNull);
      expect(estimated.performance, greaterThan(0));
      expect(ProfileStats.compute([estimated]).pp, greaterThan(estimated.performance));
    });
  });

  group('medals', () {
    Set<String> earned(List<ScoreRecord> scores, {Map<String, int> counters = const {}, int songs = 1}) => newlyEarned(
          MedalContext(scores: scores, songCount: songs, counters: counters, now: DateTime(2026, 10, 18)),
          const {},
        ).map((m) => m.id).toSet();

    test('a clear unlocks every star tier up to its rating', () {
      final e = earned([play('1', stars: 3.4)]);
      expect(e, containsAll(['pass-1', 'pass-2', 'pass-3']));
      expect(e, isNot(contains('pass-4')));
      expect(e, containsAll(['fc-1', 'fc-2', 'fc-3', 'combo-100', 'combo-250']));
    });

    test('No-Fail, failed and autoplay runs don’t count as clears', () {
      expect(earned([play('1', stars: 5, mods: const Mods(noFail: true))]), isNot(contains('pass-5')));
      expect(earned([play('1', stars: 5, failed: true)]), isNot(contains('pass-5')));
      expect(earned([play('1', stars: 5, mods: const Mods(autoplay: true))]), isEmpty);
    });

    test('mod, explorer and counter medals', () {
      final e = earned(
        [
          play('1', stars: 3.2, acc: 1, mods: const Mods(hidden: true, hardRock: true)),
          play('2', mode: GameMode.tiles, lanes: 7, origin: 'osu'),
        ],
        counters: {Counters.replaysWatched: 1, Counters.calibrations: 1},
      );
      expect(e, containsAll(['mod-hd', 'mod-hr', 'mod-hdhr', 'ss', 'both-modes', 'mania-7k', 'osu-clear', 'replay', 'calibrate']));
      expect(e, isNot(contains('practice')));
    });

    test('already unlocked medals are not reported again', () {
      final c = MedalContext(scores: [play('1', stars: 2)], songCount: 1, counters: const {});
      final first = newlyEarned(c, const {}).map((m) => m.id).toSet();
      expect(newlyEarned(c, first), isEmpty);
    });

    test('ids are unique', () {
      final ids = allMedals.map((m) => m.id).toList();
      expect(ids.toSet().length, ids.length);
    });
  });

  test('progress merges two devices: earliest unlock, highest counter', () {
    final a = Progress(medals: {'ss': DateTime(2026, 1, 2)}, counters: const {'x': 3});
    final b = Progress(medals: {'ss': DateTime(2026, 1, 1), 'fc-1': DateTime(2026, 2, 1)}, counters: const {'x': 1, 'y': 2});
    final m = a.merge(b);
    expect(m.medals['ss'], DateTime(2026, 1, 1));
    expect(m.medals.keys, containsAll(['ss', 'fc-1']));
    expect(m.counters, {'x': 3, 'y': 2});
    final back = Progress.fromJson(jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>);
    expect(back.medals.length, 2);
    expect(back.counters['y'], 2);
  });
}
