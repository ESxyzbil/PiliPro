import 'dart:io';

import 'package:flutter/services.dart';
import 'package:PiliPlus/utils/permission_handler.dart';

/// 缓存下载进度通知（普通常驻进度通知）
///
/// 实测 OnePlus 15 / ColorOS 不渲染第三方应用的实时活动/流体云，
/// 已退化为通知栏常驻进度通知（带进度条）。
class DownloadProgressChannel {
  static const _channel = MethodChannel('com.example.piliplus/download_progress');

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

    final result = await Permission.notification.request();
    if (result == PermissionStatus.granted) {
      _permissionRequested = true;
      return true;
    }
    return false;
  }

  /// 更新缓存进度通知
  static Future<void> update({
    required int queueLength,
    required String title,
    required String subText,
    required int progressBytes,
    required int totalBytes,
    required bool hasProgress,
  }) async {
    if (!await _ensureNotificationPermission()) return;
    try {
      await _channel.invokeMethod('update', {
        'queueLength': queueLength,
        'title': title,
        'subText': subText,
        'progressBytes': progressBytes,
        'totalBytes': totalBytes,
        'hasProgress': hasProgress,
      });
    } catch (_) {
      // 非 Android / 通道不可用时静默失败
    }
  }

  /// 关闭缓存进度通知
  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
