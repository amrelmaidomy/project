package com.ma3ak.reminder.wakeword

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.TimeZone
import java.util.concurrent.TimeUnit

/** Real HTTP tests: no Android/network mocks can hide the mobile API contract. */
class RafiqApiTest {
    @Test fun healthUsesGetAndRequiresReadyStatus() {
        Backend { Reply(body = """{"status":"ok"}""") }.use { backend ->
            RafiqApi(backend.url).use { it.health() }
            val request = backend.takeRequest()
            assertEquals("GET", request.method)
            assertEquals("/health", request.path)
        }
        Backend { Reply(body = """{"status":"starting"}""") }.use { backend ->
            RafiqApi(backend.url).use { api ->
                assertThrows(IllegalStateException::class.java) { api.health() }
            }
        }
    }

    @Test fun transcribeUploadsOriginalWavInMultipartFileField() {
        val wav = ByteBuffer.allocate(48).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()).putInt(40).put("WAVEfmt ".toByteArray())
            putInt(16).putShort(1).putShort(1).putInt(16_000).putInt(32_000)
            putShort(2).putShort(16).put("data".toByteArray()).putInt(4)
            putShort(1_234).putShort(-2_345)
        }.array()
        Backend { Reply(body = """{"text":"  يا رفيق  "}""") }.use { backend ->
            RafiqApi(backend.url).use { api -> assertEquals("يا رفيق", api.transcribe(wav)) }
            val request = backend.takeRequest()
            assertEquals("POST", request.method)
            assertEquals("/transcribe", request.path)
            val contentType = request.getHeader("Content-Type").orEmpty()
            assertTrue(contentType.startsWith("multipart/form-data; boundary="))
            val boundary = contentType.substringAfter("boundary=")
            val prefix = ("--$boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.wav\"\r\n" +
                "Content-Type: audio/wav\r\n\r\n").toByteArray()
            val suffix = "\r\n--$boundary--\r\n".toByteArray()
            assertArrayEquals(prefix + wav + suffix, request.body.readByteArray())
        }
    }

    @Test fun noSpeechDoesNotBecomeAConnectionFailure() {
        Backend { Reply(status = 422, body = """{"detail":"مفيش كلام واضح"}""") }.use { backend ->
            RafiqApi(backend.url).use { api -> assertEquals("", api.transcribe(byteArrayOf(1, 2))) }
        }
    }

    @Test fun parseSendsDeviceTimezoneAndClarificationContext() {
        val context = JSONObject().put("title", "دكتور").put("date", "2030-10-21")
        Backend { Reply(body = """{"time":"17:00","missing_fields":[]}""") }.use { backend ->
            RafiqApi(backend.url).use { api ->
                assertEquals("17:00", api.parse("خمسة العصر", context).getString("time"))
            }
            val request = backend.takeRequest()
            assertEquals("POST", request.method)
            assertEquals("/parse-reminder", request.path)
            assertTrue(request.getHeader("Content-Type").orEmpty().startsWith("application/json"))
            val body = JSONObject(request.body.readUtf8())
            assertEquals("خمسة العصر", body.getString("text"))
            assertEquals(TimeZone.getDefault().id, body.getString("timezone"))
            assertEquals("دكتور", body.getJSONObject("context").getString("title"))
            assertEquals("2030-10-21", body.getJSONObject("context").getString("date"))
        }
    }

    @Test fun redirectIsReportedWithoutSendingAudioToAnotherLocation() {
        Backend { Reply(status = 307, body = "{}", location = "/redirect-target") }.use { backend ->
            RafiqApi(backend.url).use { api ->
                val failure = assertThrows(IllegalStateException::class.java) {
                    api.transcribe(byteArrayOf(1, 2))
                }
                assertTrue(failure.message.orEmpty().contains("307"))
            }
            assertEquals("/transcribe", backend.takeRequest().path)
            assertEquals(1, backend.requestCount)
        }
    }

    @Test fun rejectsNonHttpAndCredentialOrQueryBearingBaseUrls() {
        listOf("file:///tmp/backend", "ftp://example.com", "http://user:pass@example.com",
            "http://example.com/?token=example", "http://example.com/#fragment", "/relative")
            .forEach { url ->
                assertThrows("URL should be rejected: $url", IllegalArgumentException::class.java) { RafiqApi(url) }
            }
    }

    private data class Reply(val status: Int = 200, val body: String, val location: String? = null)

    private class Backend(response: () -> Reply) : AutoCloseable {
        private val server = MockWebServer().apply {
            val reply = response()
            enqueue(MockResponse().setResponseCode(reply.status).setBody(reply.body)
                .setHeader("Content-Type", "application/json; charset=utf-8")
                .apply { reply.location?.let { setHeader("Location", it) } })
            // A redirect regression gets an immediate response and fails without a read-timeout delay.
            enqueue(MockResponse().setBody("""{"status":"ok","text":"unexpected redirect"}"""))
            start()
        }
        val url get() = server.url("/").toString()
        val requestCount get() = server.requestCount
        fun takeRequest() = checkNotNull(server.takeRequest(2, TimeUnit.SECONDS)) { "Backend request was not received." }
        override fun close() = server.shutdown()
    }
}
