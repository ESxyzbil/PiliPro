package com.example.piliplus

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * ColorOS 流体云 / Android 16 Live Updates 管理器
 *
 * 独立于 audio_service 的媒体通知。
 * 原理：ColorOS 16 会自动将有进度条的持续通知渲染为流体云胶囊。
 */
class LiveUpdateManager(private val context: Context) {

    companion object {
        private const val CHANNEL_ID = "music_live_update_v3"
        private const val NOTIFICATION_ID = 1002
        private const val TAG = "FluidCloud"
    }

    private val notificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    init {
        createChannel()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // 先删旧频道，确保新配置生效
            notificationManager.deleteNotificationChannel("music_live_update")
            notificationManager.deleteNotificationChannel("music_live_update_v2")

            val channel = NotificationChannel(
                CHANNEL_ID,
                "音乐实时活动",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "在流体云胶囊上显示歌词和播放进度"
                setShowBadge(false)
                setLockscreenVisibility(Notification.VISIBILITY_PUBLIC)
            }
            notificationManager.createNotificationChannel(channel)
        }
    }

    /**
     * 创建或更新流体云 Live Update 通知
     *
     * 同时添加 ProgressStyle（Android 16 原生）和标准 Progress（ColorOS 识别），双重触发。
     */
    fun updateMusic(
        songTitle: String,
        currentLyric: String,
        nextLyric: String,
        progress: Int,
        maxProgress: Int,
        isPlaying: Boolean
    ) {
        // 同时兼容 Android 16 Live Updates 和 ColorOS 流体云
        val intent = Intent(context, Class.forName("com.example.piliplus.MainActivity")).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        val pendingIntent = PendingIntent.getActivity(
            context, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        )

        val builder = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(songTitle)
            .setContentText(currentLyric)
            .setSubText(nextLyric)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setAutoCancel(false)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)

        // 标准进度条 — ColorOS 流体云可能通过它识别
        if (maxProgress > 0) {
            builder.setProgress(maxProgress, progress, false)
        }

        // Android 16+ 额外添加 ProgressStyle → Live Updates
        if (Build.VERSION.SDK_INT >= 36) {
            val progressStyle = Notification.ProgressStyle()
                .setProgress(progress)
                .setProgressIndeterminate(false)
                .setStyledByProgress(true)
            builder.setStyle(progressStyle)
            builder.setCategory(Notification.CATEGORY_PROGRESS)
        }

        notificationManager.notify(TAG, NOTIFICATION_ID, builder.build())
    }

    fun endMusic() {
        notificationManager.cancel(TAG, NOTIFICATION_ID)
    }
}
