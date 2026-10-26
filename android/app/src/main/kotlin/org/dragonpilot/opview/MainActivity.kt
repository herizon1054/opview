package org.dragonpilot.opview

import android.app.AppOpsManager
import android.os.Process
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.view.WindowManager
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "org.dragonpilot.opview/wake_lock"

    // Viewer-only brightness and picture-in-picture
    private val SYSTEM_CHANNEL = "org.dragonpilot.opview/system"
    private var systemChannel: MethodChannel? = null

    // shrink to a picture-in-picture window on Home; Dart turns this on while connected
    private var pipEnabled = false

    private fun pipSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE) &&
            (getSystemService(APP_OPS_SERVICE) as AppOpsManager).checkOpNoThrow(
                AppOpsManager.OPSTR_PICTURE_IN_PICTURE, Process.myUid(), packageName
            ) == AppOpsManager.MODE_ALLOWED

    @RequiresApi(Build.VERSION_CODES.O)
    private fun pipParams(): PictureInPictureParams {
        val b = PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12+: the system shrinks the app itself, with a smooth animation
            b.setAutoEnterEnabled(pipEnabled)
            b.setSeamlessResizeEnabled(true)
        }
        return b.build()
    }

    // Android 8-11: going Home calls this, and we ask for the window ourselves
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (pipEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S && pipSupported()) {
            try {
                enterPictureInPictureMode(pipParams())
            } catch (e: Exception) {
                // the head unit refused (PiP turned off for this app): stay as we are
            }
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        systemChannel?.invokeMethod("pipChanged", isInPictureInPictureMode)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "setKeepScreenOn") {
                val enabled = call.arguments as? Boolean ?: true
                if (enabled) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }

        val system = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_CHANNEL)
        systemChannel = system
        system.setMethodCallHandler { call, result ->
            when (call.method) {
                // whether going Home shrinks the app to a floating window
                "setPipEnabled" -> {
                    pipEnabled = call.arguments as? Boolean ?: false
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && pipSupported()) {
                        try {
                            setPictureInPictureParams(pipParams())
                        } catch (e: Exception) {
                            // not allowed on this head unit
                        }
                    }
                    result.success(pipSupported())
                }
                // 0..1 for this app's window only; below 0 hands brightness back to the system
                "setBrightness" -> {
                    val value = (call.arguments as? Number)?.toFloat() ?: -1f
                    val attrs = window.attributes
                    attrs.screenBrightness = if (value < 0f) {
                        WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    } else {
                        value.coerceIn(0.01f, 1f)
                    }
                    window.attributes = attrs
                    result.success(null)
                }
                "isInPip" -> result.success(
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && isInPictureInPictureMode)
                "enterPip" -> {
                    if (pipEnabled && pipSupported() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        try { result.success(enterPictureInPictureMode(pipParams())) }
                        catch (e: Exception) { result.success(false) }
                    } else { result.success(false) }
                }
                else -> result.notImplemented()
            }
        }
    }
}
