import 'dart:async';
import 'dart:ui' as ui;

import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart';

/// 全局「毛玻璃模糊渐显」状态（返回动效结束后遮罩渐隐）：
/// - glassRevealActive = true：渐显进行中，所有 GlassContainer 读
///   glassRevealProgress（0=纯色遮罩盖住，1=完全显示）
/// - 由 predictive_back 的 _PopFadeWriter 驱动：pop reverse 时置 active+0，
///   dismissed 后 0→1（250ms），完成后 active=false。
/// 用「遮罩渐隐」而非动态 sigma：Impeller 的 BackdropFilter 动态改 sigma
/// 会崩溃（117 已验证），遮罩方案毛玻璃始终满模糊、不崩溃，视觉上
/// 毛玻璃区域从纯色平滑浮现出模糊内容 = 模糊渐显。
final ValueNotifier<bool> glassRevealActive = ValueNotifier<bool>(false);
final ValueNotifier<double> glassRevealProgress = ValueNotifier<double>(1.0);

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
/// [reveal]（0-1）：毛玻璃模糊渐显进度。null 时读全局
/// [glassRevealActive]/[glassRevealProgress]（返回动效结束后遮罩渐隐）。
/// 实现：毛玻璃始终满模糊，上面盖同色遮罩（opacity = 1-reveal）渐隐，
/// 视觉上毛玻璃区域从纯色平滑浮现出模糊内容 = 模糊渐显。
class GlassContainer extends StatefulWidget {
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
    this.reveal,
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
  final double? reveal;

  @override
  State<GlassContainer> createState() => _GlassContainerState();
}

class _GlassContainerState extends State<GlassContainer>
    with SingleTickerProviderStateMixin {
  static DateTime? _maskLog;
  AnimationController? _localCtrl;

  @override
  void initState() {
    super.initState();
    // 信息卡片（设置项等）：挂载时本地渐显一次——push 进入页面时卡片
    // 从纯色浮现出模糊内容。不依赖全局 Timer / observer 时序，确定性
    // 100%（08-02 重构：全局 didPush 方案被过渡动画掩盖 + Timer 竞争，
    // 换成页面级本地动画，每次进入页面必然可见）。
    if (widget.kind == GlassKind.infoCard) {
      _localCtrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 450),
      )..forward();
    }
  }

  @override
  void dispose() {
    _localCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final on = widget.enabled ?? Glass.enabled(widget.kind);
    final useOpacity =
        (widget.opacity ?? Glass.opacity(widget.kind)).clamp(0.0, 1.0);
    final useBlur = (widget.blur ?? Glass.blur(widget.kind)).clamp(0.0, 20.0);
    final baseColor = widget.color ?? Glass.color(colorScheme, widget.kind);
    final bg = on
        ? baseColor.withValues(alpha: useOpacity)
        : (widget.fallbackColor ?? colorScheme.surface);

    final Widget body = widget.padding != null
        ? Padding(padding: widget.padding!, child: widget.child)
        : widget.child;

    // 毛玻璃关闭：不透明色垫 + 内容，无渐显（没有模糊可渐显）。
    if (!on || useBlur <= 0.5) {
      Widget result = ColoredBox(color: bg, child: body);
      if (widget.borderRadius != null) {
        result = ClipRRect(borderRadius: widget.borderRadius!, child: result);
      }
      return result;
    }

    // 毛玻璃开启：内容【始终正常显示】+ 只有【模糊层】渐显。
    // 08-02 重构（用户反馈"返回后页面从全透明渐变出现，不对"）：
    // 之前整卡 opacity 渐显让内容（文字）也从透明渐变；现在模糊层
    // （背景模糊 + 半透明底色）opacity = r 渐显，内容始终清晰——
    // 视觉 = 背景从清晰渐变为毛玻璃 = 真正的"模糊渐显"。
    final Widget glassLayer = ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: useBlur,
          sigmaY: useBlur,
        ),
        child: ColoredBox(color: bg),
      ),
    );

    Widget buildWithReveal(double r) {
      return Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: Opacity(
              opacity: r.clamp(0.0, 1.0),
              child: glassLayer,
            ),
          ),
          body,
        ],
      );
    }

    final double fixedReveal = widget.reveal ?? -1.0;
    final bool useGlobal = widget.reveal == null;
    Widget result;
    if (useGlobal) {
      result = AnimatedBuilder(
        animation: Listenable.merge([
          if (_localCtrl != null) _localCtrl!,
          glassRevealActive,
          glassRevealProgress,
        ]),
        builder: (context, _) {
          final double rLocal = _localCtrl?.value ?? 1.0;
          final double rGlobal =
              glassRevealActive.value ? glassRevealProgress.value : 1.0;
          final double r = rLocal < rGlobal ? rLocal : rGlobal;
          if (r < 1.0) {
            final now = DateTime.now();
            if (_maskLog == null ||
                now.difference(_maskLog!) >
                    const Duration(milliseconds: 60)) {
              _maskLog = now;
              print('[GlassPush] mask r=${r.toStringAsFixed(2)}');
            }
          }
          return buildWithReveal(r);
        },
      );
    } else if (fixedReveal < 1.0) {
      result = buildWithReveal(fixedReveal.clamp(0.0, 1.0));
    } else {
      result = buildWithReveal(1.0);
    }

    if (widget.borderRadius != null) {
      result = ClipRRect(borderRadius: widget.borderRadius!, child: result);
    }
    return result;
  }
}
