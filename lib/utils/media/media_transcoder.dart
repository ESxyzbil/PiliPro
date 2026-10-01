import 'dart:io';

import 'package:flutter/services.dart';

/// 平台原生转码：把 MP4 转为 H.264 + AAC。
///
/// Android 走 MediaCodec + MediaMuxer，Windows 走 Media Foundation；
/// 已是 H.264 / AAC 的轨道不会重新编码（直接复制样本），只有非 H.264/AAC 的轨道
/// （HEVC、AV1、FLAC、AC-3…）才会解码后重编码。
abstract final class MediaTranscoder {
  static const MethodChannel _channel = MethodChannel(
    'com.example.piliplus/media_transcoder',
  );

  /// 当前平台是否有原生转码实现。
  static bool get isSupported => Platform.isAndroid || Platform.isWindows;

  /// 把 [input] 转码为 H.264+AAC 的 mp4 写到 [output]。
  ///
  /// [onProgress] 回调进度（0~1，由平台侧上报）。失败时抛异常。
  static Future<void> transcode({
    required String input,
    required String output,
    void Function(double progress)? onProgress,
  }) async {
    if (!isSupported) {
      throw UnsupportedError('当前平台不支持转码');
    }
    if (onProgress != null) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'progress' && call.arguments is num) {
          onProgress((call.arguments as num).toDouble());
        }
        return null;
      });
    }
    try {
      await _channel.invokeMethod<Map<Object?, Object?>>('transcode', {
        'input': input,
        'output': output,
      });
    } on PlatformException catch (e) {
      throw Exception(e.message ?? e.code);
    } finally {
      if (onProgress != null) {
        _channel.setMethodCallHandler(null);
      }
    }
  }
}
