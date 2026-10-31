import 'dart:io';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/services/media/save_notification.dart';
import 'package:PiliPlus/services/migration/shared_storage.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/media/fmp4_muxer.dart';
import 'package:PiliPlus/utils/media/media_transcoder.dart';
import 'package:dio/dio.dart';
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

/// 用户主动取消保存。只在可中断阶段抛出。
class SaveCancelledException implements Exception {
  const SaveCancelledException();

  @override
  String toString() => '已取消保存';
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

  /// 已请求取消、正在等可中断点
  final RxBool cancelling = false.obs;

  /// 进度条被下滑隐藏到后台（任务继续，改由通知展示进度）
  final RxBool uiHidden = false.obs;

  /// 任务序号：每次保存自增，给 Dismissible 一个每次都新的 key
  final RxInt taskId = 0.obs;

  bool _cancelRequested = false;

  /// 当前下载的 CancelToken，取消时立刻中断网络请求
  CancelToken? _downloadCancelToken;

  int _lastNotifyMs = 0;
  double _lastNotifyPct = -1;
  int _lastNotifyStage = -1;

  @override
  void onInit() {
    super.onInit();
    SaveNotification.init(cancel);
  }

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
    if (uiHidden.value) _pushNotification();
  }

  void _checkCancel() {
    if (_cancelRequested) throw const SaveCancelledException();
  }

  /// 请求取消当前保存任务。
  ///
  /// 下载中会立刻中断网络请求；合并/转码阶段在下一个进度回调被打断。
  /// **一旦开始写入公共下载目录就不可取消**（系统侧流式写入不可回滚），
  /// 此时只提示，任务照常完成。
  void cancel() {
    if (!busy.value || _cancelRequested) return;
    if (stage.value == SaveVideoStage.done ||
        stage.value == SaveVideoStage.failed ||
        stage.value == SaveVideoStage.idle) {
      return;
    }
    if (stage.value == SaveVideoStage.writing) {
      SmartDialog.showToast('已在写入下载目录，无法取消');
      return;
    }
    _cancelRequested = true;
    cancelling.value = true;
    _downloadCancelToken?.cancel('cancelled by user');
    if (uiHidden.value) _pushNotification(force: true);
    // 下载被 CancelToken 中断后会走到 SaveCancelledException；
    // 纯本地任务（合并/转码）靠下一个 _report/进度回调抛出。
  }

  /// 进度条下滑飞走：界面隐藏，任务继续，进度改由通知展示。
  void hideUi() {
    if (!busy.value) return;
    uiHidden.value = true;
    _pushNotification(force: true);
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

  /// 通知节流：阶段变化、整百分比变化或强制时才下发，避免每毫秒一条。
  void _pushNotification({bool force = false}) {
    final pct = progress.value * 100;
    final now = DateTime.now().millisecondsSinceEpoch;
    final sameStage = _lastNotifyStage == stage.value.index;
    if (!force &&
        sameStage &&
        (pct - _lastNotifyPct).abs() < 1 &&
        now - _lastNotifyMs < 500) {
      return;
    }
    _lastNotifyMs = now;
    _lastNotifyPct = pct;
    _lastNotifyStage = stage.value.index;
    SaveNotification.update(
      title: title.value,
      stage: cancelling.value ? '正在取消…' : stageLabel,
      detail: detail.value,
      percent: pct,
      canCancel: !cancelling.value && stage.value != SaveVideoStage.writing,
    );
  }

  void _resetNotifyThrottle() {
    _lastNotifyMs = 0;
    _lastNotifyPct = -1;
    _lastNotifyStage = -1;
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
    taskId.value++;
    progress.value = 0;
    cancelling.value = false;
    uiHidden.value = false;
    _cancelRequested = false;
    _downloadCancelToken = null;
    _resetNotifyThrottle();
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
      _checkCancel();
      _report(SaveVideoStage.merging, 0.85);
      var savePath = p.join(tmpDir.path, '$baseName.mp4');
      // 先登记再合并：中途取消会留下半个文件，交给 finally 一起清掉
      tempFiles.add(savePath);
      Mp4MergeResult? merged;
      try {
        merged = await Fmp4Muxer.merge(
          videoPath: videoPath,
          audioPath: audioPath,
          outputPath: savePath,
          onProgress: (v) {
            _report(SaveVideoStage.merging, _map(v, 0.85, 0.95));
            // onProgress 在合并循环里同步回调，抛出会直接中断并关掉文件句柄
            _checkCancel();
          },
        );
      } on Mp4MuxException catch (e) {
        // 离线缓存里的整段 0.mp4 本身就是完整 MP4，直接保存原文件
        if (kDebugMode) debugPrint('merge skipped: ${e.message}');
        savePath = videoPath;
        warning = '（${e.message}）';
      }

      _checkCancel();

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

      // 写入公共下载目录：原生流式复制，内存 O(1)。
      // 进入后不可取消，故先做最后一次取消检查。
      _checkCancel();
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
        if (uiHidden.value) {
          SaveNotification.finish(
            title: title.value,
            text: '保存失败：写入下载目录出错',
            success: false,
          );
        }
        return false;
      }

      _report(SaveVideoStage.done, 1);
      detail.value = copied.displayPath;
      SmartDialog.showToast('已保存到 ${copied.displayPath}$warning');
      if (uiHidden.value) {
        SaveNotification.finish(
          title: title.value,
          text: '已保存到 ${copied.displayPath}',
        );
      }
      // 让 100% 的进度条停一会儿，避免保存很快时一闪而过
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      return true;
    } on SaveCancelledException {
      stage.value = SaveVideoStage.idle;
      progress.value = 0;
      detail.value = '';
      SmartDialog.showToast('已取消保存');
      if (uiHidden.value) {
        SaveNotification.finish(
          title: title.value,
          text: '已取消保存',
          success: false,
        );
      }
      return false;
    } catch (e, s) {
      if (kDebugMode) debugPrint('save video error: $e\n$s');
      stage.value = SaveVideoStage.failed;
      SmartDialog.showToast('保存失败：$e');
      if (uiHidden.value) {
        SaveNotification.finish(
          title: title.value,
          text: '保存失败：$e',
          success: false,
        );
      }
      return false;
    } finally {
      busy.value = false;
      uiHidden.value = false;
      cancelling.value = false;
      _cancelRequested = false;
      _downloadCancelToken = null;
      _resetNotifyThrottle();
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
    _checkCancel();
    _report(SaveVideoStage.downloading, from);
    final token = CancelToken();
    _downloadCancelToken = token;
    try {
      await Request.http11Dio.download(
        url.http2https,
        path,
        cancelToken: token,
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
    } on DioException catch (e) {
      if (CancelToken.isCancel(e) || _cancelRequested) {
        throw const SaveCancelledException();
      }
      rethrow;
    } finally {
      if (identical(_downloadCancelToken, token)) {
        _downloadCancelToken = null;
      }
    }
    _checkCancel();
    detail.value = '';
  }
}
