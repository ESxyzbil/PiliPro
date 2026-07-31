import 'dart:io';
import 'dart:ui' show loadFontFromList;

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/font_name_parser.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

/// 字体选择子页面：列出设备已安装字体，点选立即生效并返回。
class FontPickerPage extends StatefulWidget {
  const FontPickerPage({super.key});

  @override
  State<FontPickerPage> createState() => _FontPickerPageState();
}

class _FontPickerPageState extends State<FontPickerPage> {
  late List<_FontEntry> _fonts = [];
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadFonts();
  }

  Future<void> _loadFonts() async {
    final dirs = <String>[];
    if (Platform.isAndroid) {
      dirs.add('/system/fonts');
    } else if (Platform.isWindows) {
      dirs.add(r'C:\Windows\Fonts');
    } else if (Platform.isMacOS) {
      dirs.add('/System/Library/Fonts');
    } else if (Platform.isLinux) {
      dirs.add('/usr/share/fonts');
    }
    final files = <File>[];
    for (final dir in dirs) {
      try {
        final d = Directory(dir);
        if (!await d.exists()) continue;
        await for (final e in d.list(followLinks: false)) {
          if (e is! File) continue;
          final name = e.path
              .split('\\')
              .last
              .split('/')
              .last
              .toLowerCase();
          if (name.endsWith('.ttf') ||
              name.endsWith('.otf') ||
              name.endsWith('.ttc')) {
            files.add(e);
          }
        }
      } catch (_) {
        // 无权限等场景直接跳过该目录
      }
    }
    // 读取字体真实名称，同名字体去重（保留第一个）
    final seen = <String>{};
    final entries = <_FontEntry>[];
    for (final f in files) {
      final familyName = FontNameParser.parseFamilyName(f);
      if (familyName == null) {
        entries.add(_FontEntry(f, null));
        continue;
      }
      if (seen.add(familyName)) {
        entries.add(_FontEntry(f, familyName));
      }
    }
    entries.sort((a, b) {
      final an = (a.familyName ?? a.fileName).toLowerCase();
      final bn = (b.familyName ?? b.fileName).toLowerCase();
      return an.compareTo(bn);
    });
    if (mounted) {
      setState(() {
        _fonts = entries;
        _loading = false;
      });
    }
  }

  /// 读取字体文件并注册到 Flutter
  static Future<bool> loadAppFont(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      await loadFontFromList(bytes, fontFamily: Style.appFontFamilyName);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _selectFont(_FontEntry font) async {
    final ok = await loadAppFont(font.file.path);
    if (!ok) {
      if (mounted) SmartDialog.showToast('字体加载失败，请尝试其它字体');
      return;
    }
    await GStorage.setting.put(SettingBoxKey.appFontFamily, font.file.path);
    Get.updateMyAppTheme();
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _useSystemDefault() async {
    await GStorage.setting.delete(SettingBoxKey.appFontFamily);
    Get.updateMyAppTheme();
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentFont = Pref.appFontFamily;
    final filtered = _query.isEmpty
        ? _fonts
        : _fonts
            .where((e) =>
                (e.familyName ?? '').toLowerCase().contains(_query) ||
                e.fileName.toLowerCase().contains(_query))
            .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择字体'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              onChanged: (v) => setState(() => _query = v.toLowerCase()),
              decoration: InputDecoration(
                hintText: '搜索字体',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          ListTile(
            leading: const Icon(Icons.phonelink_setup_outlined),
            title: const Text('系统默认'),
            subtitle: const Text('跟随设备默认字体'),
            trailing: Radio<int>(
              value: 0,
              groupValue: currentFont.isEmpty ? 0 : 1,
              onChanged: (_) => _useSystemDefault(),
            ),
            onTap: _useSystemDefault,
          ),
          const Divider(height: 1),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  _query.isEmpty ? '未找到系统字体文件' : '没有匹配的字体',
                  style: TextStyle(color: theme.colorScheme.outline),
                ),
              ),
            )
          else
            ...filtered.map((font) {
              final selected = currentFont == font.file.path;
              final familyName = font.familyName ?? font.fileName;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    dense: true,
                    title: Text(
                      familyName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        color: selected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      font.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                    trailing: Radio<int>(
                      value: 1,
                      groupValue: selected ? 1 : 0,
                      onChanged: (_) => _selectFont(font),
                    ),
                    onTap: () => _selectFont(font),
                  ),
                  const Divider(height: 1),
                ],
              );
            }),
        ],
      ),
    );
  }
}

class _FontEntry {
  _FontEntry(this.file, this.familyName);

  final File file;
  final String? familyName;

  String get fileName => file.path.split('\\').last.split('/').last;
}
