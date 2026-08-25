import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

/// ASR 模型定义（三类）：
/// - streaming：sherpa-onnx 流式 zipformer transducer（实时字幕，讲话场景）
/// - whisper：sherpa-onnx Whisper 离线模型（分段识别，自选规模）
/// - sensevoice：阿里 SenseVoice 离线（分段识别，对歌曲/带噪音频鲁棒）
/// 源：hf-mirror.com（HuggingFace 国内镜像，sherpa-onnx 官方模型）
class AsrLanguageInfo {
  final String code; // 目录名/枚举码
  final String label; // 显示名
  final String repo; // HF 仓库 id
  final String branch; // 分支
  final String type; // 'streaming' | 'whisper' | 'sensevoice'
  final String encoderFile;
  final String decoderFile;
  final String joinerFile; // streaming 专用，其他为空
  final String tokensFile;
  final String? language; // whisper/sensevoice 识别语言（如 zh/en/auto）
  final String? task; // whisper 任务（transcribe/translate）

  /// encoder 精确字节数（用于下载完整性校验/续传判定/zip导入识别）
  final int encoderSize;

  const AsrLanguageInfo({
    required this.code,
    required this.label,
    required this.repo,
    this.branch = 'main',
    required this.type,
    required this.encoderFile,
    required this.decoderFile,
    this.joinerFile = '',
    this.tokensFile = 'tokens.txt',
    this.language,
    this.task,
    required this.encoderSize,
  });

  bool get isStreaming => type == 'streaming';
  bool get isWhisper => type == 'whisper';
  bool get isSenseVoice => type == 'sensevoice';

  /// 离线分段识别（whisper/sensevoice）
  bool get isOffline => !isStreaming;
}

class AsrModelManager extends GetxController {
  static AsrModelManager get instance => Get.find();

  /// hf-mirror 国内镜像基础地址
  static const String baseUrl = 'https://hf-mirror.com';

  /// 语言包清单（流式 zipformer transducer，均含 int8 量化版）
  /// - 中文：中英双语流式（bilingual-zh-en），约 190MB
  /// 模型清单：
  /// 流式（streaming，实时字幕，讲话场景）：中文/韩语/多语言8语
  /// Whisper（离线分段，歌曲/任意音频，自选规模）：tiny/base/small
  static const List<AsrLanguageInfo> languages = [
    // ── 流式 zipformer ──
    AsrLanguageInfo(
      code: 'zh',
      label: '中文（流式）',
      repo: 'csukuangfj/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30',
      type: 'streaming',
      encoderFile: 'encoder.int8.onnx',
      decoderFile: 'decoder.onnx',
      joinerFile: 'joiner.int8.onnx',
      encoderSize: 161141793,
    ),
    AsrLanguageInfo(
      code: 'ko',
      label: '韩语（流式）',
      repo: 'k2-fsa/sherpa-onnx-streaming-zipformer-korean-2024-06-16',
      type: 'streaming',
      encoderFile: 'encoder-epoch-99-avg-1.int8.onnx',
      decoderFile: 'decoder-epoch-99-avg-1.int8.onnx',
      joinerFile: 'joiner-epoch-99-avg-1.int8.onnx',
      encoderSize: 126968852,
    ),
    AsrLanguageInfo(
      code: 'multi',
      label: '多语言8语（流式）',
      repo: 'csukuangfj/sherpa-onnx-streaming-zipformer-ar_en_id_ja_ru_th_vi_zh-2025-02-10',
      type: 'streaming',
      encoderFile: 'encoder-epoch-75-avg-11-chunk-16-left-128.int8.onnx',
      decoderFile: 'decoder-epoch-75-avg-11-chunk-16-left-128.onnx',
      joinerFile: 'joiner-epoch-75-avg-11-chunk-16-left-128.int8.onnx',
      encoderSize: 296583597,
    ),
    // ── Whisper 离线（自选规模）──
    AsrLanguageInfo(
      code: 'w-tiny',
      label: 'Whisper tiny（离线，约103MB）',
      repo: 'csukuangfj/sherpa-onnx-whisper-tiny',
      type: 'whisper',
      encoderFile: 'tiny-encoder.int8.onnx',
      decoderFile: 'tiny-decoder.int8.onnx',
      tokensFile: 'tiny-tokens.txt',
      language: 'zh',
      task: 'transcribe',
      encoderSize: 12937772,
    ),
    AsrLanguageInfo(
      code: 'w-base',
      label: 'Whisper base（离线，约160MB）',
      repo: 'csukuangfj/sherpa-onnx-whisper-base',
      type: 'whisper',
      encoderFile: 'base-encoder.int8.onnx',
      decoderFile: 'base-decoder.int8.onnx',
      tokensFile: 'base-tokens.txt',
      language: 'zh',
      task: 'transcribe',
      encoderSize: 29120534,
    ),
    AsrLanguageInfo(
      code: 'w-small',
      label: 'Whisper small（离线，约375MB）',
      repo: 'csukuangfj/sherpa-onnx-whisper-small',
      type: 'whisper',
      encoderFile: 'small-encoder.int8.onnx',
      decoderFile: 'small-decoder.int8.onnx',
      tokensFile: 'small-tokens.txt',
      language: 'zh',
      task: 'transcribe',
      encoderSize: 112442483,
    ),
    // ── SenseVoice 离线（对歌曲/带噪鲁棒，推荐歌曲场景）──
    AsrLanguageInfo(
      code: 'sv',
      label: 'SenseVoice（离线，约237MB，歌曲推荐，中英日韩粤）',
      repo: 'csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09',
      type: 'sensevoice',
      encoderFile: 'model.int8.onnx',
      decoderFile: '',
      language: 'auto', // 自动检测：中/英/日/韩/粤
      encoderSize: 237115547,
    ),
  ];

  final RxSet<String> downloadedLangs = <String>{}.obs;
  final RxString downloadingLang = ''.obs;
  final RxDouble progress = 0.0.obs;
  final RxString error = ''.obs;

  Directory? _dir;

  Future<Directory> _root() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/asr_packs');
    if (!await dir.exists()) await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  Future<String> langPath(String code, String fileName) async =>
      '${(await _root()).path}/$code/$fileName';

  Future<String> langDir(String code) async =>
      '${(await _root()).path}/$code';

  AsrLanguageInfo? langOf(String code) {
    for (final l in languages) {
      if (l.code == code) return l;
    }
    return null;
  }

  /// 某模型是否已下载（文件齐全且非空，防下载中断误判）
  Future<bool> isLangDownloaded(String code) async {
    final lang = langOf(code);
    if (lang == null) return false;
    try {
      final root = await _root();
      final dir = Directory('${root.path}/$code');
      if (!await dir.exists()) return false;
      final enc = File('${dir.path}/${lang.encoderFile}');
      if (!await enc.exists() || await enc.length() < 1024 * 1024) {
        return false; // encoder 至少 1MB
      }
      final dec = File('${dir.path}/${lang.decoderFile}');
      if (lang.decoderFile.isNotEmpty &&
          (!await dec.exists() || await dec.length() == 0)) {
        return false;
      }
      if (lang.isStreaming) {
        final joi = File('${dir.path}/${lang.joinerFile}');
        if (!await joi.exists() || await joi.length() == 0) return false;
      }
      final tok = File('${dir.path}/${lang.tokensFile}');
      if (!await tok.exists() || await tok.length() == 0) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 已下载语言列表
  Future<void> refreshStatus() async {
    final set = <String>{};
    for (final lang in languages) {
      if (await isLangDownloaded(lang.code)) set.add(lang.code);
    }
    downloadedLangs.clear();
    downloadedLangs.addAll(set);
  }

  /// 下载某语言包（4 个文件：encoder/decoder/joiner + tokens）
  /// 支持断点续传（.tmp 残留续传）+ 失败自动重试 3 次 + encoder 精确大小校验
  Future<void> download(String code) async {
    final lang = langOf(code);
    if (lang == null) return;
    if (downloadingLang.value.isNotEmpty) return; // 并发保护
    downloadingLang.value = code;
    progress.value = 0;
    error.value = '';
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 120),
        sendTimeout: const Duration(seconds: 30),
      ),
    );
    final steps = lang.isStreaming
        ? 4 // enc+dec+joi+tok
        : (lang.isWhisper ? 3 : 2); // whisper: enc+dec+tok; sensevoice: enc+tok
    var done = 0;
    try {
      final dir = Directory(await langDir(code));
      await dir.create(recursive: true);

      Future<void> dl(
        String remoteFile,
        String savePath, {
        int? expectedBytes,
      }) async {
        final url = '$baseUrl/${lang.repo}/resolve/${lang.branch}/$remoteFile';
        final tmpPath = '$savePath.tmp';
        final tmp = File(tmpPath);
        // 断点续传：上次下载残留的 .tmp 存在则从断点继续
        var resumeFrom = 0;
        if (await tmp.exists()) resumeFrom = await tmp.length();
        Future<void> runDownload({int? from}) async {
          final resume = from != null && from > 0;
          // CDN 长连接易中断：失败自动重试 3 次（配合断点续传）
          for (var attempt = 0; attempt < 3; attempt++) {
            try {
              await dio.download(
                url,
                tmpPath,
                options: resume
                    ? Options(headers: {'range': 'bytes=$from-'})
                    : null,
                fileAccessMode:
                    resume ? FileAccessMode.append : FileAccessMode.write,
                onReceiveProgress: (c, t) {
                  if (t > 0) {
                    progress.value =
                        ((done + c / t) / steps).clamp(0.0, 1.0);
                  }
                },
              );
              return;
            } catch (e) {
              if (attempt >= 2) rethrow;
              print('[ASR] dl retry(${attempt + 1}) $remoteFile: $e');
              await Future.delayed(const Duration(seconds: 2));
            }
          }
        }

        await runDownload(from: resumeFrom);
        var bytes = await tmp.readAsBytes();
        if (expectedBytes != null && bytes.length != expectedBytes) {
          if (bytes.length > expectedBytes) {
            // 服务器忽略 range 导致内容重复：整体重下
            await tmp.delete();
            await runDownload();
            bytes = await tmp.readAsBytes();
            if (bytes.length != expectedBytes) {
              throw Exception('下载校验失败: $remoteFile');
            }
          } else {
            throw Exception('下载不完整: $remoteFile '
                '${bytes.length}/$expectedBytes');
          }
        }
        // 文件过小判定：模型(.onnx)至少 1MB；tokens.txt 等文本本来就小（仅 56KB），阈值 1KB
        final minSize = remoteFile.endsWith('.txt') ? 1024 : 1024 * 1024;
        if (bytes.length < minSize) {
          throw Exception('文件过小，下载可能失败: $remoteFile');
        }
        await tmp.rename(savePath);
        done++;
        progress.value = done / steps;
      }

      await dl(
        lang.encoderFile,
        '${dir.path}/${lang.encoderFile}',
        expectedBytes: lang.encoderSize,
      );
      if (lang.isStreaming) {
        await dl(lang.decoderFile, '${dir.path}/${lang.decoderFile}');
        await dl(lang.joinerFile, '${dir.path}/${lang.joinerFile}');
      } else if (lang.isWhisper) {
        await dl(lang.decoderFile, '${dir.path}/${lang.decoderFile}');
      }
      await dl(lang.tokensFile, '${dir.path}/${lang.tokensFile}');
      downloadedLangs.add(code);
      progress.value = 1.0;
    } catch (e) {
      print('[ASR] download "$code" failed: $e');
      error.value = e.toString();
      // 清理失败残留的 .tmp 文件
      try {
        final dir = Directory(await langDir(code));
        if (await dir.exists()) {
          await for (final f in dir.list()) {
            if (f.path.endsWith('.tmp')) await f.delete();
          }
        }
      } catch (_) {}
    } finally {
      downloadingLang.value = '';
    }
  }

  /// 删除某语言包
  Future<void> delete(String code) async {
    try {
      final root = await _root();
      final dir = Directory('${root.path}/$code');
      if (await dir.exists()) await dir.delete(recursive: true);
      downloadedLangs.remove(code);
    } catch (_) {}
  }

  /// 从本地 zip 导入语言包（免手机流量下载）。
  /// zip 内应含 encoder/decoder/joiner + tokens.txt 四个文件；
  /// 按 encoder 字节数自动识别所属语言包。
  /// 返回 null 表示成功，否则为错误描述。
  Future<String?> importFromZip(String zipPath) async {
    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final root = await _root();
      // 先解压到探测目录
      final probeDir = Directory('${root.path}/import_probe');
      if (await probeDir.exists()) {
        await probeDir.delete(recursive: true);
      }
      await probeDir.create(recursive: true);
      final extracted = <String, File>{};
      for (final entry in archive) {
        if (entry.isFile) {
          final name = entry.name.split('/').last;
          if (name.isEmpty) continue;
          extracted[name] = File('${probeDir.path}/$name');
          await extracted[name]!.writeAsBytes(
            entry.content as List<int>,
            flush: true,
          );
        }
      }
      // 按 encoder 大小匹配模型（兼容多种文件名）
      File? enc;
      for (final k in extracted.keys) {
        if (k.startsWith('encoder') && k.endsWith('.onnx')) {
          enc = extracted[k];
          break;
        }
      }
      AsrLanguageInfo? lang;
      if (enc != null) {
        final encLen = await enc.length();
        for (final l in languages) {
          if (encLen == l.encoderSize) {
            lang = l;
            break;
          }
        }
      }
      if (lang == null) {
        await probeDir.delete(recursive: true);
        return '无法识别模型（encoder 大小不匹配）';
      }
      // 校验其余文件（sensevoice 仅 encoder+tokens；whisper 无 joiner）
      final dec = lang.decoderFile.isNotEmpty ? extracted[lang.decoderFile] : null;
      final tok = extracted[lang.tokensFile];
      final joi = lang.isStreaming ? extracted[lang.joinerFile] : null;
      if (tok == null ||
          (lang.decoderFile.isNotEmpty && dec == null) ||
          (lang.isStreaming && joi == null)) {
        await probeDir.delete(recursive: true);
        return '模型不完整（缺少 ${lang.label} 文件）';
      }
      // 移动到正式目录
      final target = Directory(await langDir(lang.code));
      if (await target.exists()) {
        await target.delete(recursive: true);
      }
      await target.create(recursive: true);
      await enc!.rename('${target.path}/${enc.uri.pathSegments.last}');
      if (lang.decoderFile.isNotEmpty && dec != null) {
        await dec.rename('${target.path}/${dec.uri.pathSegments.last}');
      }
      if (lang.isStreaming && joi != null) {
        await joi.rename('${target.path}/${joi.uri.pathSegments.last}');
      }
      await tok.rename('${target.path}/${tok.uri.pathSegments.last}');
      await probeDir.delete(recursive: true);
      downloadedLangs.add(lang.code);
      return null;
    } catch (e) {
      return '导入失败: $e';
    }
  }
}
