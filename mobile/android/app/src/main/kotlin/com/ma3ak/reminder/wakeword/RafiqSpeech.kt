package com.ma3ak.reminder.wakeword

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/** Audible background replies, independent of Flutter and a visible Activity. */
internal class RafiqSpeech(private val context: Context) : AutoCloseable {
    private val main = Handler(Looper.getMainLooper())
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private val ready = CompletableFuture<Unit>()
    private val lock = Any()
    @Volatile private var closed = false
    @Volatile private var tts: TextToSpeech? = null
    private var utteranceId: String? = null
    private var completion: CompletableFuture<Unit>? = null

    init {
        main.post {
            if (closed) return@post
            tts = TextToSpeech(context.applicationContext) { status ->
                // Some engines invoke init before the constructor assignment is visible.
                main.post { finishInitialization(status) }
            }
        }
    }

    private fun finishInitialization(status: Int) {
        if (closed) { tts?.shutdown(); ready.completeExceptionally(IllegalStateException("رفيق متوقف.")); return }
        val engine = tts
        if (status != TextToSpeech.SUCCESS || engine == null) {
            ready.completeExceptionally(IllegalStateException("تعذّر تشغيل الصوت. ثبّت محرّك تحويل النص لكلام يدعم العربية."))
            return
        }
        try {
            var language = engine.setLanguage(Locale.forLanguageTag("ar-EG"))
            if (language < TextToSpeech.LANG_AVAILABLE) language = engine.setLanguage(Locale.forLanguageTag("ar"))
            check(language >= TextToSpeech.LANG_AVAILABLE) {
                "الصوت العربي غير مثبت. نزّل العربية من إعدادات تحويل النص إلى كلام في الموبايل."
            }
            engine.voices?.filter { it.locale.language == "ar" && !it.isNetworkConnectionRequired }
                ?.sortedByDescending { it.locale.country == "EG" }
                ?.firstOrNull()?.let { engine.voice = it }
            engine.setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANT).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            engine.setSpeechRate(0.92f)
            engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(id: String?) {}
                override fun onDone(id: String?) = finish(id, null)
                @Deprecated("Android legacy callback")
                override fun onError(id: String?) = finish(id, IllegalStateException("تعذّر نطق رد رفيق."))
                override fun onError(id: String?, errorCode: Int) =
                    finish(id, IllegalStateException("تعذّر نطق رد رفيق ($errorCode)."))
                override fun onStop(id: String?, interrupted: Boolean) =
                    finish(id, InterruptedException("تم إيقاف صوت رفيق."))
            })
            ready.complete(Unit)
        } catch (error: Exception) { ready.completeExceptionally(error) }
    }

    private fun finish(id: String?, error: Exception?) {
        val pending = synchronized(lock) { if (id == utteranceId) completion else null } ?: return
        if (error == null) pending.complete(Unit) else pending.completeExceptionally(error)
    }

    /** Call off the main thread. */
    fun prepare() {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Prepare speech on a worker thread." }
        try { ready.get(10, TimeUnit.SECONDS) }
        catch (error: java.util.concurrent.ExecutionException) { throw error.cause ?: error }
    }

    /** Completes after the actual utterance is finished, never merely after enqueueing. */
    fun speak(text: String, isActive: () -> Boolean) {
        prepare()
        if (!isActive() || closed) return
        val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANT)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setOnAudioFocusChangeListener({ change ->
                if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) cancel()
            }, main).build()
        check(audioManager.requestAudioFocus(focus) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            "تعذّر تشغيل الرد الصوتي دلوقتي. جرّب بعد المكالمة أو الصوت الحالي."
        }
        val id = UUID.randomUUID().toString()
        val done = CompletableFuture<Unit>()
        synchronized(lock) { utteranceId = id; completion = done }
        main.post {
            if (!isActive() || closed) {
                done.completeExceptionally(InterruptedException("رفيق متوقف."))
                return@post
            }
            if (tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, id) != TextToSpeech.SUCCESS) {
                done.completeExceptionally(IllegalStateException("تعذّر تشغيل الرد الصوتي."))
            }
        }
        try {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(40)
            while (!done.isDone) {
                if (closed || !isActive()) { cancel(); return }
                if (System.nanoTime() >= deadline) {
                    cancel()
                    error("الرد الصوتي اتأخر. راجع إعدادات تحويل النص إلى كلام.")
                }
                try { done.get(100, TimeUnit.MILLISECONDS) }
                catch (_: java.util.concurrent.TimeoutException) {}
            }
            done.get()
        } catch (error: java.util.concurrent.ExecutionException) { throw error.cause ?: error }
        finally {
            audioManager.abandonAudioFocusRequest(focus)
            synchronized(lock) {
                if (utteranceId == id) { utteranceId = null; completion = null }
            }
        }
    }

    fun cancel() {
        synchronized(lock) { completion?.completeExceptionally(InterruptedException("تم إيقاف صوت رفيق.")) }
        main.post { tts?.stop() }
    }

    override fun close() {
        closed = true
        cancel()
        ready.completeExceptionally(InterruptedException("رفيق متوقف."))
        main.post { tts?.shutdown(); tts = null }
    }
}
