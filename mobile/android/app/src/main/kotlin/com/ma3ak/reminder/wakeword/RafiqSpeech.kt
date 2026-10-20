package com.ma3ak.reminder.wakeword

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit

/** Habibi WAV playback survives Activity detach and never uses an Android TTS voice. */
internal class RafiqSpeech(private val context: Context, private val api: RafiqApi) : AutoCloseable {
    private val main = Handler(Looper.getMainLooper())
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private val lock = Any()
    @Volatile private var closed = false
    private var generation = 0L
    private var current: Playback? = null

    private class Playback(val file: File, val done: CompletableFuture<Unit>) {
        var player: MediaPlayer? = null
        var focus: AudioFocusRequest? = null
        var released = false
        val cleanup = CompletableFuture<Unit>()
    }

    fun prepare() {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Prepare speech on a worker thread." }
        check(!closed) { "رفيق متوقف." }
    }

    fun speak(text: String, isActive: () -> Boolean, onPlaying: () -> Unit = {}) {
        prepare()
        val epoch = synchronized(lock) { generation }
        fun active() = !closed && isActive() && synchronized(lock) { epoch == generation }
        val audio = api.synthesize(text, ::active)
        if (!active()) return
        val file = File.createTempFile("habibi-reply-", ".wav", context.cacheDir)
        val playback = Playback(file, CompletableFuture())
        try {
            file.outputStream().use { it.write(audio) }
            synchronized(lock) {
                if (!active()) return
                check(current == null) { "رد صوتي آخر لسه شغال." }
                current = playback
            }
            main.post {
                if (!active()) {
                    playback.done.completeExceptionally(InterruptedException("تم إيقاف الرد."))
                    release(playback)
                    return@post
                }
                try {
                    val attributes = AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANT)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
                    val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                        .setAudioAttributes(attributes)
                        .setOnAudioFocusChangeListener({ change ->
                            if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                                if (synchronized(lock) { current === playback }) cancel()
                            }
                        }, main).build()
                    playback.focus = focus
                    check(audioManager.requestAudioFocus(focus) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                        "تعذّر تشغيل الرد الصوتي دلوقتي. جرّب بعد المكالمة الحالية."
                    }
                    val player = MediaPlayer()
                    playback.player = player
                    player.setAudioAttributes(attributes)
                    player.setDataSource(file.absolutePath)
                    player.setOnPreparedListener {
                        if (!playback.released && active()) { it.start(); onPlaying() }
                        else playback.done.completeExceptionally(InterruptedException("تم إيقاف الرد."))
                    }
                    player.setOnCompletionListener { playback.done.complete(Unit) }
                    player.setOnErrorListener { _, what, extra ->
                        playback.done.completeExceptionally(IllegalStateException("تعذّر تشغيل صوت Habibi ($what/$extra)."))
                        true
                    }
                    player.prepareAsync()
                } catch (error: Exception) {
                    playback.done.completeExceptionally(error)
                }
            }
            try { playback.done.get(195, TimeUnit.SECONDS) }
            catch (error: ExecutionException) { throw error.cause ?: error }
        } finally {
            main.post { release(playback) }
            // Stop may have interrupted this worker. Still wait for player release
            // before acknowledging that the microphone can be handed back.
            val interrupted = Thread.interrupted()
            try { playback.cleanup.get(5, TimeUnit.SECONDS) }
            finally { if (interrupted) Thread.currentThread().interrupt() }
        }
    }

    /** Main thread only; idempotent across cancel, completion and late callbacks. */
    private fun release(playback: Playback) {
        if (playback.released) return
        playback.released = true
        try {
            playback.player?.let { player ->
                player.setOnPreparedListener(null)
                player.setOnCompletionListener(null)
                player.setOnErrorListener(null)
                try { player.stop() } catch (_: Exception) {}
                player.release()
            }
            playback.focus?.let { audioManager.abandonAudioFocusRequest(it) }
            playback.file.delete()
            synchronized(lock) { if (current === playback) current = null }
            playback.cleanup.complete(Unit)
        } catch (error: Exception) { playback.cleanup.completeExceptionally(error) }
    }

    fun cancel() {
        val playback = synchronized(lock) { generation++; current }
        api.cancelActiveRequest()
        playback?.done?.completeExceptionally(InterruptedException("تم إيقاف رد رفيق."))
        if (playback != null) {
            if (Looper.myLooper() == Looper.getMainLooper()) release(playback)
            else main.post { release(playback) }
        }
    }

    override fun close() {
        closed = true
        cancel()
    }
}
