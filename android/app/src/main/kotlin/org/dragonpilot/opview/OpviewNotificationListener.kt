package org.dragonpilot.opview

import android.app.Notification
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * 讀取 LINE 通知，交給 opview 直向畫面顯示（30 秒）。
 *
 * - 使用者需在系統「通知存取權」授權 opview（顯示設定 → 顯示 LINE 通知 會引導開啟）。
 * - 只處理 LINE（jp.naver.line.android）；略過群組摘要通知與沒有內容的通知。
 * - 不儲存訊息內容。
 *
 * 診斷（讀不到 LINE 時用）：只記數量與原因，不記內容；Dart 端透過 MethodChannel "lineDiag" 讀取並寫入 opview.log。
 */
class OpviewNotificationListener : NotificationListenerService() {
    companion object {
        const val LINE_PACKAGE = "jp.naver.line.android"

        /** MainActivity 的 EventChannel 設定；在主執行緒呼叫 */
        @Volatile
        var sink: ((Map<String, Any?>) -> Unit)? = null

        private val main = Handler(Looper.getMainLooper())

        // ---- 診斷計數（App 行程存活期間累計）----
        @Volatile var connected = false            // 系統目前有沒有綁定本服務
        @Volatile var connectedCount = 0
        @Volatile var disconnectedCount = 0
        @Volatile var anyPosted = 0                // 所有 App 的通知（確認服務有在收）
        @Volatile var linePosted = 0               // LINE 的通知
        @Volatile var lineDelivered = 0            // 成功交給 opview 畫面
        @Volatile var skippedSummary = 0           // 群組摘要通知（正常會略過）
        @Volatile var skippedEmpty = 0             // 沒有文字內容
        @Volatile var droppedNoListener = 0        // opview 畫面沒在監聽（App 在背景 / 功能關閉）
        @Volatile var lastLineAt = 0L
        @Volatile var lastLineInfo = ""            // 最後一則 LINE 通知的結構（不含內容）

        fun diag(): Map<String, Any?> = mapOf(
            "connected" to connected,
            "connectedCount" to connectedCount,
            "disconnectedCount" to disconnectedCount,
            "anyPosted" to anyPosted,
            "linePosted" to linePosted,
            "lineDelivered" to lineDelivered,
            "skippedSummary" to skippedSummary,
            "skippedEmpty" to skippedEmpty,
            "droppedNoListener" to droppedNoListener,
            "lastLineAt" to lastLineAt,
            "lastLineInfo" to lastLineInfo,
        )
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        connected = true
        connectedCount++
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        connected = false
        disconnectedCount++
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        anyPosted++
        if (sbn.packageName != LINE_PACKAGE) return
        linePosted++
        lastLineAt = System.currentTimeMillis()
        val n = sbn.notification ?: return
        val ex = n.extras ?: Bundle()
        val title = ex.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        var text = (ex.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: ex.getCharSequence(Notification.EXTRA_TEXT))?.toString()?.trim().orEmpty()
        var sender = title
        // MessagingStyle：EXTRA_TEXT 可能是空的，改取最後一則訊息
        val msgs = ex.getParcelableArray(Notification.EXTRA_MESSAGES)
        if (text.isEmpty() && msgs != null && msgs.isNotEmpty()) {
            val last = msgs.last()
            if (last is Bundle) {
                text = last.getCharSequence("text")?.toString()?.trim().orEmpty()
                val s = last.getCharSequence("sender")?.toString()?.trim()
                if (!s.isNullOrEmpty()) sender = s
            }
        }
        val isSummary = (n.flags and Notification.FLAG_GROUP_SUMMARY) != 0
        // 結構資訊（不含任何文字內容），讀不到時用來判斷 LINE 用的是哪種通知格式
        lastLineInfo = "channel=${n.channelId ?: "-"} category=${n.category ?: "-"} summary=$isSummary " +
            "title=${title.isNotEmpty()} text=${text.isNotEmpty()} messages=${msgs?.size ?: 0} " +
            "template=${ex.getString(Notification.EXTRA_TEMPLATE)?.substringAfterLast('$') ?: "-"}"
        if (isSummary) { skippedSummary++; return }
        if (text.isEmpty()) { skippedEmpty++; return }
        if (sink == null) { droppedNoListener++; return }
        val conversation = ex.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString()?.trim()
        val msg = mapOf<String, Any?>(
            "title" to sender,
            "text" to text,
            "conversation" to conversation,
            "time" to sbn.postTime,
            "key" to sbn.key,
        )
        lineDelivered++
        main.post { sink?.invoke(msg) }
    }
}
