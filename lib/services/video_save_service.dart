import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/services/migration/shared_storage.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/media/fmp4_muxer.dart';
import 'package:PiliPlus/utils/media/media_transcoder.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 保存阶段。
enum SaveVideoStage {
  idle,
  preparing,
  downloading,
  merging,
  transcoding,
  writing,
  done,
  failed,
}

/// 视频保存服务：把在线/缓存的 m4s 合并成 MP4 并写入公共下载目录。
///
/// 关键点（2026-10-31 修 OOM）：整个过程**不把文件读进 Dart 内存**——
/// 合并产物由原生侧以 1MB 缓冲流式复制到系统下载目录，避免
/// `readAsBytes` + MethodChannel 传输导致的 300MB 级单次分配。
///
/// 任务挂在全局 GetxService 上，页面只订阅进度：切页、切标签、退到后台都不中断。
class VideoSaveService extends GetxService {
  static VideoSaveService get instance {
    if (Get.isRegistered<VideoSaveService>()) {
      return Get.find<VideoSaveService>();
    }
    return Get.put(VideoSaveService(), permanent: true);
  }

  /// 是否有任务在进行
  final RxBool busy = false.obs;

  /// 总进度 0~1
  final RxDouble progress = 0.0.obs;

  /// 当前阶段
  final Rx<SaveVideoStage> stage = SaveVideoStage.idle.obs;

  /// 任务标题（视频名）
  final RxString title = ''.obs;

  /// 附加信息（已下载字节 / 已保存位置）
  final RxString detail = ''.obs;

  String get stageLabel => switch (stage.value) {
    SaveVideoStage.preparing => '准备中',
    SaveVideoStage.downloading => '下载中',
    SaveVideoStage.merging => '合并音视频',
    SaveVideoStage.transcoding => '转码 H.264/AAC',
    SaveVideoStage.writing => '写入下载目录',
    SaveVideoStage.done => '已完成',
    SaveVideoStage.failed => '失败',
    SaveVideoStage.idle => '',
  };

  void _report(SaveVideoStage s, double overall) {
    if (stage.value != s) stage.value = s;
    progress.value = overall.clamp(0.0, 1.0);
  }

  static double _map(double v, double from, double to) =>
      from + (to - from) * v.clamp(0.0, 1.0);

  static String _size(int bytes) {
    if (bytes >= 1 << 20) {
      return '${(bytes / (1 << 20)).toStringAsFixed(1)}MB';
    }
    if (bytes >= 1 << 10) {
      return '${(bytes / (1 << 10)).toStringAsFixed(0)}KB';
    }
    return '${bytes}B';
  }

  /// 开始保存。
  ///
  /// [videoSource] 在线时为播放直链、已缓存时为本地文件路径；
  /// [audioSource] 音频轨（可空，缓存整段 mp4 时为 null）。
  Future<bool> saveVideo({
    required String baseName,
    required String videoSource,
    String? audioSource,
    required bool isFileSource,
    String? displayTitle,
  }) async {
    if (busy.value) {
      SmartDialog.showToast('已有保存任务在进行');
      return false;
    }
    busy.value = true;
    progress.value = 0;
    title.value = displayTitle?.isNotEmpty == true ? displayTitle! : baseName;
    detail.value = '';
    stage.value = SaveVideoStage.preparing;

    final tmpDir = await getTemporaryDirectory();
    final tempFiles = <String>[];
    var warning = '';

    try {
      late String videoPath;
      String? audioPath;

      if (isFileSource) {
        videoPath = videoSource;
        audioPath = audioSource;
        _report(SaveVideoStage.preparing, 0.02);
      } else {
        final hasAudio = audioSource != null && audioSource.isNotEmpty;
        videoPath = p.join(tmpDir.path, '$baseName.m4s');
        await _download(
          url: videoSource,
          path: videoPath,
          from: 0.02,
          to: hasAudio ? 0.75 : 0.85,
        );
        tempFiles.add(videoPath);
        if (hasAudio) {
          audioPath = p.join(tmpDir.path, '${baseName}_audio.m4s');
          await _download(
            url: audioSource,
            path: audioPath,
            from: 0.75,
            to: 0.85,
          );
          tempFiles.add(audioPath);
        }
      }

      // 合并：纯 Dart 重封装，样本原样搬运
      _report(SaveVideoStage.merging, 0.85);
      var savePath = p.join(tmpDir.path, '$baseName.mp4');
      Mp4MergeResult? merged;
      try {
        merged = await Fmp4Muxer.merge(
          videoPath: videoPath,
          audioPath: audioPath,
          outputPath: savePath,
          onProgress: (v) => _report(SaveVideoStage.merging, _map(v, 0.85, 0.95)),
        );
        tempFiles.add(savePath);
      } on Mp4MuxException catch (e) {
        // 离线缓存里的整段 0.mp4 本身就是完整 MP4，直接保存原文件
        if (kDebugMode) debugPrint('merge skipped: ${e.message}');
        savePath = videoPath;
        warning = '（${e.message}）';
      }

      // 非 H.264/AAC 时转码（失败不阻断保存）
      if (merged != null && !merged.isCompatible) {
        final codec =
            '${merged.video.codec}/${merged.audio?.codec ?? '无音频'}';
        if (MediaTranscoder.isSupported) {
          final target = p.join(tmpDir.path, '${baseName}_h264.mp4');
          try {
            await MediaTranscoder.transcode(
              input: savePath,
              output: target,
              onProgress: (v) =>
                  _report(SaveVideoStage.transcoding, _map(v, 0.95, 0.98)),
            );
            savePath = target;
            tempFiles.add(target);
          } catch (e) {
            if (kDebugMode) debugPrint('transcode error: $e');
            warning = '（转码失败，源为 $codec）';
          }
        } else {
          warning = '（本平台不支持转码，源为 $codec）';
        }
      }

      // 写入公共下载目录：原生流式复制，内存 O(1)
      _report(SaveVideoStage.writing, 0.98);
      final copied = await SharedStorage.copyToDownloads(
        savePath,
        displayName: '$baseName.mp4',
        mimeType: 'video/mp4',
        onProgress: (v) => _report(SaveVideoStage.writing, _map(v, 0.98, 1.0)),
      );

      if (copied == null) {
        _report(SaveVideoStage.failed, 0);
        SmartDialog.showToast('保存失败：写入下载目录出错');
        return false;
      }

      _report(SaveVideoStage.done, 1);
      detail.value = copied.displayPath;
      SmartDialog.showToast('已保存到 ${copied.displayPath}$warning');
      // 让 100% 的进度条停一会儿，避免保存很快时一闪而过
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      return true;
    } catch (e, s) {
      if (kDebugMode) debugPrint('save video error: $e\n$s');
      stage.value = SaveVideoStage.failed;
      SmartDialog.showToast('保存失败：$e');
      return false;
    } finally {
      busy.value = false;
      for (final f in tempFiles) {
        try {
          final file = File(f);
          if (file.existsSync()) {
            file.deleteSync();
          }
        } catch (_) {}
      }
    }
  }

  Future<void> _download({
    required String url,
    required String path,
    required double from,
    required double to,
  }) async {
    _report(SaveVideoStage.downloading, from);
    await Request.http11Dio.download(
      url.http2https,
      path,
      onReceiveProgress: (received, total) {
        if (total > 0) {
          _report(
            SaveVideoStage.downloading,
            _map(received / total, from, to),
          );
          detail.value = '${_size(received)} / ${_size(total)}';
        }
      },
    );
    detail.value = '';
  }
}
