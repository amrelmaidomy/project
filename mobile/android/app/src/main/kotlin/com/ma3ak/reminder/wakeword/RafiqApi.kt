package com.ma3ak.reminder.wakeword

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.TimeZone
import java.util.UUID

/** Requests go only to the backend explicitly selected when the user opts in. */
internal class RafiqApi(baseUrl: String) : AutoCloseable {
    private val base: String
    @Volatile private var connection: HttpURLConnection? = null
    @Volatile private var closed = false

    init {
        val uri = URI(baseUrl)
        require(uri.scheme in setOf("http", "https") && !uri.host.isNullOrBlank() &&
            uri.userInfo == null && uri.query == null && uri.fragment == null) {
            "عنوان الخادم غير صالح. أعد فتح التطبيق وشغّل يا رفيق."
        }
        base = baseUrl.trimEnd('/')
    }

    fun health() {
        val result = request("/health", null, null)
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
        return request("/transcribe", body, "multipart/form-data; boundary=$boundary", allowNoSpeech = true)
            .optString("text").trim()
    }

    fun parse(text: String, context: JSONObject?): JSONObject {
        val request = JSONObject().put("text", text).put("timezone", TimeZone.getDefault().id)
        if (context != null && context.length() > 0) request.put("context", context)
        return request("/parse-reminder", request.toString().toByteArray(Charsets.UTF_8), "application/json; charset=utf-8")
    }

    private fun request(path: String, body: ByteArray?, contentType: String?, allowNoSpeech: Boolean = false): JSONObject {
        check(!closed && !Thread.currentThread().isInterrupted) { "تم إيقاف الاستماع." }
        val active = URL(base + path).openConnection() as HttpURLConnection
        active.connectTimeout = 10_000
        active.readTimeout = 75_000
        active.instanceFollowRedirects = false
        active.setRequestProperty("Accept", "application/json")
        active.requestMethod = if (body == null) "GET" else "POST"
        connection = active
        try {
            check(!closed) { "تم إيقاف الاستماع." }
            if (body != null) {
                active.doOutput = true
                active.setRequestProperty("Content-Type", contentType)
                active.setFixedLengthStreamingMode(body.size)
                active.outputStream.use { it.write(body) }
            }
            val status = active.responseCode
            val stream = if (status in 200..299) active.inputStream else active.errorStream
            val response = stream?.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(4096)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    check(output.size() + count <= 256 * 1024) { "رد الخادم أكبر من المتوقع." }
                    output.write(buffer, 0, count)
                }
                output.toString("UTF-8")
            } ?: "{}"
            if (status == 422 && allowNoSpeech) return JSONObject().put("text", "")
            if (status !in 200..299) {
                val detail = runCatching { JSONObject(response).optString("detail") }.getOrDefault("")
                error(if (detail.isNotBlank() && detail.length <= 300) detail else "الخادم رجّع خطأ $status. راجع نافذة الخادم على اللاب.")
            }
            return JSONObject(response)
        } finally {
            active.disconnect()
            if (connection === active) connection = null
        }
    }

    override fun close() {
        closed = true
        connection?.disconnect()
        connection = null
    }
}
