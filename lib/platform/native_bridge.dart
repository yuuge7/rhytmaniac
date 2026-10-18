import 'dart:async';

import 'package:flutter/services.dart';

class PickedFile {
  const PickedFile({required this.uri, required this.name, this.size, this.mime});
  final String uri;
  final String name;
  final int? size;
  final String? mime;
}

class PickedFolder {
  const PickedFolder({required this.uri, required this.name});
  final String uri;
  final String name;
}

class MediaMetadata {
  const MediaMetadata({this.title, this.artist, this.durationMs = 0, this.hasVideo = false, this.hasCover = false});
  final String? title;
  final String? artist;
  final double durationMs;
  final bool hasVideo;
  final bool hasCover;
}

class DecodeResult {
  const DecodeResult({required this.sampleRate, required this.samples, required this.durationMs});
  final int sampleRate;
  final int samples;
  final double durationMs;
}

/// Dart side of `MainActivity.kt`.
class NativeBridge {
  NativeBridge._() {
    _channel.setMethodCallHandler(_onCall);
  }

  static final instance = NativeBridge._();
  static const _channel = MethodChannel('rhytmaniac/native');
  final Map<String, void Function(double)> _decodeListeners = {};
  final _fileOpened = StreamController<void>.broadcast();

  /// Fires when another app opens or shares a file with Rhytmaniac while it
  /// runs; fetch it with [takeOpenedFile].
  Stream<void> get fileOpened => _fileOpened.stream;

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'decodeProgress') {
      final args = (call.arguments as Map).cast<String, dynamic>();
      _decodeListeners[args['id'] as String]?.call((args['progress'] as num).toDouble());
    } else if (call.method == 'fileOpened') {
      _fileOpened.add(null);
    }
  }

  /// The file Rhytmaniac was opened with (or that was shared to it), once.
  Future<PickedFile?> takeOpenedFile() async {
    final r = await _channel.invokeMapMethod<String, dynamic>('takeOpenedFile');
    if (r == null) return null;
    return PickedFile(
      uri: r['uri'] as String,
      name: r['name'] as String? ?? 'file',
      size: (r['size'] as num?)?.toInt(),
      mime: r['mime'] as String?,
    );
  }

  /// Asks the display for its fastest refresh rate (or back to 60 Hz).
  Future<void> setHighRefreshRate(bool on) async {
    try {
      await _channel.invokeMethod('setHighRefreshRate', {'on': on});
    } on MissingPluginException {
      // Not on Android.
    }
  }

  /// Opens the system file picker. Returns null if the user backs out.
  Future<PickedFile?> pickFile(List<String> mimeTypes) async {
    final r = await _channel.invokeMapMethod<String, dynamic>('pickFile', {'mimeTypes': mimeTypes});
    if (r == null) return null;
    return PickedFile(
      uri: r['uri'] as String,
      name: r['name'] as String? ?? 'file',
      size: (r['size'] as num?)?.toInt(),
      mime: r['mime'] as String?,
    );
  }

  Future<PickedFolder?> pickFolder() async {
    final r = await _channel.invokeMapMethod<String, dynamic>('pickFolder');
    if (r == null) return null;
    return PickedFolder(uri: r['uri'] as String, name: r['name'] as String? ?? 'Folder');
  }

  Future<int> copyUri(String uri, String destPath) async =>
      (await _channel.invokeMethod<num>('copyUri', {'uri': uri, 'dest': destPath}))?.toInt() ?? 0;

  Future<MediaMetadata> readMetadata(String path, String coverPath) async {
    final r = await _channel.invokeMapMethod<String, dynamic>('readMetadata', {'path': path, 'coverPath': coverPath});
    if (r == null) return const MediaMetadata();
    String? clean(Object? v) {
      final s = (v as String?)?.trim();
      return (s == null || s.isEmpty) ? null : s;
    }

    return MediaMetadata(
      title: clean(r['title']),
      artist: clean(r['artist']),
      durationMs: (r['durationMs'] as num?)?.toDouble() ?? 0,
      hasVideo: r['hasVideo'] as bool? ?? false,
      hasCover: r['cover'] as bool? ?? false,
    );
  }

  Future<DecodeResult> decodeAudio(
    String path,
    String destPath, {
    int sampleRate = 22050,
    void Function(double)? onProgress,
  }) async {
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    if (onProgress != null) _decodeListeners[id] = onProgress;
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>(
        'decodeAudio',
        {'id': id, 'path': path, 'dest': destPath, 'sampleRate': sampleRate},
      );
      return DecodeResult(
        sampleRate: (r!['sampleRate'] as num).toInt(),
        samples: (r['samples'] as num).toInt(),
        durationMs: (r['durationMs'] as num).toDouble(),
      );
    } finally {
      _decodeListeners.remove(id);
    }
  }

  /// Saves into Download/Rhytmaniac. On Android 9 and older this asks for
  /// storage access first; if it's refused, throws [PlatformException] with
  /// message `needs_saf` so the caller can use the system save dialog.
  Future<String> saveToDownloads(String sourcePath, String name, String mime) async =>
      (await _channel.invokeMethod<String>('saveToDownloads', {'source': sourcePath, 'name': name, 'mime': mime}))!;

  Future<String> saveToFolder(String treeUri, String sourcePath, String name, String mime) async =>
      (await _channel.invokeMethod<String>(
        'saveToFolder',
        {'treeUri': treeUri, 'source': sourcePath, 'name': name, 'mime': mime},
      ))!;

  /// Lets the user choose where to save via the system dialog.
  Future<String?> createDocument(String sourcePath, String name, String mime) =>
      _channel.invokeMethod<String>('createDocument', {'source': sourcePath, 'name': name, 'mime': mime});
}
