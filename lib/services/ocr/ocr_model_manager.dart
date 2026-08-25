import 'dart:io';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

/// OCR（fast_paddle_ocr / NCNN）单个模型文件描述
class OcrModelFile {
  final String fileName;
  final String urlPath;
  final int size;

  const OcrModelFile(this.fileName, this.urlPath, this.size);
}

enum OcrModelStatus { notDownloaded, downloading, downloaded, error }

/// OCR 歌词模型懒下载管理：
/// 需要 4 个 NCNN 模型文件（det/rec 的 .param + .bin），首次使用时才下载到
/// 应用目录，下载后识别完全离线；APK 内不打包模型，减小包体。
class OcrModelManager extends GetxController {
  static OcrModelManager get instance => Get.find();

  /// 模型下载基础地址 —— 目前默认使用插件仓库的 jsDelivr CDN（国内可访问），
  /// 生产环境请替换为自己的托管地址。
  static const String baseUrl =
      'https://cdn.jsdelivr.net/gh/Saifulkamil/flutter_paddle_ocr@main/example/assets';

  static const List<OcrModelFile> modelFiles = [
    OcrModelFile('PP_OCRv5_mobile_det.ncnn.param', 'PP_OCRv5_mobile_det.ncnn.param', 24821),
    OcrModelFile('PP_OCRv5_mobile_det.ncnn.bin', 'PP_OCRv5_mobile_det.ncnn.bin', 2357216),
    OcrModelFile('PP_OCRv5_mobile_rec.ncnn.param', 'PP_OCRv5_mobile_rec.ncnn.param', 20031),
    OcrModelFile('PP_OCRv5_mobile_rec.ncnn.bin', 'PP_OCRv5_mobile_rec.ncnn.bin', 8242276),
  ];

  /// 4 个文件总字节数（约 10.15MB）
  static const int totalBytes = 10644344;

  final RxDouble progress = 0.0.obs;
  final Rx<OcrModelStatus> status = OcrModelStatus.notDownloaded.obs;
  final RxString error = ''.obs;

  Directory? _dir;

  Future<Directory> _modelsDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/ocr_models');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dir = dir;
    return dir;
  }

  Future<String> filePath(String fileName) async =>
      '${(await _modelsDir()).path}/$fileName';

  /// 4 个模型文件是否已完整下载（按字节数校验）
  Future<bool> isDownloaded() async {
    try {
      final dir = await _modelsDir();
      for (final f in modelFiles) {
        final file = File('${dir.path}/${f.fileName}');
        if (!await file.exists() || await file.length() != f.size) {
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 开始下载全部模型（带整体进度）；已下载则直接置 downloaded
  Future<void> download() async {
    if (status.value == OcrModelStatus.downloading) return;
    if (await isDownloaded()) {
      status.value = OcrModelStatus.downloaded;
      progress.value = 1.0;
      return;
    }
    status.value = OcrModelStatus.downloading;
    progress.value = 0.0;
    error.value = '';
    final dio = Dio();
    var filesDone = 0;
    try {
      final dir = await _modelsDir();
      for (final f in modelFiles) {
        final savePath = '${dir.path}/${f.fileName}';
        final tmpPath = '$savePath.tmp';
        final tmp = File(tmpPath);
        if (await tmp.exists()) await tmp.delete();
        await dio.download(
          '$baseUrl/${f.urlPath}',
          tmpPath,
          onReceiveProgress: (count, total) {
            final fProg = total > 0 ? count / total : 0.0;
            progress.value =
                ((filesDone + fProg) / modelFiles.length).clamp(0.0, 1.0);
          },
        );
        if (!await tmp.exists() || await tmp.length() != f.size) {
          throw Exception('${f.fileName} 大小校验失败');
        }
        await tmp.rename(savePath);
        filesDone++;
        progress.value = filesDone / modelFiles.length;
      }
      status.value = OcrModelStatus.downloaded;
      progress.value = 1.0;
    } catch (e) {
      error.value = e.toString();
      status.value = OcrModelStatus.error;
    }
  }

  /// 删除已下载的模型
  Future<void> delete() async {
    try {
      final dir = await _modelsDir();
      for (final f in modelFiles) {
        final file = File('${dir.path}/${f.fileName}');
        if (await file.exists()) await file.delete();
        final tmp = File('${dir.path}/${f.fileName}.tmp');
        if (await tmp.exists()) await tmp.delete();
      }
      status.value = OcrModelStatus.notDownloaded;
      progress.value = 0.0;
      error.value = '';
    } catch (_) {}
  }
}
