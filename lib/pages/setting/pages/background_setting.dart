import 'dart:io';

import 'package:PiliPlus/common/widgets/app_background.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
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
          ..._buildGroup(theme, '全局', const [
            (BgSlot.global, Icons.public, '所有页面的默认背景（含二级页面）'),
          ]),
          ..._buildGroup(theme, '主页面', const [
            (BgSlot.home, Icons.home_outlined, '首页推荐流背景'),
            (BgSlot.dynamics, Icons.motion_photos_on_outlined, '动态页背景'),
            (BgSlot.mine, Icons.person_outline, '我的页背景'),
          ]),
          ..._buildGroup(theme, '其它页面', const [
            (BgSlot.video, Icons.play_circle_outline, '视频播放页、视频标签页'),
            (BgSlot.audio, Icons.music_note_outlined, '音频播放页'),
            (BgSlot.search, Icons.search_outlined, '搜索页、搜索结果页'),
            (BgSlot.member, Icons.person_outline, '用户空间页'),
            (BgSlot.fav, Icons.star_outline, '收藏夹列表、收藏夹详情'),
            (BgSlot.live, Icons.live_tv_outlined, '直播页、直播间'),
          ]),
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

  /// 按分组渲染背景项（槽位顺序即展示顺序）
  List<Widget> _buildGroup(
    ThemeData theme,
    String title,
    List<(BgSlot, IconData, String)> items,
  ) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
      ...items.map(
        (e) => _buildItem(
          theme,
          icon: e.$2,
          title: e.$1.label,
          subtitle: e.$3,
          path: Pref.bgPath(e.$1.key),
          opacity: Pref.bgOpacity(e.$1.key),
          blur: Pref.bgBlur(e.$1.key),
          key: e.$1.key,
        ),
      ),
    ];
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
