import 'package:flutter/services.dart';

class ShortcutService {
  static const _channel = MethodChannel('com.example.piliplus/shortcuts');

  /// 将收藏夹添加为桌面长按快捷方式（动态），返回系统是否真的登记成功
  static Future<bool> addCollectionShortcut(int id, String name) async {
    try {
      return await _channel.invokeMethod<bool>(
        'addCollectionShortcut',
        {'id': id, 'name': name},
      ) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 请求固定到主屏幕（系统确认弹窗，桌面不显示长按菜单时的兜底）
  static Future<bool> pinCollectionShortcut(int id, String name) async {
    try {
      return await _channel.invokeMethod<bool>(
        'pinCollectionShortcut',
        {'id': id, 'name': name},
      ) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 移除指定的快捷方式
  static Future<void> removeShortcut(String shortcutId) async {
    try {
      await _channel.invokeMethod('removeShortcut', shortcutId);
    } catch (e) {
      // 静默失败
    }
  }
}
