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

/// 全局背景层状态：所有背景统一由 main.dart 的全局层渲染，
/// 根据「是否在主 tab 页 + 当前 tab」解析背景图，切换时 AnimatedSwitcher 平滑过渡。
abstract final class GlobalBgState {
  /// 是否在主 tab 页（MainApp）。二级页面 push 时 false，pop 回时 true。
  static final RxBool inMainTab = true.obs;

  /// 当前主 tab 索引（0=首页, 1=动态, 2=我的）。
  static final RxInt tabIndex = 0.obs;

  /// 解析当前应显示的背景 (path, opacity, blur)。
  static (String, double, double) resolve() {
    if (inMainTab.value) {
      switch (tabIndex.value) {
        case 0:
          return (
            Pref.homeBg.isNotEmpty ? Pref.homeBg : Pref.globalBg,
            Pref.homeBgOpacity,
            Pref.homeBgBlur,
          );
        case 1:
          return (
            Pref.dynamicsBg.isNotEmpty ? Pref.dynamicsBg : Pref.globalBg,
            Pref.dynamicsBgOpacity,
            Pref.dynamicsBgBlur,
          );
        case 2:
          return (
            Pref.mineBg.isNotEmpty ? Pref.mineBg : Pref.globalBg,
            Pref.mineBgOpacity,
            Pref.mineBgBlur,
          );
      }
    }
    return (Pref.globalBg, Pref.globalBgOpacity, Pref.globalBgBlur);
  }
}

/// 统一的全局背景层：挂在 main.dart 的 Navigator 之下。
/// tab 页时显示 tab 背景，二级页面显示全局背景，切换走 AnimatedSwitcher 交叉过渡。
class GlobalBackgroundLayer extends StatelessWidget {
  const GlobalBackgroundLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // 订阅背景刷新：设置页调节透明度/模糊/换图时实时重建
      BgNotifier.revision.value;
      GlobalBgState.inMainTab.value;
      GlobalBgState.tabIndex.value;
      final (path, opacity, blur) = GlobalBgState.resolve();
      return AppBackgroundLayer(path: path, opacity: opacity, blur: blur);
    });
  }
}

/// 监听路由 push/pop，同步全局背景层状态：
/// 顶层是主 tab 页（栈底 first route）时显示 tab 背景，二级页面显示全局背景。
/// 用 isFirst + name 双保险判断，不依赖 push 计数。
class BgRouteObserver extends NavigatorObserver {
  static bool _isMainTab(Route<dynamic>? route) {
    if (route is! PageRoute) return false;
    return route.isFirst ||
        route.settings.name == '/' ||
        route.settings.name == '/main';
  }

  void _sync(Route<dynamic>? top) {
    if (top is! PageRoute) return;
    GlobalBgState.inMainTab.value = _isMainTab(top);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _sync(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _sync(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _sync(newRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _sync(previousRoute);
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
