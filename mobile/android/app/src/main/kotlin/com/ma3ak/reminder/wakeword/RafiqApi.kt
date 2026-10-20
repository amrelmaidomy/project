package com.ma3ak.reminder.wakeword

import okhttp3.Call
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.URI
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Requests go only to the backend explicitly selected when the user opts in. */
internal class RafiqApi(baseUrl: String) : AutoCloseable {
    private val base: String
    private val lock = Any()
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .followRedirects(false).followSslRedirects(false).build()
    @Volatile private var closed = false
    private var activeCall: Call? = null
    private var cancellationGeneration = 0L

    init {
        val uri = URI(baseUrl)
        require(uri.scheme in setOf("http", "https") && !uri.host.isNullOrBlank() &&
            uri.userInfo == null && uri.query == null && uri.fragment == null) {
            "عنوان الخادم غير صالح. أعد فتح التطبيق وشغّل يا رفيق."
        }
        base = baseUrl.trimEnd('/')
    }

    fun health() {
        val result = requestJson("/health", null, null, timeoutSeconds = 15)
        check(result.optString("status") == "ok") { "خادم الصوت غير جاهز." }
    }

    fun transcribe(wav: ByteArray): String {
        val boundary = "Ma3ak${UUID.randomUUID().toString().replace("-", "")}"
        val body = ByteArrayOutputStream(wav.size + 256).apply {
            write(("--$boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.wav\"\r\n" +
                "Content-Type: audio/wav\r\n\r\n").toByteArray(Charsets.UTF_8))
            write(wav)
            write("\r\n--$boundary--\r\n".toByteArray(Charsets.UTF_8))
        }.toByteArray()
        return requestJson("/transcribe", body, "multipart/form-data; boundary=$boundary", allowNoSpeech = true,
            timeoutSeconds = 180).optString("text").trim()
    }

    fun parse(text: String, context: JSONObject?): JSONObject {
        val request = JSONObject().put("text", text).put("timezone", TimeZone.getDefault().id)
        if (context != null && context.length() > 0) request.put("context", context)
        return requestJson("/parse-reminder", request.toString().toByteArray(Charsets.UTF_8), "application/json; charset=utf-8")
    }

    /** Habibi PCM WAV is validated before any temporary file or MediaPlayer is created. */
    fun synthesize(text: String, isActive: () -> Boolean = { true }): ByteArray {
        require(text.isNotBlank()) { "الرد الصوتي فارغ." }
        val payload = JSONObject().put("text", text.trim()).toString().toByteArray(Charsets.UTF_8)
        val result = request("/synthesize", payload, "application/json; charset=utf-8", "audio/wav",
            MAX_AUDIO_BYTES, 300, isActive)
        checkSuccess(result)
        check(result.contentType in setOf("audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave")) {
            "خادم Habibi رجّع ملف غير صوتي. راجع إعدادات توليد الصوت على اللاب."
        }
        validateWav(result.bytes)
        return result.bytes
    }

    private fun requestJson(path: String, body: ByteArray?, contentType: String?,
                            allowNoSpeech: Boolean = false, timeoutSeconds: Long = 75): JSONObject {
        val response = request(path, body, contentType, "application/json", MAX_JSON_BYTES, timeoutSeconds)
        if (response.status == 422 && allowNoSpeech) return JSONObject().put("text", "")
        checkSuccess(response)
        return try { JSONObject(response.bytes.toString(Charsets.UTF_8)) }
        catch (_: Exception) { error("الخادم رجّع استجابة غير صالحة. راجع نافذة الخادم على اللاب.") }
    }

    private data class Reply(val status: Int, val contentType: String, val bytes: ByteArray)

    private fun request(path: String, body: ByteArray?, contentType: String?, accept: String,
                        maxBytes: Int, timeoutSeconds: Long, isActive: () -> Boolean = { true }): Reply {
        val request = Request.Builder().url(base + path).header("Accept", accept).apply {
            if (body != null) post(body.toRequestBody(checkNotNull(contentType).toMediaType()))
        }.build()
        val call = client.newBuilder().readTimeout(timeoutSeconds, TimeUnit.SECONDS)
            .callTimeout(timeoutSeconds + 15, TimeUnit.SECONDS).build().newCall(request)
        val generation = synchronized(lock) {
            check(!closed && !Thread.currentThread().isInterrupted && isActive()) { "تم إيقاف الاستماع." }
            check(activeCall == null) { "طلب صوت آخر لسه شغّال." }
            activeCall = call
            cancellationGeneration
        }
        fun ensureActive() {
            synchronized(lock) {
                check(!closed && generation == cancellationGeneration && !Thread.currentThread().isInterrupted && isActive()) {
                    "تم إيقاف الطلب الصوتي."
                }
            }
        }
        try {
            ensureActive()
            return call.execute().use { response ->
                ensureActive()
                val limit = if (response.isSuccessful) maxBytes else MAX_JSON_BYTES
                val responseBody = checkNotNull(response.body) { "الخادم رجّع استجابة فارغة." }
                val length = responseBody.contentLength()
                check(length <= limit) { "رد الخادم أكبر من الحد المسموح." }
                val bytes = responseBody.byteStream().use { input ->
                    val output = ByteArrayOutputStream(if (length in 1..limit.toLong()) length.toInt() else 4096)
                    val buffer = ByteArray(8192)
                    while (true) {
                        ensureActive()
                        val count = input.read(buffer)
                        if (count < 0) break
                        check(output.size() + count <= limit) { "رد الخادم أكبر من الحد المسموح." }
                        output.write(buffer, 0, count)
                    }
                    ensureActive()
                    output.toByteArray()
                }
                Reply(response.code, response.header("Content-Type").orEmpty().substringBefore(';').lowercase(), bytes)
            }
        } finally {
            call.cancel()
            synchronized(lock) { if (activeCall === call) activeCall = null }
        }
    }

    private fun checkSuccess(reply: Reply) {
        if (reply.status in 200..299) return
        val detail = runCatching { JSONObject(reply.bytes.toString(Charsets.UTF_8)).optString("detail") }.getOrDefault("")
        error(if (detail.isNotBlank() && detail.length <= 300) detail
            else "الخادم رجّع خطأ ${reply.status}. راجع نافذة الخادم على اللاب.")
    }

    /** Cancels a blocked upload/download without waiting for its long inference timeout. */
    fun cancelActiveRequest() {
        val call = synchronized(lock) { cancellationGeneration++; activeCall }
        call?.cancel()
    }

    override fun close() {
        synchronized(lock) { closed = true }
        cancelActiveRequest()
        client.connectionPool.evictAll()
        client.dispatcher.executorService.shutdown()
    }

    private fun validateWav(bytes: ByteArray) {
        fun invalid(): Nothing = error("ملف الرد الصوتي غير صالح. راجع خادم Habibi على اللاب.")
        fun tag(offset: Int) = bytes.copyOfRange(offset, offset + 4).toString(Charsets.US_ASCII)
        fun uint32(offset: Int) = ByteBuffer.wrap(bytes, offset, 4).order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xffffffffL
        fun uint16(offset: Int) = ByteBuffer.wrap(bytes, offset, 2).order(ByteOrder.LITTLE_ENDIAN).short.toInt() and 0xffff
        if (bytes.size < 44 || tag(0) != "RIFF" || tag(8) != "WAVE" || uint32(4) + 8 != bytes.size.toLong()) invalid()
        var offset = 12L
        var rate = 0L
        var block = 0L
        var dataSize = 0L
        while (offset + 8 <= bytes.size) {
            val start = offset.toInt()
            val length = uint32(start + 4)
            val end = offset + 8 + length
            if (end > bytes.size) invalid()
            when (tag(start)) {
                "fmt " -> {
                    if (length < 16 || uint16(start + 8) != 1) invalid()
                    val channels = uint16(start + 10)
                    rate = uint32(start + 12)
                    block = uint16(start + 20).toLong()
                    if (channels !in 1..2 || rate !in 8_000..48_000 ||
                        block != channels * 2L || uint16(start + 22) != 16 || uint32(start + 16) != rate * block) invalid()
                }
                "data" -> dataSize += length
            }
            offset = end + (length and 1)
        }
        if (rate == 0L || block == 0L || dataSize == 0L || dataSize % block != 0L || dataSize > rate * block * 180L) invalid()
    }

    private companion object {
        const val MAX_JSON_BYTES = 256 * 1024
        const val MAX_AUDIO_BYTES = 20 * 1024 * 1024
    }
}
