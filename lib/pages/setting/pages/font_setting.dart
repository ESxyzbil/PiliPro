import 'dart:io';

import 'package:PiliPlus/pages/setting/pages/font_picker_page.dart';
import 'package:PiliPlus/pages/setting/widgets/slider_dialog.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/font_name_parser.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class FontSettingPage extends StatefulWidget {
  const FontSettingPage({super.key});

  @override
  State<FontSettingPage> createState() => _FontSettingPageState();
}

class _FontSettingPageState extends State<FontSettingPage> {
  String? _currentFamilyName;

  @override
  void initState() {
    super.initState();
    _refreshCurrentFont();
  }

  Future<void> _refreshCurrentFont() async {
    final path = Pref.appFontFamily;
    String? familyName;
    if (path.isNotEmpty) {
      familyName = FontNameParser.parseFamilyName(File(path));
    }
    if (mounted) {
      setState(() => _currentFamilyName = familyName);
    }
  }

  Future<void> _useSystemDefault() async {
    await GStorage.setting.delete(SettingBoxKey.appFontFamily);
    Get.updateMyAppTheme();
    _refreshCurrentFont();
  }

  Future<void> _showFontWeightDialog() async {
    final res = await showDialog<double>(
      context: context,
      builder: (context) => SliderDialog(
        title: const Text('App字体字重'),
        value: Pref.appFontWeight.toDouble() + 1,
        min: 1,
        max: FontWeight.values.length.toDouble(),
        divisions: FontWeight.values.length - 1,
      ),
    );
    if (res != null) {
      await GStorage.setting.put(SettingBoxKey.appFontWeight, res.toInt() - 1);
      Get.updateMyAppTheme();
    }
  }

  Future<void> _openFontPicker() async {
    final changed = await Get.to<bool>(() => const FontPickerPage());
    if (changed == true) {
      _refreshCurrentFont();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentFont = Pref.appFontFamily;
    return Scaffold(
      appBar: AppBar(title: const Text('字体设置')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _sectionHeader(theme, '字体'),
          // 当前字体
          ListTile(
            leading: const Icon(Icons.font_download_outlined),
            title: const Text('当前字体'),
            subtitle: Text(
              currentFont.isEmpty
                  ? '系统默认'
                  : (_currentFamilyName ?? _fileName(currentFont)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openFontPicker,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.phonelink_setup_outlined),
            title: const Text('使用系统默认'),
            subtitle: const Text('跟随设备默认字体'),
            enabled: currentFont.isNotEmpty,
            onTap: _useSystemDefault,
          ),
          const SizedBox(height: 8),
          _sectionHeader(theme, '字体大小'),
          ListTile(
            leading: const Icon(Icons.format_size_outlined),
            title: const Text('字体大小'),
            subtitle: Text(
              Pref.defaultTextScale == 1.0
                  ? '默认'
                  : Pref.defaultTextScale.toString(),
            ),
            onTap: () async {
              final res = await Get.toNamed('/fontSizeSetting');
              if (res != null && mounted) setState(() {});
            },
          ),
          const SizedBox(height: 8),
          _sectionHeader(theme, '字重'),
          SwitchListTile(
            secondary: const Icon(Icons.format_size),
            title: const Text('App字体字重'),
            subtitle: const Text('开启后点击设置字重'),
            value: Pref.appFontWeight != -1,
            onChanged: (value) async {
              await GStorage.setting.put(
                SettingBoxKey.appFontWeight,
                value ? 4 : -1,
              );
              Get.updateMyAppTheme();
            },
          ),
          ListTile(
            enabled: Pref.appFontWeight != -1,
            title: const Text('字重等级'),
            trailing: Text(
              Pref.appFontWeight == -1
                  ? '未启用'
                  : _fontWeightLabel(FontWeight.values[Pref.appFontWeight]),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            onTap: _showFontWeightDialog,
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '字体选择会扫描设备内置字体文件（ttf/otf/ttc），选中后立即生效；'
              '已按字体族去重，部分 ttc 集合字体可能无法加载。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _fileName(String path) => path.split('\\').last.split('/').last;

  String _fontWeightLabel(FontWeight fw) {
    final weight = fw.value; // 100-900
    return switch (weight) {
      <= 300 => '细 ($weight)',
      >= 700 => '粗 ($weight)',
      _ => '常规 ($weight)',
    };
  }

  Widget _sectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
