import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

class PpiSettingPage extends StatefulWidget {
  const PpiSettingPage({super.key});

  @override
  State<PpiSettingPage> createState() => _PpiSettingPageState();
}

class _PpiSettingPageState extends State<PpiSettingPage> {
  static const List<int> _ppiOptions = [120, 160, 240, 320, 480, 640];
  static const int _ppiMin = 80;
  static const int _ppiMax = 1000;

  late int _devicePpi;
  late int _currentActivePpi;
  final _customController = TextEditingController();
  int? _selectedPpi;
  late int _initialPpi;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    _devicePpi = (160 * dpr).round();
    _currentActivePpi = Pref.targetPpi ?? _devicePpi;
    _initialPpi = _currentActivePpi;
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  int get _currentSelected => _selectedPpi ?? _initialPpi;

  bool get _isCustom =>
      _selectedPpi != null &&
      !_ppiOptions.contains(_selectedPpi) &&
      _selectedPpi != _devicePpi;

  void _onSelect(int? ppi) {
    if (ppi != null) {
      setState(() {
        _selectedPpi = ppi;
        _customController.clear();
      });
    }
  }

  void _onCustomSubmit() {
    final text = _customController.text.trim();
    final parsed = int.tryParse(text);
    if (parsed == null || parsed < _ppiMin || parsed > _ppiMax) return;
    setState(() {
      _selectedPpi = parsed;
    });
  }

  Future<void> _onApply() async {
    final targetPpi = _currentSelected;

    if (targetPpi == _devicePpi) {
      await GStorage.setting.delete(SettingBoxKey.targetPpi);
    } else {
      await GStorage.setting.put(SettingBoxKey.targetPpi, targetPpi);
    }
    Get.appUpdate();
    Get.back();
  }

  void _onReset() {
    setState(() {
      _selectedPpi = _devicePpi;
      _customController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = _currentSelected;
    final effectiveChanged = current != _initialPpi;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('应用内PPI'),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                // 当前状态
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '物理密度: $_devicePpi PPI',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '当前: $_currentActivePpi PPI',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      if (effectiveChanged) ...[
                        const SizedBox(height: 2),
                        Text(
                          '目标: $current PPI',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                      Text(
                        '设备像素比: ${(current / 160).toStringAsFixed(2)}x',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // 默认
                RadioListTile<int>(
                  title: const Text('自动（设备默认）'),
                  subtitle: Text('$_currentActivePpi PPI'),
                  value: _devicePpi,
                  groupValue: current,
                  onChanged: (v) => _onSelect(v),
                ),
                const Divider(height: 1),
                // PPI 预设
                ..._ppiOptions
                    .where((ppi) => ppi != _devicePpi)
                    .map((ppi) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            RadioListTile<int>(
                              title: Text('$ppi PPI'),
                              subtitle: Text(
                                ppi > _currentActivePpi
                                    ? '${(ppi / _currentActivePpi).toStringAsFixed(2)}x 缩小'
                                    : '${(_currentActivePpi / ppi).toStringAsFixed(2)}x 放大',
                              ),
                              value: ppi,
                              groupValue: current,
                              onChanged: (v) => _onSelect(v),
                            ),
                            const Divider(height: 1),
                          ],
                        )),
                // 自定义
                RadioListTile<int>(
                  title: const Text('自定义'),
                  subtitle: const Text('手动输入 PPI 值'),
                  value: _ppiMin - 1,
                  groupValue: _isCustom ? _ppiMin - 1 : current,
                  onChanged: (v) {
                    if (v != null) {
                      _customController.text = _devicePpi.toString();
                      setState(() => _selectedPpi = _devicePpi);
                    }
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: TextField(
                            controller: _customController,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(4),
                            ],
                            decoration: InputDecoration(
                              hintText: '$_ppiMin - $_ppiMax',
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              isDense: true,
                            ),
                            style: theme.textTheme.bodyLarge,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _onCustomSubmit(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 40,
                        child: FilledButton.tonal(
                          onPressed: _onCustomSubmit,
                          style: FilledButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 16),
                          ),
                          child: const Text('确定'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // 预览
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Text(
                          '预览',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _buildPreviewRow(theme, current),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
          // 底部确定按钮
          if (effectiveChanged)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                border: Border(
                  top: BorderSide(
                    color: theme.colorScheme.outline.withValues(alpha: 0.12),
                  ),
                ),
              ),
              child: FilledButton(
                onPressed: _onApply,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('应用'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPreviewRow(ThemeData theme, int ppi) {
    final dpr = ppi / 160.0;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _previewItem(
              theme, 'Aa', 14.0 * dpr / MediaQuery.devicePixelRatioOf(context),
            ),
            _previewItem(
              theme, '标题', 20.0 * dpr / MediaQuery.devicePixelRatioOf(context),
            ),
            _previewItem(
              theme, '图标', 24.0 * dpr / MediaQuery.devicePixelRatioOf(context),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '等效像素比 ${dpr.toStringAsFixed(2)}x',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }

  Widget _previewItem(ThemeData theme, String label, double size) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: size,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${size.toStringAsFixed(0)}sp',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }
}
