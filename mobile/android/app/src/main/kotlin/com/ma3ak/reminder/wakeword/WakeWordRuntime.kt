package com.ma3ak.reminder.wakeword

import android.os.Handler
import android.os.Looper
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/** Process-local events survive a Flutter engine detach, without launching activities. */
internal object WakeWordRuntime {
    @Volatile var service: WakeWordForegroundService? = null
    private val main = Handler(Looper.getMainLooper())
    private val listeners = CopyOnWriteArraySet<(Map<String, Any?>) -> Unit>()
    private val requests = ConcurrentHashMap<Int, (Map<String, Any?>) -> Unit>()
    private val ids = AtomicInteger()
    @Volatile private var snapshot: Map<String, Any?> = mapOf(
        "type" to "status", "state" to "disabled", "enabled" to false,
        "listening" to false, "profile" to "ya_rafiq", "phrase" to "يا رفيق",
        "pendingDetection" to false,
        "message" to "يا رفيق مقفول. شغّله من شاشة المساعد للاستماع والرد في الخلفية عبر خادمك.",
    )

    fun state(): Map<String, Any?> = snapshot.toMap()

    @Synchronized fun publish(values: Map<String, Any?>) {
        snapshot = snapshot + values
        val event = snapshot.toMap()
        main.post { listeners.forEach { it(event) } }
    }

    fun listen(listener: (Map<String, Any?>) -> Unit) { listeners.add(listener) }
    fun unlisten(listener: (Map<String, Any?>) -> Unit) { listeners.remove(listener) }
    fun register(callback: (Map<String, Any?>) -> Unit): Int = ids.incrementAndGet().also { requests[it] = callback }
    fun reply(id: Int, value: Map<String, Any?>) { main.post { requests.remove(id)?.invoke(value) } }
    fun abandon(id: Int) { requests.remove(id) }
}
