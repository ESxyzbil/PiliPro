import 'package:PiliPlus/services/asr/asr_model_manager.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

/// ASR 语言包管理页：选择下载流式识别模型（sherpa-onnx / zipformer transducer）
class AsrLanguagePackSettingPage extends StatefulWidget {
  const AsrLanguagePackSettingPage({super.key});

  @override
  State<AsrLanguagePackSettingPage> createState() =>
      _AsrLanguagePackSettingPageState();
}

class _AsrLanguagePackSettingPageState
    extends State<AsrLanguagePackSettingPage> {
  late final AsrModelManager _mgr;

  @override
  void initState() {
    super.initState();
    _mgr = Get.isRegistered<AsrModelManager>()
        ? Get.find<AsrModelManager>()
        : Get.put(AsrModelManager(), permanent: true);
    _mgr.refreshStatus();
  }

  /// 从本地 zip 导入语言包（免手机流量下载）
  Future<void> _importZip() async {
    if (_mgr.downloadingLang.value.isNotEmpty) {
      SmartDialog.showToast('正在下载中，请稍后再导入');
      return;
    }
    final result = await FilePicker.pickFile(
      type: .custom,
      allowedExtensions: const ['zip'],
    );
    final path = result?.xFile.path;
    if (path == null) return;
    final err = await _mgr.importFromZip(path);
    if (err == null) {
      SmartDialog.showToast('导入成功');
      _mgr.refreshStatus();
    } else {
      SmartDialog.showToast(err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('ASR 语音识别语言包'),
        actions: [
          IconButton(
            tooltip: '从本地 zip 导入（免下载）',
            icon: const Icon(Icons.folder_open),
            onPressed: _importZip,
          ),
        ],
      ),
      body: Obx(() {
        final downloading = _mgr.downloadingLang.value;
        final downloaded = _mgr.downloadedLangs.toSet();
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                '语音识别（ASR）模型按语言下载，每语言一个流式模型（sherpa-onnx zipformer，约 130-310MB）。'
                '中文为中英双语模型；多语言模型含中/英/日/印尼/俄/泰/越/阿 8 种语言。',
                style: TextStyle(fontSize: 12),
              ),
            ),
            for (final lang in AsrModelManager.languages) ...[
              ListTile(
                leading: Icon(
                  downloaded.contains(lang.code)
                      ? Icons.check_circle
                      : Icons.record_voice_over_outlined,
                  color: downloaded.contains(lang.code)
                      ? cs.primary
                      : cs.outline,
                ),
                title: Text(lang.label),
                subtitle: Text(
                  downloading == lang.code
                      ? '下载中 ${(_mgr.progress.value * 100).toStringAsFixed(0)}%'
                      : downloaded.contains(lang.code)
                          ? '已下载'
                          : '未下载',
                ),
                trailing: downloading == lang.code
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          value: _mgr.progress.value,
                        ),
                      )
                    : IconButton(
                        icon: Icon(
                          downloaded.contains(lang.code)
                              ? Icons.delete_outline
                              : Icons.download,
                        ),
                        onPressed: () {
                          if (downloaded.contains(lang.code)) {
                            _mgr.delete(lang.code);
                          } else {
                            _mgr.download(lang.code);
                          }
                        },
                      ),
              ),
              const Divider(height: 1),
            ],
            if (_mgr.error.value.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _mgr.error.value,
                  style: TextStyle(fontSize: 12, color: cs.error),
                ),
              ),
          ],
        );
      }),
    );
  }
}
