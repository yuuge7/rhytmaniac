import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/medals.dart';
import '../platform/native_bridge.dart';
import '../state/providers.dart';
import 'widgets/common.dart';
import 'widgets/medals.dart';

/// Imports a song or video; the progress card in the library shows how it goes.
Future<void> importSongFile(BuildContext context, WidgetRef ref, PickedFile file) async {
  try {
    await ref.read(importProvider.notifier).importPicked(file);
  } catch (e) {
    if (context.mounted) showMessage(context, 'Could not open the file: $e');
  }
}

/// Imports an osu! beatmap set (.osz) and says what came in.
Future<void> importOszFile(BuildContext context, WidgetRef ref, PickedFile file) async {
  try {
    final r = await ref.read(importProvider.notifier).importOsz(file);
    if (r == null || !context.mounted) return;
    final n = r.added.length;
    final skipped = r.skipped.isEmpty ? '' : ' Skipped ${r.skipped.length}: ${r.skipped.map((s) => '${s.version} (${s.reason})').join(', ')}.';
    showMessage(
      context,
      n == 0
          ? 'No playable difficulties in this set.$skipped'
          : 'Added $n osu! difficult${n == 1 ? 'y' : 'ies'} to “${r.song.title}”.$skipped',
    );
    final medals = await ref.read(progressProvider.notifier).bump(Counters.osuImports);
    if (context.mounted) announceMedals(context, medals);
  } catch (e) {
    if (context.mounted) showMessage(context, 'Could not open the file: $e');
  }
}

/// Imports a Rhytmaniac song pack. Returns false when the file isn't one.
Future<bool> importPackFile(BuildContext context, WidgetRef ref, PickedFile file, {bool quietIfNotPack = false}) async {
  try {
    final services = ref.read(servicesProvider);
    final tmp = '${services.paths.tmpDir}/incoming_${DateTime.now().millisecondsSinceEpoch}.zip';
    await NativeBridge.instance.copyUri(file.uri, tmp);
    final r = await services.packs.importSongPack(tmp);
    await ref.read(libraryProvider.notifier).refresh();
    if (context.mounted) {
      showMessage(context, r.songsAdded == 0 && r.mapsAdded == 0
          ? 'Nothing new in this pack'
          : 'Added ${r.songsAdded} song${r.songsAdded == 1 ? '' : 's'} and ${r.mapsAdded} difficult${r.mapsAdded == 1 ? 'y' : 'ies'}');
    }
    return true;
  } on FormatException catch (e) {
    if (!quietIfNotPack && context.mounted) showMessage(context, e.message);
    return false;
  } catch (e) {
    if (context.mounted) showMessage(context, 'Could not import the pack: $e');
    return true;
  }
}

const _audioVideo = ['.mp3', '.m4a', '.aac', '.ogg', '.opus', '.wav', '.flac', '.mp4', '.mkv', '.webm', '.3gp', '.mov'];

/// A file opened with or shared to Rhytmaniac from another app: picks the
/// right importer by name and type.
Future<void> openIncomingFile(BuildContext context, WidgetRef ref, PickedFile file) async {
  final name = file.name.toLowerCase();
  final mime = (file.mime ?? '').toLowerCase();
  if (name.endsWith('.osz') || mime.contains('osu')) {
    await importOszFile(context, ref, file);
  } else if (name.endsWith('.zip')) {
    // A pack, or an .osz someone renamed.
    final wasPack = await importPackFile(context, ref, file, quietIfNotPack: true);
    if (!wasPack && context.mounted) await importOszFile(context, ref, file);
  } else if (mime.startsWith('audio/') || mime.startsWith('video/') || _audioVideo.any(name.endsWith)) {
    await importSongFile(context, ref, file);
  } else if (context.mounted) {
    showMessage(context, 'Rhytmaniac can’t open “${file.name}”. Try a song, a video, an .osz or a song pack.');
  }
}
