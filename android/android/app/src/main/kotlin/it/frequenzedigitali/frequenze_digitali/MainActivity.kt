package it.frequenzedigitali.frequenze_digitali

import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val alertChannelName = "it.frequenzedigitali/anomaly_alert"
    private val mainHandler = Handler(Looper.getMainLooper())
    private var toneGenerator: ToneGenerator? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            alertChannelName,
        ).setMethodCallHandler { call, result ->
            if (call.method != "playBeep") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val volume = call.argument<Int>("volume")
            if (volume == null || volume !in 10..100) {
                result.error("invalid_volume", "Volume must be between 10 and 100.", null)
                return@setMethodCallHandler
            }

            try {
                playBeep(volume)
                result.success(null)
            } catch (error: Exception) {
                result.error("alert_playback_failed", error.message, null)
            }
        }
    }

    private fun playBeep(volume: Int) {
        releaseToneGenerator()
        val generator = ToneGenerator(AudioManager.STREAM_ALARM, volume)
        toneGenerator = generator
        if (!generator.startTone(ToneGenerator.TONE_PROP_BEEP, 180)) {
            releaseToneGenerator()
            throw IllegalStateException("Android could not play the alert tone.")
        }
        mainHandler.postDelayed({
            if (toneGenerator === generator) releaseToneGenerator()
        }, 220)
    }

    private fun releaseToneGenerator() {
        toneGenerator?.let {
            it.stopTone()
            it.release()
        }
        toneGenerator = null
    }

    override fun onDestroy() {
        mainHandler.removeCallbacksAndMessages(null)
        releaseToneGenerator()
        super.onDestroy()
    }
}
