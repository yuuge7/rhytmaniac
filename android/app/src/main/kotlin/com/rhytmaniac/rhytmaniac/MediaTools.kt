package com.rhytmaniac.rhytmaniac

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.roundToLong

object MediaTools {

    /**
     * Decodes the first audio track of [path] (MP4, M4A, MP3, WAV, OGG, FLAC...)
     * to mono signed 16-bit little-endian PCM at [targetRate], written to [dest].
     *
     * Output buffers are placed by their presentation timestamps, so encoder
     * priming and gaps line up with what the player (also PTS-based) plays.
     */
    fun decodeToMonoPcm16(path: String, dest: String, targetRate: Int, progress: (Double) -> Unit): Map<String, Any> {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)
        var track = -1
        var format: MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                track = i
                format = f
                break
            }
        }
        if (track < 0 || format == null) {
            extractor.release()
            throw IllegalArgumentException("This file has no audio track")
        }
        extractor.selectTrack(track)
        val mime = format.getString(MediaFormat.KEY_MIME)!!
        val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L
        var srcRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        var encoding = AudioFormat.ENCODING_PCM_16BIT

        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(format, null, null, 0)
        codec.start()

        val out = BufferedOutputStream(FileOutputStream(dest), 1 shl 16)
        val writer = Pcm16Writer(out)
        var resampler = StreamResampler(srcRate, targetRate) { writer.write(it) }
        var consumedFrames = 0L
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false
        var lastReported = -1.0
        try {
            while (!outputDone) {
                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(10_000)
                    if (inIdx >= 0) {
                        val buf = codec.getInputBuffer(inIdx)!!
                        val size = extractor.readSampleData(buf, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIdx = codec.dequeueOutputBuffer(info, 10_000)
                if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val f = codec.outputFormat
                    val newRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    if (f.containsKey(MediaFormat.KEY_PCM_ENCODING)) encoding = f.getInteger(MediaFormat.KEY_PCM_ENCODING)
                    if (newRate != srcRate) {
                        srcRate = newRate
                        resampler = StreamResampler(srcRate, targetRate) { writer.write(it) }
                        consumedFrames = 0
                    }
                } else if (outIdx >= 0) {
                    val buf = codec.getOutputBuffer(outIdx)!!
                    if (info.size > 0) {
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        val mono = toMono(buf.slice().order(ByteOrder.nativeOrder()), channels, encoding)
                        var start = 0
                        val ptsFrame = (info.presentationTimeUs * srcRate / 1_000_000.0).roundToLong()
                        val drift = ptsFrame - consumedFrames
                        if (drift > 2) {
                            // Gap in the stream: pad with silence.
                            for (i in 0L until drift) resampler.push(0f)
                            consumedFrames += drift
                        } else if (drift < -2) {
                            // Overlap (e.g. negative-timestamp priming): drop it.
                            start = (-drift).coerceAtMost(mono.size.toLong()).toInt()
                        }
                        for (i in start until mono.size) resampler.push(mono[i])
                        consumedFrames += (mono.size - start)
                    }
                    codec.releaseOutputBuffer(outIdx, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                    if (durationUs > 0) {
                        val p = (info.presentationTimeUs.toDouble() / durationUs).coerceIn(0.0, 1.0)
                        if (p - lastReported >= 0.02) {
                            lastReported = p
                            progress(p)
                        }
                    }
                }
            }
        } finally {
            writer.flush()
            out.close()
            codec.stop()
            codec.release()
            extractor.release()
        }
        progress(1.0)
        return mapOf(
            "sampleRate" to targetRate,
            "samples" to writer.count,
            "durationMs" to writer.count * 1000.0 / targetRate,
            "sourceRate" to srcRate,
            "channels" to channels,
        )
    }

    private fun toMono(buf: ByteBuffer, channels: Int, encoding: Int): FloatArray {
        val ch = max(1, channels)
        return if (encoding == AudioFormat.ENCODING_PCM_FLOAT) {
            val fb = buf.asFloatBuffer()
            val frames = fb.remaining() / ch
            FloatArray(frames) { f ->
                var s = 0f
                for (c in 0 until ch) s += fb.get(f * ch + c)
                s / ch
            }
        } else {
            val sb = buf.asShortBuffer()
            val frames = sb.remaining() / ch
            FloatArray(frames) { f ->
                var s = 0f
                for (c in 0 until ch) s += sb.get(f * ch + c) / 32768f
                s / ch
            }
        }
    }

    /** Title, artist, duration, video flag, and a cover image if one exists. */
    fun readMetadata(path: String, coverPath: String): Map<String, Any?> {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(path)
            val title = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE)
            val artist = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)
                ?: r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUMARTIST)
            val duration = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            val hasVideo = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) == "yes"
            var cover: Bitmap? = null
            val art = r.embeddedPicture
            if (art != null) cover = BitmapFactory.decodeByteArray(art, 0, art.size)
            if (cover == null && hasVideo) {
                val at = (duration * 1000L * 0.3).toLong()
                cover = r.getFrameAtTime(at, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            }
            var coverSaved = false
            if (cover != null) {
                val scaled = scaleDown(cover, 720)
                File(coverPath).parentFile?.mkdirs()
                FileOutputStream(coverPath).use { scaled.compress(Bitmap.CompressFormat.JPEG, 86, it) }
                coverSaved = true
            }
            return mapOf(
                "title" to title,
                "artist" to artist,
                "durationMs" to duration.toDouble(),
                "hasVideo" to hasVideo,
                "cover" to coverSaved,
            )
        } finally {
            r.release()
        }
    }

    private fun scaleDown(b: Bitmap, maxSide: Int): Bitmap {
        val longest = max(b.width, b.height)
        if (longest <= maxSide) return b
        val s = maxSide.toFloat() / longest
        return Bitmap.createScaledBitmap(b, (b.width * s).roundToInt(), (b.height * s).roundToInt(), true)
    }
}

/** Streaming linear resampler with a box pre-filter when downsampling. */
class StreamResampler(srcRate: Int, dstRate: Int, private val sink: (Float) -> Unit) {
    private val step = srcRate.toDouble() / dstRate
    private val boxLen = if (step >= 1.5) step.roundToInt() else 1
    private val ring = FloatArray(boxLen)
    private var ringPos = 0
    private var ringSum = 0f
    private var ringFill = 0
    private var index = -1L
    private var prev = 0f
    private var t = 0.0

    fun push(x: Float) {
        val y = if (boxLen == 1) x else {
            ringSum += x - ring[ringPos]
            ring[ringPos] = x
            ringPos = (ringPos + 1) % boxLen
            if (ringFill < boxLen) ringFill++
            ringSum / ringFill
        }
        index++
        while (t <= index) {
            val frac = (t - (index - 1)).toFloat()
            sink(prev + (y - prev) * frac)
            t += step
        }
        prev = y
    }
}

class Pcm16Writer(private val out: BufferedOutputStream) {
    private val buffer = ByteBuffer.allocate(16384).order(ByteOrder.LITTLE_ENDIAN)
    var count = 0L
        private set

    fun write(sample: Float) {
        val v = (sample.coerceIn(-1f, 1f) * 32767f).roundToInt().toShort()
        buffer.putShort(v)
        count++
        if (!buffer.hasRemaining()) flush()
    }

    fun flush() {
        if (buffer.position() > 0) {
            out.write(buffer.array(), 0, buffer.position())
            buffer.clear()
        }
    }
}
