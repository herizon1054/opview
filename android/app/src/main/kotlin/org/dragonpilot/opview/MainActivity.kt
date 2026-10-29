package org.dragonpilot.opview

import android.app.AppOpsManager
import android.content.ContentValues
import android.content.Intent
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import android.os.Process
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.MediaCodecInfo
import android.media.MediaCodecList
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

    private val LOG_CHANNEL = "org.dragonpilot.opview/log"

    // Android 10+：存到「下載/opview/」（MediaStore，不需權限），再用該 content:// URI 分享
    // Android 9 以下：分享最後 100 KB 文字
    private fun shareLog(f: File): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, f.name)
                put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/opview")
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: return "error: MediaStore insert failed"
            contentResolver.openOutputStream(uri)?.use { out -> f.inputStream().use { it.copyTo(out) } }
                ?: return "error: open output failed"
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, f.name)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(send, "分享 opview log"))
            return "ok:下載/opview/${f.name}"
        }
        val text = f.readText().takeLast(100_000)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, f.name)
            putExtra(Intent.EXTRA_TEXT, text)
        }
        startActivity(Intent.createChooser(send, "分享 opview log"))
        return "text"
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

        // opview log：私有目錄、裝置資訊、分享
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LOG_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "dir" -> result.success(filesDir.absolutePath)
                "info" -> {
                    val m = HashMap<String, Any>()
                    m["manufacturer"] = Build.MANUFACTURER
                    m["model"] = Build.MODEL
                    m["release"] = Build.VERSION.RELEASE
                    m["sdk"] = Build.VERSION.SDK_INT
                    try {
                        val pi = packageManager.getPackageInfo(packageName, 0)
                        m["version"] = pi.versionName ?: "?"
                        @Suppress("DEPRECATION")
                        m["build"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) pi.longVersionCode else pi.versionCode.toLong()
                    } catch (e: Exception) { }
                    result.success(m)
                }
                // 手機 H.264 解碼器能力（判斷硬體解碼器能不能吃 comma 的 1928×1208 串流）
                "codecs" -> {
                    val w = (call.argument<Int>("width")) ?: 1928
                    val h = (call.argument<Int>("height")) ?: 1208
                    val out = ArrayList<String>()
                    try {
                        for (ci in MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos) {
                            if (ci.isEncoder || !ci.supportedTypes.any { it.equals("video/avc", true) }) continue
                            val vc = ci.getCapabilitiesForType("video/avc").videoCapabilities
                            val hw = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                                (if (ci.isHardwareAccelerated) "hw" else "sw") else "?"
                            out.add("${ci.name} [$hw] 寬 ${vc.supportedWidths} 高 ${vc.supportedHeights} " +
                                "對齊 ${vc.widthAlignment}x${vc.heightAlignment} " +
                                "${w}x${h}=${vc.isSizeSupported(w, h)} " +
                                "${w}x${h}@20fps=${vc.areSizeAndRateSupported(w, h, 20.0)}")
                        }
                    } catch (e: Exception) { out.add("查詢失敗：${e.message}") }
                    // 實際 configure 測試（不經過 WebRTC）：找出 c2.qti 在哪種設定下會拋 IllegalArgumentException。
                    // WebRTC 的 AndroidVideoDecoder 用 createVideoFormat(mime, 初始寬, 初始高) + 輸出到 Surface 來 configure，
                    // 初始寬高是 libwebrtc 的預設 320x180（之後才依串流重設）。
                    Thread {
                        val probe = ArrayList<String>()
                        val names = try {
                            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
                                .filter { !it.isEncoder && it.supportedTypes.any { t -> t.equals("video/avc", true) } }
                                .map { it.name }
                        } catch (e: Exception) { emptyList() }
                        for (name in names) {
                            for ((pw, ph) in listOf(320 to 180, w to h)) {
                                for (useSurface in listOf(false, true)) {
                                    probe.add("probe $name ${pw}x${ph} ${if (useSurface) "surface" else "buffer"} → " +
                                        configureProbe(name, pw, ph, useSurface))
                                }
                            }
                        }
                        runOnUiThread { result.success(out + probe) }
                    }.start()
                }
                "share" -> {
                    val path = call.arguments as? String
                    if (path == null) { result.success("error"); return@setMethodCallHandler }
                    try { result.success(shareLog(File(path))) }
                    catch (e: Exception) { result.success("error: ${e.message}") }
                }
                else -> result.notImplemented()
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
                // 以系統瀏覽器開啟網址（OP 設定網頁 http://<comma IP>:5088）
                "openUrl" -> {
                    val url = call.arguments as? String
                    if (url == null) { result.success(false) } else {
                        try {
                            val i = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url))
                            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(i)
                            result.success(true)
                        } catch (e: Exception) { result.success(false) }
                    }
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

    /** 直接用 MediaCodec configure/start 一次，回傳 OK 或例外。surface 模式用 detached SurfaceTexture（不需 GL context）。 */
    private fun configureProbe(name: String, w: Int, h: Int, useSurface: Boolean): String {
        var codec: android.media.MediaCodec? = null
        var st: android.graphics.SurfaceTexture? = null
        var surface: android.view.Surface? = null
        return try {
            codec = android.media.MediaCodec.createByCodecName(name)
            val fmt = android.media.MediaFormat.createVideoFormat("video/avc", w, h)
            if (useSurface) {
                st = android.graphics.SurfaceTexture(false)
                surface = android.view.Surface(st)
            } else {
                fmt.setInteger(android.media.MediaFormat.KEY_COLOR_FORMAT,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            }
            codec.configure(fmt, surface, null, 0)
            codec.start()
            codec.stop()
            "OK"
        } catch (e: Exception) {
            "${e.javaClass.simpleName}: ${e.message ?: ""}" +
                (if (e is android.media.MediaCodec.CodecException) " (diag=${e.diagnosticInfo}, code=${e.errorCode})" else "")
        } finally {
            try { codec?.release() } catch (_: Exception) {}
            surface?.release()
            st?.release()
        }
    }
}
