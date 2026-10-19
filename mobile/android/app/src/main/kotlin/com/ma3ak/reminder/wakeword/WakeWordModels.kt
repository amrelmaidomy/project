package com.ma3ak.reminder.wakeword

import android.content.Context
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.security.MessageDigest

/** Only explicitly installed, checksum-pinned assets are eligible for inference. */
internal object WakeWordModels {
    const val DIRECTORY = "wakeword"
    private const val MAX_MODEL_BYTES = 32 * 1024 * 1024
    data class Bundle(val mel: ByteArray, val embedding: ByteArray, val classifier: ByteArray,
                      val phrase: String, val threshold: Float)

    fun availability(context: Context): Map<String, Any> = mapOf(
        "available" to present(context, "ya_mosaed"),
        "demoAvailable" to present(context, "hey_jarvis"),
    )

    private fun manifest(context: Context): JSONObject = context.assets
        .open("$DIRECTORY/models.json").bufferedReader().use { JSONObject(it.readText()) }
        .also { require(it.getInt("version") == 1) { "Unsupported wake model manifest version." } }

    private fun present(context: Context, profile: String): Boolean = try {
        val json = manifest(context)
        val entries = listOf(json.getJSONObject("mel"), json.getJSONObject("embedding"),
            json.getJSONObject("classifiers").getJSONObject(profile))
        entries.all { entry ->
            require(entry.getString("sha256").matches(Regex("[a-fA-F0-9]{64}")))
            context.assets.open("$DIRECTORY/${filename(entry)}").use { it.read() >= 0 }
        }
    } catch (_: Exception) { false }

    private fun filename(entry: JSONObject): String = entry.getString("file").also {
        require(it.matches(Regex("[a-zA-Z0-9_.-]+\\.onnx"))) { "Unsafe wake model filename." }
    }

    private fun readVerified(context: Context, entry: JSONObject): ByteArray {
        val name = filename(entry)
        val expected = entry.getString("sha256").lowercase()
        require(expected.matches(Regex("[a-f0-9]{64}"))) { "Missing SHA-256 for $name." }
        val bytes = context.assets.open("$DIRECTORY/$name").use { stream ->
            val output = ByteArrayOutputStream()
            val chunk = ByteArray(64 * 1024)
            var total = 0
            while (true) {
                val count = stream.read(chunk)
                if (count < 0) break
                total += count
                require(total <= MAX_MODEL_BYTES) { "Wake model exceeds the size limit: $name." }
                output.write(chunk, 0, count)
            }
            output.toByteArray()
        }
        require(bytes.isNotEmpty() && bytes.size <= MAX_MODEL_BYTES) { "Wake model size is invalid: $name." }
        val actual = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        require(actual == expected) { "Wake model checksum mismatch: $name. Reinstall verified assets." }
        return bytes
    }

    fun load(context: Context, profile: String): Bundle {
        require(profile in setOf("ya_mosaed", "hey_jarvis")) { "Unknown wake profile." }
        val json = try { manifest(context) } catch (error: Exception) {
            throw IllegalStateException("Wake models are absent. Install pinned assets using scripts/fetch_wake_models.py.", error)
        }
        val classifier = json.getJSONObject("classifiers").optJSONObject(profile)
            ?: throw IllegalStateException(if (profile == "ya_mosaed")
                "No trained يا مساعد model is installed. See docs/wake-word.md."
                else "Hey Jarvis demo assets are absent. Run scripts/fetch_wake_models.py --demo.")
        val phrase = classifier.getString("phrase")
        require(phrase == if (profile == "ya_mosaed") "يا مساعد" else "Hey Jarvis") {
            "The classifier phrase does not match the selected profile."
        }
        val threshold = classifier.optDouble("threshold", 0.6).toFloat()
        require(threshold.isFinite() && threshold in 0.01f..0.99f) { "Invalid wake threshold." }
        return Bundle(readVerified(context, json.getJSONObject("mel")),
            readVerified(context, json.getJSONObject("embedding")),
            readVerified(context, classifier), phrase, threshold)
    }
}
