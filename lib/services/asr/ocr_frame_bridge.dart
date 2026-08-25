import 'dart:async';

import 'package:flutter/services.dart';

/// OCR 整段识别取帧桥（Kotlin MediaCodec 视频解码逐帧 JPEG）
/// 事件：'ocrdone:<dir>:<count>' / 'ocrfailed:<msg>'
class OcrFrameBridge {
  static const MethodChannel _channel =
      MethodChannel('com.example.piliplus/ocr_frames');
  static const EventChannel _events =
      EventChannel('com.example.piliplus/ocr_frames_events');

  StreamSubscription<dynamic>? _sub;
  void Function(String dir, int count)? onDone;
  void Function(String err)? onFailed;

  void start({
    required String url,
    required String outDir,
    int sampleEveryMs = 1000,
  }) {
    _sub ??= _events.receiveBroadcastStream().listen((event) {
      if (event is String) {
        if (event.startsWith('ocrdone:')) {
          final parts = event.substring(8).split(':');
          if (parts.length >= 2) {
            onDone?.call(parts[0], int.tryParse(parts[1]) ?? 0);
          }
        } else if (event.startsWith('ocrfailed:')) {
          onFailed?.call(event.substring(10));
        }
      }
    });
    _channel.invokeMethod('start', {
      'url': url,
      'outDir': outDir,
      'sampleEveryMs': sampleEveryMs,
    });
  }

  void stop() {
    _channel.invokeMethod('stop');
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _channel.invokeMethod('stop');
  }
}
