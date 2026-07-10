import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:PiliPlus/services/desktop_lyrics_service.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

class DesktopLyricsPage extends StatefulWidget {
  const DesktopLyricsPage({super.key});

  @override
  State<DesktopLyricsPage> createState() => _DesktopLyricsPageState();
}

class _DesktopLyricsPageState extends State<DesktopLyricsPage> {
  final _box = GStorage.setting;

  late int _opacity;
  late int _fontSize;
  late int _width;
  late int _posX;
  late int _posY;
  late String _fontFamily;
  late int _layoutMode;
  late int _fontStyle;
  late int _textAlign;
  late Color _textColor;
  late Color _nextTextColor;
  late bool _strokeEnabled;
  late Color _strokeColor;

  List<String> _systemFonts = [];
  bool _fontsLoaded = false;
  double _screenW = 1920;
  double _screenH = 1080;

  static const _layoutModes = [
    '当前行在上，下一行在下',
    '单行模式（仅当前行）',
  ];

  static const _alignOptions = [
    '居左',
    '居中',
    '居右',
  ];

  static const _fontStyles = [
    'Regular',
    'Bold',
    'Italic',
    'Bold Italic',
  ];

  @override
  void initState() {
    super.initState();
    _loadFromBox();
    _getScreenSize();
    _loadSystemFonts();
  }

  void _getScreenSize() {
    final d = MediaQuery.of(context);
    _screenW = math.max(d.size.width * d.devicePixelRatio, 1920);
    _screenH = math.max(d.size.height * d.devicePixelRatio, 1080);
  }

  void _loadFromBox() {
    _opacity = _box.get(SettingBoxKey.desktopLyricsOpacity, defaultValue: 85) as int;
    _fontSize = _box.get(SettingBoxKey.desktopLyricsFontSize, defaultValue: 28) as int;
    _width = _box.get(SettingBoxKey.desktopLyricsWidth, defaultValue: 1200) as int;
    _posX = _box.get(SettingBoxKey.desktopLyricsPosX, defaultValue: -1) as int;
    _posY = _box.get(SettingBoxKey.desktopLyricsPosY, defaultValue: -1) as int;
    _fontFamily = _box.get(SettingBoxKey.desktopLyricsFontFamily, defaultValue: 'Microsoft YaHei') as String;
    _layoutMode = _box.get(SettingBoxKey.desktopLyricsLayoutMode, defaultValue: 0) as int;
    _fontStyle = _box.get(SettingBoxKey.desktopLyricsFontStyle, defaultValue: 0) as int;
    _textAlign = _box.get(SettingBoxKey.desktopLyricsTextAlign, defaultValue: 1) as int;
    _strokeEnabled = _box.get(SettingBoxKey.desktopLyricsStrokeEnabled, defaultValue: true) as bool;

    int tc = _box.get(SettingBoxKey.desktopLyricsTextColor, defaultValue: 0xFFFFFFFF) as int;
    int ntc = _box.get(SettingBoxKey.desktopLyricsNextTextColor, defaultValue: 0x80FFFFFF) as int;
    int sc = _box.get(SettingBoxKey.desktopLyricsStrokeColor, defaultValue: 0xFF000000) as int;
    _textColor = Color(tc);
    _nextTextColor = Color(ntc);
    _strokeColor = Color(sc);
  }

  Future<void> _loadSystemFonts() async {
    try {
      final result = await DesktopLyricsService.enumerateFonts();
      if (result is List && result.length > 10) {
        _systemFonts = result.cast<String>();
        if (!_systemFonts.contains(_fontFamily)) {
          _systemFonts.insert(0, _fontFamily);
        }
        _fontsLoaded = true;
        if (mounted) setState(() {});
        return;
      }
    } catch (_) {}
    // Fallback: PowerShell via shell to enumerate .NET fonts
    try {
      final process = await Process.start('powershell', [
        '-NoProfile',
        '-Command',
        'Add-Type -AssemblyName System.Drawing; '
        '[System.Drawing.Text.InstalledFontCollection]::new().Families '
        '| ForEach-Object { \$_.Name }',
      ]);
      final stdout = await process.stdout.transform(SystemEncoding().decoder).join();
      final lines = stdout.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      if (lines.length > 10) {
        _systemFonts = lines;
        if (!_systemFonts.contains(_fontFamily)) {
          _systemFonts.insert(0, _fontFamily);
        }
      }
    } catch (_) {}
    if (_systemFonts.isEmpty) {
      _systemFonts = ['Microsoft YaHei', 'Arial', 'Segoe UI'];
    }
    _fontsLoaded = true;
    if (mounted) setState(() {});
  }

  void _reset() {
    _opacity = 85;
    _fontSize = 28;
    _width = 1200;
    _posX = -1;
    _posY = -1;
    _fontFamily = 'Microsoft YaHei';
    _layoutMode = 0;
    _fontStyle = 0;
    _textAlign = 1;
    _textColor = Colors.white;
    _nextTextColor = Colors.white.withValues(alpha: 0.5);
    _strokeEnabled = true;
    _strokeColor = Colors.black;
    _applyAll();
    setState(() {});
  }

  void _applyAll() {
    DesktopLyricsService.setOpacity(_opacity);
    DesktopLyricsService.setFontSize(_fontSize);
    DesktopLyricsService.setWindowWidth(_width);
    DesktopLyricsService.setFontFamily(_fontFamily);
    DesktopLyricsService.setLayoutMode(_layoutMode);
    DesktopLyricsService.setFontStyle(_fontStyle);
    DesktopLyricsService.setTextAlign(_textAlign);
    DesktopLyricsService.setTextColor(_textColor.value);
    DesktopLyricsService.setNextTextColor(_nextTextColor.value);
    DesktopLyricsService.setStrokeEnabled(_strokeEnabled);
    DesktopLyricsService.setStrokeColor(_strokeColor.value);
    if (_posX >= 0 && _posY >= 0) {
      DesktopLyricsService.setPosition(x: _posX, y: _posY);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hPadding = MediaQuery.paddingOf(context).horizontal;
    final sc = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('桌面歌词'),
        actions: [
          TextButton(onPressed: _reset, child: const Text('重置')),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16 + hPadding, 8, 16 + hPadding, 100),
        children: [
          Card(
            color: sc.tertiaryContainer.withValues(alpha: 0.5),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 18, color: sc.onTertiaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '所有调整即时生效，在音频页播放时桌面上会同步看到效果。',
                      style: theme.textTheme.bodySmall?.copyWith(color: sc.onTertiaryContainer),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ============ 外观 ============
          _SectionTitle(title: '外观'),
          _InputSliderTile(
            title: '透明度',
            value: _opacity,
            min: 20,
            max: 100,
            suffix: '%',
            onChanged: (v) {
              _opacity = v;
              DesktopLyricsService.setOpacity(_opacity);
              setState(() {});
            },
          ),
          _InputSliderTile(
            title: '字号',
            value: _fontSize,
            min: 14,
            max: 60,
            suffix: 'px',
            onChanged: (v) {
              _fontSize = v;
              DesktopLyricsService.setFontSize(_fontSize);
              setState(() {});
            },
          ),
          _InputSliderTile(
            title: '窗口宽度',
            value: _width,
            min: 400,
            max: 2000,
            suffix: 'px',
            onChanged: (v) {
              _width = v;
              DesktopLyricsService.setWindowWidth(_width);
              setState(() {});
            },
          ),

          // ============ 位置 ============
          _SectionTitle(title: '位置'),
          _InputSliderTile(
            title: 'X 坐标',
            value: _posX < 0 ? (_screenW ~/ 2 - _width ~/ 2) : _posX,
            min: 0,
            max: _screenW.toInt(),
            suffix: 'px',
            onChanged: (v) {
              _posX = v;
              DesktopLyricsService.setPosition(x: _posX, y: _posY < 0 ? 0 : _posY);
              setState(() {});
            },
          ),
          _InputSliderTile(
            title: 'Y 坐标',
            value: _posY < 0 ? 0 : _posY,
            min: 0,
            max: _screenH.toInt(),
            suffix: 'px',
            onChanged: (v) {
              _posY = v;
              DesktopLyricsService.setPosition(
                x: _posX < 0 ? (_screenW ~/ 2 - _width ~/ 2) : _posX,
                y: _posY,
              );
              setState(() {});
            },
          ),

          // ============ 字体 ============
          _SectionTitle(title: '字体'),
          _FontSelector(
            fonts: _systemFonts,
            loaded: _fontsLoaded,
            selected: _fontFamily,
            onChanged: (v) {
              _fontFamily = v;
              DesktopLyricsService.setFontFamily(_fontFamily);
              setState(() {});
            },
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: DropdownButtonFormField<int>(
              value: _fontStyle,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                labelText: '字体样式',
              ),
              items: List.generate(
                _fontStyles.length,
                (i) => DropdownMenuItem(value: i, child: Text(_fontStyles[i])),
              ),
              onChanged: (v) {
                if (v != null) {
                  _fontStyle = v;
                  DesktopLyricsService.setFontStyle(_fontStyle);
                  setState(() {});
                }
              },
            ),
          ),

          // ============ 排列 ============
          _SectionTitle(title: '排列方式'),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SegmentedButton<int>(
              segments: List.generate(
                _layoutModes.length,
                (i) => ButtonSegment(value: i, label: Text(_layoutModes[i])),
              ),
              selected: {_layoutMode},
              onSelectionChanged: (v) {
                _layoutMode = v.first;
                DesktopLyricsService.setLayoutMode(_layoutMode);
                setState(() {});
              },
            ),
          ),

          // ============ 对齐 ============
          _SectionTitle(title: '文字对齐'),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SegmentedButton<int>(
              segments: List.generate(
                _alignOptions.length,
                (i) => ButtonSegment(
                  value: i,
                  label: Text(_alignOptions[i]),
                  icon: Icon(
                    i == 0 ? Icons.format_align_left
                        : i == 2 ? Icons.format_align_right
                            : Icons.format_align_center,
                  ),
                ),
              ),
              selected: {_textAlign},
              onSelectionChanged: (v) {
                _textAlign = v.first;
                DesktopLyricsService.setTextAlign(_textAlign);
                setState(() {});
              },
            ),
          ),

          // ============ 颜色 ============
          _SectionTitle(title: '颜色'),
          _ColorTile(
            title: '当前行文字',
            color: _textColor,
            onChanged: (c) {
              _textColor = c;
              DesktopLyricsService.setTextColor(_textColor.value);
              setState(() {});
            },
          ),
          _ColorTile(
            title: '下一行文字',
            color: _nextTextColor,
            onChanged: (c) {
              _nextTextColor = c;
              DesktopLyricsService.setNextTextColor(_nextTextColor.value);
              setState(() {});
            },
          ),

          // ============ 描边 ============
          _SectionTitle(title: '描边'),
          SwitchListTile(
            title: const Text('启用描边'),
            subtitle: Text(_strokeEnabled ? '文字带有描边，更清晰' : '无描边，文字可能和背景融合'),
            value: _strokeEnabled,
            onChanged: (v) {
              _strokeEnabled = v;
              DesktopLyricsService.setStrokeEnabled(_strokeEnabled);
              setState(() {});
            },
          ),
          if (_strokeEnabled)
            _ColorTile(
              title: '描边颜色',
              color: _strokeColor,
              onChanged: (c) {
                _strokeColor = c;
                DesktopLyricsService.setStrokeColor(_strokeColor.value);
                setState(() {});
              },
            ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ================================================================
// 带搜索的字体选择器
// ================================================================

class _FontSelector extends StatefulWidget {
  final List<String> fonts;
  final bool loaded;
  final String selected;
  final ValueChanged<String> onChanged;

  const _FontSelector({
    required this.fonts,
    required this.loaded,
    required this.selected,
    required this.onChanged,
  });

  @override
  State<_FontSelector> createState() => _FontSelectorState();
}

class _FontSelectorState extends State<_FontSelector> {
  final _searchCtrl = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<String> get _filtered {
    if (_filter.isEmpty) return widget.fonts;
    return widget.fonts
        .where((f) => f.toLowerCase().contains(_filter.toLowerCase()))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!widget.loaded) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              const Text('正在加载系统字体…'),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: '搜索字体…',
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              onChanged: (v) => setState(() => _filter = v),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 200,
              child: ListView(
                children: [
                  for (final f in _filtered)
                    ListTile(
                      dense: true,
                      selected: f == widget.selected,
                      selectedTileColor: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                      title: Text(f, style: TextStyle(fontFamily: f)),
                      trailing: f == widget.selected
                          ? Icon(Icons.check, size: 18, color: theme.colorScheme.primary)
                          : null,
                      onTap: () => widget.onChanged(f),
                    ),
                  if (_filtered.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('未找到匹配的字体', style: theme.textTheme.bodySmall),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ================================================================
// 带输入框的滑块
// ================================================================

class _InputSliderTile extends StatefulWidget {
  final String title;
  final int value;
  final int min;
  final int max;
  final String suffix;
  final ValueChanged<int> onChanged;

  const _InputSliderTile({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.suffix,
    required this.onChanged,
  });

  @override
  State<_InputSliderTile> createState() => _InputSliderTileState();
}

class _InputSliderTileState extends State<_InputSliderTile> {
  late TextEditingController _ctrl;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value.toString());
  }

  @override
  void didUpdateWidget(_InputSliderTile old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value && !_editing) {
      _ctrl.text = widget.value.toString();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    _editing = false;
    final v = int.tryParse(_ctrl.text);
    if (v != null && v >= widget.min && v <= widget.max) {
      widget.onChanged(v);
    } else {
      _ctrl.text = widget.value.toString();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sc = theme.colorScheme;
    final divisions = widget.max - widget.min;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(widget.title, style: theme.textTheme.titleSmall),
                const Spacer(),
                SizedBox(
                  width: 72,
                  height: 32,
                  child: TextField(
                    controller: _ctrl,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: sc.primary, fontWeight: FontWeight.w600),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                      suffixText: widget.suffix,
                      suffixStyle: TextStyle(fontSize: 11, color: sc.outline),
                    ),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onTap: () {
                      _editing = true;
                      _ctrl.selection = TextSelection(baseOffset: 0, extentOffset: _ctrl.text.length);
                    },
                    onSubmitted: (_) => _submit(),
                    onEditingComplete: _submit,
                  ),
                ),
              ],
            ),
            Slider(
              min: widget.min.toDouble(),
              max: widget.max.toDouble(),
              divisions: divisions,
              value: widget.value.toDouble().clamp(widget.min.toDouble(), widget.max.toDouble()),
              onChanged: (v) {
                widget.onChanged(v.round());
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ================================================================
// Section Title
// ================================================================

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}

// ================================================================
// Color Picker
// ================================================================

class _ColorTile extends StatelessWidget {
  final String title;
  final Color color;
  final ValueChanged<Color> onChanged;

  const _ColorTile({
    required this.title,
    required this.color,
    required this.onChanged,
  });

  static const _presets = [
    Color(0xFFFFFFFF),
    Color(0xFF00FFFF),
    Color(0xFFFF69B4),
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFFFF4500),
    Color(0xFF87CEEB),
    Color(0xFFDDA0DD),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.5)),
                  ),
                ),
                const SizedBox(width: 12),
                Text(title, style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: _presets.map((c) {
                final isSelected = c.value == color.value;
                return GestureDetector(
                  onTap: () => onChanged(c),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: c,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isSelected ? theme.colorScheme.primary : theme.colorScheme.outline.withValues(alpha: 0.3),
                        width: isSelected ? 3 : 1,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}
