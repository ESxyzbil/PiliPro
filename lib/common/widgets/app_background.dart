import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:PiliPlus/common/widgets/glass.dart'
    show glassRevealActive, glassRevealProgress, startGlassRevealPush;
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:material_ui/material_ui.dart';
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

  /// 安全更新 inMainTab：路由 observer 回调可能发生在 Navigator
  /// build/commit 期间，直接改 Rx 会让依赖它的 Obx（GlobalBackgroundLayer）
  /// 在 build 中被标记（"setState during build"），并连锁触发框架
  /// GlobalKey retake 断言（_elements.contains）。延迟到帧后更新。
  static void setInMainTab(bool v) {
    if (inMainTab.value == v) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (inMainTab.value != v) {
        inMainTab.value = v;
      }
    });
  }

  /// 安全更新 tabIndex（原因同上：MainController.onInit 在首帧 build 期间
  /// 触发，直接赋值会让背景层 Obx 在 build 中被标记）。
  static void setTabIndex(int v) {
    if (tabIndex.value == v) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (tabIndex.value != v) {
        tabIndex.value = v;
      }
    });
  }

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
    // 二级页面：优先全局背景；没有则回退当前 tab 的背景，
    // 避免 push 页面时背景瞬间变白（globalBg 未设置时 AppBackgroundLayer 铺白色）。
    if (Pref.globalBg.isNotEmpty) {
      return (Pref.globalBg, Pref.globalBgOpacity, Pref.globalBgBlur);
    }
    switch (tabIndex.value) {
      case 1:
        return (
          Pref.dynamicsBg,
          Pref.dynamicsBgOpacity,
          Pref.dynamicsBgBlur,
        );
      case 2:
        return (
          Pref.mineBg,
          Pref.mineBgOpacity,
          Pref.mineBgBlur,
        );
    }
    return (
      Pref.homeBg,
      Pref.homeBgOpacity,
      Pref.homeBgBlur,
    );
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
    GlobalBgState.setInMainTab(_isMainTab(top));
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _sync(route);
    // push 进入的毛玻璃遮罩渐显（伪模糊强度 0→设置值）：
    // 卡片毛玻璃从纯色平滑浮现出模糊内容。用 didPush 触发，
    // 不依赖页面动画 status 时序（实测 status 监听会错过 forward）。
    // push 渐显由 GlassContainer 本地动画（infoCard 挂载时）驱动，
    // 不再用全局 Timer（08-02 重构）。
    // 旧页淡出：只有 push 不透明页面（PageRoute）时才驱动，
    // 弹窗（PopupRoute 如回复框）覆盖时旧页保持显示，不淡出。
    if (route is PageRoute && previousRoute is GetPageRoute) {
      previousRoute.fadeOutOldPage();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _sync(previousRoute);
    // 只有 pop 的是不透明页面（PageRoute）时才恢复旧页淡入；
    // pop 弹窗时旧页没淡出过，不触发。
    if (route is PageRoute && previousRoute is GetPageRoute) {
      previousRoute.fadeInOldPage();
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _sync(newRoute);
    if (oldRoute is GetPageRoute && oldRoute != newRoute) {
      oldRoute.fadeInOldPage();
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _sync(previousRoute);
    if (previousRoute is GetPageRoute) {
      previousRoute.fadeInOldPage();
    }
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
      // 指定背景（tab/全局）文件无效时回退全局背景，避免 pop 回主页
      // 瞬间露 surface 背板色（"全局背景先消失"的闪，08-02 用户反馈）。
      // 全局背景也无效才铺主题表面色。
      var bgPath = path.isNotEmpty ? path : Pref.globalBg;
      if (bgPath.isNotEmpty &&
          !File(bgPath).existsSync() &&
          bgPath != Pref.globalBg) {
        bgPath = Pref.globalBg;
      }
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
          // 加载中保持透明（由 _BgSwitcher 垫底旧图兜底），加载完成直接
          // 显示；淡入交给 _BgSwitcher 的 TweenAnimationBuilder 统一做，
          // 避免双重渐显导致新图更晚才完全不透明（垫底撤走时露白）。
          if (wasSynchronouslyLoaded) return child;
          return frame == null ? const SizedBox.expand() : child;
        },
        errorBuilder: (_, __, ___) => ColoredBox(
          color: theme.scaffoldBackgroundColor,
        ),
      );
      if (useBlur > 0.5) {
        // 模糊层透明度渐显（用户方案）：先把后方内容模糊成模糊层
        // （ImageFiltered 静态 blur），再让该层的 opacity 0->1 渐显。
        // 单层、固定 sigma、不交叉淡入——避开 128/129 的 SIGSEGV。
        final Widget blurImg = ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: useBlur,
            sigmaY: useBlur,
          ),
          child: img,
        );
        img = AnimatedBuilder(
          animation: Listenable.merge([glassRevealActive, glassRevealProgress]),
          builder: (context, _) {
            // 只在返回主 tab 页时做模糊渐显（inMainTab=true）。
            // 返回二级页面时 inMainTab=false：背景保持不透明静态模糊，
            // 避免松手后背景透明闪烁（12:46 用户报告）。
            final double t =
                glassRevealActive.value && GlobalBgState.inMainTab.value
                ? glassRevealProgress.value
                : 1.0;
            if (t >= 1.0) return blurImg;
            return Opacity(opacity: t.clamp(0.0, 1.0), child: blurImg);
          },
        );
      }
      if (useOpacity < 1.0) {
        img = Opacity(opacity: useOpacity, child: img);
      }
      // 背景图路径切换时：旧图保持不透明垫底（缓存未命中时用旧图主色兜底），
      // 新图淡入覆盖。相比交叉淡入淡出，过渡中不会露出底色（避免发白）。
      final bg = _BgSwitcher(
        keyPath: bgPath,
        child: img,
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

/// 背景图切换器：旧图保持不透明垫底（缓存未命中重新解码期间，
/// 用旧图主色 ColoredBox 兜底，不露底层白色），新图淡入覆盖。
/// 相比 AnimatedSwitcher 的交叉淡入淡出，过渡全程不露底色（不会发白）。
/// 修复 08-02：旧 Image.file 重挂载时若图片缓存被视频页大量封面挤掉，
/// 会重新解码，frame==null 期间透明 → 露出白色 surface（"全局背景先消失"）。
/// 注意：不要用 RawImage/自行解码位图方案（142/143 在 Android 上 SIGSEGV 崩溃）。
class _BgSwitcher extends StatefulWidget {
  const _BgSwitcher({required this.keyPath, required this.child});

  /// 背景路径（变化时触发切换动画）
  final String keyPath;

  final Widget child;

  @override
  State<_BgSwitcher> createState() => _BgSwitcherState();
}

class _BgSwitcherState extends State<_BgSwitcher> {
  // 覆盖新图加载 + 淡入（700ms）的完整窗口，
  // 确保垫底旧图撤走时新图已经完全不透明（不会露白）。
  static const _duration = Duration(milliseconds: 1500);
  static const _fallbackColor = Color(0xFF17171A);

  Widget? _prevChild;
  bool _switching = false;
  Timer? _timer;
  Color _prevColor = _fallbackColor;
  int _colorGen = 0;

  @override
  void didUpdateWidget(_BgSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyPath != widget.keyPath) {
      // 旧背景保持不透明垫底，新背景淡入覆盖
      _prevChild = oldWidget.child;
      _switching = true;
      // 异步采样旧图主色：垫底图片缓存被挤掉重新解码（期间透明）时兜底
      _sampleColor(oldWidget.keyPath);
      _timer?.cancel();
      _timer = Timer(_duration, () {
        if (mounted) {
          setState(() {
            _prevChild = null;
            _switching = false;
          });
        }
      });
    }
  }

  /// 后台解码旧图并采样平均色，作为垫底兜底色（不管理 RawImage，只取颜色）。
  Future<void> _sampleColor(String path) async {
    final gen = ++_colorGen;
    try {
      final data = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(data);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final byteData = await img.toByteData();
      img.dispose();
      if (byteData == null || !mounted || gen != _colorGen) return;
      final buffer = byteData.buffer.asUint8List();
      final pixelCount = (buffer.length / 4).floor();
      if (pixelCount <= 0) return;
      // 均匀采样最多 256 个像素求平均色
      var r = 0, g = 0, b = 0, n = 0;
      final step = (pixelCount / 256).floor().clamp(1, pixelCount);
      for (var i = 0; i < pixelCount; i += step) {
        final o = i * 4;
        r += buffer[o];
        g += buffer[o + 1];
        b += buffer[o + 2];
        n++;
      }
      if (n == 0) return;
      setState(() {
        _prevColor = Color.fromARGB(
          255,
          (r / n).round(),
          (g / n).round(),
          (b / n).round(),
        );
      });
    } catch (_) {
      // 采样失败保留兜底色
    }
  }

  @override
  void dispose() {
    _colorGen++;
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_switching) ...[
          // 主色兜底（旧图下方）：旧图缓存被挤掉重新解码期间不露白
          ColoredBox(color: _prevColor),
          if (_prevChild != null) _prevChild!,
        ],
        // key 用路径：路径变化时重建，新图 0→1 淡入（700ms，页面切换
        // 背景过渡更明显）。图片加载完成直接显示（frameBuilder 不做
        // 二次渐显），整体淡入由这里统一驱动——垫底撤走时（1500ms）
        // 新图已完全不透明。
        TweenAnimationBuilder<double>(
          key: ValueKey(widget.keyPath),
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 700),
          curve: Curves.easeOut,
          builder: (context, opacity, child) =>
              Opacity(opacity: opacity, child: child),
          child: widget.child,
        ),
      ],
    );
  }
}
