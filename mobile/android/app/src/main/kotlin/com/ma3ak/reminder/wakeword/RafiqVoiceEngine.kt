package com.ma3ak.reminder.wakeword

import android.content.Context
import android.os.PowerManager
import android.os.SystemClock

/** A complete voice conversation independent from the Flutter Activity. */
internal class RafiqVoiceEngine(
    context: Context,
    baseUrl: String,
    private val onStatus: (String, String) -> Unit,
    private val onFailure: (Exception) -> Unit,
) : AutoCloseable {
    private val audio = RafiqAudioCapture(context)
    private val speech = RafiqSpeech(context)
    private val api = RafiqApi(baseUrl)
    private val store = RafiqReminderStore(context)
    private val conversation = RafiqConversation(api) { draft ->
        check(running && !Thread.currentThread().isInterrupted) { "تم إيقاف المحادثة قبل الحفظ." }
        store.save(draft)
    }
    private val wakeLock = (context.getSystemService(Context.POWER_SERVICE) as PowerManager)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Ma3ak:RafiqListening").apply { setReferenceCounted(false) }
    @Volatile private var running = false
    private var worker: Thread? = null
    private var wakeLockRenewAt = 0L
    private var responseDeadline = 0L

    fun start() {
        check(worker == null) { "الاستماع شغال بالفعل." }
        running = true
        worker = Thread(::run, "Ma3akRafiqVoice").also { it.start() }
    }

    private fun run() {
        var failure: Exception? = null
        try {
            renewWakeLock()
            onStatus("loading", "بجهّز الصوت والاتصال باللاب…")
            speech.prepare()
            var needsHealth = true
            var failedRequests = 0
            while (running && !Thread.currentThread().isInterrupted) {
                renewWakeLock()
                if (needsHealth) {
                    try { api.health(); needsHealth = false }
                    catch (error: Exception) {
                        if (!running) break
                        failedRequests = minOf(failedRequests + 1, 4)
                        backoff(failedRequests, "تأكد إن الخادم شغال وكابل USB متوصل.")
                        continue
                    }
                }
                onStatus("listening", if (conversation.awaitingInput)
                    "بسمع ردك. اتكلم بعد انتهاء صوت رفيق."
                    else "بسمع «يا رفيق». المقاطع الصوتية بتتفسّر على اللاب.")
                val wasAwaiting = conversation.awaitingInput
                if (wasAwaiting && responseDeadline != 0L && SystemClock.elapsedRealtime() >= responseDeadline) {
                    conversation.reset()
                    reply("المحادثة انتهت من غير تأكيد. قول يا رفيق لو عايز تبدأ من جديد.")
                    continue
                }
                // Microphone/permission failures are fatal, not backend retries.
                val wav = audio.capture(wasAwaiting) { running }
                if (!running) break
                if (wav == null) {
                    if (wasAwaiting) {
                        conversation.reset()
                        reply("ما سمعتش رد. قول يا رفيق لما تكون جاهز.")
                    }
                    continue
                }
                onStatus("processing", "بفسّر الكلام على اللاب… استنى الرد قبل ما تتكلم.")
                val turn = try {
                    val text = api.transcribe(wav)
                    if (!running) break
                    if (wasAwaiting && responseDeadline != 0L && SystemClock.elapsedRealtime() >= responseDeadline) {
                        conversation.reset()
                        RafiqConversation.Turn("المحادثة انتهت من غير تأكيد. قول يا رفيق لو عايز تبدأ من جديد.",
                            finished = true, handled = true)
                    } else {
                        if (text.isBlank()) continue
                        conversation.receive(text).also { failedRequests = 0 }
                    }
                } catch (error: Exception) {
                    if (!running || Thread.currentThread().isInterrupted) break
                    val activeConversation = wasAwaiting || conversation.awaitingInput
                    conversation.reset()
                    needsHealth = true
                    failedRequests = minOf(failedRequests + 1, 4)
                    if (activeConversation) {
                        // A failed save may need reconciliation, so do not claim it was cancelled.
                        reply("ما قدرتش أكمل الطلب أو أتأكد من الحفظ. افتح مواعيدك وراجع الخادم قبل ما تحاول تاني.")
                    }
                    backoff(failedRequests, "تأكد إن الخادم شغال وكابل USB متوصل. ${error.message.orEmpty().take(180)}")
                    continue
                }
                // A TTS error stops the service: silent replies are never reported as success.
                if (turn.handled && turn.reply != null) reply(turn.reply)
            }
        } catch (error: Exception) {
            if (running && !Thread.currentThread().isInterrupted) failure = error
        } finally {
            running = false
            try { audio.close() } catch (_: Exception) {}
            try { api.close() } catch (_: Exception) {}
            try { speech.close() } catch (_: Exception) {}
            try { store.close() } catch (_: Exception) {}
            if (wakeLock.isHeld) wakeLock.release()
        }
        if (failure != null) onFailure(failure)
    }

    private fun backoff(failures: Int, message: String) {
        onStatus("retrying", "تعذّر إكمال الطلب. $message")
        val waitUntil = SystemClock.elapsedRealtime() + minOf(15_000L, 1_000L shl failures)
        while (running && SystemClock.elapsedRealtime() < waitUntil) Thread.sleep(250)
    }

    private fun reply(text: String) {
        if (!running) return
        onStatus("speaking", text)
        speech.speak(text) { running }
        responseDeadline = if (conversation.awaitingInput) SystemClock.elapsedRealtime() + 90_000L else 0L
        // Give speaker/room echo time to decay before reacquiring the microphone.
        if (running) Thread.sleep(350)
    }

    private fun renewWakeLock() {
        if (SystemClock.elapsedRealtime() >= wakeLockRenewAt || !wakeLock.isHeld) {
            wakeLock.acquire(10 * 60 * 1000L)
            wakeLockRenewAt = SystemClock.elapsedRealtime() + 5 * 60 * 1000L
        }
    }

    override fun close() {
        running = false
        speech.cancel()
        worker?.interrupt()
        audio.close()
        api.close()
        val previous = worker
        if (previous != null && previous !== Thread.currentThread()) {
            previous.join(5_000)
            check(!previous.isAlive) { "الميكروفون لسه بيقفل. حاول إيقاف الاستماع تاني." }
        }
        worker = null
    }
}
