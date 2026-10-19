/*
 * Streaming algorithm adapted from msnilsen/openwakeword-android
 * commit b49f3ab14cf558ac0c2aef73a5e6c83da7a08558 (Apache-2.0),
 * and dscripka/openWakeWord AudioFeatures. See docs/wake-word.md for attribution.
 */
package com.ma3ak.reminder.wakeword

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.TensorInfo
import java.nio.FloatBuffer
import java.util.ArrayDeque

/** A real 16 kHz PCM -> mel -> speech embedding -> classifier ONNX pipeline. */
internal class OpenWakeWordEngine(
    private val context: Context,
    private val bundle: WakeWordModels.Bundle,
    private val onDetected: (Float) -> Unit,
    private val onFailure: (Exception) -> Unit,
) : AutoCloseable {
    private val environment = OrtEnvironment.getEnvironment()
    private var mel: OrtSession? = null
    private var embedding: OrtSession? = null
    private var classifier: OrtSession? = null
    @Volatile private var running = false
    @Volatile private var recorder: AudioRecord? = null
    private var thread: Thread? = null

    init {
        try {
            OrtSession.SessionOptions().use { options ->
                options.setIntraOpNumThreads(1)
                options.setInterOpNumThreads(1)
                mel = environment.createSession(bundle.mel, options)
                embedding = environment.createSession(bundle.embedding, options)
                classifier = environment.createSession(bundle.classifier, options)
            }
            validateSession(mel!!, longArrayOf(1, 1760), longArrayOf(1, 1, 8, 32))
            validateSession(embedding!!, longArrayOf(1, 76, 32, 1), longArrayOf(1, 1, 1, 96))
            validateSession(classifier!!, longArrayOf(1, 16, 96), longArrayOf(1, 1))
        } catch (error: Exception) {
            closeSessions()
            throw error
        }
    }

    private fun validateSession(session: OrtSession, input: LongArray, output: LongArray) {
        require(session.inputInfo.size == 1 && session.outputInfo.size == 1) { "Each wake model must have one input and output." }
        validateInfo(session.inputInfo.values.single().info as? TensorInfo, input, true)
        validateInfo(session.outputInfo.values.single().info as? TensorInfo, output, true)
    }

    private fun validateInfo(info: TensorInfo?, expected: LongArray, dynamic: Boolean = false) {
        require(info != null && info.type == OnnxJavaType.FLOAT && info.shape.size == expected.size) {
            "Wake model requires a FLOAT tensor of rank ${expected.size}."
        }
        require(info.shape.indices.all { (dynamic && info.shape[it] < 0) || info.shape[it] == expected[it] }) {
            "Unsupported wake tensor ${info.shape.contentToString()}; expected ${expected.contentToString()}."
        }
    }

    fun start() {
        check(thread == null) { "Wake engine has already started." }
        check(context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            "Microphone permission is required."
        }
        val minimum = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        check(minimum > 0) { "16 kHz mono recording is unsupported." }
        val audio = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, 16000,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(minimum, 1280 * 4))
        try {
            check(audio.state == AudioRecord.STATE_INITIALIZED) { "Cannot initialize the wake microphone." }
            audio.startRecording()
            check(audio.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "Cannot start the wake microphone." }
        } catch (error: Exception) { audio.release(); throw error }
        recorder = audio
        running = true
        thread = Thread({ capture(audio) }, "Ma3akWakeWord").also { it.start() }
    }

    private fun run(session: OrtSession, samples: FloatArray, shape: LongArray, expectedOutput: LongArray): FloatArray {
        OnnxTensor.createTensor(environment, FloatBuffer.wrap(samples), shape).use { tensor ->
            session.run(mapOf(session.inputNames.single() to tensor)).use { outputs ->
                val output = outputs[0] as? OnnxTensor ?: error("Wake output is not a tensor.")
                validateInfo(output.info, expectedOutput)
                val buffer = output.floatBuffer
                return FloatArray(buffer.remaining()).also { buffer.get(it) }.also { values ->
                    check(values.all { it.isFinite() }) { "Wake model produced a non-finite result." }
                }
            }
        }
    }

    private fun capture(audio: AudioRecord) {
        var detected: Float? = null
        var failure: Exception? = null
        try {
            val frame = ShortArray(1280)
            val overlap = FloatArray(480)
            var hasPreviousFrame = false
            val melFrames = ArrayDeque<FloatArray>()
            val features = ArrayDeque<FloatArray>()
            while (running) {
                var filled = 0
                while (running && filled < frame.size) {
                    val count = audio.read(frame, filled, frame.size - filled, AudioRecord.READ_BLOCKING)
                    if (!running) break
                    check(count > 0) { "Wake microphone read failed ($count)." }
                    filled += count
                }
                if (!running) break
                val slice = FloatArray(1760)
                overlap.copyInto(slice)
                for (i in frame.indices) slice[480 + i] = frame[i].toFloat()
                for (i in overlap.indices) overlap[i] = frame[frame.size - 480 + i].toFloat()
                if (!hasPreviousFrame) { hasPreviousFrame = true; continue }
                // PCM amplitudes deliberately remain int16 scale, as upstream expects.
                val spectrum = run(mel!!, slice, longArrayOf(1, 1760), longArrayOf(1, 1, 8, 32))
                repeat(8) { frameIndex ->
                    melFrames.addLast(FloatArray(32) { spectrum[frameIndex * 32 + it] / 10f + 2f })
                    if (melFrames.size > 76) melFrames.removeFirst()
                }
                // Warm up using real captured data; no synthetic wake predictions.
                if (melFrames.size < 76) continue
                val melInput = FloatArray(76 * 32)
                melFrames.forEachIndexed { index, row -> row.copyInto(melInput, index * 32) }
                features.addLast(run(embedding!!, melInput, longArrayOf(1, 76, 32, 1), longArrayOf(1, 1, 1, 96)))
                if (features.size > 16) features.removeFirst()
                if (features.size < 16) continue
                val classifierInput = FloatArray(16 * 96)
                features.forEachIndexed { index, row -> row.copyInto(classifierInput, index * 96) }
                val score = run(classifier!!, classifierInput, longArrayOf(1, 16, 96), longArrayOf(1, 1)).single()
                check(score in 0f..1f) { "Wake classifier score must be between 0 and 1." }
                if (score >= bundle.threshold) { detected = score; break }
            }
        } catch (error: Exception) { if (running) failure = error }
        finally {
            running = false
            try { audio.stop() } catch (_: Exception) {}
            audio.release()
            recorder = null
        }
        // Notify only after AudioRecord has released the microphone.
        if (detected != null) onDetected(detected)
        else if (failure != null) onFailure(failure)
    }

    override fun close() {
        running = false
        try { recorder?.stop() } catch (_: Exception) {}
        val processing = thread
        if (processing != null && processing !== Thread.currentThread()) {
            processing.join(5000)
            check(!processing.isAlive) { "Wake microphone is still shutting down. Retry before recording." }
        }
        thread = null
        closeSessions()
    }

    private fun closeSessions() {
        val sessions = listOfNotNull(classifier, embedding, mel)
        classifier = null; embedding = null; mel = null
        var failure: Exception? = null
        sessions.forEach { try { it.close() } catch (error: Exception) { failure = failure ?: error } }
        if (failure != null) throw failure!!
        // OrtEnvironment is process-shared: do not close it while another client may use it.
    }
}
