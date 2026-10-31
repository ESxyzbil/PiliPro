import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:PiliPlus/common/widgets/glass.dart'
    show glassRevealActive, glassRevealProgress, startGlassRevealPush;
import 'package:PiliPlus/utils/storage_key.dart';
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

/// 背景槽位：一组「背景图 + 透明度 + 模糊」设置，键为
/// `<key>` / `<key>Opacity` / `<key>Blur`。
/// 页面识别一律用槽位，不再用 navbar 下标——用户删改或重排 Navbar 后，
/// 下标与页面不再对应（原实现按 tabIndex 0/1/2 硬编码首页/动态/我的）。
enum BgSlot {
  global(SettingBoxKey.globalBg, '全局背景'),
  home(SettingBoxKey.homeBg, '首页背景'),
  dynamics(SettingBoxKey.dynamicsBg, '动态背景'),
  mine(SettingBoxKey.mineBg, '我的背景'),
  video(SettingBoxKey.videoBg, '视频页背景'),
  audio(SettingBoxKey.audioBg, '音频页背景'),
  search(SettingBoxKey.searchBg, '搜索页背景'),
  member(SettingBoxKey.memberBg, '用户空间背景'),
  fav(SettingBoxKey.favBg, '收藏夹背景'),
  live(SettingBoxKey.liveBg, '直播间背景');

  const BgSlot(this.key, this.label);

  /// 设置键；透明度与模糊按 `<key>Opacity`、`<key>Blur` 派生。
  final String key;
  final String label;
}

/// 全局背景层状态：所有背景统一由 main.dart 的全局层渲染，
/// 根据「当前页面槽位」解析背景图，切换时 AnimatedSwitcher 平滑过渡。
abstract final class GlobalBgState {
  /// 是否在主 tab 页（MainApp）。二级页面 push 时 false，pop 回时 true。
  static final RxBool inMainTab = true.obs;

  /// 主内容当前页面对应的槽位（由 MainController 按 NavigationBarType 设置）。
  static final Rx<BgSlot> navSlot = BgSlot.home.obs;

  /// 当前标签页内容对应的槽位（标签页系统；普通页面标签为 null）。
  static final Rx<BgSlot?> tabSlot = Rx<BgSlot?>(null);

  /// 是否打开了标签页（用于区分「主内容」与「无专属背景的标签页」）。
  static final RxBool tabOpen = false.obs;

  /// 顶层二级路由名（非主 tab 页时用于判定页面类型）。
  static final RxString routeName = ''.obs;

  /// 安全赋值：路由 observer / 首帧 build 期间直接改 Rx 会让背景层 Obx
  /// 在 build 中被标记（"setState during build"）并连锁触发框架断言，
  /// 故统一延迟到帧后。
  static void _safeSet<T>(Rx<T> target, T value) {
    if (target.value == value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (target.value != value) target.value = value;
    });
  }

  static void setInMainTab(bool v) => _safeSet(inMainTab, v);

  static void setNavSlot(BgSlot slot) => _safeSet(navSlot, slot);

  static void setTabSlot(BgSlot? slot) {
    _safeSet(tabSlot, slot);
    _safeSet(tabOpen, true);
  }

  static void clearTab() {
    _safeSet(tabSlot, null);
    _safeSet(tabOpen, false);
  }

  static void setRouteName(String? name) => _safeSet(routeName, name ?? '');

  /// 二级路由名 → 槽位
  static BgSlot? slotForRoute(String? name) => switch (name) {
    '/videoV' => BgSlot.video,
    '/audio' => BgSlot.audio,
    '/search' || '/searchResult' => BgSlot.search,
    '/member' => BgSlot.member,
    '/fav' || '/favDetail' => BgSlot.fav,
    '/liveRoom' => BgSlot.live,
    _ => null,
  };

  /// 标签页 id → 槽位（id 规则见 PageUtils / TabHostController）
  static BgSlot? slotForTabId(String id) {
    if (id.startsWith('video_')) return BgSlot.video;
    if (id.startsWith('audio_')) return BgSlot.audio;
    if (id == 'page_search' || id.startsWith('search_result_')) {
      return BgSlot.search;
    }
    if (id.startsWith('member_')) return BgSlot.member;
    if (id.startsWith('fav_') || id.startsWith('fav_detail_'))
      return BgSlot.fav;
    return null;
  }

  static (String, double, double) _read(BgSlot slot) => (
    Pref.bgPath(slot.key),
    Pref.bgOpacity(slot.key),
    Pref.bgBlur(slot.key),
  );

  /// 解析当前应显示的背景 (path, opacity, blur)。
  /// 优先级：页面专属槽位 →（主内容时）主 tab 槽位 → 全局背景 → 兜底。
  static (String, double, double) resolve() {
    final BgSlot? pageSlot = inMainTab.value
        ? tabSlot.value
        : slotForRoute(routeName.value);

    // ① 页面专属背景（标签页内容 / 二级路由）
    if (pageSlot != null) {
      final r = _read(pageSlot);
      if (r.$1.isNotEmpty) return r;
    }
    // ② 主内容页（无标签页、无二级路由覆盖）：主 tab 的专属背景
    if (inMainTab.value && !tabOpen.value) {
      final r = _read(navSlot.value);
      if (r.$1.isNotEmpty) return r;
    }
    // ③ 全局背景
    final g = _read(BgSlot.global);
    if (g.$1.isNotEmpty) return g;
    // ④ 兜底：主 tab 背景 → 首页背景（避免 push 页面时瞬间露底）
    final n = _read(navSlot.value);
    if (n.$1.isNotEmpty) return n;
    return _read(BgSlot.home);
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
      GlobalBgState.navSlot.value;
      GlobalBgState.tabSlot.value;
      GlobalBgState.tabOpen.value;
      GlobalBgState.routeName.value;
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
    final isMain = _isMainTab(top);
    GlobalBgState.setInMainTab(isMain);
    // 二级路由页面按路由名映射背景槽位；回到主 tab 时清空
    GlobalBgState.setRouteName(isMain ? null : top.settings.name);
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
