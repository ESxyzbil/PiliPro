import 'dart:io';

import 'package:flutter/services.dart';

/// Manages Windows SMTC (System Media Transport Controls) integration.
class MediaControlWindows {
  static MediaControlWindows? _instance;

  bool _enabled = false;
  bool _isPlaying = false;

  /// Whether SMTC has been enabled (has callbacks set up).
  bool get enabled => _enabled;

  void Function()? _onPlay;
  void Function()? _onPause;
  void Function()? _onNext;
  void Function()? _onPrevious;

  static const _channel = MethodChannel('windows_smtc');

  MediaControlWindows._() {
    _channel.setMethodCallHandler(_onSystemCall);
  }

  factory MediaControlWindows() {
    _instance ??= MediaControlWindows._();
    return _instance!;
  }

  Future<dynamic> _onSystemCall(MethodCall call) async {
    _log('SMTC event: ${call.method}');
    switch (call.method) {
      case 'onPlay':
        _isPlaying = true;
        _log('SMTC onPlay: _onPlay is ${_onPlay != null}');
        _onPlay?.call();
        break;
      case 'onPause':
        _isPlaying = false;
        _log('SMTC onPause: _onPause is ${_onPause != null}');
        _onPause?.call();
        break;
      case 'onNext':
        _log('SMTC onNext: _onNext is ${_onNext != null}');
        _onNext?.call();
        break;
      case 'onPrevious':
        _log('SMTC onPrevious: _onPrevious is ${_onPrevious != null}');
        _onPrevious?.call();
        break;
    }
  }

  static void _log(String msg) {
    try {
      final f = File(
          '${Platform.environment['TEMP'] ?? 'C:\\Windows\\Temp'}\\piliplus_smtc_debug.log');
      f.writeAsStringSync('[${DateTime.now()}] $msg\n', mode: FileMode.append);
    } catch (_) {}
  }

  void enable({
    void Function()? onPlay,
    void Function()? onPause,
    void Function()? onNext,
    void Function()? onPrevious,
  }) {
    if (_enabled || !Platform.isWindows) return;
    // 只覆盖非 null 回调：enable() 常被 audio_handler 首次调用（只传 play/pause），
    // 若无条件赋值会把视频页已设的 next/prev 清空（SMTC 上下曲失效）
    if (onPlay != null) _onPlay = onPlay;
    if (onPause != null) _onPause = onPause;
    if (onNext != null) _onNext = onNext;
    if (onPrevious != null) _onPrevious = onPrevious;
    _enabled = true;
  }

  /// Update callbacks without changing _enabled state.
  /// Only updates callbacks that are explicitly provided (non-null).
  /// Use [clearNavigationCallbacks] to explicitly null out next/prev.
  void updateCallbacks({
    void Function()? onPlay,
    void Function()? onPause,
    void Function()? onNext,
    void Function()? onPrevious,
  }) {
    if (onPlay != null) _onPlay = onPlay;
    if (onPause != null) _onPause = onPause;
    if (onNext != null) _onNext = onNext;
    if (onPrevious != null) _onPrevious = onPrevious;
  }

  /// Set navigation (next/prev) callbacks without affecting play/pause.
  void setNavigationCallbacks({
    void Function()? onNext,
    void Function()? onPrevious,
  }) {
    _onNext = onNext;
    _onPrevious = onPrevious;
  }

  /// Explicitly clear next/prev callbacks (e.g. when video has no playlist).
  void clearNavigationCallbacks() {
    _onNext = null;
    _onPrevious = null;
  }

  void updatePlaybackStatus(bool isPlaying) {
    if (!_enabled) return;
    _isPlaying = isPlaying;
    _channel.invokeMethod('updatePlaybackState', {'playing': isPlaying});
  }

  void updateMetadata({
    required String title,
    String? artist,
    String? thumbnail,
  }) {
    if (!_enabled) return;
    _channel.invokeMethod('updateMetadata', {
      'title': title,
      'artist': artist ?? '',
      'thumbnail': thumbnail ?? '',
    });
  }

  /// Clear SMTC display — push empty metadata to hide current content.
  void clearMetadata() {
    if (!_enabled) return;
    _channel.invokeMethod('updateMetadata', {
      'title': '',
      'artist': '',
      'thumbnail': '',
    });
  }

  /// Re-enable SMTC: always sets callbacks and ensures _enabled=true.
  /// Unlike [enable], this does not check _enabled first.
  /// Used when returning to a page that needs to reclaim SMTC callbacks.
  void restore({
    void Function()? onPlay,
    void Function()? onPause,
    void Function()? onNext,
    void Function()? onPrevious,
  }) {
    _onPlay = onPlay;
    _onPause = onPause;
    _onNext = onNext;
    _onPrevious = onPrevious;
    _enabled = true;
  }

  void disable() {
    if (!Platform.isWindows) return;
    // Don't clear _enabled — otherwise SMTC button state and updatePlaybackStatus
    // break after another page restores callbacks but disable runs later.
    // _enabled = false;
  }

  void dispose() {
    disable();
    _channel.setMethodCallHandler(null);
    _instance = null;
  }
}
