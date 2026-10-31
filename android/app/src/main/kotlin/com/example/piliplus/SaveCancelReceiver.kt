package com.example.piliplus

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 保存进度通知上的「取消」按钮接收器。
 *
 * 只把动作转给 [SaveNotificationManager.cancelListener]（MainActivity 注入，
 * 经 MethodChannel 回到 Dart 执行 VideoSaveService.cancel()）。
 * 进程已结束时不做事——那时也没有在跑的保存任务。
 */
class SaveCancelReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == SaveNotificationManager.ACTION_CANCEL) {
            SaveNotificationManager.cancelListener?.invoke()
        }
    }
}
