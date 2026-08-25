import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:fast_paddle_ocr/ocr.dart';
import 'package:get/get.dart';

import 'ocr_model_manager.dart';

/// OCR 引擎封装：加载模型 + 识别图片（fast_paddle_ocr / NCNN）
class OcrService extends GetxService {
  static OcrService get instance => Get.find();

  final Ocr _ocr = Ocr();
  bool _loaded = false;
  final RxBool loading = false.obs;

  /// 识别输入尺寸 sizeid：0=320, 1=400, 2=480, 3=560, 4=640。
  /// 320 对视频字幕等小字几乎不可用，默认用 560 兼顾速度与准确率。
  static const int inputSizeId = 3;

  /// 当前设备是否 arm64。OCR 引擎仅在 arm64 包中编入，
  /// 非 arm64 设备直接视为不支持。
  Future<bool> isSupported() async {
    if (!Platform.isAndroid) return false;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.supportedAbis?.contains('arm64-v8a') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 确保模型已下载并加载；返回 null 表示成功，否则为错误描述
  Future<String?> ensureLoaded() async {
    final mgr = OcrModelManager.instance;
    if (!await mgr.isDownloaded()) {
      return 'OCR 模型未下载';
    }
    if (_loaded) return null;
    loading.value = true;
    try {
      final ok = await _ocr.loadModel(
        detParam: await mgr.filePath('PP_OCRv5_mobile_det.ncnn.param'),
        detModel: await mgr.filePath('PP_OCRv5_mobile_det.ncnn.bin'),
        recParam: await mgr.filePath('PP_OCRv5_mobile_rec.ncnn.param'),
        recModel: await mgr.filePath('PP_OCRv5_mobile_rec.ncnn.bin'),
        sizeid: inputSizeId,
      );
      _loaded = ok;
      return ok ? null : 'OCR 模型加载失败';
    } catch (e) {
      return 'OCR 初始化失败: $e';
    } finally {
      loading.value = false;
    }
  }

  /// 识别图片文件，返回按行分隔的文本；失败返回 null
  Future<String?> recognize(String imagePath) async {
    final err = await ensureLoaded();
    if (err != null) return null;
    try {
      return await _ocr.ocrFromImage(imagePath);
    } catch (_) {
      return null;
    }
  }
}
