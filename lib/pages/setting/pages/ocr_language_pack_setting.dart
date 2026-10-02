import 'package:PiliPlus/services/ocr/ocr_language_pack_manager.dart';
import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';

/// OCR 语言包管理页：选择下载语言（RapidOCR / ONNX）
class OcrLanguagePackSettingPage extends StatefulWidget {
  const OcrLanguagePackSettingPage({super.key});

  @override
  State<OcrLanguagePackSettingPage> createState() =>
      _OcrLanguagePackSettingPageState();
}

class _OcrLanguagePackSettingPageState extends State<OcrLanguagePackSettingPage> {
  late final OcrLanguagePackManager _mgr;

  @override
  void initState() {
    super.initState();
    _mgr = Get.isRegistered<OcrLanguagePackManager>()
        ? Get.find<OcrLanguagePackManager>()
        : Get.put(OcrLanguagePackManager(), permanent: true);
    _mgr.refreshStatus();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('OCR 语言包')),
      body: Obx(() {
        final downloading = _mgr.downloadingLang.value;
        final downloaded = _mgr.downloadedLangs.value;
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                '选择需要识别语言，按语言包下载（识别模型+字典）。det/cls 共享模型首次下载时自动带上。',
                style: TextStyle(fontSize: 12),
              ),
            ),
            for (final lang in OcrLanguagePackManager.languages) ...[
              ListTile(
                leading: Icon(
                  downloaded.contains(lang.code)
                      ? Icons.check_circle
                      : Icons.language,
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
