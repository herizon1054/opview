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
        installCrashRecorder()
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    // ---- 閃退診斷 ----
    // Java / Kotlin 例外（例如外掛在主執行緒丟出的 IllegalArgumentException）：寫到 last_crash.txt 再交給系統處理。
    // 原生崩潰（SIGSEGV 等）與 ANR 由系統記錄，下次啟動用 ApplicationExitInfo 讀出（Android 11+）。
    // 兩者都在下次啟動時由 Dart 的 AppLog 寫進 opview.log（"prev exit" 行），分享 log 就看得到。
    private fun installCrashRecorder() {
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        if (prev is CrashRecorder) return
        Thread.setDefaultUncaughtExceptionHandler(CrashRecorder(File(filesDir, "last_crash.txt"), prev))
    }

    private class CrashRecorder(val file: File, val prev: Thread.UncaughtExceptionHandler?) :
        Thread.UncaughtExceptionHandler {
        override fun uncaughtException(t: Thread, e: Throwable) {
            try {
                val sw = java.io.StringWriter()
                e.printStackTrace(java.io.PrintWriter(sw))
                file.writeText("time=${System.currentTimeMillis()} thread=${t.name}\n" + sw.toString().take(20_000))
            } catch (_: Throwable) {}
            prev?.uncaughtException(t, e)
        }
    }

    private fun exitReasonName(r: Int): String = when (r) {
        1 -> "EXIT_SELF"; 2 -> "SIGNALED"; 3 -> "LOW_MEMORY"; 4 -> "CRASH(Java)"; 5 -> "CRASH_NATIVE"
        6 -> "ANR"; 7 -> "INITIALIZATION_FAILURE"; 8 -> "PERMISSION_CHANGE"; 9 -> "EXCESSIVE_RESOURCE_USAGE"
        10 -> "USER_REQUESTED"; 11 -> "USER_STOPPED"; 12 -> "DEPENDENCY_DIED"; 13 -> "OTHER"
        14 -> "FREEZER"; 15 -> "PACKAGE_STATE_CHANGE"; 16 -> "PACKAGE_UPDATED"
        else -> "UNKNOWN($r)"
    }

    /** 上次（以及之前尚未回報過的）程式結束原因；每筆只回報一次 */
    private fun lastExitReport(): List<String> {
        val out = ArrayList<String>()
        val marker = File(filesDir, "last_exit_reported.txt")
        val reported = try { marker.readText().trim().toLong() } catch (_: Exception) { 0L }
        var newest = reported
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val am = getSystemService(ACTIVITY_SERVICE) as android.app.ActivityManager
                val infos = am.getHistoricalProcessExitReasons(packageName, 0, 5)
                for (info in infos.sortedBy { it.timestamp }) {
                    if (info.timestamp <= reported) continue
                    if (info.timestamp > newest) newest = info.timestamp
                    val ts = java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", java.util.Locale.US)
                        .format(java.util.Date(info.timestamp))
                    out.add("prev exit $ts ${exitReasonName(info.reason)} status=${info.status} " +
                        "importance=${info.importance} desc=${info.description ?: ""}")
                    if (info.reason == 5 || info.reason == 6) { // CRASH_NATIVE / ANR
                        try {
                            info.traceInputStream?.use { ins ->
                                val bytes = ins.readBytes()
                                val lines = if (info.reason == 6) {
                                    // ANR：文字 trace，只取主執行緒那段
                                    val text = String(bytes)
                                    val i = text.indexOf("\"main\"")
                                    (if (i >= 0) text.substring(i) else text).lineSequence().take(60).toList()
                                } else {
                                    // 原生崩潰：tombstone（protobuf），抽出可讀字串（signal、abort 訊息、.so 與函式名稱）
                                    Regex("[\\x20-\\x7e]{6,}").findAll(String(bytes, Charsets.ISO_8859_1))
                                        .map { it.value }
                                        .filter { it.contains(".so") || it.contains("SIG") || it.contains("Abort") ||
                                            it.contains("abort") || it.contains("fault") || it.contains("Java_") ||
                                            it.contains("::") || it.contains("cause") }
                                        .distinct().take(80).toList()
                                }
                                for (l in lines) out.add("prev exit trace: $l")
                            }
                        } catch (e: Exception) { out.add("prev exit trace 讀取失敗：${e.message}") }
                    }
                }
            } catch (e: Exception) { out.add("prev exit 查詢失敗：${e.message}") }
        }
        val crash = File(filesDir, "last_crash.txt")
        if (crash.exists()) {
            try {
                crash.readText().lineSequence().take(80).forEach { out.add("prev crash: $it") }
            } catch (_: Exception) {}
            crash.delete()
        }
        if (newest > reported) try { marker.writeText(newest.toString()) } catch (_: Exception) {}
        return out
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
                "lastExit" -> Thread { val r = lastExitReport(); runOnUiThread { result.success(r) } }.start()
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
                    // 註：之前在這裡用 MediaCodec + detached SurfaceTexture 實測 configure（configureProbe），
                    // 該 SurfaceTexture 被 GC finalize 時在 Android 16（Xiaomi）會 SIGSEGV 閃退
                    // （tombstone：SurfaceTexture_finalize → SurfaceTexture::setSurfaceTextureListener），已移除。
                    // 硬體解碼器寬度上限 1920 已確認，comma 端以 max_frame_width = 1440 處理。
                    result.success(out)
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
}
