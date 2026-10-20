package com.ma3ak.reminder.wakeword

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit

/** Saves through the existing Dart repository and notification plugin without an Activity. */
internal class RafiqReminderStore(context: Context) : AutoCloseable {
    private val context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var closed = false
    // Flutter engines and channels are created, called and destroyed on the main thread.
    private var current: Session? = null

    private class Session(val completion: CompletableFuture<Unit>) {
        var engine: FlutterEngine? = null
        var channel: MethodChannel? = null
        var ready = false
        var shutdownRequested = false
        var shuttingDown = false
        var saving = false
    }

    fun save(draft: JSONObject) {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Background save cannot block the main thread." }
        check(!closed) { "خدمة الحفظ اتقفلت." }
        val payload = jsonMap(draft).toMutableMap().apply {
            put("confirmed", true)
            put("expiresAt", System.currentTimeMillis() + 45_000L)
        }
        val session = Session(CompletableFuture())
        main.post { start(session, payload) }
        try {
            session.completion.get(50, TimeUnit.SECONDS)
        } catch (error: ExecutionException) {
            throw (error.cause ?: error)
        } finally {
            // If interrupted during a save, shutdown queues behind the Dart write
            // so its SQLite/alarm rollback is never killed halfway through.
            main.post { shutdown(session) }
        }
    }

    private fun start(session: Session, payload: Map<String, Any?>) {
        if (closed) {
            session.completion.completeExceptionally(IllegalStateException("خدمة الحفظ اتقفلت."))
            return
        }
        if (current != null) {
            session.completion.completeExceptionally(IllegalStateException("في موعد تاني بيتحفظ. راجع مواعيدك قبل المحاولة."))
            return
        }
        current = session
        try {
            val engine = FlutterEngine(context)
            session.engine = engine
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.ma3ak.reminder/rafiq_background")
            session.channel = channel
            channel.setMethodCallHandler { call, result ->
                if (call.method != "ready") { result.notImplemented(); return@setMethodCallHandler }
                session.ready = true
                result.success(null)
                if (closed || session.shutdownRequested) {
                    session.completion.completeExceptionally(IllegalStateException("اتلغى الحفظ قبل البداية."))
                    shutdown(session)
                } else {
                    session.saving = true
                    channel.invokeMethod("save", payload, object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            session.saving = false
                            val id = (result as? Map<*, *>)?.get("id") as? Number
                            if (id == null || id.toInt() <= 0) {
                                session.completion.completeExceptionally(IllegalStateException("تعذّر التأكد من حفظ الموعد. راجع مواعيدك."))
                            } else {
                                WakeWordRuntime.publish(mapOf("type" to "status", "reminderRevision" to SystemClock.elapsedRealtimeNanos()))
                                session.completion.complete(Unit)
                            }
                            shutdown(session)
                        }
                        override fun error(code: String, message: String?, details: Any?) {
                            session.saving = false
                            session.completion.completeExceptionally(IllegalStateException(message ?: "تعذّر حفظ الموعد. افتح التطبيق وراجع أذونات التنبيه."))
                            shutdown(session)
                        }
                        override fun notImplemented() {
                            session.saving = false
                            session.completion.completeExceptionally(IllegalStateException("خدمة الحفظ مش متاحة في النسخة دي."))
                            destroy(session)
                        }
                    })
                }
            }
            val loader = FlutterInjector.instance().flutterLoader()
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "rafiqBackgroundMain")
            )
            main.postDelayed({
                if (current === session && !session.ready) {
                    session.completion.completeExceptionally(IllegalStateException("تعذّر بدء خدمة الحفظ. افتح التطبيق وراجع مواعيدك."))
                    destroy(session)
                }
            }, 20_000L)
        } catch (error: Exception) {
            session.completion.completeExceptionally(error)
            destroy(session)
        }
    }

    private fun shutdown(session: Session) {
        session.shutdownRequested = true
        if (current !== session || session.shuttingDown || !session.ready) return
        session.shuttingDown = true
        // Dart serializes this after any in-flight save. Do not force-destroy
        // its engine on a timeout while an alarm/database write could be running.
        session.channel?.invokeMethod("shutdown", null, object : MethodChannel.Result {
            override fun success(result: Any?) = destroy(session)
            override fun error(code: String, message: String?, details: Any?) = destroy(session)
            override fun notImplemented() = destroy(session)
        })
    }

    private fun destroy(session: Session) {
        if (current !== session) return
        session.channel?.setMethodCallHandler(null)
        session.engine?.destroy()
        session.engine = null
        session.channel = null
        current = null
    }

    override fun close() {
        closed = true
        main.post { current?.let(::shutdown) }
    }

    private fun jsonMap(value: JSONObject): Map<String, Any?> = value.keys().asSequence().associateWith { key ->
        jsonValue(value.get(key))
    }

    private fun jsonValue(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> jsonMap(value)
        is JSONArray -> (0 until value.length()).map { jsonValue(value.get(it)) }
        else -> value
    }
}
