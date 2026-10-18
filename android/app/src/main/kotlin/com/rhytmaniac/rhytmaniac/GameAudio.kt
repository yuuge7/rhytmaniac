package com.rhytmaniac.rhytmaniac

import android.content.Context
import android.media.AudioAttributes as PlatformAudioAttributes
import android.media.SoundPool
import android.net.Uri
import android.os.SystemClock
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The app's only music player plus low-latency hit sounds.
 *
 * - Music: one long-lived ExoPlayer. Dart polls [position] while playing, so
 *   the game clock follows the real audio output (ExoPlayer derives it from
 *   AudioTrack timestamps), not an extrapolation that drifts after stalls.
 * - Sound effects: SoundPool, which never takes audio focus from the music.
 * - Leaving the app pauses the music here, whatever state Dart is in.
 *
 * Every call arrives on the main thread, which is also ExoPlayer's
 * application thread.
 */
class GameAudio(private val context: Context, private val channel: MethodChannel) : Player.Listener {
    private var player: ExoPlayer? = null
    private var loadedPath: String? = null
    private val pendingLoads = mutableListOf<MethodChannel.Result>()

    private var pool: SoundPool? = null
    private val samples = HashMap<String, Int>()
    private val readySamples = HashSet<Int>()

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "load" -> load(call.argument<String>("path")!!, result)
            "play" -> {
                player?.play()
                result.success(state())
            }
            "pause" -> {
                player?.pause()
                result.success(state())
            }
            "seek" -> {
                val ms = (call.argument<Number>("ms") ?: 0).toLong()
                player?.seekTo(ms.coerceAtLeast(0))
                result.success(state())
            }
            "setSpeed" -> {
                val speed = (call.argument<Number>("speed") ?: 1.0).toFloat()
                val pitch = (call.argument<Number>("pitch") ?: 1.0).toFloat()
                player?.playbackParameters = PlaybackParameters(speed, pitch)
                result.success(null)
            }
            "setVolume" -> {
                player?.volume = (call.argument<Number>("volume") ?: 1.0).toFloat().coerceIn(0f, 1f)
                result.success(null)
            }
            "position" -> result.success(state())
            "unload" -> {
                failPending("unloaded")
                player?.stop()
                player?.clearMediaItems()
                loadedPath = null
                result.success(null)
            }
            "sfxLoad" -> {
                result.success(sfxLoad(call.argument<String>("name")!!, call.argument<String>("path")!!))
            }
            "sfxPlay" -> {
                sfxPlay(
                    call.argument<String>("name")!!,
                    (call.argument<Number>("volume") ?: 1.0).toFloat(),
                    (call.argument<Number>("rate") ?: 1.0).toFloat(),
                )
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // --- music ----------------------------------------------------------------------

    private fun ensurePlayer(): ExoPlayer {
        player?.let { return it }
        val attrs = AudioAttributes.Builder()
            .setUsage(C.USAGE_GAME)
            .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
            .build()
        val p = ExoPlayer.Builder(context)
            .setAudioAttributes(attrs, true)
            .setHandleAudioBecomingNoisy(true)
            .build()
        p.addListener(this)
        player = p
        return p
    }

    private fun load(path: String, result: MethodChannel.Result) {
        val p = ensurePlayer()
        p.playWhenReady = false
        if (path == loadedPath && p.playerError == null && p.playbackState != Player.STATE_IDLE) {
            if (p.playbackState == Player.STATE_READY || p.playbackState == Player.STATE_ENDED) {
                result.success(info(p))
            } else {
                pendingLoads.add(result)
            }
            return
        }
        failPending("superseded")
        loadedPath = path
        p.setMediaItem(MediaItem.fromUri(Uri.fromFile(File(path))))
        p.prepare()
        pendingLoads.add(result)
    }

    private fun info(p: ExoPlayer): Map<String, Any> {
        val d = p.duration
        return mapOf("durationMs" to (if (d == C.TIME_UNSET) 0L else d))
    }

    private fun failPending(reason: String) {
        val waiting = pendingLoads.toList()
        pendingLoads.clear()
        for (r in waiting) r.error("load_failed", reason, null)
    }

    /** Position in ms, whether sound is coming out, and a monotonic timestamp. */
    private fun state(): Map<String, Any> {
        val p = player
        return mapOf(
            "pos" to (p?.currentPosition ?: 0L),
            "playing" to (p?.isPlaying ?: false),
            "wants" to (p?.playWhenReady ?: false),
            "state" to (p?.playbackState ?: Player.STATE_IDLE),
            "t" to SystemClock.elapsedRealtimeNanos() / 1000,
        )
    }

    override fun onPlaybackStateChanged(playbackState: Int) {
        val p = player ?: return
        if (playbackState == Player.STATE_READY || playbackState == Player.STATE_ENDED) {
            val waiting = pendingLoads.toList()
            pendingLoads.clear()
            for (r in waiting) r.success(info(p))
        }
        if (playbackState == Player.STATE_ENDED) send("completed")
    }

    override fun onIsPlayingChanged(isPlaying: Boolean) = send("playing")

    override fun onPlayerError(error: PlaybackException) {
        failPending(error.message ?: "playback error")
        loadedPath = null
        send("error", error.message ?: "playback error")
    }

    private fun send(type: String, message: String? = null) {
        val s = state().toMutableMap()
        s["type"] = type
        if (message != null) s["message"] = message
        channel.invokeMethod("event", s)
    }

    /** Called when the activity leaves the foreground. */
    fun onHostPause() {
        val p = player ?: return
        if (p.playWhenReady) {
            p.pause()
            send("interrupted")
        }
    }

    // --- sound effects ------------------------------------------------------------------

    private fun ensurePool(): SoundPool {
        pool?.let { return it }
        val attrs = PlatformAudioAttributes.Builder()
            .setUsage(PlatformAudioAttributes.USAGE_GAME)
            .setContentType(PlatformAudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val sp = SoundPool.Builder().setMaxStreams(16).setAudioAttributes(attrs).build()
        sp.setOnLoadCompleteListener { _, id, status -> if (status == 0) readySamples.add(id) }
        pool = sp
        return sp
    }

    private fun sfxLoad(name: String, path: String): Boolean {
        val sp = ensurePool()
        samples.remove(name)?.let {
            sp.unload(it)
            readySamples.remove(it)
        }
        val id = sp.load(path, 1)
        if (id == 0) return false
        samples[name] = id
        return true
    }

    private fun sfxPlay(name: String, volume: Float, rate: Float) {
        val sp = pool ?: return
        val id = samples[name] ?: return
        if (id !in readySamples) return
        val v = volume.coerceIn(0f, 1f)
        sp.play(id, v, v, 1, 0, rate.coerceIn(0.5f, 2f))
    }

    fun release() {
        failPending("released")
        player?.removeListener(this)
        player?.release()
        player = null
        loadedPath = null
        pool?.release()
        pool = null
        samples.clear()
        readySamples.clear()
    }
}
