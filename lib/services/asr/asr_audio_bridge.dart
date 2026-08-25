import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Android 侧音频 PCM 桥（MediaCodec 解码音轨 → 16kHz mono float PCM）
/// 平台通道：
/// - MethodChannel com.example.piliplus/asr_audio：start(url, startMs) / stop
/// - EventChannel  com.example.piliplus/asr_audio_events：float32 LE PCM 块 / 'ended'
class AsrAudioBridge {
  static const MethodChannel _channel =
      MethodChannel('com.example.piliplus/asr_audio');
  static const EventChannel _events =
      EventChannel('com.example.piliplus/asr_audio_events');

  StreamSubscription<dynamic>? _sub;

  /// 每块 16kHz 单声道 float PCM（Float32List）
  void Function(Float32List pcm)? onPcm;

  /// 解码流自然结束（播放到音轨末尾）
  void Function()? onEnded;

  /// 启动解码推送；startMs 为起始毫秒（支持 seek 后重启）
  /// note 为调试备注，随调用传给原生侧打日志（release 下 Dart 日志不可见）
  void start({
    required String url,
    required int startMs,
    String note = '',
  }) {
    _sub ??= _events.receiveBroadcastStream().listen(
      (event) {
        if (event is Uint8List) {
          // 复制字节消除底层 buffer 偏移，再按 float32 LE 视图解析
          // （直接 view(event.buffer) 会因 offsetInBytes≠0 错位 4 字节）
          final bytes = Uint8List.fromList(event);
          final floats = Float32List.view(bytes.buffer);
          onPcm?.call(floats);
        } else if (event == 'ended') {
          onEnded?.call();
        }
      },
      onError: (Object e, StackTrace s) {
        try {
          _channel.invokeMethod('log', '[BRIDGE] stream error: $e');
        } catch (_) {}
      },
      onDone: () {
        try {
          _channel.invokeMethod('log', '[BRIDGE] stream done');
        } catch (_) {}
      },
    );
    _channel.invokeMethod(
      'start',
      {'url': url, 'startMs': startMs, 'note': note},
    );
  }

  void stop() {
    _channel.invokeMethod('stop');
  }

  /// Dart 侧日志经此通道转发到 Kotlin（release 下 Dart 日志不可见）
  void log(String msg) {
    _channel.invokeMethod('log', msg);
  }

  /// 全速解码整段音轨到文件（供整段识别生成字幕）
  void Function(String path)? onAllDone;
  void Function(String err)? onAllFailed;

  void decodeAll({required String url, required String outPath}) {
    _sub ??= _events.receiveBroadcastStream().listen((event) {
      if (event is String) {
        if (event.startsWith('alldone:')) {
          onAllDone?.call(event.substring(8));
        } else if (event.startsWith('allfailed:')) {
          onAllFailed?.call(event.substring(10));
        }
      }
    });
    _channel.invokeMethod(
      'decodeAll',
      {'url': url, 'outPath': outPath},
    );
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _channel.invokeMethod('stop');
  }
}
