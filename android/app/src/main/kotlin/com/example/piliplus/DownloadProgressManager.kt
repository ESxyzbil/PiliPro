package com.example.piliplus

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * 缓存下载进度实时活动通知（Android 16 Live Updates / ColorOS 流体云）
 *
 * 按官方文档 https://developer.android.google.cn/develop/ui/views/notifications/live-update 实现：
 * - 标准样式 ProgressStyle + setOngoing + CATEGORY_PROGRESS
 * - setRequestPromotedOngoing(true) 请求系统"提升"为实时更新
 * - 清单声明 POST_PROMOTED_NOTIFICATIONS 权限
 *
 * 注意：ColorOS 16 国行默认禁止第三方应用发布推广通知
 * （canPostPromotedNotifications=false），需用户在系统设置
 * 「应用通知 → 实时活动」里手动开启后才会渲染为实时活动/流体云。
 */
class DownloadProgressManager(private val context: Context) {

    companion object {
        private const val CHANNEL_ID = "download_progress_v3"
        private const val NOTIFICATION_ID = 1003
        private const val TAG = "DownloadProgress"
    }

    private val notificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    init {
        createChannel()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "缓存进度",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "显示离线缓存下载进度"
                setShowBadge(false)
                setLockscreenVisibility(Notification.VISIBILITY_PUBLIC)
            }
            notificationManager.createNotificationChannel(channel)
        }
    }

    /**
     * 创建或更新缓存进度通知
     *
     * [hasProgress] 为 false 时不带进度条（如暂停/等待状态）。
     */
    fun update(
        queueLength: Int,
        title: String,
        subText: String,
        progressBytes: Long,
        totalBytes: Long,
        hasProgress: Boolean,
    ) {
        val intent = Intent(context, Class.forName("com.example.piliplus.MainActivity")).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        val pendingIntent = PendingIntent.getActivity(
            context, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        )

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("正在缓存 ($queueLength)")
            .setContentText(title)
            .setSubText(subText)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setAutoCancel(false)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            // Android 16 Live Updates：显式请求系统"提升"为实时更新
            .setRequestPromotedOngoing(true)

        if (hasProgress && totalBytes > 0 && progressBytes >= 0) {
            // setProgress 使用 int，超 2GB 时按比例缩放到 Int.MAX_VALUE
            val max = if (totalBytes > Int.MAX_VALUE) Int.MAX_VALUE else totalBytes.toInt()
            val progress = if (totalBytes > Int.MAX_VALUE) {
                (progressBytes.toDouble() / totalBytes.toDouble() * Int.MAX_VALUE).toInt()
            } else {
                progressBytes.toInt()
            }
            builder.setProgress(max, progress, false)

            // Android 16+：ProgressStyle 触发 Live Updates（低版本由 core 自动降级）
            val pct = (progressBytes.toDouble() / totalBytes.toDouble() * 100)
                .toInt()
                .coerceIn(0, 100)
            builder.setStyle(
                NotificationCompat.ProgressStyle()
                    .setProgress(pct)
                    .setProgressIndeterminate(false)
                    .setStyledByProgress(true)
            )
        }

        notificationManager.notify(TAG, NOTIFICATION_ID, builder.build())
    }

    fun stop() {
        notificationManager.cancel(TAG, NOTIFICATION_ID)
    }
}
