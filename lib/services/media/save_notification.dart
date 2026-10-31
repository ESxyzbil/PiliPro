import 'dart:io';

import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 「保存到本地」任务的实时活动通知（Android 16 Live Updates / ColorOS 流体云）。
///
/// 只在进度条被下滑隐藏到后台（[VideoSaveService.uiHidden]）时使用，
/// 样式对齐 [DownloadProgressManager]：ProgressStyle + 常驻 + CATEGORY_PROGRESS。
///
/// 通知上的「取消」按钮由原生广播接收，再经本通道回调 `cancel`，
/// 由上层转到 `VideoSaveService.cancel()` —— 点了是真的取消，不是只收掉通知。
abstract final class SaveNotification {
  static const _channel = MethodChannel('com.example.piliplus/save_progress');

  static bool _handlerReady = false;
  static bool _permissionRequested = false;

  /// 注册原生回调（幂等）。[onCancel] 为通知栏取消按钮的落地动作。
  static void init(void Function() onCancel) {
    if (_handlerReady) return;
    _handlerReady = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'cancel') {
        if (kDebugMode) debugPrint('[SaveNotification] cancel from notification');
        onCancel();
      }
      return null;
    });
  }

  /// Android 13+ 通知权限；未授予时静默跳过，不能因此中断保存。
  static Future<bool> _ensurePermission() async {
    if (!Platform.isAndroid) return false;
    if (_permissionRequested) return true;
    try {
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
    } catch (e) {
      if (kDebugMode) debugPrint('[SaveNotification] permission error: $e');
    }
    return false;
  }

  /// 创建或更新进度通知。[percent] 为 0~100。
  static Future<void> update({
    required String title,
    required String stage,
    required String detail,
    required double percent,
    required bool canCancel,
  }) async {
    if (!await _ensurePermission()) return;
    try {
      await _channel.invokeMethod('update', {
        'title': title,
        'stage': stage,
        'detail': detail,
        'percent': percent.clamp(0.0, 100.0),
        'canCancel': canCancel,
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[SaveNotification] update error: $e');
    }
  }

  /// 任务结束（成功/失败/取消）：推送一条终态，随后由原生侧自动收起。
  static Future<void> finish({
    required String title,
    required String text,
    bool success = true,
  }) async {
    if (!await _ensurePermission()) return;
    try {
      await _channel.invokeMethod('finish', {
        'title': title,
        'text': text,
        'success': success,
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[SaveNotification] finish error: $e');
    }
  }

  /// 立即收起通知（不展示终态）。
  static Future<void> dismiss() async {
    try {
      await _channel.invokeMethod('dismiss');
    } catch (_) {}
  }
}
