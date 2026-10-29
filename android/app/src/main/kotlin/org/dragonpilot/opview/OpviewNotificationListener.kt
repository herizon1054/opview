package org.dragonpilot.opview

import android.app.Notification
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * 讀取 LINE 通知，交給 opview 直向畫面顯示（30 秒）。
 *
 * - 使用者需在系統「通知存取權」授權 opview（顯示設定 → 顯示 LINE 通知 會引導開啟）。
 * - 只處理 LINE（jp.naver.line.android）；略過群組摘要通知與沒有內容的通知。
 * - 不儲存、不寫 log；opview 沒在監聽（sink == null）時直接丟棄。
 */
class OpviewNotificationListener : NotificationListenerService() {
    companion object {
        const val LINE_PACKAGE = "jp.naver.line.android"

        /** MainActivity 的 EventChannel 設定；在主執行緒呼叫 */
        @Volatile
        var sink: ((Map<String, Any?>) -> Unit)? = null

        private val main = Handler(Looper.getMainLooper())
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null || sbn.packageName != LINE_PACKAGE) return
        if (sink == null) return
        val n = sbn.notification ?: return
        if ((n.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return
        val ex = n.extras ?: return
        val title = ex.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        val text = (ex.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: ex.getCharSequence(Notification.EXTRA_TEXT))?.toString()?.trim().orEmpty()
        if (text.isEmpty()) return
        val conversation = ex.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString()?.trim()
        val msg = mapOf<String, Any?>(
            "title" to title,
            "text" to text,
            "conversation" to conversation,
            "time" to sbn.postTime,
            "key" to sbn.key,
        )
        main.post { sink?.invoke(msg) }
    }
}
