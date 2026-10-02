import 'dart:io';

import 'package:PiliPlus/common/widgets/app_background.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

/// 背景填充设置页：为各页面/全局设置背景图，支持透明度和模糊调节。
class BackgroundSettingPage extends StatefulWidget {
  const BackgroundSettingPage({super.key});

  @override
  State<BackgroundSettingPage> createState() => _BackgroundSettingPageState();
}

class _BackgroundSettingPageState extends State<BackgroundSettingPage> {
  late final _picker = ImagePicker();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('设置背景')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              '为不同页面区域设置背景图片，未单独设置的页面会跟随全局背景。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          _buildItem(
            theme,
            icon: Icons.public,
            title: '全局背景',
            subtitle: '所有页面的默认背景（含二级页面）',
            path: Pref.globalBg,
            opacity: Pref.globalBgOpacity,
            blur: Pref.globalBgBlur,
            key: SettingBoxKey.globalBg,
          ),
          _buildItem(
            theme,
            icon: Icons.home_outlined,
            title: '首页背景',
            subtitle: '首页推荐流背景',
            path: Pref.homeBg,
            opacity: Pref.homeBgOpacity,
            blur: Pref.homeBgBlur,
            key: SettingBoxKey.homeBg,
          ),
          _buildItem(
            theme,
            icon: Icons.motion_photos_on_outlined,
            title: '动态背景',
            subtitle: '动态页背景',
            path: Pref.dynamicsBg,
            opacity: Pref.dynamicsBgOpacity,
            blur: Pref.dynamicsBgBlur,
            key: SettingBoxKey.dynamicsBg,
          ),
          _buildItem(
            theme,
            icon: Icons.person_outline,
            title: '我的背景',
            subtitle: '我的页背景',
            path: Pref.mineBg,
            opacity: Pref.mineBgOpacity,
            blur: Pref.mineBgBlur,
            key: SettingBoxKey.mineBg,
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '背景图片会保存在应用目录中，从相册选择后自动复制保存；'
              '点击已设置项可调节透明度与高斯模糊强度，'
              '深色模式下会自动叠加暗色遮罩保证可读性。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItem(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required String path,
    required double opacity,
    required double blur,
    required String key,
  }) {
    final hasImage = path.isNotEmpty && File(path).existsSync();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(
            hasImage ? '已设置，点击调节效果' : subtitle,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasImage)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.broken_image_outlined),
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '清除',
                icon: const Icon(Icons.close),
                onPressed: hasImage ? () => _clear(key) : null,
              ),
            ],
          ),
          onTap: () => _showActionSheet(theme, title, key, path),
        ),
        const Divider(height: 1, indent: 16),
      ],
    );
  }

  Future<void> _showActionSheet(
    ThemeData theme,
    String title,
    String key,
    String path,
  ) async {
    final hasImage = path.isNotEmpty && File(path).existsSync();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.colorScheme.surfaceContainerLow,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  '$title设置',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (hasImage) ...[
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 120,
                      height: 72,
                      child: Image.file(
                        File(path),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.broken_image_outlined,
                        ),
                      ),
                    ),
                  ),
                ),
                _EffectSlider(
                  title: '透明度',
                  value: _getOpacity(key),
                  min: 0.2,
                  max: 1.0,
                  display: (v) => '${(v * 100).round()}%',
                  onChanged: (v) {
                    GStorage.setting.put('${key}Opacity', v);
                    BgNotifier.notify();
                  },
                ),
                _EffectSlider(
                  title: '高斯模糊',
                  value: _getBlur(key),
                  min: 0,
                  max: 20,
                  display: (v) => v <= 0.5 ? '无' : v.round().toString(),
                  onChanged: (v) {
                    GStorage.setting.put('${key}Blur', v);
                    BgNotifier.notify();
                  },
                ),
                const Divider(height: 1),
              ],
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('从相册选择'),
                onTap: () {
                  Navigator.pop(context);
                  _pickFromGallery(key);
                },
              ),
              if (hasImage)
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('清除背景'),
                  onTap: () {
                    Navigator.pop(context);
                    _clear(key);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  double _getOpacity(String key) {
    final v = GStorage.setting.get('${key}Opacity', defaultValue: 1.0);
    return v is num ? v.toDouble() : 1.0;
  }

  double _getBlur(String key) {
    final v = GStorage.setting.get('${key}Blur', defaultValue: 0.0);
    return v is num ? v.toDouble() : 0.0;
  }

  Future<void> _pickFromGallery(String key) async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 92,
        requestFullMetadata: false,
      );
      if (picked == null || !mounted) return;
      // 复制到应用目录持久化（相册缓存路径可能被回收）
      final dir = Directory(p.join(appSupportDirPath, 'background'));
      await dir.create(recursive: true);
      final ext = picked.name.contains('.')
          ? picked.name.split('.').last.toLowerCase()
          : 'jpg';
      final dest = p.join(dir.path, '$key.$ext');
      await File(picked.path).copy(dest);
      await GStorage.setting.put(key, dest);
      // 预加载背景图，避免切换/进入时闪烁
      if (mounted) {
        await precacheImage(FileImage(File(dest)), context);
      }
      BgNotifier.notify();
      Get.updateMyAppTheme();
      if (mounted) {
        setState(() {});
        SmartDialog.showToast('背景已设置');
      }
    } catch (e) {
      if (mounted) SmartDialog.showToast('设置背景失败：$e');
    }
  }

  Future<void> _clear(String key) async {
    await GStorage.setting.delete(key);
    BgNotifier.notify();
    Get.updateMyAppTheme();
    if (mounted) {
      setState(() {});
      SmartDialog.showToast('背景已清除');
    }
  }
}

/// 效果调节滑块：拖动时实时预览
class _EffectSlider extends StatefulWidget {
  const _EffectSlider({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });

  final String title;
  final double value;
  final double min;
  final double max;
  final String Function(double) display;
  final ValueChanged<double> onChanged;

  @override
  State<_EffectSlider> createState() => _EffectSliderState();
}

class _EffectSliderState extends State<_EffectSlider> {
  late double _value;

  @override
  void initState() {
    super.initState();
    _value = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              widget.title,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          Expanded(
            child: Slider(
              value: _value.clamp(widget.min, widget.max),
              min: widget.min,
              max: widget.max,
              divisions: widget.max - widget.min <= 1 ? 80 : 40,
              onChanged: (v) {
                setState(() => _value = v);
                widget.onChanged(v);
              },
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              widget.display(_value),
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
