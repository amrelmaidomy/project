package com.ma3ak.reminder

import com.ma3ak.reminder.wakeword.WakeWordBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var wakeWordBridge: WakeWordBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        wakeWordBridge?.close()
        wakeWordBridge = WakeWordBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onDestroy() {
        wakeWordBridge?.close()
        wakeWordBridge = null
        super.onDestroy()
    }
}
