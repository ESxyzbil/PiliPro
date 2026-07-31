import 'package:PiliPlus/common/widgets/glass.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

/// 毛玻璃设置页：顶栏 / 视频卡片 / 信息卡片 三类独立调节
/// （开关 + 模糊强度 + 不透明度 + 颜色）。
class GlassSettingPage extends StatefulWidget {
  const GlassSettingPage({super.key});

  @override
  State<GlassSettingPage> createState() => _GlassSettingPageState();
}

class _GlassSettingPageState extends State<GlassSettingPage> {
  static const _presetColors = <Color>[
    Color(0xFFECECEC), // 浅灰
    Color(0xFFF5F5F5), // 亮白
    Color(0xFF1E1E1E), // 深灰
    Color(0xFF2B2B2B), // 暗黑
    Color(0xFF3A3A4A), // 蓝灰
    Color(0xFF4A3A4A), // 紫灰
    Color(0xFF4A443A), // 棕灰
    Color(0xFF3A4A44), // 绿灰
  ];

  late final List<_KindConfig> _kinds = [
    const _KindConfig(
      kind: GlassKind.topBar,
      icon: Icons.blur_on,
      title: '顶栏毛玻璃',
      subtitle: '顶栏半透明模糊，透出背景',
      enabledKey: SettingBoxKey.glassTopBar,
      blurKey: SettingBoxKey.glassTopBarBlur,
      opacityKey: SettingBoxKey.glassTopBarOpacity,
      colorKey: SettingBoxKey.glassTopBarColor,
    ),
    const _KindConfig(
      kind: GlassKind.card,
      icon: Icons.style_outlined,
      title: '视频卡片毛玻璃',
      subtitle: '首页视频卡片半透明模糊（耗性能，建议开启后调低模糊）',
      enabledKey: SettingBoxKey.glassCard,
      blurKey: SettingBoxKey.glassCardBlur,
      opacityKey: SettingBoxKey.glassCardOpacity,
      colorKey: SettingBoxKey.glassCardColor,
    ),
    const _KindConfig(
      kind: GlassKind.infoCard,
      icon: Icons.widgets_outlined,
      title: '信息卡片毛玻璃',
      subtitle: '设置页、动态等列表项卡片半透明模糊',
      enabledKey: SettingBoxKey.glassInfoCard,
      blurKey: SettingBoxKey.glassInfoCardBlur,
      opacityKey: SettingBoxKey.glassInfoCardOpacity,
      colorKey: SettingBoxKey.glassInfoCardColor,
    ),
    const _KindConfig(
      kind: GlassKind.bottomBar,
      icon: Icons.navigation_outlined,
      title: '底栏毛玻璃',
      subtitle: '底部导航栏半透明模糊，透出背景',
      enabledKey: SettingBoxKey.glassBottomBar,
      blurKey: SettingBoxKey.glassBottomBarBlur,
      opacityKey: SettingBoxKey.glassBottomBarOpacity,
      colorKey: SettingBoxKey.glassBottomBarColor,
    ),
    const _KindConfig(
      kind: GlassKind.replyPanel,
      icon: Icons.forum_outlined,
      title: '回复面板毛玻璃',
      subtitle: '评论回复弹层半透明模糊，提升可读性',
      enabledKey: SettingBoxKey.glassReplyPanel,
      blurKey: SettingBoxKey.glassReplyPanelBlur,
      opacityKey: SettingBoxKey.glassReplyPanelOpacity,
      colorKey: SettingBoxKey.glassReplyPanelColor,
    ),
  ];

  Future<void> _set(String key, Object value) async {
    await GStorage.setting.put(key, value);
    Get.updateMyAppTheme();
  }

  Future<void> _showSliderDialog({
    required String title,
    required double value,
    required double min,
    required double max,
    required String Function(double) display,
    required String key,
  }) async {
    await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: StatefulBuilder(
          builder: (context, setState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Slider(
                value: value.clamp(min, max).toDouble(),
                min: min,
                max: max,
                divisions: ((max - min) * 40).round(),
                label: display(value),
                onChanged: (v) {
                  setState(() => value = v);
                },
                onChangeEnd: (v) => _set(key, v),
              ),
              Text(
                display(value),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showColorPicker(String current, String key) async {
    final theme = Theme.of(context);
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: theme.colorScheme.surfaceContainerLow,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '选择毛玻璃颜色',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _colorDot(
                    context,
                    color: null,
                    label: '跟随主题',
                    selected: current.isEmpty,
                    onTap: () => Navigator.pop(context, ''),
                  ),
                  ..._presetColors.map(
                    (c) => _colorDot(
                      context,
                      color: c,
                      selected: current == _hex(c),
                      onTap: () => Navigator.pop(context, _hex(c)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      await _set(key, selected);
      SmartDialog.showToast(selected.isEmpty ? '已跟随主题' : '颜色已更新');
    }
  }

  Widget _colorDot(
    BuildContext context, {
    required Color? color,
    required bool selected,
    required VoidCallback onTap,
    String? label,
  }) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color ?? theme.colorScheme.surfaceContainerHighest,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
                width: selected ? 3 : 1,
              ),
            ),
            child: color == null
                ? Icon(
                    Icons.auto_awesome,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  )
                : null,
          ),
          if (label != null) ...[
            const SizedBox(height: 4),
            Text(label, style: theme.textTheme.labelSmall),
          ],
        ],
      ),
    );
  }

  /// 单个类别的完整分组：开关 + 模糊 + 透明度 + 颜色
  Widget _buildGroup(ThemeData theme, _KindConfig cfg) {
    final enabled = Glass.enabled(cfg.kind);
    final blur = Glass.blur(cfg.kind);
    final opacity = Glass.opacity(cfg.kind);
    final color = Glass.colorStr(cfg.kind);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Icon(cfg.icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(cfg.title, style: theme.textTheme.titleMedium),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            cfg.subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ),
        SwitchListTile(
          secondary: Icon(cfg.icon),
          title: const Text('启用'),
          value: enabled,
          onChanged: (v) => _set(cfg.enabledKey, v),
        ),
        ListTile(
          enabled: enabled,
          leading: const Icon(Icons.gradient_outlined),
          title: const Text('模糊强度'),
          trailing: Text(
            blur <= 0.5 ? '无' : blur.round().toString(),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          onTap: () => _showSliderDialog(
            title: '模糊强度',
            value: blur,
            min: 0,
            max: 20,
            display: (v) => v <= 0.5 ? '无' : v.round().toString(),
            key: cfg.blurKey,
          ),
        ),
        ListTile(
          enabled: enabled,
          leading: const Icon(Icons.opacity),
          title: const Text('不透明度'),
          trailing: Text(
            '${(opacity * 100).round()}%',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          onTap: () => _showSliderDialog(
            title: '不透明度',
            value: opacity,
            min: 0.15,
            max: 1.0,
            display: (v) => '${(v * 100).round()}%',
            key: cfg.opacityKey,
          ),
        ),
        ListTile(
          enabled: enabled,
          leading: const Icon(Icons.palette_outlined),
          title: const Text('颜色'),
          subtitle: const Text('毛玻璃底色，默认跟随主题'),
          trailing: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: _parseHex(color) ?? theme.colorScheme.surface,
              shape: BoxShape.circle,
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
          ),
          onTap: () => _showColorPicker(color, cfg.colorKey),
        ),
        const Divider(height: 1),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('毛玻璃设置')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final cfg in _kinds) _buildGroup(theme, cfg),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '三类毛玻璃各自独立调节。卡片毛玻璃在瀑布流中同时渲染多个模糊层，'
              '中低端设备建议将模糊强度控制在 8 以内，或仅开启顶栏毛玻璃。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _hex(Color c) {
    final v = c.toARGB32();
    return '#${(v & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  static Color? _parseHex(String hex) {
    if (hex.isEmpty) return null;
    var h = hex.trim().replaceFirst('#', '');
    if (h.length == 6) h = 'FF$h';
    final v = int.tryParse(h, radix: 16);
    return v == null ? null : Color(v);
  }
}

/// 单类毛玻璃的配置描述
class _KindConfig {
  const _KindConfig({
    required this.kind,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabledKey,
    required this.blurKey,
    required this.opacityKey,
    required this.colorKey,
  });

  final GlassKind kind;
  final IconData icon;
  final String title;
  final String subtitle;
  final String enabledKey;
  final String blurKey;
  final String opacityKey;
  final String colorKey;
}
