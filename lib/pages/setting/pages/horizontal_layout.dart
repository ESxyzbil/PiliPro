import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:material_ui/material_ui.dart';

/// 横屏适配设置页（用户要求：把原来的「横屏适配」开关拆成一个可点进去的
/// 设置项，包含两部分）：
/// 1. 横屏布局：关 / 自动（按屏幕宽高比阈值判定）/ 开（全局应用，即原行为）
/// 2. 屏幕旋转：允许旋转（跟随传感器）/ 锁定竖屏
///
/// 与旧的单一开关 `horizontalScreen` 的关系：未写入新的模式值时，由旧值
/// 推导（true → 开，false → 关），见 Pref.horizontalLayoutMode。
class HorizontalLayoutSettingPage extends StatefulWidget {
  const HorizontalLayoutSettingPage({super.key});

  @override
  State<HorizontalLayoutSettingPage> createState() =>
      _HorizontalLayoutSettingPageState();
}

class _HorizontalLayoutSettingPageState
    extends State<HorizontalLayoutSettingPage> {
  late int _mode = Pref.horizontalLayoutMode;
  late double _ratio = Pref.horizontalLayoutRatio;
  late bool _rotation = Pref.allowScreenRotation;

  /// 当前设备宽高比（最长边/最短边），用于提示阈值是否命中
  double get _deviceRatio {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return 0;
    final dpr = views.first.devicePixelRatio;
    if (dpr <= 0) return 0;
    final Size size = views.first.physicalSize / dpr;
    final shortest = size.shortestSide;
    if (shortest <= 0) return 0;
    return size.longestSide / shortest;
  }

  void _onModeChanged(int mode) {
    _mode = mode;
    Pref.setHorizontalLayoutMode(mode);
    setState(() {});
  }

  void _onRatioChanged(double ratio) {
    _ratio = ratio;
    Pref.setHorizontalLayoutRatio(ratio);
    setState(() {});
  }

  void _onRotationChanged(bool value) {
    _rotation = value;
    Pref.setAllowScreenRotation(value);
    // 立即生效：允许旋转 → 跟随传感器；不允许 → 锁定竖屏
    if (PlatformUtils.isMobile) {
      if (value) {
        fullMode();
      } else {
        portraitUpMode();
      }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deviceRatio = _deviceRatio;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: const Text('横屏适配')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _header(theme, '横屏布局'),
          RadioGroup<int>(
            groupValue: _mode,
            onChanged: (v) => _onModeChanged(v ?? 0),
            child: Column(
              children: [
                const RadioListTile<int>(
                  value: 0,
                  title: Text('关'),
                  subtitle: Text('始终使用竖屏布局'),
                ),
                RadioListTile<int>(
                  value: 1,
                  title: const Text('自动'),
                  subtitle: Text(
                    '屏幕宽高比 ≥ ${_ratio.toStringAsFixed(2)} 时使用横屏布局'
                    '${deviceRatio > 0 ? '（当前 ${deviceRatio.toStringAsFixed(2)}）' : ''}',
                  ),
                ),
                const RadioListTile<int>(
                  value: 2,
                  title: Text('开'),
                  subtitle: Text('始终按横屏布局渲染（原「横屏适配」行为）'),
                ),
              ],
            ),
          ),
          if (_mode == 1) _ratioSlider(theme, deviceRatio),
          const Divider(height: 24),
          _header(theme, '屏幕旋转'),
          SwitchListTile(
            value: _rotation,
            onChanged: _onRotationChanged,
            title: const Text('允许屏幕旋转'),
            subtitle: const Text('关闭后应用锁定竖屏（视频全屏等仍可临时旋转）'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Text(
              '说明：横屏布局决定界面按横屏排版（侧边栏/双栏等），屏幕旋转决定'
              '应用是否跟随设备方向；两者相互独立，可自由组合。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _ratioSlider(ThemeData theme, double deviceRatio) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('宽高比阈值', style: theme.textTheme.bodyMedium),
              const Spacer(),
              Text(
                _ratio.toStringAsFixed(2),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          Slider(
            value: _ratio.clamp(1.05, 2.0),
            min: 1.05,
            max: 2.0,
            divisions: 19,
            label: _ratio.toStringAsFixed(2),
            onChanged: _onRatioChanged,
          ),
          Text(
            '数值越小越容易判定为横屏（正方形屏为 1.00，普通手机竖屏约 '
            '2.0 以上）；当前设备宽高比 ${deviceRatio > 0 ? deviceRatio.toStringAsFixed(2) : '未知'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
