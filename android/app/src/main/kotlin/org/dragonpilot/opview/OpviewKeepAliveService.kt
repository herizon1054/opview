package org.dragonpilot.opview

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * 背景執行（保留綠燈起步 / 前車起步語音）。
 *
 * Android 會凍結背景 App（Android 12+ 幾秒內，各廠牌更積極），連線、資料處理與語音都會停止。
 * 離開 opview 畫面（MainActivity.onPause）時，若使用者開啟「背景執行」且起步提醒有開、聲音不是靜音，
 * 就啟動這個前景服務：通知列顯示「opview 背景執行中」，並持有
 *   - PARTIAL_WAKE_LOCK：關閉螢幕後 CPU 不休眠，Dart 端持續處理 comma 資料與起步偵測
 *   - Wi-Fi lock：關閉螢幕後 Wi-Fi 不進省電（手機當熱點時不需要，持有也無妨）
 * 回到 App（onResume）、從最近使用清除 App、或按通知上的「停止」就結束。
 *
 * 前景服務類型 connectedDevice：透過網路連接外部裝置（comma）。Android 14 需要
 * FOREGROUND_SERVICE_CONNECTED_DEVICE 權限，以及 CHANGE_NETWORK_STATE 等其中一項（皆為一般權限，安裝即授予）。
 */
class OpviewKeepAliveService : Service() {
    companion object {
        private const val CHANNEL_ID = "opview_background"
        private const val NOTIF_ID = 2001
        private const val ACTION_STOP = "org.dragonpilot.opview.STOP_BACKGROUND"
        private const val MAX_HOLD_MS = 6L * 60 * 60 * 1000 // 最長 6 小時，避免忘記關閉時一直耗電

        @Volatile var running = false
            private set
        @Volatile var lastError: String? = null

        /** 啟動；成功回傳 null，失敗回傳原因 */
        fun start(ctx: Context): String? = try {
            val i = Intent(ctx, OpviewKeepAliveService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i) else ctx.startService(i)
            null
        } catch (e: Exception) {
            "${e.javaClass.simpleName}: ${e.message}"
        }

        fun stop(ctx: Context) {
            try { ctx.stopService(Intent(ctx, OpviewKeepAliveService::class.java)) } catch (_: Exception) {}
        }
    }

    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            val n = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(NOTIF_ID, n)
            }
        } catch (e: Exception) {
            lastError = "startForeground 失敗：${e.javaClass.simpleName}: ${e.message}"
            stopSelf()
            return START_NOT_STICKY
        }
        acquireLocks()
        running = true
        lastError = null
        return START_NOT_STICKY
    }

    // 從最近使用清除 App：一起結束
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        try { wake?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        try { wifi?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        wake = null
        wifi = null
        super.onDestroy()
    }

    private fun acquireLocks() {
        try {
            if (wake == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "opview:background").apply {
                    setReferenceCounted(false)
                    acquire(MAX_HOLD_MS)
                }
            }
        } catch (_: Exception) {}
        try {
            if (wifi == null) {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                @Suppress("DEPRECATION")
                wifi = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "opview:background").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } catch (_: Exception) {}
    }

    private fun buildNotification(): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL_ID, "opview 背景執行",
                NotificationManager.IMPORTANCE_LOW).apply {
                description = "離開 App 時保持連線，播放綠燈起步、前車起步語音"
                setShowBadge(false)
            })
        }
        val immutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or immutable)
        val stop = PendingIntent.getService(this, 1,
            Intent(this, OpviewKeepAliveService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or immutable)
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL_ID)
                else @Suppress("DEPRECATION") Notification.Builder(this)
        b.setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("opview 背景執行中")
            .setContentText("保持連線，綠燈起步／前車起步會播放語音")
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
        @Suppress("DEPRECATION")
        b.addAction(Notification.Action.Builder(0, "停止", stop).build())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            b.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return b.build()
    }
}
