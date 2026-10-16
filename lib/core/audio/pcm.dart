import 'dart:math' as math;
import 'dart:typed_data';

/// Mono float PCM at a known sample rate.
class MonoPcm {
  const MonoPcm(this.samples, this.sampleRate);
  final Float32List samples;
  final int sampleRate;

  double get durationMs => samples.length * 1000.0 / sampleRate;
}

/// Sample rate used for analysis everywhere.
const analysisSampleRate = 22050;

/// Reads raw little-endian signed 16-bit mono PCM (the format the native
/// decoder writes) into floats.
Float32List pcm16ToFloat(Uint8List bytes) {
  final n = bytes.length ~/ 2;
  final view = ByteData.sublistView(bytes);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// Parses a PCM WAV file (8/16/24/32-bit int or 32-bit float), downmixes to
/// mono and resamples to [targetRate].
MonoPcm decodeWav(Uint8List bytes, {int targetRate = analysisSampleRate}) {
  final data = ByteData.sublistView(bytes);
  String tag(int o) => String.fromCharCodes(bytes.sublist(o, o + 4));
  if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
    throw const FormatException('Not a RIFF/WAVE file');
  }
  var offset = 12;
  int? format, channels, rate, bits;
  int? dataStart, dataLen;
  while (offset + 8 <= bytes.length) {
    final id = tag(offset);
    final size = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ') {
      format = data.getUint16(body, Endian.little);
      channels = data.getUint16(body + 2, Endian.little);
      rate = data.getUint32(body + 4, Endian.little);
      bits = data.getUint16(body + 14, Endian.little);
      if (format == 0xFFFE && size >= 26) {
        // WAVE_FORMAT_EXTENSIBLE: real format is the first 2 bytes of the GUID.
        format = data.getUint16(body + 24, Endian.little);
      }
    } else if (id == 'data') {
      dataStart = body;
      dataLen = math.min(size, bytes.length - body);
      break;
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }
  if (format == null || dataStart == null || channels == null || rate == null || bits == null) {
    throw const FormatException('WAV is missing fmt or data chunk');
  }
  if (format != 1 && format != 3) {
    throw FormatException('Unsupported WAV encoding $format');
  }
  final bytesPerSample = bits ~/ 8;
  final frameBytes = bytesPerSample * channels;
  final frames = dataLen! ~/ frameBytes;
  final mono = Float32List(frames);
  for (var f = 0; f < frames; f++) {
    var sum = 0.0;
    for (var c = 0; c < channels; c++) {
      final o = dataStart + f * frameBytes + c * bytesPerSample;
      sum += _readSample(data, o, bits, format == 3);
    }
    mono[f] = sum / channels;
  }
  return MonoPcm(resampleLinear(mono, rate, targetRate), targetRate);
}

double _readSample(ByteData d, int o, int bits, bool isFloat) {
  if (isFloat) {
    return bits == 64 ? d.getFloat64(o, Endian.little) : d.getFloat32(o, Endian.little);
  }
  switch (bits) {
    case 8:
      return (d.getUint8(o) - 128) / 128.0;
    case 16:
      return d.getInt16(o, Endian.little) / 32768.0;
    case 24:
      var v = d.getUint8(o) | (d.getUint8(o + 1) << 8) | (d.getUint8(o + 2) << 16);
      if (v & 0x800000 != 0) v -= 0x1000000;
      return v / 8388608.0;
    case 32:
      return d.getInt32(o, Endian.little) / 2147483648.0;
  }
  throw FormatException('Unsupported bit depth $bits');
}

/// Linear-interpolation resampler with a box pre-filter when downsampling.
Float32List resampleLinear(Float32List input, int fromRate, int toRate) {
  if (fromRate == toRate) return input;
  var src = input;
  final ratio = fromRate / toRate;
  if (ratio >= 1.5) {
    final w = ratio.round();
    final filtered = Float32List(src.length);
    var acc = 0.0;
    for (var i = 0; i < src.length; i++) {
      acc += src[i];
      if (i >= w) acc -= src[i - w];
      filtered[i] = acc / math.min(i + 1, w);
    }
    src = filtered;
  }
  final outLen = (src.length / ratio).floor();
  final out = Float32List(outLen);
  for (var i = 0; i < outLen; i++) {
    final pos = i * ratio;
    final j = pos.floor();
    final f = pos - j;
    final a = src[j];
    final b = j + 1 < src.length ? src[j + 1] : a;
    out[i] = a + (b - a) * f;
  }
  return out;
}

/// Encodes mono float samples as a 16-bit PCM WAV (used for the metronome).
Uint8List encodeWav16(Float32List samples, int sampleRate) {
  final dataLen = samples.length * 2;
  final b = ByteData(44 + dataLen);
  void str(int o, String s) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, 36 + dataLen, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, dataLen, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    b.setInt16(44 + i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}
