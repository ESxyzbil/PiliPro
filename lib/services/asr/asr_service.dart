import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:get/get.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'asr_model_manager.dart';

/// ASR 引擎封装（sherpa-onnx）
/// - 流式（streaming）：zipformer transducer，实时字幕（讲话场景）
/// - Whisper（offline）：离线分段识别（歌曲/任意音频，自选规模）
class AsrService extends GetxService {
  static AsrService get instance => Get.find();

  static const int sampleRate = 16000;

  // 流式
  sherpa_onnx.OnlineRecognizer? _recognizer;
  sherpa_onnx.OnlineStream? _stream;
  // Whisper 离线
  sherpa_onnx.OfflineRecognizer? _offlineRecognizer;
  final RxBool loading = false.obs;

  bool get isLoaded => _recognizer != null || _offlineRecognizer != null;

  /// 加载模型（按 lang 类型分流式/Whisper）
  /// 返回 null 表示成功，否则为错误描述
  Future<String?> init(AsrLanguageInfo lang, String modelDir) async {
    if (_recognizer != null || _offlineRecognizer != null) return null;
    loading.value = true;
    try {
      sherpa_onnx.initBindings();
      if (lang.isWhisper) {
        final model = sherpa_onnx.OfflineModelConfig(
          whisper: sherpa_onnx.OfflineWhisperModelConfig(
            encoder: '$modelDir/${lang.encoderFile}',
            decoder: '$modelDir/${lang.decoderFile}',
            language: lang.language ?? 'zh',
            task: lang.task ?? 'transcribe',
          ),
          tokens: '$modelDir/${lang.tokensFile}',
          numThreads: 2,
          provider: 'cpu',
        );
        final config = sherpa_onnx.OfflineRecognizerConfig(
          feat: const sherpa_onnx.FeatureConfig(
            sampleRate: sampleRate,
            featureDim: 80,
          ),
          model: model,
          decodingMethod: 'greedy_search',
        );
        _offlineRecognizer = sherpa_onnx.OfflineRecognizer(config);
        return null;
      }
      if (lang.isSenseVoice) {
        final model = sherpa_onnx.OfflineModelConfig(
          senseVoice: sherpa_onnx.OfflineSenseVoiceModelConfig(
            model: '$modelDir/${lang.encoderFile}',
            language: lang.language ?? 'zh',
          ),
          tokens: '$modelDir/${lang.tokensFile}',
          numThreads: 2,
          provider: 'cpu',
        );
        final config = sherpa_onnx.OfflineRecognizerConfig(
          feat: const sherpa_onnx.FeatureConfig(
            sampleRate: sampleRate,
            featureDim: 80,
          ),
          model: model,
          decodingMethod: 'greedy_search',
        );
        _offlineRecognizer = sherpa_onnx.OfflineRecognizer(config);
        return null;
      }
      final files = _modelName(modelDir);
      final model = sherpa_onnx.OnlineModelConfig(
        transducer: sherpa_onnx.OnlineTransducerModelConfig(
          encoder: '$modelDir/${files.encoder}',
          decoder: '$modelDir/${files.decoder}',
          joiner: '$modelDir/${files.joiner}',
        ),
        tokens: '$modelDir/${lang.tokensFile}',
        numThreads: 2,
        provider: 'cpu',
        // modelType 留空由 sherpa-onnx 自动检测：
        // bilingual-zh-en 等是 zipformer（非 zipformer2），
        // 硬编码 zipformer2 会因缺 query_head_dims metadata 初始化失败
        modelType: '',
      );
      final config = sherpa_onnx.OnlineRecognizerConfig(
        feat: const sherpa_onnx.FeatureConfig(
          sampleRate: sampleRate,
          featureDim: 80,
        ),
        model: model,
        enableEndpoint: true,
      );
      _recognizer = sherpa_onnx.OnlineRecognizer(config);
      _stream = _recognizer!.createStream();
      return null;
    } catch (e) {
      return 'ASR 初始化失败: $e';
    } finally {
      loading.value = false;
    }
  }

  /// Whisper 离线识别单段（16k mono float PCM），返回文本
  Future<String?> recognizeSegment(Float32List samples) async {
    if (_offlineRecognizer == null) return null;
    try {
      final stream = _offlineRecognizer!.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
      _offlineRecognizer!.decode(stream);
      final text = _offlineRecognizer!.getResult(stream).text;
      stream.free();
      return text;
    } catch (e) {
      return null;
    }
  }

  /// 喂入 16kHz 单声道 float PCM 样本
  void acceptWaveform(Float32List samples) {
    _stream?.acceptWaveform(samples: samples, sampleRate: sampleRate);
  }

  /// 解码并把尾部文本推进到当前状态
  String decodeAndGetText() {
    final r = _recognizer;
    final s = _stream;
    if (r == null || s == null) return '';
    while (r.isReady(s)) {
      r.decode(s);
    }
    return r.getResult(s).text;
  }

  bool get isEndpoint {
    final r = _recognizer;
    final s = _stream;
    if (r == null || s == null) return false;
    return r.isEndpoint(s);
  }

  /// 句末定稿：解码至 ready 耗尽，返回完整句子，并 reset 开启新句
  String finalizeSegment() {
    final r = _recognizer;
    final s = _stream;
    if (r == null || s == null) return '';
    while (r.isReady(s)) {
      r.decode(s);
    }
    final text = r.getResult(s).text;
    r.reset(s);
    return text;
  }

  void reset() {
    final r = _recognizer;
    final s = _stream;
    if (r == null || s == null) return;
    r.reset(s);
  }

  void dispose() {
    try {
      _stream?.free();
      _recognizer?.free();
      _offlineRecognizer?.free();
    } catch (_) {}
    _stream = null;
    _recognizer = null;
    _offlineRecognizer = null;
  }

  /// 根据目录内文件推断模型文件名（兼容多种命名：
  /// encoder-epoch-99-avg-1.int8.onnx / encoder-epoch-75-... / encoder.int8.onnx 等）
  ({String encoder, String decoder, String joiner}) _modelName(
    String modelDir,
  ) {
    final files = _listFiles(modelDir);
    String pick(String prefix) {
      for (final f in files) {
        if (f.startsWith(prefix) && f.endsWith('.onnx')) return f;
      }
      return '';
    }

    return (
      encoder: pick('encoder'),
      decoder: pick('decoder'),
      joiner: pick('joiner'),
    );
  }

  List<String> _listFiles(String modelDir) {
    try {
      return Directory(modelDir).listSync().map((e) => e.uri.pathSegments.last).toList();
    } catch (_) {
      return const [];
    }
  }
}

/// 整段音频离线识别（后台 isolate，一次性）：
/// 加载模型 → 按段识别 raw PCM（16k mono float32）→ 返回带时间轴的字幕段。
/// [segmentMs] 段长（默认 12s），[overlapMs] 段间重叠（默认 2s，防歌词句被切断）。
Future<List<({Duration start, Duration end, String text})>> recognizeFullAudio({
  required AsrLanguageInfo lang,
  required String modelDir,
  required String rawPath,
  int segmentMs = 12000,
  int overlapMs = 2000,
}) {
  return Isolate.run(() async {
    sherpa_onnx.initBindings();
    final config = _buildOfflineConfig(lang, modelDir);
    final rec = sherpa_onnx.OfflineRecognizer(config);
    final bytes = File(rawPath).readAsBytesSync();
    final samples = Float32List.view(bytes.buffer);
    final segLen = (segmentMs * AsrService.sampleRate) ~/ 1000;
    final step = ((segmentMs - overlapMs) * AsrService.sampleRate) ~/ 1000;
    final segs = <({Duration start, Duration end, String text})>[];
    var start = 0;
    while (start < samples.length) {
      final end = (start + segLen < samples.length) ? start + segLen : samples.length;
      final stream = rec.createStream();
      stream.acceptWaveform(
        samples: samples.sublist(start, end),
        sampleRate: AsrService.sampleRate,
      );
      rec.decode(stream);
      final text = rec.getResult(stream).text.trim();
      if (text.isNotEmpty) {
        segs.add((
          start: Duration(milliseconds: (start * 1000) ~/ AsrService.sampleRate),
          end: Duration(milliseconds: (end * 1000) ~/ AsrService.sampleRate),
          text: text,
        ));
      }
      stream.free();
      start += step;
    }
    rec.free();
    return segs;
  });
}

/// 构建离线识别配置（whisper/sensevoice）
sherpa_onnx.OfflineRecognizerConfig _buildOfflineConfig(
  AsrLanguageInfo lang,
  String modelDir,
) {
  if (lang.isWhisper) {
    return sherpa_onnx.OfflineRecognizerConfig(
      feat: const sherpa_onnx.FeatureConfig(
        sampleRate: AsrService.sampleRate,
        featureDim: 80,
      ),
      model: sherpa_onnx.OfflineModelConfig(
        whisper: sherpa_onnx.OfflineWhisperModelConfig(
          encoder: '$modelDir/${lang.encoderFile}',
          decoder: '$modelDir/${lang.decoderFile}',
          language: lang.language ?? 'zh',
          task: lang.task ?? 'transcribe',
        ),
        tokens: '$modelDir/${lang.tokensFile}',
        numThreads: 2,
        provider: 'cpu',
      ),
      decodingMethod: 'greedy_search',
    );
  }
  // SenseVoice
  return sherpa_onnx.OfflineRecognizerConfig(
    feat: const sherpa_onnx.FeatureConfig(
      sampleRate: AsrService.sampleRate,
      featureDim: 80,
    ),
    model: sherpa_onnx.OfflineModelConfig(
      senseVoice: sherpa_onnx.OfflineSenseVoiceModelConfig(
        model: '$modelDir/${lang.encoderFile}',
        language: lang.language ?? 'zh',
      ),
      tokens: '$modelDir/${lang.tokensFile}',
      numThreads: 2,
      provider: 'cpu',
    ),
    decodingMethod: 'greedy_search',
  );
}
