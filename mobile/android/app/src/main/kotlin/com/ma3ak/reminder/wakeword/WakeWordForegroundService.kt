package com.ma3ak.reminder.wakeword

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import com.ma3ak.reminder.R
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/** Explicit user-started microphone service. Never restarts itself or opens UI. */
class WakeWordForegroundService : Service() {
    companion object {
        const val START = "com.ma3ak.reminder.wake.START"
        const val STOP = "com.ma3ak.reminder.wake.STOP"
        private const val CHANNEL = "wake_word_microphone"
        private const val NOTIFICATION_ID = 2147483646
    }
    private val commands = Executors.newSingleThreadExecutor()
    private var engine: AutoCloseable? = null
    @Volatile private var enabled = false
    private var profile = "ya_rafiq"
    private var phrase = "يا رفيق"
    private var baseUrl = "http://127.0.0.1:8000"
    private var captureGeneration = 0
    private var foregroundError: String? = null

    override fun onCreate() {
        super.onCreate()
        WakeWordRuntime.service = this
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "ميكروفون كلمة التنبيه", NotificationManager.IMPORTANCE_LOW).apply {
            description = "إشعار دائم أثناء تشغيل الاستماع الاختياري لكلمة التنبيه"
            setSound(null, null)
        })
        val notification = notification("بجهّز الاستماع والرد الصوتي…")
        try {
            if (Build.VERSION.SDK_INT >= 30) startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            else startForeground(NOTIFICATION_ID, notification)
        } catch (error: Exception) {
            foregroundError = error.message ?: "Cannot create the microphone foreground service. Open the app and verify permissions."
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getIntExtra("requestId", 0) ?: 0
        if (foregroundError != null) {
            WakeWordRuntime.publish(mapOf("type" to "status", "state" to "error", "enabled" to false,
                "listening" to false, "message" to foregroundError))
            if (id != 0) WakeWordRuntime.reply(id, WakeWordRuntime.state() + mapOf("ok" to false))
            stopSelf()
            return START_NOT_STICKY
        }
        when (intent?.action) {
            START -> submit("start", intent.getStringExtra("profile") ?: "ya_rafiq", id,
                intent.getStringExtra("baseUrl") ?: "http://127.0.0.1:8000")
            STOP -> submit("stop", profile, id)
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /** A late engine callback after explicit teardown must not crash its thread. */
    private fun callback(action: () -> Unit) {
        try { commands.execute { action() } }
        catch (error: RejectedExecutionException) {
            if (!commands.isShutdown) throw error
        }
    }

    internal fun submit(command: String, requestedProfile: String = profile, requestId: Int = 0,
                        requestedBaseUrl: String = baseUrl) {
        commands.execute {
            try {
                when (command) {
                    "start" -> {
                        closeEngine()
                        profile = requestedProfile
                        baseUrl = requestedBaseUrl
                        enabled = true
                        WakeWordRuntime.publish(mapOf("profile" to profile, "enabled" to true,
                            "state" to "loading", "listening" to false, "pendingDetection" to false, "type" to "status"))
                        listen()
                    }
                    "resume" -> if (enabled && engine == null) listen()
                    "pause" -> {
                        closeEngine()
                        if (enabled) update("paused", "الاستماع متوقف أثناء المحادثة.")
                    }
                    "acknowledgeDetection" -> WakeWordRuntime.publish(mapOf("pendingDetection" to false, "type" to "status"))
                    "stop" -> {
                        closeEngine()
                        enabled = false
                        update("disabled", "الاستماع لكلمة التنبيه مقفول.")
                        WakeWordRuntime.publish(mapOf("pendingDetection" to false))
                        stopForeground(STOP_FOREGROUND_REMOVE)
                        stopSelf()
                    }
                    else -> error("Unknown wake command.")
                }
                if (requestId != 0) WakeWordRuntime.reply(requestId, WakeWordRuntime.state() + mapOf("ok" to true))
            } catch (error: Exception) {
                enabled = false
                val message = error.message ?: "Wake word operation failed."
                update("error", message)
                if (requestId != 0) WakeWordRuntime.reply(requestId, WakeWordRuntime.state() + mapOf("ok" to false, "message" to message))
                // A microphone shutdown timeout must not falsely acknowledge release.
                // Keep its service alive for cleanup; a later stop can retry.
                if (engine == null) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }
    }

    private fun listen() {
        if (profile == "ya_rafiq") {
            phrase = "يا رفيق"
            val generation = ++captureGeneration
            val created = RafiqVoiceEngine(this, baseUrl,
                onStatus = { state, message -> callback {
                    if (enabled && generation == captureGeneration) update(state, message)
                } },
                onFailure = { error -> callback {
                    if (enabled && generation == captureGeneration) failCapture(error)
                } })
            engine = created
            try { created.start() } catch (error: Exception) {
                closeEngine()
                throw error
            }
            return
        }
        val bundle = WakeWordModels.load(this, profile)
        phrase = bundle.phrase
        val generation = ++captureGeneration
        val created = OpenWakeWordEngine(this, bundle,
            onDetected = { score -> callback {
                if (!enabled || generation != captureGeneration) return@callback
                try {
                    closeEngine()
                    update("detected", "سمعت «$phrase». افتح التطبيق عشان تقول موعدك.")
                    WakeWordRuntime.publish(mapOf("type" to "detected", "score" to score, "detectionId" to SystemClock.elapsedRealtimeNanos(),
                        "pendingDetection" to true, "listening" to false))
                } catch (error: Exception) { failCapture(error) }
            } },
            onFailure = { error -> callback {
                if (enabled && generation == captureGeneration) failCapture(error)
            } })
        engine = created
        try { created.start() } catch (error: Exception) {
            closeEngine()
            throw error
        }
        update("listening", "بسمع «$phrase» على الجهاز. اضغط إيقاف لإغلاق الميكروفون.")
    }

    private fun closeEngine() {
        ++captureGeneration
        val previous = engine ?: return
        previous.close()
        engine = null
    }

    private fun failCapture(error: Exception) {
        try { closeEngine() } catch (_: Exception) {}
        enabled = false
        update("error", error.message ?: "تعذّر تشغيل ميكروفون كلمة التنبيه.")
        if (engine == null) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
    }

    private fun update(state: String, message: String) {
        WakeWordRuntime.publish(mapOf("type" to "status", "state" to state, "enabled" to enabled,
            "profile" to profile, "phrase" to phrase, "listening" to (state == "listening"), "message" to message))
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(message))
    }

    private fun notification(message: String): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val open = launch?.let { PendingIntent.getActivity(this, 721, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE) }
        val stop = PendingIntent.getService(this, 722, Intent(this, WakeWordForegroundService::class.java).setAction(STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("معاك · ميكروفون كلمة التنبيه")
            .setContentText(message).setStyle(Notification.BigTextStyle().bigText(message))
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(Notification.Action.Builder(null, "إيقاف", stop).build()).build()
    }

    override fun onDestroy() {
        WakeWordRuntime.service = null
        enabled = false
        // Keep a fatal permission/TTS/microphone failure visible after stopSelf.
        // A deliberate stop already changed the snapshot to "disabled".
        val finalState = if (WakeWordRuntime.state()["state"] == "error") "error" else "disabled"
        WakeWordRuntime.publish(mapOf("type" to "status", "enabled" to false, "listening" to false,
            "state" to finalState, "pendingDetection" to false))
        commands.execute { try { closeEngine() } finally { commands.shutdown() } }
        super.onDestroy()
    }
}
