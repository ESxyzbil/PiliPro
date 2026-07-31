import 'dart:io';
import 'dart:ui' as ui;

import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// 背景层全局刷新通知。
/// 滑块拖动时只通知背景层重建，避免整棵 app 树重建。
abstract final class BgNotifier {
  static final RxInt revision = 0.obs;

  static void notify() => revision.value++;
}

/// 全局背景层随路由的透明度状态：
/// 0 = 主 tab 页（有自己的背景层覆盖），1 = 二级页面（透出全局背景）。
abstract final class BgRouteState {
  static final ValueNotifier<double> target = ValueNotifier(0.0);
}

/// 监听路由 push/pop，同步全局背景层透明度，
/// 让「tab 页背景 → 全局背景」的切换跟随页面过渡动画平滑渐变。
class BgRouteObserver extends NavigatorObserver {
  static bool isMainTab(Route<dynamic>? route) =>
      route?.settings.name == '/';

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    BgRouteState.target.value = isMainTab(route) ? 0.0 : 1.0;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    BgRouteState.target.value = isMainTab(previousRoute) ? 0.0 : 1.0;
  }
}

/// 通用背景填充层：
/// - [path] 为空时回退到全局背景，再没有则铺主题背景色（保证不透明）
/// - [opacity] 图片透明度 0~1
/// - [blur] 高斯模糊强度（像素）
class AppBackgroundLayer extends StatelessWidget {
  const AppBackgroundLayer({
    super.key,
    this.path = '',
    this.opacity = 1.0,
    this.blur = 0.0,
  });

  final String path;
  final double opacity;
  final double blur;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // 订阅背景刷新（revision 变化时重建）
      BgNotifier.revision.value;
      final theme = Theme.of(context);
      final bgPath = path.isNotEmpty ? path : Pref.globalBg;
      final hasImage = bgPath.isNotEmpty && File(bgPath).existsSync();
      if (!hasImage) {
        // 无背景图时铺主题表面色，保证页面不透底
        return ColoredBox(
          color: theme.colorScheme.surface,
        );
      }
      final isDark = theme.brightness == Brightness.dark;
      final useOpacity = opacity.clamp(0.0, 1.0);
      final useBlur = blur.clamp(0.0, 40.0);
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final width = MediaQuery.sizeOf(context).width;
      Widget img = Image.file(
        File(bgPath),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        cacheWidth: (width * dpr).round(),
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          // 背景图加载完成后透明度渐入，避免首次出现生硬
          if (wasSynchronouslyLoaded) return child;
          return AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOut,
            child: child,
          );
        },
        errorBuilder: (_, __, ___) => ColoredBox(
          color: theme.scaffoldBackgroundColor,
        ),
      );
      if (useBlur > 0.5) {
        img = ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: useBlur,
            sigmaY: useBlur,
          ),
          child: img,
        );
      }
      if (useOpacity < 1.0) {
        img = Opacity(opacity: useOpacity, child: img);
      }
      // 背景图路径切换时交叉淡入淡出：key 用路径，
      // 无论图片是否已缓存，每次切换背景都有过渡
      final bg = AnimatedSwitcher(
        duration: const Duration(milliseconds: 450),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        layoutBuilder: (currentChild, previousChildren) => Stack(
          fit: StackFit.expand,
          children: [...previousChildren, if (currentChild != null) currentChild],
        ),
        child: KeyedSubtree(
          key: ValueKey(bgPath),
          child: img,
        ),
      );
      return Stack(
        fit: StackFit.expand,
        children: [
          // 基础底色：透明度为 0 / 图片加载中时保证不露黑
          ColoredBox(color: theme.colorScheme.surface),
          bg,
          // 可读性遮罩：深色模式更暗
          ColoredBox(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.18),
          ),
        ],
      );
    });
  }
}
