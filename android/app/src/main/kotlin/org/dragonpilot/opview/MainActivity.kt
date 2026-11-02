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
import io.flutter.plugin.common.EventChannel
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
            deleteOldSharedLogs()
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

    /** 「下載/opview/」裡 opview 自己存的舊 log 只留 3 天內的（App 刪自己建立的 MediaStore 檔不需權限） */
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun deleteOldSharedLogs() {
        try {
            val cutoffSec = System.currentTimeMillis() / 1000 - 3L * 24 * 3600
            contentResolver.delete(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ? AND " +
                    "${MediaStore.MediaColumns.DISPLAY_NAME} LIKE ? AND " +
                    "${MediaStore.MediaColumns.DATE_ADDED} < ?",
                arrayOf(Environment.DIRECTORY_DOWNLOADS + "/opview%", "opview-log-%", cutoffSec.toString()))
        } catch (_: Exception) {
            // 其他 App 建立的同名檔或系統不允許：略過
        }
    }

    // ---- 起步提醒聲音 ----
    // 語音：TextToSpeech，優先使用 Google 文字轉語音引擎（com.google.android.tts），語言 zh-TW；
    // 使用 Google 台灣中文的預設聲音（男聲或女聲依系統「文字轉語音」設定）。音訊用途設為導航語音：播放時系統會壓低音樂音量。
    private var tts: android.speech.tts.TextToSpeech? = null
    private var ttsReady = false
    private var pendingSpeech: String? = null

    // Android 11 以上（targetSdk 30+）：AndroidManifest 必須在 <queries> 宣告 TTS_SERVICE，
    // 否則看不到任何文字轉語音引擎 → TextToSpeech 初始化失敗、完全沒有語音（v30 以前的問題）。
    private var ttsNoChinese = false
    private var ttsEngine = "-"

    /** 回傳目前狀態（給 Dart 寫入 log、顯示在試聽按鈕下方） */
    private fun speakAlert(text: String): String {
        if (text.isEmpty()) return "沒有文字"
        val t = tts
        if (t == null) {
            pendingSpeech = text
            val listener = android.speech.tts.TextToSpeech.OnInitListener { status ->
                if (status == android.speech.tts.TextToSpeech.SUCCESS) {
                    tts?.let { e ->
                        val tw = e.setLanguage(java.util.Locale.TAIWAN)
                        var lang = "zh-TW"
                        if (tw < android.speech.tts.TextToSpeech.LANG_AVAILABLE) {
                            val zh = e.setLanguage(java.util.Locale.CHINESE)
                            lang = if (zh >= android.speech.tts.TextToSpeech.LANG_AVAILABLE) "中文（沒有台灣中文，用一般中文）"
                                   else "沒有中文語音資料（zh-TW=$tw, zh=$zh）"
                            ttsNoChinese = zh < android.speech.tts.TextToSpeech.LANG_AVAILABLE
                        }
                        e.setAudioAttributes(android.media.AudioAttributes.Builder()
                            .setUsage(android.media.AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                            .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH).build())
                        e.setOnUtteranceProgressListener(object : android.speech.tts.UtteranceProgressListener() {
                            override fun onStart(utteranceId: String?) {}
                            override fun onDone(utteranceId: String?) {}
                            @Deprecated("Deprecated in Java")
                            override fun onError(utteranceId: String?) { onSpeechError("onError") }
                            override fun onError(utteranceId: String?, errorCode: Int) { onSpeechError("錯誤碼 $errorCode") }
                        })
                        ttsReady = true
                        nativeLog("提醒聲音：文字轉語音就緒（引擎 $ttsEngine，語言 $lang）")
                        if (ttsNoChinese) {
                            nativeLog("提醒聲音：手機沒有中文語音資料，改播嗶嗶聲；請到系統「文字轉語音」下載中文（台灣）語音")
                            pendingSpeech = null
                            beepFallback()
                        } else {
                            pendingSpeech?.let { p -> e.speak(p, android.speech.tts.TextToSpeech.QUEUE_FLUSH, null, "opview-stopgo") }
                            pendingSpeech = null
                        }
                    }
                } else {
                    // 沒有可用的語音引擎：改用嗶嗶聲，下次再重新初始化
                    nativeLog("提醒聲音：文字轉語音初始化失敗（status=$status，引擎 $ttsEngine），改播嗶嗶聲")
                    pendingSpeech = null
                    try { tts?.shutdown() } catch (_: Exception) {}
                    tts = null
                    ttsReady = false
                    beepFallback()
                }
            }
            val google = "com.google.android.tts"
            val hasGoogle = try { packageManager.getPackageInfo(google, 0); true } catch (e: Exception) { false }
            ttsEngine = if (hasGoogle) google else "系統預設"
            tts = if (hasGoogle) android.speech.tts.TextToSpeech(this, listener, google)
                  else android.speech.tts.TextToSpeech(this, listener)
            return "語音引擎初始化中（$ttsEngine），完成後播放"
        }
        if (!ttsReady) {
            pendingSpeech = text
            return "語音引擎初始化中（$ttsEngine），完成後播放"
        }
        if (ttsNoChinese) {
            val err = beepFallback()
            return "手機沒有中文語音資料，改播嗶嗶聲" + (err?.let { "（$it）" } ?: "")
        }
        val r = t.speak(text, android.speech.tts.TextToSpeech.QUEUE_FLUSH, null, "opview-stopgo")
        return if (r == android.speech.tts.TextToSpeech.SUCCESS) "語音播放中（$ttsEngine）"
               else { beepFallback(); "語音播放失敗（speak=$r），改播嗶嗶聲" }
    }

    private fun onSpeechError(why: String) {
        runOnUiThread {
            nativeLog("提醒聲音：語音播放失敗（$why），改播嗶嗶聲")
            beepFallback()
        }
    }

    // ---- 嗶嗶聲 WAV ----
    // 嗶嗶聲播放 App 內建的 assets/sounds/beep.wav（Flutter asset），失敗時改用程式產生的短音（beepAlert）。
    // Google 語音不使用音檔（speakAlert）。
    private var wavPlayer: android.media.MediaPlayer? = null

    /** 播放 Flutter asset 的 WAV；成功回傳 null，失敗回傳原因 */
    private fun playAssetWav(asset: String): String? {
        val key = try {
            io.flutter.FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(asset)
        } catch (e: Exception) { return "找不到 Flutter asset 路徑：${e.message}" }
        val mp = android.media.MediaPlayer()
        return try {
            mp.setAudioAttributes(android.media.AudioAttributes.Builder()
                .setUsage(android.media.AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH).build())
            try {
                assets.openFd(key).use { afd -> mp.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length) }
            } catch (e: java.io.FileNotFoundException) {
                mp.release()
                return "沒有 $asset"
            } catch (e: java.io.IOException) {
                // APK 裡被壓縮（一般 wav 不會）：複製到快取再播
                val f = File(cacheDir, asset.substringAfterLast('/'))
                assets.open(key).use { input -> f.outputStream().use { input.copyTo(it) } }
                mp.setDataSource(f.absolutePath)
            }
            mp.setOnCompletionListener { p -> p.release(); if (wavPlayer === p) wavPlayer = null }
            mp.setOnErrorListener { p, what, extra ->
                nativeLog("提醒聲音：$asset 播放錯誤（$what/$extra）")
                p.release(); if (wavPlayer === p) wavPlayer = null
                true
            }
            mp.prepare()
            wavPlayer?.let { try { it.stop() } catch (_: Exception) {}; it.release() }
            wavPlayer = mp
            mp.start()
            null
        } catch (e: Exception) {
            try { mp.release() } catch (_: Exception) {}
            "${e.javaClass.simpleName}: ${e.message}"
        }
    }

    /** 語音失敗時的嗶嗶聲：先播 beep.wav，失敗再用程式產生的短音；成功回傳 null */
    private fun beepFallback(): String? = playAssetWav("assets/sounds/beep.wav")?.let { beepAlert() }

    /** 媒體音量（語音、嗶嗶聲都用導航語音用途，跟著媒體音量） */
    private fun mediaVolumeNote(): String = try {
        val am = getSystemService(AUDIO_SERVICE) as android.media.AudioManager
        val v = am.getStreamVolume(android.media.AudioManager.STREAM_MUSIC)
        val m = am.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
        if (v == 0) "媒體音量 0/$m（靜音，聽不到，請調高媒體音量）" else "媒體音量 $v/$m"
    } catch (_: Exception) { "媒體音量未知" }

    // 嗶嗶聲：程式產生兩聲 1 kHz 短音（各 130 ms，間隔 90 ms），用 AudioTrack 播放。
    // 音訊用途與語音相同（導航語音），音量跟著「媒體音量」，聽得到語音就聽得到嗶聲。
    // （原本用 ToneGenerator＋通知音量：通知音量為 0、勿擾模式、部分機型會完全沒有聲音。）
    private var beepTrack: android.media.AudioTrack? = null

    /** 成功回傳 null，失敗回傳原因（交給 Dart 寫入 log） */
    private fun beepAlert(): String? {
        return try {
            val rate = 44100
            val beepN = rate * 130 / 1000
            val gapN = rate * 90 / 1000
            val total = beepN * 2 + gapN
            val fade = rate * 5 / 1000.0 // 前後 5 ms 淡入淡出，避免爆音
            val pcm = ShortArray(total)
            for (b in 0 until 2) {
                val off = b * (beepN + gapN)
                for (i in 0 until beepN) {
                    val env = minOf(1.0, i / fade, (beepN - 1 - i) / fade)
                    pcm[off + i] = (Math.sin(2.0 * Math.PI * 1000.0 * i / rate) * env * 0.8 * Short.MAX_VALUE)
                        .toInt().toShort()
                }
            }
            beepTrack?.release()
            beepTrack = null
            val attrs = android.media.AudioAttributes.Builder()
                .setUsage(android.media.AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
            val format = android.media.AudioFormat.Builder()
                .setSampleRate(rate)
                .setEncoding(android.media.AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(android.media.AudioFormat.CHANNEL_OUT_MONO).build()
            val track = android.media.AudioTrack(attrs, format, total * 2,
                android.media.AudioTrack.MODE_STATIC, android.media.AudioManager.AUDIO_SESSION_ID_GENERATE)
            val written = track.write(pcm, 0, total)
            if (written != total || track.state != android.media.AudioTrack.STATE_INITIALIZED) {
                track.release()
                return "AudioTrack 初始化失敗（write=$written, state=${track.state}）"
            }
            track.play()
            beepTrack = track
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                if (beepTrack === track) beepTrack = null
                track.release()
            }, total * 1000L / rate + 300)
            null
        } catch (e: Exception) {
            "嗶嗶聲播放失敗：${e.javaClass.simpleName} ${e.message}"
        }
    }

    // ---- 背景執行（保留起步語音）----
    // Dart 端（app.dart）在 opview 畫面、背景執行開啟、起步提醒有開且聲音不是靜音時設為 true。
    // 離開 App（onPause，此時 Activity 仍可見，Android 12+ 允許啟動前景服務）啟動 OpviewKeepAliveService，
    // 回到 App（onResume）就停止。
    private var keepAliveWanted = false

    private fun nativeLog(msg: String) {
        try { systemChannel?.invokeMethod("nativeLog", msg) } catch (_: Exception) {}
    }

    override fun onPause() {
        super.onPause()
        if (keepAliveWanted && !isFinishing) {
            val err = OpviewKeepAliveService.start(this)
            nativeLog(if (err == null) "背景執行：啟動前景服務（通知列顯示 opview 背景執行中）"
                      else "背景執行：前景服務啟動失敗 $err")
            if (err == null) {
                // startForeground 在服務內執行，結果稍後確認
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    OpviewKeepAliveService.lastError?.let { nativeLog("背景執行：$it") }
                }, 1500)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        if (OpviewKeepAliveService.running) nativeLog("背景執行：回到 App，停止前景服務")
        OpviewKeepAliveService.stop(this)
    }

    // Android 13+：前景服務的通知需要通知權限（沒有權限服務照樣運作，只是通知列看不到）。只詢問一次。
    private fun askNotificationPermissionOnce() {
        if (Build.VERSION.SDK_INT < 33) return
        if (checkSelfPermission("android.permission.POST_NOTIFICATIONS") == PackageManager.PERMISSION_GRANTED) return
        val prefs = getSharedPreferences("opview_native", MODE_PRIVATE)
        if (prefs.getBoolean("asked_post_notifications", false)) return
        prefs.edit().putBoolean("asked_post_notifications", true).apply()
        try { requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"), 7301) } catch (_: Exception) {}
    }

    override fun onDestroy() {
        OpviewKeepAliveService.stop(this)
        wavPlayer?.release()
        wavPlayer = null
        beepTrack?.release()
        beepTrack = null
        tts?.shutdown()
        tts = null
        ttsReady = false
        super.onDestroy()
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

    private fun hasNotificationAccess(): Boolean {
        val enabled = android.provider.Settings.Secure.getString(
            contentResolver, "enabled_notification_listeners") ?: ""
        return enabled.split(":").any {
            android.content.ComponentName.unflattenFromString(it)?.packageName == packageName }
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

        // LINE 通知（OpviewNotificationListener → Dart）
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "org.dragonpilot.opview/line")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    OpviewNotificationListener.sink = { m -> events?.success(m) }
                }
                override fun onCancel(arguments: Any?) {
                    OpviewNotificationListener.sink = null
                }
            })

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
                // 是否已授權「通知存取權」（讀取 LINE 通知）
                "notificationAccess" -> result.success(hasNotificationAccess())
                // LINE 通知診斷：授權、服務綁定、LINE 是否安裝、收到 / 略過的數量（不含內容）
                "lineDiag" -> {
                    val m = HashMap<String, Any?>(OpviewNotificationListener.diag())
                    m["access"] = hasNotificationAccess()
                    m["lineInstalled"] = try {
                        packageManager.getPackageInfo(OpviewNotificationListener.LINE_PACKAGE, 0); true
                    } catch (e: Exception) { false }
                    result.success(m)
                }
                // 已授權但系統沒有綁定服務（例如被省電機制停掉）：要求系統重新綁定
                // 小米 HyperOS：從最近工作上滑清除（SwipeUpClean）後，系統不再綁定通知服務，
                // 單純 requestRebind 無效（log 實測）。先把服務元件停用再啟用，讓系統重新掃描並綁定，再 requestRebind。
                "lineRebind" -> {
                    if (!hasNotificationAccess()) { result.success("未授權"); return@setMethodCallHandler }
                    val cn = android.content.ComponentName(this, OpviewNotificationListener::class.java)
                    val steps = ArrayList<String>()
                    try {
                        packageManager.setComponentEnabledSetting(cn,
                            PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)
                        packageManager.setComponentEnabledSetting(cn,
                            PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
                        steps.add("元件重新啟用")
                    } catch (e: Exception) { steps.add("元件重新啟用失敗：${e.message}") }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        try {
                            android.service.notification.NotificationListenerService.requestRebind(cn)
                            steps.add("requestRebind")
                        } catch (e: Exception) { steps.add("requestRebind 失敗：${e.message}") }
                    }
                    result.success(steps.joinToString(" + "))
                }
                // 開啟系統「通知存取權」設定頁
                "openNotificationAccess" -> {
                    try {
                        val i = Intent(android.provider.Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(i)
                        result.success(true)
                    } catch (e: Exception) { result.success(false) }
                }
                // 前車起步 / 綠燈起步提醒聲音：{mode: voice|beep, text}
                "setBackgroundKeepAlive" -> {
                    keepAliveWanted = call.arguments as? Boolean ?: false
                    if (keepAliveWanted) askNotificationPermissionOnce()
                    result.success(true)
                }
                "alertSound" -> {
                    val mode = call.argument<String>("mode") ?: "beep"
                    val text = call.argument<String>("text") ?: ""
                    val vol = mediaVolumeNote()
                    if (mode == "voice") {
                        result.success("Google 語音：${speakAlert(text)}；$vol")
                    } else {
                        val asset = call.argument<String>("asset") ?: "assets/sounds/beep.wav"
                        val wavErr = playAssetWav(asset)
                        if (wavErr == null) { result.success("嗶嗶聲（beep.wav）播放中；$vol"); return@setMethodCallHandler }
                        val err = beepAlert()
                        if (err == null) result.success("$wavErr → 程式產生的嗶嗶聲已播放；$vol")
                        else result.error("beep", "$wavErr；$err；$vol", null)
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
