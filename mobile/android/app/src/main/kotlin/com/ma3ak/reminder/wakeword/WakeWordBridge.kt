package com.ma3ak.reminder.wakeword

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Channel adapter: UI opt-in is required before a microphone FGS is created. */
class WakeWordBridge(private val activity: FlutterActivity, messenger: BinaryMessenger) : AutoCloseable {
    private val methods = MethodChannel(messenger, "com.ma3ak.reminder/wake_word")
    private val events = EventChannel(messenger, "com.ma3ak.reminder/wake_word/events")
    private var sink: EventChannel.EventSink? = null
    private val pending = mutableSetOf<Int>()
    private val listener: (Map<String, Any?>) -> Unit = { event ->
        sink?.success(event + WakeWordModels.availability(activity))
    }

    init {
        methods.setMethodCallHandler(::handle)
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
                sink = eventSink
                WakeWordRuntime.listen(listener)
                eventSink.success(WakeWordRuntime.state() + WakeWordModels.availability(activity))
            }
            override fun onCancel(arguments: Any?) { sink = null; WakeWordRuntime.unlisten(listener) }
        })
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "status") {
            result.success(WakeWordRuntime.state() + WakeWordModels.availability(activity)); return
        }
        if (call.method !in setOf("start", "stop", "pause", "resume", "acknowledgeDetection")) {
            result.notImplemented(); return
        }
        if (call.method == "start") {
            if (!activity.hasWindowFocus()) { result.error("foreground_required", "افتح التطبيق قبل تشغيل ميكروفون كلمة التنبيه.", null); return }
            if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED ||
                (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)) {
                result.error("permission_required", "اسمح بالميكروفون والإشعارات قبل تشغيل كلمة التنبيه.", null); return
            }
            val profile = call.argument<String>("profile") ?: "ya_mosaed"
            if (profile !in setOf("ya_mosaed", "hey_jarvis")) { result.error("invalid_profile", "Unknown wake profile.", null); return }
            val available = WakeWordModels.availability(activity)
            if (available[if (profile == "ya_mosaed") "available" else "demoAvailable"] != true) {
                result.error("model_missing", if (profile == "ya_mosaed")
                    "نموذج يا مساعد المدرّب غير مرفق. راجع docs/wake-word.md."
                    else "نزّل أصول Hey Jarvis التجريبية بالسكريبت الموثّق أولًا.", null); return
            }
            val id = request(result)
            try {
                activity.startForegroundService(Intent(activity, WakeWordForegroundService::class.java)
                    .setAction(WakeWordForegroundService.START).putExtra("requestId", id).putExtra("profile", profile))
            } catch (error: Exception) {
                WakeWordRuntime.abandon(id); pending.remove(id)
                result.error("start_failed", error.message, null)
            }
            return
        }
        val service = WakeWordRuntime.service
        if (service == null) {
            result.success(WakeWordRuntime.state() + WakeWordModels.availability(activity)); return
        }
        service.submit(call.method, requestId = request(result))
    }

    private fun request(result: MethodChannel.Result): Int {
        var id = 0
        id = WakeWordRuntime.register { response ->
            pending.remove(id)
            if (response["ok"] == false) result.error("wake_failed", response["message"] as? String, null)
            else result.success(response + WakeWordModels.availability(activity))
        }
        pending.add(id)
        return id
    }

    override fun close() {
        WakeWordRuntime.unlisten(listener)
        pending.forEach { WakeWordRuntime.abandon(it) }; pending.clear()
        sink = null
        methods.setMethodCallHandler(null); events.setStreamHandler(null)
        // Explicit opt-in service stays alive when Flutter detaches. Stop action remains available.
    }
}
