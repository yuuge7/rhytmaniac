import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhytmaniac/core/models/difficulty.dart';
import 'package:rhytmaniac/core/models/score.dart';
import 'package:rhytmaniac/core/models/song.dart';
import 'package:rhytmaniac/core/profile_stats.dart';
import 'package:rhytmaniac/data/settings.dart';
import 'package:rhytmaniac/ui/theme.dart';
import 'package:rhytmaniac/ui/widgets/common.dart';
import 'package:rhytmaniac/ui/widgets/signal_strip.dart';

ScoreRecord rec(String id, {double acc = 0.95, double stars = 3, DateTime? at, String map = 'm1', bool failed = false}) =>
    ScoreRecord(
      id: id,
      songId: 's',
      songHash: 'h',
      beatmapId: map,
      beatmapName: 'Hard',
      mode: GameMode.tiles,
      stars: stars,
      score: (acc * 1000000).round(),
      accuracy: acc,
      maxCombo: 200,
      counts: const {Judgment.perfect: 180, Judgment.great: 15, Judgment.good: 5, Judgment.miss: 0},
      mods: const Mods(),
      grade: Grade.fromAccuracy(acc),
      failed: failed,
      timestamp: at ?? DateTime(2026, 10, 16, 12),
      durationMs: 90000,
      meanErrorMs: 3,
      unstableRate: 110,
      songTitle: 'Song',
    );

void main() {
  test('score record json round trip', () {
    final r = rec('a');
    final back = ScoreRecord.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
    expect(back.score, r.score);
    expect(back.count(Judgment.great), 15);
    expect(back.grade, r.grade);
    expect(back.formatVersion, 1);
  });

  test('song json round trip keeps fingerprint and offset', () {
    final s = Song(
      id: 'x',
      title: 'T',
      artist: 'A',
      durationMs: 1000,
      bpm: 128,
      addedAt: DateTime(2026),
      sourceFile: 'source.mp4',
      contentHash: 'h',
      offsetMs: 12,
      fingerprint: const [
        [0.1, 0.2, 0.3],
      ],
    );
    final back = Song.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expect(back.offsetMs, 12);
    expect(back.fingerprint.single, [0.1, 0.2, 0.3]);
  });

  test('settings json keeps values and portable copy drops device fields', () {
    const s = AppSettings(globalOffsetMs: 15, exportFolderUri: 'content://tree', demoInstalled: true);
    final back = AppSettings.fromJson(s.toJson());
    expect(back.globalOffsetMs, 15);
    expect(back.exportFolderUri, 'content://tree');
    expect(s.portableJson().containsKey('exportFolderUri'), isFalse);
    expect(s.portableJson().containsKey('demoInstalled'), isFalse);
  });

  test('mods labels', () {
    expect(const Mods().labels, isEmpty);
    expect(const Mods(rate: 1.5, hidden: true).labels, ['1.5×', 'Hidden']);
  });

  test('profile stats: best per map, pulse weighting, streak', () {
    final now = DateTime(2026, 10, 16, 18);
    final stats = ProfileStats.compute([
      rec('1', acc: 0.90, at: DateTime(2026, 10, 14)),
      rec('2', acc: 0.97, at: DateTime(2026, 10, 15)),
      rec('3', acc: 0.99, stars: 5, map: 'm2', at: DateTime(2026, 10, 16)),
      rec('4', acc: 0.5, failed: true, map: 'm3', at: DateTime(2026, 10, 16)),
    ], now: now);
    expect(stats.plays, 4);
    expect(stats.bestPlays, hasLength(2));
    expect(stats.bestPlays.first.stars, 5);
    expect(stats.streakDays, 3);
    expect(stats.pulse, greaterThan(stats.bestPlays.first.pulse));
    expect(stats.accuracyTrend, hasLength(3));
  });

  testWidgets('signal strip and badges render with the theme', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: Column(children: [
          SignalStrip(fingerprint: [
            for (var i = 0; i < 20; i++) [i / 20, 0.5, 1 - i / 20],
          ]),
          const StarBadge(3.42),
          const GradeMark(Grade.s),
          ModeSwitch(mode: GameMode.tiles, onChanged: (_) {}),
        ]),
      ),
    ));
    expect(find.text('3.42★'), findsOneWidget);
    expect(find.text('S'), findsOneWidget);
    expect(find.text('Circles'), findsOneWidget);
  });

  test('heat ramp endpoints', () {
    expect(Palette.heat(0), Palette.violet);
    expect(Palette.heat(1), Palette.flare);
  });
}
