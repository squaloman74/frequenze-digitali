package it.frequenzedigitali.frequenze_digitali

import android.content.Intent
import android.media.AudioManager
import android.media.ToneGenerator
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val alertChannelName = "it.frequenzedigitali/anomaly_alert"
    private val apkInstallerChannelName = "it.frequenzedigitali/apk_installer"
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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            apkInstallerChannelName,
        ).setMethodCallHandler { call, result ->
            if (call.method != "installApk") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val apkPath = call.argument<String>("path")
            if (apkPath == null) {
                result.error("invalid_apk_path", "APK path is required.", null)
                return@setMethodCallHandler
            }

            try {
                result.success(installApk(apkPath))
            } catch (error: Exception) {
                result.error("apk_install_failed", error.message, null)
            }
        }
    }

    private fun installApk(apkPath: String): Boolean {
        val updatesDirectory = File(cacheDir, "updates").canonicalFile
        val apkFile = File(apkPath).canonicalFile
        if (!apkFile.path.startsWith("${updatesDirectory.path}${File.separator}") ||
            !apkFile.isFile
        ) {
            throw IllegalArgumentException("The downloaded APK is not available.")
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ),
            )
            return false
        }

        val apkUri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            apkFile,
        )
        val installIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(apkUri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(installIntent)
        return true
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
