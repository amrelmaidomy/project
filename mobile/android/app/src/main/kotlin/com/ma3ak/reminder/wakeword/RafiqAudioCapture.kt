package com.ma3ak.reminder.wakeword

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.SystemClock
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.sqrt

/** Bounded, in-memory PCM utterances. Silence is discarded on the phone. */
internal class RafiqAudioCapture(private val context: Context) : AutoCloseable {
    private val lock = Any()
    @Volatile private var closed = false
    @Volatile private var recorder: AudioRecord? = null
    @Volatile private var owner: Thread? = null
    @Volatile private var released = CountDownLatch(0)

    /** Call on one worker thread. null means timeout/cancel or no actual speech. */
    fun capture(awaitingInput: Boolean, isActive: () -> Boolean): ByteArray? {
        check(!closed) { "ميكروفون رفيق متوقف." }
        check(context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            "اسمح بالميكروفون لتشغيل يا رفيق."
        }
        val minimum = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        check(minimum > 0) { "الجهاز لا يدعم تسجيل 16 kHz." }
        val audio = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, RATE,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(minimum, FRAME * 8))
        val completion = CountDownLatch(1)
        synchronized(lock) {
            if (closed) { audio.release(); return null }
            check(recorder == null) { "ميكروفون رفيق مستخدم بالفعل." }
            recorder = audio
            owner = Thread.currentThread()
            released = completion
        }
        try {
            check(audio.state == AudioRecord.STATE_INITIALIZED) { "تعذّر تجهيز ميكروفون رفيق." }
            if (!isActive() || closed) return null
            audio.startRecording()
            check(audio.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "تعذّر تشغيل ميكروفون رفيق." }
            return readUtterance(audio, awaitingInput, isActive)
        } catch (error: Exception) {
            if (closed || !isActive()) return null
            throw error
        } finally {
            try { audio.stop() } catch (_: Exception) {}
            audio.release()
            synchronized(lock) {
                if (recorder === audio) { recorder = null; owner = null }
            }
            completion.countDown()
        }
    }

    private fun readUtterance(audio: AudioRecord, awaitingInput: Boolean, isActive: () -> Boolean): ByteArray? {
        val frame = ShortArray(FRAME)
        val preRoll = ArrayDeque<ShortArray>()
        val samples = ArrayList<ShortArray>()
        val startDeadline = SystemClock.elapsedRealtime() + if (awaitingInput) 15_000 else 20_000
        val maxFrames = if (awaitingInput) 1_000 else 300
        var speech = false
        var noise = 80.0
        var consecutiveVoice = 0
        var voicedFrames = 0
        var silentFrames = 0
        while (!closed && isActive()) {
            var offset = 0
            while (offset < frame.size && !closed && isActive()) {
                val count = audio.read(frame, offset, frame.size - offset, AudioRecord.READ_BLOCKING)
                if (closed || !isActive()) return null
                check(count > 0) { "تعذّرت قراءة الميكروفون ($count)." }
                offset += count
            }
            if (closed || !isActive()) return null
            val rms = sqrt(frame.fold(0.0) { sum, value -> sum + value.toDouble() * value } / FRAME)
            val voiced = rms >= maxOf(260.0, noise * 2.8)
            if (!speech) {
                preRoll.addLast(frame.copyOf())
                if (preRoll.size > 15) preRoll.removeFirst()
                if (voiced) consecutiveVoice++ else {
                    consecutiveVoice = 0
                    // Adapt only to non-speech: a sustained word cannot raise its own gate.
                    noise = noise * 0.96 + rms.coerceAtMost(2_000.0) * 0.04
                }
                if (consecutiveVoice >= 3) {
                    speech = true
                    voicedFrames = consecutiveVoice
                    samples.addAll(preRoll)
                    preRoll.clear()
                } else if (SystemClock.elapsedRealtime() >= startDeadline) return null
            } else {
                samples.add(frame.copyOf())
                if (voiced) { voicedFrames++; silentFrames = 0 } else silentFrames++
                if (silentFrames >= 45 || samples.size >= maxFrames) {
                    if (voicedFrames >= 9) return wav(samples)
                    // A click/pop is not an utterance; continue waiting within the deadline.
                    speech = false
                    samples.clear()
                    consecutiveVoice = 0
                    voicedFrames = 0
                    silentFrames = 0
                    if (SystemClock.elapsedRealtime() >= startDeadline) return null
                }
            }
        }
        return null
    }

    private fun wav(frames: List<ShortArray>): ByteArray {
        val bytes = frames.sumOf { it.size } * 2
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray(Charsets.US_ASCII)).putInt(36 + bytes)
        header.put("WAVEfmt ".toByteArray(Charsets.US_ASCII)).putInt(16)
        header.putShort(1).putShort(1).putInt(RATE).putInt(RATE * 2).putShort(2).putShort(16)
        header.put("data".toByteArray(Charsets.US_ASCII)).putInt(bytes)
        val output = ByteArrayOutputStream(bytes + 44)
        output.write(header.array())
        val buffer = ByteBuffer.allocate(FRAME * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (frame in frames) {
            buffer.clear()
            frame.forEach { buffer.putShort(it) }
            output.write(buffer.array(), 0, frame.size * 2)
        }
        return output.toByteArray()
    }

    override fun close() {
        val audio: AudioRecord?
        val completion: CountDownLatch
        val capturing: Thread?
        synchronized(lock) {
            closed = true
            audio = recorder
            completion = released
            capturing = owner
        }
        try { audio?.stop() } catch (_: Exception) {}
        if (capturing !== Thread.currentThread()) {
            check(completion.await(5, TimeUnit.SECONDS)) { "ميكروفون رفيق لسه بيقفل. جرّب تاني." }
        }
    }

    private companion object {
        const val RATE = 16_000
        const val FRAME = 320 // 20 ms, 16-bit mono.
    }
}
