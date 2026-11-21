import 'dart:async';
import 'dart:io' show Platform;

import 'package:PiliPlus/utils/device_utils.dart';
import 'package:flutter/services.dart'
    show SystemChrome, MethodChannel, SystemUiOverlay, DeviceOrientation;

bool _isDesktopFullScreen = false;

@pragma('vm:notify-debugger-on-exception')
Future<void> enterDesktopFullScreen({bool inAppFullScreen = false}) async {
  if (!inAppFullScreen && !_isDesktopFullScreen) {
    _isDesktopFullScreen = true;
    try {
      await const MethodChannel(
        'com.alexmercerind/media_kit_video',
      ).invokeMethod('Utils.EnterNativeFullscreen');
    } catch (_) {}
  }
}

@pragma('vm:notify-debugger-on-exception')
Future<void> exitDesktopFullScreen() async {
  if (_isDesktopFullScreen) {
    _isDesktopFullScreen = false;
    try {
      await const MethodChannel(
        'com.alexmercerind/media_kit_video',
      ).invokeMethod('Utils.ExitNativeFullscreen');
    } catch (_) {}
  }
}

/// 上一次下发的方向集合，用于跳过重复调用。
///
/// 这个缓存只在「同一个策略被重复下发」时省一次通道调用；一旦 Activity 的
/// 实际方向被别处改过而缓存仍命中，就会漏掉一次必须的下发（屏幕被钉在某个
/// 单方向上）。所以恢复全局策略的路径（退出全屏/销毁播放器）必须用
/// `force: true` 绕过缓存。
List<DeviceOrientation>? _lastOrientation;
Future<void>? _setPreferredOrientations(
  List<DeviceOrientation> orientations, {
  bool force = false,
}) {
  if (!force && _lastOrientation == orientations) {
    return null;
  }
  _lastOrientation = orientations;
  return SystemChrome.setPreferredOrientations(orientations);
}

Future<void>? portraitUpMode({bool force = false}) {
  return _setPreferredOrientations(const [.portraitUp], force: force);
}

Future<void>? portraitDownMode({bool force = false}) {
  return _setPreferredOrientations(const [.portraitDown], force: force);
}

Future<void>? landscapeLeftMode({bool force = false}) {
  return _setPreferredOrientations(const [.landscapeLeft], force: force);
}

Future<void>? landscapeRightMode({bool force = false}) {
  return _setPreferredOrientations(const [.landscapeRight], force: force);
}

Future<void>? fullMode({bool force = false}) {
  return _setPreferredOrientations(
    const [.portraitUp, .portraitDown, .landscapeLeft, .landscapeRight],
    force: force,
  );
}

bool _showSystemBar = true;
bool get showSystemBar_ => _showSystemBar;
Future<void>? hideSystemBar() {
  if (!_showSystemBar) {
    return null;
  }
  _showSystemBar = false;
  return SystemChrome.setEnabledSystemUIMode(.immersiveSticky);
}

//退出全屏显示
Future<void>? showSystemBar() {
  if (_showSystemBar) {
    return null;
  }
  _showSystemBar = true;
  return SystemChrome.setEnabledSystemUIMode(
    Platform.isAndroid && DeviceUtils.sdkInt < 29 ? .manual : .edgeToEdge,
    overlays: SystemUiOverlay.values,
  );
}
