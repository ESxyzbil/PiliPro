import 'dart:io';

import 'package:flutter/services.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';

/// Desktop lyrics overlay service.
///
/// Controls a transparent, click-through, topmost overlay window
/// that displays synchronized lyrics text above all other windows.
///
/// On non-Windows platforms, all methods are no-ops.
class DesktopLyricsService {
  static const _channel = MethodChannel('desktop_lyrics');
  static bool? _supported;

  /// Check whether the overlay is available on this platform.
  static bool get isSupported {
    _supported ??= Platform.isWindows;
    return _supported!;
  }

  /// Load saved settings and apply them.
  static Future<void> loadSettings() async {
    if (!isSupported) return;
    try {
      final box = GStorage.setting;

      final opacity = box.get(SettingBoxKey.desktopLyricsOpacity, defaultValue: 85) as int;
      final fontSize = box.get(SettingBoxKey.desktopLyricsFontSize, defaultValue: 28) as int;
      final width = box.get(SettingBoxKey.desktopLyricsWidth, defaultValue: 1200) as int;
      final fontFamily = box.get(SettingBoxKey.desktopLyricsFontFamily, defaultValue: 'Microsoft YaHei') as String;
      final layoutMode = box.get(SettingBoxKey.desktopLyricsLayoutMode, defaultValue: 0) as int;
      final fontStyle = box.get(SettingBoxKey.desktopLyricsFontStyle, defaultValue: 0) as int;
      final textAlign = box.get(SettingBoxKey.desktopLyricsTextAlign, defaultValue: 1) as int;
      final posX = box.get(SettingBoxKey.desktopLyricsPosX, defaultValue: -1) as int;
      final posY = box.get(SettingBoxKey.desktopLyricsPosY, defaultValue: -1) as int;
      final strokeEnabled = box.get(SettingBoxKey.desktopLyricsStrokeEnabled, defaultValue: true) as bool;
      final textColor = box.get(SettingBoxKey.desktopLyricsTextColor, defaultValue: 0xFFFFFFFF) as int;
      final nextTextColor = box.get(SettingBoxKey.desktopLyricsNextTextColor, defaultValue: 0x80FFFFFF) as int;
      final strokeColor = box.get(SettingBoxKey.desktopLyricsStrokeColor, defaultValue: 0xFF000000) as int;

      await _channel.invokeMethod('setOpacity', {'percent': opacity});
      await _channel.invokeMethod('setFontSize', {'size': fontSize});
      await _channel.invokeMethod('setWindowWidth', {'width': width});
      await _channel.invokeMethod('setFontFamily', {'family': fontFamily});
      await _channel.invokeMethod('setLayoutMode', {'mode': layoutMode});
      await _channel.invokeMethod('setFontStyle', {'style': fontStyle});
      await _channel.invokeMethod('setTextAlign', {'align': textAlign});
      await _channel.invokeMethod('setStrokeEnabled', {'enabled': strokeEnabled});
      await _channel.invokeMethod('setTextColor', {
        'r': (textColor >> 16) & 0xFF,
        'g': (textColor >> 8) & 0xFF,
        'b': textColor & 0xFF,
      });
      await _channel.invokeMethod('setNextTextColor', {
        'r': (nextTextColor >> 16) & 0xFF,
        'g': (nextTextColor >> 8) & 0xFF,
        'b': nextTextColor & 0xFF,
      });
      await _channel.invokeMethod('setStrokeColor', {
        'r': (strokeColor >> 16) & 0xFF,
        'g': (strokeColor >> 8) & 0xFF,
        'b': strokeColor & 0xFF,
      });
      if (posX >= 0 && posY >= 0) {
        await _channel.invokeMethod('setPosition', {'x': posX, 'y': posY});
      }
    } catch (_) {}
  }

  /// Show the lyrics overlay window.
  static Future<void> show() async {
    if (!isSupported) return;
    try {
      await loadSettings();
      await _channel.invokeMethod('show');
    } catch (_) {}
  }

  /// Hide the lyrics overlay window.
  static Future<void> hide() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('hide');
    } catch (_) {}
  }

  /// Rebuild the lyrics overlay window from scratch (fresh surface) and
  /// re-render the current lyrics/settings. Use this when the overlay
  /// disappears during long playback (e.g. after display/DWM changes).
  static Future<void> reload() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('reload');
    } catch (_) {}
  }

  /// Update the lyrics displayed on the overlay.
  static Future<void> setLyrics({
    required String currentLine,
    String nextLine = '',
    double progress = 0.0,
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setLyrics', {
        'currentLine': currentLine,
        'nextLine': nextLine,
        'progress': progress,
      });
    } catch (_) {}
  }

  /// Enumerate all installed TrueType fonts on the system.
  static Future<List<String>> enumerateFonts() async {
    if (!isSupported) return [];
    try {
      final result = await _channel.invokeMethod('enumerateFonts');
      if (result is List) return result.cast<String>();
      return [];
    } catch (_) {
      return [];
    }
  }

  // ---- Settings (auto-apply + persist) ----

  static Future<void> setPosition({required int x, required int y}) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setPosition', {'x': x, 'y': y});
      GStorage.setting.put(SettingBoxKey.desktopLyricsPosX, x);
      GStorage.setting.put(SettingBoxKey.desktopLyricsPosY, y);
    } catch (_) {}
  }

  static Future<void> setFontSize(int size) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setFontSize', {'size': size});
      GStorage.setting.put(SettingBoxKey.desktopLyricsFontSize, size);
    } catch (_) {}
  }

  static Future<void> setFontFamily(String family) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setFontFamily', {'family': family});
      GStorage.setting.put(SettingBoxKey.desktopLyricsFontFamily, family);
    } catch (_) {}
  }

  static Future<void> setFontStyle(int style) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setFontStyle', {'style': style});
      GStorage.setting.put(SettingBoxKey.desktopLyricsFontStyle, style);
    } catch (_) {}
  }

  static Future<void> setTextAlign(int align) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setTextAlign', {'align': align});
      GStorage.setting.put(SettingBoxKey.desktopLyricsTextAlign, align);
    } catch (_) {}
  }

  static Future<void> setOpacity(int percent) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setOpacity', {'percent': percent});
      GStorage.setting.put(SettingBoxKey.desktopLyricsOpacity, percent);
    } catch (_) {}
  }

  static Future<void> setWindowWidth(int width) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setWindowWidth', {'width': width});
      GStorage.setting.put(SettingBoxKey.desktopLyricsWidth, width);
    } catch (_) {}
  }

  static Future<void> setLayoutMode(int mode) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setLayoutMode', {'mode': mode});
      GStorage.setting.put(SettingBoxKey.desktopLyricsLayoutMode, mode);
    } catch (_) {}
  }

  static Future<void> setTextColor(int color) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setTextColor', {
        'r': (color >> 16) & 0xFF,
        'g': (color >> 8) & 0xFF,
        'b': color & 0xFF,
      });
      GStorage.setting.put(SettingBoxKey.desktopLyricsTextColor, color);
    } catch (_) {}
  }

  static Future<void> setNextTextColor(int color) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setNextTextColor', {
        'r': (color >> 16) & 0xFF,
        'g': (color >> 8) & 0xFF,
        'b': color & 0xFF,
      });
      GStorage.setting.put(SettingBoxKey.desktopLyricsNextTextColor, color);
    } catch (_) {}
  }

  static Future<void> setStrokeEnabled(bool enabled) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setStrokeEnabled', {'enabled': enabled});
      GStorage.setting.put(SettingBoxKey.desktopLyricsStrokeEnabled, enabled);
    } catch (_) {}
  }

  static Future<void> setStrokeColor(int color) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setStrokeColor', {
        'r': (color >> 16) & 0xFF,
        'g': (color >> 8) & 0xFF,
        'b': color & 0xFF,
      });
      GStorage.setting.put(SettingBoxKey.desktopLyricsStrokeColor, color);
    } catch (_) {}
  }
}
