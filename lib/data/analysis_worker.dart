import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../core/analysis/analyzer.dart';
import '../core/audio/pcm.dart';
import '../core/generator/beatmap_generator.dart';
import '../core/models/analysis.dart';
import '../core/models/beatmap.dart';
import '../core/models/difficulty.dart';

/// Makes [maps] again from [analysis] with their own settings, seeds and
/// names (new ids), in a background isolate.
Future<List<Beatmap>> regenerateMaps(SongAnalysis analysis, List<Beatmap> maps) => Isolate.run(() => [
      for (final m in maps)
        BeatmapGenerator.generate(
          analysis: analysis,
          songId: m.songId,
          mode: m.mode,
          params: m.difficulty,
          seed: m.seed,
          metadata: m.metadata,
          name: m.name,
        ),
    ]);

/// What the background isolate should do for one song.
class AnalysisJob {
  const AnalysisJob({
    required this.audioPath,
    required this.isWav,
    required this.songId,
    required this.title,
    required this.artist,
    required this.lanes,
    required this.seed,
    this.generateDefaults = true,
  });

  /// Raw mono PCM16 file from the native decoder, or a WAV file.
  final String audioPath;
  final bool isWav;
  final String songId;
  final String title;
  final String artist;
  final int lanes;
  final int seed;
  final bool generateDefaults;
}

class AnalysisJobResult {
  const AnalysisJobResult(this.analysis, this.beatmaps);
  final SongAnalysis analysis;
  final List<Beatmap> beatmaps;
}

/// Runs analysis (and default map generation) in a separate isolate so the
/// UI never freezes. [onProgress] receives 0..1.
Future<AnalysisJobResult> runAnalysisJob(AnalysisJob job, {void Function(double)? onProgress}) async {
  final port = ReceivePort();
  final errors = ReceivePort();
  final isolate = await Isolate.spawn(
    _entry,
    [port.sendPort, job.audioPath, job.isWav, job.songId, job.title, job.artist, job.lanes, job.seed, job.generateDefaults],
    onError: errors.sendPort,
  );
  final completer = Completer<AnalysisJobResult>();
  late StreamSubscription sub, errSub;
  sub = port.listen((msg) {
    if (msg is double) {
      onProgress?.call(msg);
    } else if (msg is Map) {
      final analysis = SongAnalysis.fromJson((msg['analysis'] as Map).cast<String, dynamic>());
      final maps = (msg['beatmaps'] as List)
          .map((m) => Beatmap.fromJson((m as Map).cast<String, dynamic>()))
          .toList();
      completer.complete(AnalysisJobResult(analysis, maps));
    } else if (msg is String) {
      completer.completeError(Exception(msg));
    }
  });
  errSub = errors.listen((e) {
    if (!completer.isCompleted) completer.completeError(Exception('Analysis crashed: ${(e as List).first}'));
  });
  try {
    return await completer.future;
  } finally {
    await sub.cancel();
    await errSub.cancel();
    port.close();
    errors.close();
    isolate.kill();
  }
}

Future<void> _entry(List<Object?> args) async {
  final send = args[0] as SendPort;
  try {
    final path = args[1] as String;
    final isWav = args[2] as bool;
    final songId = args[3] as String;
    final title = args[4] as String;
    final artist = args[5] as String;
    final lanes = args[6] as int;
    final seed = args[7] as int;
    final generate = args[8] as bool;

    final bytes = await File(path).readAsBytes();
    send.send(0.02);
    final pcm = isWav ? decodeWav(bytes) : MonoPcm(pcm16ToFloat(bytes), analysisSampleRate);
    final raw = analyzePcm(pcm.samples, pcm.sampleRate, onProgress: (p) => send.send(0.05 + p * 0.75));
    // Generate from the rounded, serialized form so regenerating later from
    // analysis.json with the same seed reproduces these maps exactly.
    final analysis = SongAnalysis.fromJson(raw.toJson());

    final maps = <Map<String, dynamic>>[];
    if (generate) {
      final meta = BeatmapMetadata(title: title, artist: artist, creator: 'Rhytmaniac generator');
      var i = 0;
      for (final mode in GameMode.values) {
        for (final preset in DifficultyPreset.ladder) {
          final map = BeatmapGenerator.generate(
            analysis: analysis,
            songId: songId,
            mode: mode,
            params: DifficultyParams.preset(mode, preset, lanes: lanes),
            seed: seed + i,
            metadata: meta,
          );
          maps.add(map.toJson());
          i++;
          send.send(0.8 + 0.2 * i / (GameMode.values.length * DifficultyPreset.ladder.length));
        }
      }
    }
    send.send({'analysis': analysis.toJson(), 'beatmaps': maps});
  } catch (e, st) {
    send.send('$e\n$st');
  }
}
