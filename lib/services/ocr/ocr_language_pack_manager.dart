import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

/// OCR 语言包（RapidOCR / ONNX，PP-OCRv4 系）
/// 每语言包 = rec.onnx + dict.txt；det/cls 为共享模型，下载一次。
class OcrLanguageInfo {
  final String code; // 目录名/枚举码
  final String label;
  final String recModel;
  final String recSha256;
  final String dictName;

  const OcrLanguageInfo({
    required this.code,
    required this.label,
    required this.recModel,
    required this.recSha256,
    required this.dictName,
  });
}

class OcrLanguagePackManager extends GetxController {
  static OcrLanguagePackManager get instance => Get.find();

  /// 模型/字典基础地址（modelscope，国内可访问）
  static const String baseUrl =
      'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.9.2';

  /// 共享模型
  static const String detPath = 'onnx/PP-OCRv4/det/ch_PP-OCRv4_det_mobile.onnx';
  static const String detSha256 =
      'd2a7720d45a54257208b1e13e36a8479894cb74155a5efe29462512d42f49da9';
  static const String clsPath =
      'onnx/PP-OCRv4/cls/ch_ppocr_mobile_v2.0_cls_mobile.onnx';
  static const String clsSha256 =
      'e47acedf663230f8863ff1ab0e64dd2d82b838fceb5957146dab185a89d6215c';

  /// 首批语言包（rec 模型 SHA256 取自 RapidOCR default_models.yaml）
  static const List<OcrLanguageInfo> languages = [
    OcrLanguageInfo(
      code: 'ch',
      label: '中文',
      recModel: 'ch_PP-OCRv4_rec_mobile.onnx',
      recSha256: '48fc40f24f6d2a207a2b1091d3437eb3cc3eb6b676dc3ef9c37384005483683b',
      dictName: 'ppocr_keys_v1.txt',
    ),
    OcrLanguageInfo(
      code: 'en',
      label: '英文',
      recModel: 'en_PP-OCRv4_rec_mobile.onnx',
      recSha256: 'e8770c967605983d1570cdf5352041dfb68fa0c21664f49f47b155abd3e0e318',
      dictName: 'en_dict.txt',
    ),
    OcrLanguageInfo(
      code: 'japan',
      label: '日文',
      recModel: 'japan_PP-OCRv4_rec_mobile.onnx',
      recSha256: 'e1075a67dba758ecfc7ebc78a10ae61c95ac8fb66a9c86fab5541e33f085cb7a',
      dictName: 'japan_dict.txt',
    ),
    OcrLanguageInfo(
      code: 'korean',
      label: '韩文',
      recModel: 'korean_PP-OCRv4_rec_mobile.onnx',
      recSha256: 'ab151ba9065eccd98f884cf4d927db091be86137276392072edd4f9d43ad7426',
      dictName: 'korean_dict.txt',
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
    final dir = Directory('${base.path}/ocr_packs');
    if (!await dir.exists()) await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  Future<String> sharedPath(String fileName) async =>
      '${(await _root()).path}/shared/$fileName';

  Future<String> langPath(String code, String fileName) async =>
      '${(await _root()).path}/$code/$fileName';

  /// 某语言包是否已下载（rec + dict 存在）
  Future<bool> isLangDownloaded(String code) async {
    final lang = languages.firstWhereOrNullC(code);
    if (lang == null) return false;
    try {
      final root = await _root();
      final rec = File('${root.path}/$code/rec.onnx');
      final dict = File('${root.path}/$code/dict.txt');
      final det = File('${root.path}/shared/det.onnx');
      if (!await det.exists() || !await rec.exists() || !await dict.exists()) {
        return false;
      }
      if (await rec.length() < 1024 * 1024) return false; // rec 至少 1MB
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
    downloadedLangs.value = set;
  }

  /// 下载某语言包（含共享 det/cls）
  Future<void> download(String code) async {
    final lang = languages.firstWhereOrNullC(code);
    if (lang == null) return;
    if (downloadingLang.value.isNotEmpty) return; // 并发保护
    downloadingLang.value = code;
    progress.value = 0;
    error.value = '';
    final dio = Dio();
    const steps = 6; // det + cls + rec + dict
    var done = 0;
    try {
      final root = await _root();
      final sharedDir = Directory('${root.path}/shared');
      final langDir = Directory('${root.path}/$code');
      await sharedDir.create(recursive: true);
      await langDir.create(recursive: true);

      Future<void> dl(
        String url,
        String savePath,
        String expectedSha256,
      ) async {
        final tmpPath = '$savePath.tmp';
        final tmp = File(tmpPath);
        if (await tmp.exists()) await tmp.delete();
        await dio.download(url, tmpPath, onReceiveProgress: (c, t) {
          if (t > 0) {
            progress.value = ((done + c / t) / steps).clamp(0.0, 1.0);
          }
        });
        final bytes = await tmp.readAsBytes();
        final sha = sha256.convert(bytes).toString();
        if (expectedSha256.isNotEmpty && sha != expectedSha256) {
          throw Exception('校验失败: ${savePath.split('/').last}');
        }
        await tmp.rename(savePath);
        done++;
        progress.value = done / steps;
      }

      await dl('$baseUrl/$detPath', '${sharedDir.path}/det.onnx', detSha256);
      await dl('$baseUrl/$clsPath', '${sharedDir.path}/cls.onnx', clsSha256);
      await dl(
        '$baseUrl/onnx/PP-OCRv4/rec/${lang.recModel}',
        '${langDir.path}/rec.onnx',
        lang.recSha256,
      );
      // 字典位于 paddle/PP-OCRv4/rec/<模型名去掉.onnx>/<dictName>
      await dl(
        '$baseUrl/paddle/PP-OCRv4/rec/'
        '${lang.recModel.replaceAll('.onnx', '')}/${lang.dictName}',
        '${langDir.path}/dict.txt',
        '', // 字典不做 SHA 校验（源无哈希）
      );
      downloadedLangs.add(code);
      progress.value = 1.0;
    } catch (e) {
      error.value = e.toString();
    } finally {
      downloadingLang.value = '';
    }
  }

  /// 删除某语言包（共享模型保留）
  Future<void> delete(String code) async {
    try {
      final root = await _root();
      final dir = Directory('${root.path}/$code');
      if (await dir.exists()) await dir.delete(recursive: true);
      downloadedLangs.remove(code);
    } catch (_) {}
  }
}

extension _LangsX on List<OcrLanguageInfo> {
  OcrLanguageInfo? firstWhereOrNullC(String code) {
    for (final e in this) {
      if (e.code == code) return e;
    }
    return null;
  }
}
