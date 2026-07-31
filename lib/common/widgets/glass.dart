import 'dart:ui' as ui;

import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart';

/// 毛玻璃类别：顶栏 / 视频卡片 / 信息卡片 / 底栏 / 回复弹层
enum GlassKind { topBar, card, infoCard, bottomBar, replyPanel }

/// 毛玻璃效果统一入口：按类别读取独立配置。
abstract final class Glass {
  static bool enabled(GlassKind k) => switch (k) {
    GlassKind.topBar => Pref.glassTopBar,
    GlassKind.card => Pref.glassCard,
    GlassKind.infoCard => Pref.glassInfoCard,
    GlassKind.bottomBar => Pref.glassBottomBar,
    GlassKind.replyPanel => Pref.glassReplyPanel,
  };

  static double blur(GlassKind k) => switch (k) {
    GlassKind.topBar => Pref.glassTopBarBlur,
    GlassKind.card => Pref.glassCardBlur,
    GlassKind.infoCard => Pref.glassInfoCardBlur,
    GlassKind.bottomBar => Pref.glassBottomBarBlur,
    GlassKind.replyPanel => Pref.glassReplyPanelBlur,
  }
      .clamp(0.0, 20.0);

  static double opacity(GlassKind k) => switch (k) {
    GlassKind.topBar => Pref.glassTopBarOpacity,
    GlassKind.card => Pref.glassCardOpacity,
    GlassKind.infoCard => Pref.glassInfoCardOpacity,
    GlassKind.bottomBar => Pref.glassBottomBarOpacity,
    GlassKind.replyPanel => Pref.glassReplyPanelOpacity,
  }
      .clamp(0.0, 1.0);

  static String colorStr(GlassKind k) => switch (k) {
    GlassKind.topBar => Pref.glassTopBarColor,
    GlassKind.card => Pref.glassCardColor,
    GlassKind.infoCard => Pref.glassInfoCardColor,
    GlassKind.bottomBar => Pref.glassBottomBarColor,
    GlassKind.replyPanel => Pref.glassReplyPanelColor,
  };

  /// 毛玻璃颜色：未设置时跟随主题表面色
  static Color color(ColorScheme colorScheme, GlassKind k) {
    final hex = colorStr(k);
    if (hex.isNotEmpty) {
      final parsed = _parseHex(hex);
      if (parsed != null) return parsed;
    }
    return colorScheme.surface;
  }

  /// 毛玻璃背景色（含透明度）
  static Color bgColor(ColorScheme colorScheme, GlassKind k) =>
      color(colorScheme, k).withValues(alpha: opacity(k));

  static Color? _parseHex(String hex) {
    var h = hex.trim().replaceFirst('#', '');
    if (h.length == 6) h = 'FF$h';
    if (h.length != 8) return null;
    final value = int.tryParse(h, radix: 16);
    if (value == null) return null;
    return Color(value);
  }
}

/// 毛玻璃容器：BackdropFilter 模糊 + 半透明色。
/// 按 [kind] 读取对应类别的开关/模糊/透明度/颜色；
/// 毛玻璃关闭时铺 [fallbackColor]（默认主题表面色，保证不透明可读）。
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.kind = GlassKind.topBar,
    this.borderRadius,
    this.color,
    this.opacity,
    this.blur,
    this.enabled,
    this.fallbackColor,
    this.padding,
  });

  final Widget child;
  final GlassKind kind;
  final BorderRadius? borderRadius;
  final Color? color;
  final double? opacity;
  final double? blur;
  final bool? enabled;
  final Color? fallbackColor;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final on = enabled ?? Glass.enabled(kind);
    final useOpacity = (opacity ?? Glass.opacity(kind)).clamp(0.0, 1.0);
    final useBlur = (blur ?? Glass.blur(kind)).clamp(0.0, 20.0);
    final bg = on
        ? (color ?? Glass.color(colorScheme, kind)).withValues(alpha: useOpacity)
        : (fallbackColor ?? colorScheme.surface);

    Widget content = ColoredBox(
      color: bg,
      child: padding != null
          ? Padding(padding: padding!, child: child)
          : child,
    );
    if (on && useBlur > 0.5) {
      content = ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
            sigmaX: useBlur,
            sigmaY: useBlur,
          ),
          child: content,
        ),
      );
    }
    if (borderRadius != null) {
      content = ClipRRect(borderRadius: borderRadius!, child: content);
    }
    return content;
  }
}
