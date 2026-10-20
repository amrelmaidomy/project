package com.ma3ak.reminder.wakeword

import java.time.Instant
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class RafiqConversationTest {
    private val clock = Instant.parse("2050-01-01T12:00:00Z")

    private fun complete(): JSONObject = JSONObject().apply {
        put("title", "دكتور")
        put("date", "2050-01-02")
        put("time", "17:00")
        put("remind_before_minutes", 120)
        put("event_datetime", "2050-01-02T17:00:00+02:00")
        put("reminder_datetime", "2050-01-02T15:00:00+02:00")
        put("missing_fields", JSONArray())
        put("ambiguous_fields", JSONArray())
        put("question", JSONObject.NULL)
    }

    @Test fun `only complete exact wake phrase starts a session`() {
        val conversation = RafiqConversation({ _, _ -> error("No parse expected") }, { error("No save expected") })
        for (text in listOf("رفيق", "يا مساعد", "يا رفيقي", "اسم صاحبي يا رفيق", "يا رفيقنا", "يارفيق")) {
            assertFalse("Unexpected wake from $text", conversation.receive(text).handled)
            assertFalse(conversation.awaitingInput)
        }
        for (text in listOf("«يَا، رَفِيق!»", "«يا رفيق»", "\"يا رفيق\"", "يا رفيق؟")) {
            val reply = conversation.receive(text)
            assertTrue(reply.handled)
            assertTrue(reply.reply!!.contains("أيوه"))
            assertTrue(conversation.awaitingInput)
        }
    }

    @Test fun `wake plus command retains date and time punctuation`() {
        var parsed: String? = null
        val conversation = RafiqConversation({ text, _ -> parsed = text; complete() }, { error("No save expected") }, { clock })
        conversation.receive("يا رفيق، عندي دكتور 2050-01-02 الساعة 17:00")
        assertEquals("عندي دكتور 2050-01-02 الساعة 17:00", parsed)
        assertTrue(conversation.awaitingInput)
    }

    @Test fun `parsing a complete draft never saves without explicit confirmation`() {
        var saves = 0
        val conversation = RafiqConversation({ _, _ -> complete() }, { saves++ }, { clock })
        conversation.receive("يا رفيق")
        val response = conversation.receive("عندي دكتور بكرة خمسة العصر فكرني قبله بساعتين")
        assertTrue(response.reply!!.contains("دكتور"))
        assertTrue(response.reply!!.contains("الساعة 5 مساءً"))
        assertTrue(response.reply!!.contains("الساعة 3 مساءً"))
        assertTrue(response.reply!!.contains("أيوه احفظ"))
        assertEquals(0, saves)
        for (reply in listOf("تمام", "أيوه", "نعم", "موافق")) {
            conversation.receive(reply)
            assertEquals(0, saves)
        }
        val saved = conversation.receive("أيوه، احفظ!")
        assertEquals(1, saves)
        assertTrue(saved.finished)
        assertFalse(conversation.awaitingInput)
        assertFalse(conversation.receive("احفظ").handled)
        assertEquals(1, saves)
    }

    @Test fun `all supported explicit confirmations authorize one save`() {
        for (confirmation in RafiqPhrases.confirmations) {
            var saves = 0
            val conversation = RafiqConversation({ _, _ -> complete() }, { saves++ }, { clock })
            conversation.receive("يا رفيق موعد")
            conversation.receive(confirmation)
            assertEquals("Confirmation: $confirmation", 1, saves)
        }
    }

    @Test fun `wake prefix can address the current confirmation without replacing draft`() {
        var saves = 0
        val conversation = RafiqConversation({ _, _ -> complete() }, { saves++ }, { clock })
        conversation.receive("يا رفيق موعد")
        assertTrue(conversation.receive("يا رفيق، تأكيد").finished)
        assertEquals(1, saves)
    }

    @Test fun `wake and confirmation alone cannot create a new reminder`() {
        val conversation = RafiqConversation({ _, _ -> error("No parse expected") }, { error("No save expected") })
        conversation.receive("يا رفيق تأكيد")
        assertTrue(conversation.awaitingInput)
        assertTrue(conversation.receive("يا رفيق إلغاء").finished)
        assertFalse(conversation.awaitingInput)
    }

    @Test fun `negated and cancel commands never save`() {
        for (cancel in listOf("إلغاء", "لا تحفظ", "ما تحفظش", "خلاص إلغي", "لا", "مش موافق")) {
            var saves = 0
            val conversation = RafiqConversation({ _, _ -> complete() }, { saves++ }, { clock })
            conversation.receive("يا رفيق موعد")
            assertTrue(conversation.receive(cancel).finished)
            assertEquals(0, saves)
            assertFalse(conversation.awaitingInput)
        }
    }

    @Test fun `substring confirmation never authorizes saving`() {
        var saves = 0
        val conversation = RafiqConversation({ _, _ -> complete() }, { saves++ }, { clock })
        conversation.receive("يا رفيق موعد")
        for (text in listOf("ما قلتش احفظ", "احفظ بس مش دلوقتي", "ايوه احفظ لا", "مش عايزك تقول اكد")) {
            conversation.receive(text)
            assertEquals(0, saves)
        }
    }

    @Test fun `followup carries supported context and asks missing question`() {
        var context: JSONObject? = null
        var calls = 0
        val conversation = RafiqConversation({ _, received ->
            calls++
            if (calls == 1) complete().apply {
                put("time", JSONObject.NULL)
                put("event_datetime", JSONObject.NULL)
                put("reminder_datetime", JSONObject.NULL)
                put("missing_fields", JSONArray().put("time"))
                put("question", "الساعة كام؟")
                put("secret_or_unknown_key", "must not propagate")
            } else {
                context = received
                complete()
            }
        }, { error("No save expected") }, { clock })
        val first = conversation.receive("يا رفيق عندي دكتور بكرة")
        assertEquals("الساعة كام؟", first.reply)
        conversation.receive("خمسة العصر")
        assertEquals("دكتور", context!!.getString("title"))
        assertEquals("2050-01-02", context!!.getString("date"))
        assertEquals(120, context!!.getInt("remind_before_minutes"))
        assertFalse(context!!.has("time"))
        assertFalse(context!!.has("event_datetime"))
        assertFalse(context!!.has("secret_or_unknown_key"))
    }

    @Test fun `incomplete or ambiguous responses cannot be confirmed`() {
        for (invalid in listOf(
            complete().put("missing_fields", JSONArray().put("time")),
            complete().put("ambiguous_fields", JSONArray().put("time")),
            complete().put("event_datetime", "2050-01-02T17:00:00"),
            complete().put("reminder_datetime", JSONObject.NULL),
            complete().put("remind_before_minutes", -1),
            complete().put("remind_before_minutes", 0.5),
            complete().put("date", "2050-01-03"),
            complete().put("reminder_datetime", "2049-01-02T15:00:00+02:00"),
        )) {
            var saves = 0
            val conversation = RafiqConversation({ _, _ -> invalid }, { saves++ }, { clock })
            conversation.receive("يا رفيق موعد")
            conversation.receive("احفظ")
            assertEquals("Invalid draft: $invalid", 0, saves)
        }
    }

    @Test fun `correction invalidates old pending draft until new complete parse`() {
        var calls = 0
        var saves = 0
        val conversation = RafiqConversation({ _, _ ->
            calls++
            if (calls == 1) complete() else complete().apply {
                put("time", JSONObject.NULL)
                put("missing_fields", JSONArray().put("time"))
            }
        }, { saves++ }, { clock })
        conversation.receive("يا رفيق موعد")
        conversation.receive("لا خلي الساعة ستة")
        conversation.receive("أيوه احفظ")
        assertEquals(0, saves)
    }

    @Test fun `network error during correction cannot leave stale confirmation active`() {
        var calls = 0
        var saves = 0
        val conversation = RafiqConversation({ _, _ ->
            calls++
            if (calls == 1) complete() else error("server unavailable")
        }, { saves++ }, { clock })
        conversation.receive("يا رفيق موعد")
        assertThrows(IllegalStateException::class.java) { conversation.receive("خليه الساعة سبعة") }
        conversation.receive("احفظ")
        assertEquals(0, saves)
    }

    @Test fun `new wake and manual reset discard the previous draft`() {
        var saves = 0
        val conversation = RafiqConversation({ _, _ -> complete() }, { saves++ }, { clock })
        conversation.receive("يا رفيق موعد")
        conversation.receive("يا رفيق")
        conversation.receive("احفظ")
        assertEquals(0, saves)
        conversation.reset()
        assertFalse(conversation.awaitingInput)
        assertFalse(conversation.receive("احفظ").handled)
    }

    @Test fun `failed save consumes confirmation instead of permitting duplicate retry`() {
        var attempts = 0
        val conversation = RafiqConversation({ _, _ -> complete() }, { attempts++; error("save uncertain") }, { clock })
        conversation.receive("يا رفيق موعد")
        assertThrows(IllegalStateException::class.java) { conversation.receive("احفظ") }
        assertFalse(conversation.awaitingInput)
        assertFalse(conversation.receive("احفظ").handled)
        assertEquals(1, attempts)
    }

    @Test fun `expired reminder requires a new date instead of saving`() {
        var currentTime = clock
        var saves = 0
        val conversation = RafiqConversation({ _, _ -> complete() }, { saves++ }, { currentTime })
        conversation.receive("يا رفيق موعد")
        currentTime = Instant.parse("2050-01-02T15:01:00Z")
        val response = conversation.receive("احفظ")
        assertTrue(response.reply!!.contains("عدى"))
        assertEquals(0, saves)
        assertTrue(conversation.awaitingInput)
    }

    @Test fun `empty transcript has no side effects`() {
        val conversation = RafiqConversation({ _, _ -> error("No parse expected") }, { error("No save expected") })
        assertFalse(conversation.receive("  ").handled)
        assertNull(conversation.receive("").reply)
    }
}
