package com.ma3ak.reminder.wakeword

import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import org.json.JSONObject

/** A single hands-free reminder conversation. Parsing never authorizes a save. */
internal class RafiqConversation(
    private val parse: (String, JSONObject?) -> JSONObject,
    private val save: (JSONObject) -> Unit,
    private val now: () -> Instant = { Instant.now() },
) {
    constructor(api: RafiqApi, save: (JSONObject) -> Unit) : this(api::parse, save)

    data class Turn(
        val reply: String? = null,
        val finished: Boolean = false,
        val handled: Boolean = false,
    )

    private enum class Phase { IDLE, COLLECTING, CONFIRMING }
    private var phase = Phase.IDLE
    private var context: JSONObject? = null
    private var pending: JSONObject? = null
    val awaitingInput: Boolean get() = phase != Phase.IDLE

    fun reset() {
        phase = Phase.IDLE
        context = null
        pending = null
    }

    fun receive(text: String): Turn {
        val normalized = RafiqPhrases.normalize(text)
        if (normalized.isBlank()) return Turn()
        val command = RafiqPhrases.commandAfterWake(text)
        if (phase == Phase.IDLE && command == null) return Turn()

        // A new wake starts a fresh reminder, except when explicitly addressing
        // the current confirmation/cancellation to Rafiq by name.
        if (command != null) {
            val normalizedCommand = RafiqPhrases.normalize(command)
            if (phase != Phase.IDLE &&
                (normalizedCommand in RafiqPhrases.confirmations || normalizedCommand in RafiqPhrases.cancellations)) {
                return receive(command)
            }
            reset()
            phase = Phase.COLLECTING
            return if (command.isBlank()) {
                Turn("أيوه، معاك. قولّي أذكرك بإيه؟", handled = true)
            } else if (normalizedCommand in RafiqPhrases.confirmations) {
                Turn("لسه محتاج تفاصيل الموعد. قولّي الموعد يوم إيه والساعة كام؟", handled = true)
            } else if (normalizedCommand in RafiqPhrases.cancellations) {
                reset()
                Turn("تمام، لغيت المحادثة ومش هحفظ تذكير.", finished = true, handled = true)
            } else {
                parseDetails(command)
            }
        }
        if (normalized in RafiqPhrases.cancellations) {
            reset()
            return Turn("تمام، لغيت المحادثة ومش هحفظ تذكير.", finished = true, handled = true)
        }
        if (normalized in RafiqPhrases.confirmations) {
            val draft = pending
            if (phase != Phase.CONFIRMING || draft == null) {
                return Turn("لسه محتاج تفاصيل الموعد. قولّي الموعد يوم إيه والساعة كام؟", handled = true)
            }
            if (!complete(draft)) {
                pending = null
                phase = Phase.COLLECTING
                return Turn("وقت التذكير عدى أو تفاصيله مش كاملة. قولّي موعد جديد.", handled = true)
            }
            // Consume authorization before external work. A failed/uncertain save
            // cannot be repeated by an unrelated later utterance of "احفظ".
            reset()
            save(copy(draft))
            return Turn("حفظت التذكير. هفكرك في معاده.", finished = true, handled = true)
        }
        if (phase == Phase.CONFIRMING && normalized in RafiqPhrases.ambiguousReplies) {
            return Turn("عشان أحفظ الموعد قول «أيوه احفظ». ولو عايز تلغيه قول «إلغاء».", handled = true)
        }
        return parseDetails(text.trim())
    }

    private fun parseDetails(text: String): Turn {
        // A correction immediately invalidates the previous candidate, even if
        // its network request fails. It must receive a new spoken confirmation.
        pending = null
        phase = Phase.COLLECTING
        val response = copy(parse(text, context?.let(::copy)))
        context = supportedContext(response)
        if (!complete(response)) {
            val question = response.opt("question") as? String
            return Turn(
                question?.trim()?.takeIf { it.isNotEmpty() && it.length <= 500 }
                    ?: "تفاصيل الموعد مش كاملة. قولّي التاريخ والساعة ووقت التذكير تاني.",
                handled = true,
            )
        }
        pending = response
        phase = Phase.CONFIRMING
        return Turn(confirmationSummary(response), handled = true)
    }

    private fun supportedContext(response: JSONObject): JSONObject = JSONObject().apply {
        for (key in listOf("title", "date", "time")) {
            val value = response.opt(key) as? String
            if (!value.isNullOrBlank()) put(key, value)
        }
        val offset = response.opt("remind_before_minutes")
        if (offset is Number && offset.toDouble() == offset.toInt().toDouble() && offset.toInt() in 0..525600) {
            put("remind_before_minutes", offset.toInt())
        }
    }.takeIf { it.length() > 0 } ?: JSONObject()

    private fun complete(draft: JSONObject): Boolean {
        val title = draft.opt("title") as? String ?: return false
        if (title.trim().isEmpty() || title.length > 200) return false
        val missing = draft.optJSONArray("missing_fields") ?: return false
        val ambiguous = draft.optJSONArray("ambiguous_fields") ?: return false
        if (missing.length() != 0 || ambiguous.length() != 0) return false
        val offset = draft.opt("remind_before_minutes") as? Number ?: return false
        if (offset.toDouble() != offset.toInt().toDouble() || offset.toInt() !in 0..525600) return false
        return try {
            val date = LocalDate.parse(draft.getString("date"))
            val time = draft.getString("time")
            if (!Regex("(?:[01]\\d|2[0-3]):[0-5]\\d").matches(time)) return false
            val event = OffsetDateTime.parse(draft.getString("event_datetime"))
            val reminder = OffsetDateTime.parse(draft.getString("reminder_datetime"))
            event.toLocalDate() == date &&
                event.toLocalTime().format(DateTimeFormatter.ofPattern("HH:mm")) == time &&
                reminder.toInstant().isAfter(now()) &&
                !reminder.toInstant().isAfter(event.toInstant()) &&
                java.time.Duration.between(reminder.toInstant(), event.toInstant()).seconds == offset.toLong() * 60
        } catch (_: Exception) {
            false
        }
    }

    private fun confirmationSummary(draft: JSONObject): String {
        val event = OffsetDateTime.parse(draft.getString("event_datetime"))
        val reminder = OffsetDateTime.parse(draft.getString("reminder_datetime"))
        return "الموعد ${draft.getString("title")}، يوم ${spokenDate(event)} ${spokenTime(event)}. " +
            "وهفكرك يوم ${spokenDate(reminder)} ${spokenTime(reminder)}. " +
            "لو موافق قول «أيوه احفظ»، أو قول «إلغاء»."
    }

    private fun spokenDate(value: OffsetDateTime): String =
        value.format(DateTimeFormatter.ofPattern("d MMMM uuuu", Locale.forLanguageTag("ar-EG")))

    private fun spokenTime(value: OffsetDateTime): String {
        val hour = ((value.hour + 11) % 12) + 1
        val minutes = if (value.minute == 0) "" else " و${value.minute} دقيقة"
        val period = if (value.hour < 12) "صباحًا" else "مساءً"
        return "الساعة $hour$minutes $period"
    }

    private fun copy(value: JSONObject): JSONObject = JSONObject(value.toString())
}

/** Only complete explicit commands count; substrings and fuzzy names never do. */
object RafiqPhrases {
    private val marks = Regex("[\\u064b-\\u065f\\u0670\\u0640]")
    private val punctuation = Regex("[\\p{P}\\p{S}]+")
    private val whitespace = Regex("\\s+")

    val confirmations = setOf(
        "تاكيد", "اكد", "احفظ", "احفظه", "احفظ الموعد", "احفظ التذكير",
        "ايوه احفظ", "ايوه احفظه", "نعم احفظ", "تمام احفظ", "اكد واحفظ",
    )
    val cancellations = setOf(
        "الغي", "الغاء", "الغيه", "الغي الموعد", "الغي التذكير", "خلاص الغي",
        "لا", "لا تحفظ", "ما تحفظش", "متحفظش", "مش موافق", "لا الغي",
    )
    val ambiguousReplies = setOf("تمام", "ايوه", "نعم", "ماشي", "حاضر", "اوكي", "موافق", "اكيد")

    fun normalize(text: String): String = whitespace.replace(
        punctuation.replace(canonical(text), " "), " "
    ).trim()

    fun commandAfterWake(text: String): String? {
        // Preserve date/time punctuation in the remainder forwarded to the
        // existing parser, while allowing punctuation between the two words.
        val canonical = canonical(text).trim()
        val match = Regex("^[\\p{P}\\p{S}\\s]*يا[\\p{P}\\p{S}\\s]+رفيق(?=[\\p{P}\\p{S}\\s]|$)").find(canonical)
            ?: return null
        val remainder = canonical.substring(match.range.last + 1)
            .trimStart { it.isWhitespace() || (!it.isLetterOrDigit() && it !in "-+/") }
        return if (normalize(remainder).isBlank()) "" else remainder
    }

    private fun canonical(text: String): String = marks.replace(text, "")
        .replace('أ', 'ا').replace('إ', 'ا').replace('آ', 'ا').replace('ى', 'ي')
        .lowercase(Locale.ROOT)
}
