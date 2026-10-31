package com.example.piliplus

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat

/**
 * 「保存到本地」任务的实时活动通知（Android 16 Live Updates / ColorOS 流体云）。
 *
 * 与 [DownloadProgressManager] 同一套写法：
 * - ProgressStyle + setOngoing + CATEGORY_PROGRESS
 * - setRequestPromotedOngoing(true) 请求系统提升为实时更新
 * - channel id / notification id 与缓存下载错开（v3 / 1003）
 *
 * 通知上的「取消」按钮发一条广播给 [SaveCancelReceiver]，再由 MainActivity
 * 通过 MethodChannel 回到 Dart 调 VideoSaveService.cancel() —— 是真的取消任务。
 */
class SaveNotificationManager(private val context: Context) {

    companion object {
        private const val CHANNEL_ID = "save_progress_v1"
        private const val NOTIFICATION_ID = 1004
        private const val TAG = "SaveProgress"
        const val ACTION_CANCEL = "com.example.piliplus.action.CANCEL_SAVE"

        /** 通知栏取消按钮的落地动作，由 MainActivity 注入（转发到 Dart）。 */
        @Volatile
        var cancelListener: (() -> Unit)? = null
    }

    private val notificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        createChannel()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "保存进度",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "显示视频保存到本地的进度"
                setShowBadge(false)
                setLockscreenVisibility(Notification.VISIBILITY_PUBLIC)
            }
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun contentIntent(): PendingIntent {
        val intent = Intent(context, Class.forName("com.example.piliplus.MainActivity")).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        return PendingIntent.getActivity(
            context, NOTIFICATION_ID, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        )
    }

    private fun cancelIntent(): PendingIntent {
        val intent = Intent(context, SaveCancelReceiver::class.java).apply {
            action = ACTION_CANCEL
        }
        return PendingIntent.getBroadcast(
            context, NOTIFICATION_ID, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    /**
     * 创建或更新保存进度通知。
     *
     * [percent] 为 0~100；[canCancel] 为 false 时不带取消按钮（写入下载目录后不可取消）。
     */
    fun update(
        title: String,
        stage: String,
        detail: String,
        percent: Double,
        canCancel: Boolean,
    ) {
        val pct = percent.toInt().coerceIn(0, 100)
        val text = if (detail.isEmpty()) "$stage · $pct%" else "$stage · $detail · $pct%"

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(contentIntent())
            .setOngoing(true)
            .setAutoCancel(false)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            // Android 16 Live Updates：显式请求系统"提升"为实时更新
            .setRequestPromotedOngoing(true)
            .setProgress(100, pct, false)
            .setStyle(
                NotificationCompat.ProgressStyle()
                    .setProgress(pct)
                    .setProgressIndeterminate(false)
                    .setStyledByProgress(true)
            )

        if (canCancel) {
            builder.addAction(
                NotificationCompat.Action.Builder(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "取消",
                    cancelIntent()
                ).build()
            )
        }

        notificationManager.notify(TAG, NOTIFICATION_ID, builder.build())
    }

    /** 任务结束：推一条终态（自动收起），4 秒后移除。 */
    fun finish(title: String, text: String, success: Boolean) {
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(
                if (success) {
                    android.R.drawable.stat_sys_download_done
                } else {
                    android.R.drawable.stat_notify_error
                }
            )
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(contentIntent())
            .setOngoing(false)
            .setAutoCancel(true)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)

        notificationManager.notify(TAG, NOTIFICATION_ID, builder.build())
        mainHandler.postDelayed({ cancel() }, 4000)
    }

    /** 立即收起通知。 */
    fun cancel() {
        notificationManager.cancel(TAG, NOTIFICATION_ID)
    }
}
