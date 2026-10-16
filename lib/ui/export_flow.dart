import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models/song.dart';
import '../platform/native_bridge.dart';
import '../state/providers.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// Saves a finished temp file where the player wants it: their chosen export
/// folder, or Download/Rhytmaniac by default, or a one-off location.
Future<String?> saveExport(BuildContext context, WidgetRef ref, String tmpPath, {String mime = 'application/zip'}) async {
  final settings = ref.read(settingsProvider);
  final name = tmpPath.split(Platform.pathSeparator).last.split('/').last;
  final where = await showModalBottomSheet<String>(
    context: context,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, 4),
            child: Text('Save $name', style: AppText.display(19, width: 110, weight: 780), maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          ListTile(
            leading: const Icon(Icons.download_rounded),
            title: Text(settings.exportFolderName == null ? 'Downloads' : settings.exportFolderName!),
            subtitle: Text(settings.exportFolderUri == null ? 'Download/Rhytmaniac' : 'Your export folder'),
            onTap: () => Navigator.pop(c, 'default'),
          ),
          ListTile(
            leading: const Icon(Icons.folder_open_rounded),
            title: const Text('Choose location…'),
            subtitle: const Text('Pick a folder or app with the system dialog'),
            onTap: () => Navigator.pop(c, 'pick'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (where == null) return null;
  final bridge = NativeBridge.instance;
  try {
    String? saved;
    if (where == 'pick') {
      saved = await bridge.createDocument(tmpPath, name, mime);
    } else if (settings.exportFolderUri != null) {
      saved = await bridge.saveToFolder(settings.exportFolderUri!, tmpPath, name, mime);
    } else {
      try {
        saved = await bridge.saveToDownloads(tmpPath, name, mime);
      } on PlatformException catch (e) {
        if ((e.message ?? '').contains('needs_saf')) {
          saved = await bridge.createDocument(tmpPath, name, mime);
        } else {
          rethrow;
        }
      }
    }
    if (saved != null && context.mounted) showMessage(context, 'Saved to $saved');
    return saved;
  } catch (e) {
    if (context.mounted) showMessage(context, 'Could not save: $e');
    return null;
  } finally {
    try {
      await File(tmpPath).delete();
    } catch (_) {}
  }
}

Future<void> exportSongPack(BuildContext context, WidgetRef ref, List<Song> songs) async {
  final packs = ref.read(servicesProvider).packs;
  showMessage(context, 'Packing ${songs.length == 1 ? '“${songs.first.title}”' : '${songs.length} songs'}…');
  try {
    final path = await packs.exportSongs(songs);
    if (context.mounted) await saveExport(context, ref, path);
  } catch (e) {
    if (context.mounted) showMessage(context, 'Could not export: $e');
  }
}
