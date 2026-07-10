import 'dart:io';

import 'package:flutter/services.dart';
import 'package:PiliPlus/utils/permission_handler.dart';

/// OPPO 流体云 / Android 16 Live Updates 通道
///
/// 独立于 audio_service 的媒体通知。
/// 流体云是 ColorOS 渲染 `Notification.ProgressStyle` 的胶囊 UI，
/// 不是媒体通知的下拉栏样式。两者完全独立。
class LiveUpdateChannel {
  static const _channel = MethodChannel('com.example.piliplus/live_update');

  static bool _permissionRequested = false;

  /// 检查并申请通知权限（Android 13+ 必须）
  static Future<bool> _ensureNotificationPermission() async {
    if (_permissionRequested) return true;
    if (!Platform.isAndroid) return false;

    final status = await Permission.notification.status;
    if (status == PermissionStatus.granted) {
      _permissionRequested = true;
      return true;
    }

    // 还没授权，主动弹窗
    final result = await Permission.notification.request();
    if (result == PermissionStatus.granted) {
      _permissionRequested = true;
      return true;
    }
    return false;
  }

  /// 更新流体云歌词胶囊
  static Future<void> updateMusic({
    required String songTitle,
    required String currentLyric,
    String nextLyric = '',
    int progress = 0,
    int maxProgress = 100,
    bool isPlaying = true,
  }) async {
    // Android 13+ 必须先有通知权限
    if (!await _ensureNotificationPermission()) return;

    try {
      await _channel.invokeMethod('updateMusic', {
        'songTitle': songTitle,
        'currentLyric': currentLyric,
        'nextLyric': nextLyric,
        'progress': progress,
        'maxProgress': maxProgress,
        'isPlaying': isPlaying,
      });
    } catch (_) {
      // 非 Android 16 / ColorOS 16 设备静默失败
    }
  }

  /// 关闭流体云胶囊
  static Future<void> endMusic() async {
    try {
      await _channel.invokeMethod('endMusic');
    } catch (_) {}
  }
}
