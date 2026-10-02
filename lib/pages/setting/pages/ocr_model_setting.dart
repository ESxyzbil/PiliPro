import 'package:PiliPlus/services/ocr/ocr_model_manager.dart';
import 'package:PiliPlus/services/ocr/ocr_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';

/// OCR 歌词模型下载管理页（懒下载，仅 arm64 设备）
class OcrModelSettingPage extends StatefulWidget {
  const OcrModelSettingPage({super.key});

  @override
  State<OcrModelSettingPage> createState() => _OcrModelSettingPageState();
}

class _OcrModelSettingPageState extends State<OcrModelSettingPage> {
  late final OcrModelManager _mgr;
  bool _supported = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _mgr = Get.isRegistered<OcrModelManager>()
        ? Get.find<OcrModelManager>()
        : Get.put(OcrModelManager(), permanent: true);
    if (!Get.isRegistered<OcrService>()) {
      Get.put(OcrService(), permanent: true);
    }
    _init();
  }

  Future<void> _init() async {
    _supported = await OcrService.instance.isSupported();
    _mgr.status.value = await _mgr.isDownloaded()
        ? OcrModelStatus.downloaded
        : OcrModelStatus.notDownloaded;
    if (mounted) setState(() => _checking = false);
  }

  String _statusText(OcrModelStatus s) => switch (s) {
        OcrModelStatus.notDownloaded => '未下载',
        OcrModelStatus.downloading => '下载中',
        OcrModelStatus.downloaded => '已下载',
        OcrModelStatus.error => '下载失败',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('OCR 歌词模型')),
      body: _checking
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                // 设备支持状态
                ListTile(
                  leading: Icon(
                    _supported ? Icons.check_circle : Icons.error_outline,
                    color: _supported ? cs.primary : cs.error,
                  ),
                  title: const Text('设备支持'),
                  subtitle: Text(
                    _supported
                        ? '当前设备为 arm64，可使用本地 OCR'
                        : 'OCR 引擎仅编入 arm64 包，当前设备不支持',
                  ),
                ),
                const Divider(height: 1),
                // 模型状态
                Obx(() {
                  final s = _mgr.status.value;
                  final prog = _mgr.progress.value;
                  return ListTile(
                    leading: Icon(
                      switch (s) {
                        OcrModelStatus.notDownloaded =>
                          Icons.download_outlined,
                        OcrModelStatus.downloading =>
                          Icons.downloading,
                        OcrModelStatus.downloaded => Icons.verified,
                        OcrModelStatus.error => Icons.error_outline,
                      },
                      color: s == OcrModelStatus.error
                          ? cs.error
                          : s == OcrModelStatus.downloaded
                              ? cs.primary
                              : null,
                    ),
                    title: Text('模型状态: ${_statusText(s)}'),
                    subtitle: s == OcrModelStatus.downloading
                        ? LinearProgressIndicator(value: prog)
                        : Text(
                            s == OcrModelStatus.downloaded
                                ? '4 个 NCNN 模型已就绪（约 10.15MB）'
                                : '需下载 4 个 NCNN 模型（det/rec），约 10.15MB',
                          ),
                  );
                }),
                if (_mgr.error.value.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      _mgr.error.value,
                      style: TextStyle(fontSize: 12, color: cs.error),
                    ),
                  ),
                const Divider(height: 1),
                // 操作按钮
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Obx(() {
                    final s = _mgr.status.value;
                    final busy = s == OcrModelStatus.downloading;
                    return Column(
                      children: [
                        FilledButton.icon(
                          onPressed: !_supported || busy
                              ? null
                              : () => _mgr.download(),
                          icon: const Icon(Icons.download),
                          label: Text(
                            s == OcrModelStatus.downloaded ? '重新下载' : '下载模型',
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (s == OcrModelStatus.downloaded ||
                            s == OcrModelStatus.error)
                          OutlinedButton.icon(
                            onPressed: busy ? null : () => _mgr.delete(),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('删除模型'),
                          ),
                      ],
                    );
                  }),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '说明：模型来自 ${OcrModelManager.baseUrl}\n'
                    '下载后识别完全离线；可删除以释放空间。',
                    style: TextStyle(fontSize: 12, color: cs.outline),
                  ),
                ),
              ],
            ),
    );
  }
}
