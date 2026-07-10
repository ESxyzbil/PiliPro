import 'package:flutter/services.dart';

class ShortcutService {
  static const _channel = MethodChannel('com.example.piliplus/shortcuts');

  /// 将收藏夹添加为桌面长按快捷方式（动态）
  static Future<void> addCollectionShortcut(int id, String name) async {
    try {
      await _channel.invokeMethod('addCollectionShortcut', {
        'id': id,
        'name': name,
      });
    } catch (e) {
      // 静默失败
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
