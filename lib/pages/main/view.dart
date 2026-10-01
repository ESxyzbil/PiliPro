import 'dart:io';

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/app_background.dart';
import 'package:PiliPlus/common/widgets/floating_navigation_bar.dart';
import 'package:PiliPlus/common/widgets/flutter/pop_scope.dart';
import 'package:PiliPlus/common/widgets/flutter/root_back_gesture_observer.dart'
    show tabBackGestureProgress;
import 'package:PiliPlus/common/widgets/flutter/tabs.dart';
import 'package:PiliPlus/common/widgets/glass.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/route_aware_mixin.dart';
import 'package:PiliPlus/models/common/nav_bar_config.dart';
import 'package:PiliPlus/pages/home/view.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/pages/tabhost/tab_controller.dart';
import 'package:PiliPlus/pages/tabhost/tab_strip.dart';
import 'package:PiliPlus/pages/tabhost/tab_transition.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/extension/context_ext.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/mobile_observer.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:win32/win32.dart' as kernel32;
import 'package:window_manager/window_manager.dart';

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends PopScopeState<MainApp>
    with
        RouteAware,
        RouteAwareMixin,
        WidgetsBindingObserver,
        WindowListener,
        TrayListener {
  final _mainController = Get.put(MainController());
  late final _setting = GStorage.setting;
  late EdgeInsets _padding;
  late ThemeData theme;

  @override
  bool get initCanPop => false;

  @override
  void initState() {
    super.initState();
    addObserverMobile(this);
    if (PlatformUtils.isDesktop || PlatformUtils.isMobile) {
      // 多页面标签页（方案 C：侧边标签栏）——桌面端始终；手机端横屏时启用
      Get.put(TabHostController(), permanent: true);
    }
    if (PlatformUtils.isDesktop) {
      windowManager
        ..addListener(this)
        ..setPreventClose(true);
      if (_mainController.showTrayIcon) {
        trayManager.addListener(this);
        _handleTray();
      }
    } else {
      // FlutterSmartDialog throws
      PiliScheme.init();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _padding = MediaQuery.viewPaddingOf(context);
    theme = Theme.of(context);
    // 手机端标签栏显隐（多页面标签功能）
    if (PlatformUtils.isMobile) {
      // 手机端始终走标签（竖屏标签栏隐藏、标签内容全屏），横竖屏切换
      // 只是标签栏显隐，页面/播放状态不销毁重建（零重载）——不再需要
      // 竖屏↔横屏的路由/标签互转（那会销毁重建导致重载）。
      // ⚠️ 显隐只跟**设备方向**走，**不再绑定「横屏适配」设置**（用户实测：
      // 手表横屏不显示标签栏，根因是该手表「横屏适配」为关，而旧写法
      // `Pref.useHorizontalLayout && …` 使整条条件为假）。标签页功能本身
      // 已由「多页面标签」开关控制，两者应当解耦：横屏适配只管视频页
      // 布局，标签栏只管方向。
      // ⚠️ 不能用 Size.isPortrait：正方形屏（480x480 手表等）宽==高时
      // isPortrait 为 true，会把横屏设备判成竖屏 → 标签栏永不显示，
      // 所以这里用 width >= height（正方形视为横向）。
      final size = MediaQuery.sizeOf(context);
      TabHostController.landscapeMode = size.width >= size.height;
    }
    final brightness = theme.brightness;
    NetworkImgLayer.reduce =
        NetworkImgLayer.reduceLuxColor != null && brightness.isDark;
    if (PlatformUtils.isDesktop) {
      windowManager.setBrightness(brightness);
    }
    if (!_mainController.useSideBar) {
      _mainController.useBottomNav = MediaQuery.sizeOf(context).isPortrait;
    }
  }

  @override
  void didPopNext() {
    addObserverMobile(this);
    // 回到主 tab 页：全局背景层切回 tab 背景（帧后安全更新）
    GlobalBgState.setInMainTab(true);
    _mainController
      ..checkUnreadDynamic()
      ..checkDefaultSearch(true)
      ..checkUnread(_mainController.useBottomNav);
    super.didPopNext();
  }

  @override
  void didPushNext() {
    removeObserverMobile(this);
    // 被二级页面覆盖：全局背景层切到全局背景（帧后安全更新）
    GlobalBgState.setInMainTab(false);
    super.didPushNext();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _mainController
        ..checkUnreadDynamic()
        ..checkDefaultSearch(true)
        ..checkUnread(_mainController.useBottomNav);
    }
  }

  @override
  void dispose() {
    if (PlatformUtils.isDesktop) {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
    }
    removeObserverMobile(this);
    PiliScheme.listener?.cancel();
    GStorage.close();
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    _setting.put(SettingBoxKey.isWindowMaximized, true);
  }

  @override
  void onWindowUnmaximize() {
    _setting.put(SettingBoxKey.isWindowMaximized, false);
  }

  @override
  Future<void> onWindowMoved() async {
    if (PlPlayerController.instance?.isDesktopPip ?? false) {
      return;
    }
    final Offset offset = await windowManager.getPosition();
    _setting.put(SettingBoxKey.windowPosition, [offset.dx, offset.dy]);
  }

  @override
  Future<void> onWindowResized() async {
    if (PlPlayerController.instance?.isDesktopPip ?? false) {
      return;
    }
    final Rect bounds = await windowManager.getBounds();
    _setting.putAll({
      SettingBoxKey.windowSize: [bounds.width, bounds.height],
      SettingBoxKey.windowPosition: [bounds.left, bounds.top],
    });
  }

  @override
  void onWindowClose() {
    if (_mainController.showTrayIcon && _mainController.minimizeOnExit) {
      windowManager.hide();
      _onHideWindow();
    } else {
      _onClose();
    }
  }

  Future<void> _onClose() async {
    await GStorage.compact();
    await GStorage.close();
    await trayManager.destroy();
    if (Platform.isWindows) {
      // flutter_inappwebview
      // 6.2.0-beta.2+ https://github.com/pichillilorenzo/flutter_inappwebview/issues/2482
      // 6.1.5 https://github.com/pichillilorenzo/flutter_inappwebview/issues/2512#issuecomment-3031039587
      final hProcess = kernel32.GetCurrentProcess();
      kernel32.TerminateProcess(hProcess, 0);
    } else {
      exit(0);
    }
  }

  @override
  void onWindowMinimize() {
    _onHideWindow();
  }

  @override
  void onWindowRestore() {
    _onShowWindow();
  }

  void _onHideWindow() {
    if (_mainController.pauseOnMinimize) {
      if (PlPlayerController.instance case final player?) {
        if (_mainController.isPlaying = player.playerStatus.isPlaying) {
          player.pause();
        }
      } else {
        _mainController.isPlaying = false;
      }
    }
  }

  void _onShowWindow() {
    if (_mainController.pauseOnMinimize && _mainController.isPlaying) {
      PlPlayerController.instance?.play();
    }
  }

  @override
  Future<void> onTrayIconMouseDown() async {
    if (await windowManager.isVisible()) {
      _onHideWindow();
      windowManager.hide();
    } else {
      _onShowWindow();
      windowManager.show();
    }
  }

  @override
  Future<void> onTrayIconRightMouseDown() async {
    // ignore: deprecated_member_use
    trayManager.popUpContextMenu(bringAppToFront: true);
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        windowManager.show();
      case 'exit':
        _onClose();
    }
  }

  Future<void> _handleTray() async {
    if (Platform.isWindows) {
      await trayManager.setIcon(Assets.logoIco);
    } else {
      await trayManager.setIcon(Assets.logoLarge);
    }
    if (!Platform.isLinux) {
      await trayManager.setToolTip(Constants.appName);
    }

    Menu trayMenu = Menu(
      items: [
        MenuItem(key: 'show', label: '显示窗口'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: '退出 ${Constants.appName}'),
      ],
    );
    await trayManager.setContextMenu(trayMenu);
  }

  @pragma('vm:prefer-inline')
  static void _onBack() {
    if (Platform.isAndroid) {
      PiliAndroidHelper.back();
    }
  }

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    // 标签页模式：系统返回先关闭当前标签/恢复来源，不回桌面不退出
    if (TabHostController.handleBack()) {
      return;
    }
    if (_mainController.directExitOnBack) {
      _onBack();
    } else {
      if (_mainController.selectedIndex.value != 0) {
        _mainController
          ..setIndex(0)
          ..barOffset?.value = 0.0
          ..showBottomBar?.value = true
          ..setSearchBar();
      } else {
        _onBack();
      }
    }
  }

  @override
  // ignore: deprecated_member_use
  Future<bool> didPopRoute() async {
    // GetX nav2 的 popRoute 不检查 PopScope：根路由 pop 失败会返回 false
    // 直接退出应用。必须在此（WidgetsBinding observer 层）先拦截——
    // 标签模式返回先关标签/恢复来源，返回 true 阻断 GetX 的退出路径。
    if (TabHostController.handleBack()) {
      return true;
    }
    return false;
  }

  /// 底栏毛玻璃包装：开启时给底栏加模糊+半透明背景
  Widget _wrapBottomBarGlass(Widget bar, bool glassOn) {
    if (!glassOn) return bar;
    return GlassContainer(
      kind: GlassKind.bottomBar,
      borderRadius: BorderRadius.circular(24),
      child: bar,
    );
  }

  Widget? get _bottomNav {
    Widget? bottomNav;
    if (_mainController.navigationBars.length > 1) {
      if (_mainController.floatingNavBar) {
        bottomNav = Obx(
          () => FloatingNavigationBar(
            onDestinationSelected: _mainController.setIndex,
            selectedIndex: _mainController.selectedIndex.value,
            destinations: _mainController.navigationBars
                .map(
                  (e) => FloatingNavigationDestination(
                    label: e.label,
                    icon: _buildIcon(type: e),
                    selectedIcon: _buildIcon(type: e, selected: true),
                  ),
                )
                .toList(),
          ),
        );
      } else if (_mainController.enableMYBar) {
        bottomNav = Obx(
          () {
            final glassOn = Glass.enabled(GlassKind.bottomBar);
            final bar = NavigationBar(
              maintainBottomViewPadding: true,
              backgroundColor: glassOn ? Colors.transparent : null,
              onDestinationSelected: _mainController.setIndex,
              selectedIndex: _mainController.selectedIndex.value,
              destinations: _mainController.navigationBars
                  .map(
                    (e) => NavigationDestination(
                      label: e.label,
                      icon: _buildIcon(type: e),
                      selectedIcon: _buildIcon(type: e, selected: true),
                    ),
                  )
                  .toList(),
            );
            return _wrapBottomBarGlass(bar, glassOn);
          },
        );
      } else {
        bottomNav = Obx(
          () {
            final glassOn = Glass.enabled(GlassKind.bottomBar);
            final bar = BottomNavigationBar(
              currentIndex: _mainController.selectedIndex.value,
              onTap: _mainController.setIndex,
              iconSize: 16,
              selectedFontSize: 12,
              unselectedFontSize: 12,
              type: .fixed,
              backgroundColor: glassOn ? Colors.transparent : null,
              items: _mainController.navigationBars
                  .map(
                    (e) => BottomNavigationBarItem(
                      label: e.label,
                      icon: _buildIcon(type: e),
                      activeIcon: _buildIcon(type: e, selected: true),
                    ),
                  )
                  .toList(),
            );
            return _wrapBottomBarGlass(bar, glassOn);
          },
        );
      }

      if (_mainController.hideBottomBar) {
        if (_mainController.barOffset case final barOffset?) {
          return Obx(
            () => FractionalTranslation(
              translation: Offset(
                0.0,
                barOffset.value / Style.topBarHeight,
              ),
              child: bottomNav,
            ),
          );
        }
        if (_mainController.showBottomBar case final showBottomBar?) {
          return Obx(
            () => AnimatedSlide(
              curve: Curves.easeInOutCubicEmphasized,
              duration: const Duration(milliseconds: 500),
              offset: Offset(0, showBottomBar.value ? 0 : 1),
              child: bottomNav,
            ),
          );
        }
      }
    }

    return bottomNav;
  }

  Widget _sideBar(ThemeData theme) {
    return _mainController.navigationBars.length > 1
        ? context.isTablet && _mainController.optTabletNav
              ? Column(
                  children: [
                    const SizedBox(height: 25),
                    userAndSearchVertical(theme),
                    const Spacer(flex: 2),
                    Expanded(
                      flex: 5,
                      child: SizedBox(
                        width: 130,
                        child: Obx(
                          () => NavigationDrawer(
                            backgroundColor: Colors.transparent,
                            tilePadding: const .symmetric(
                              vertical: 5,
                              horizontal: 12,
                            ),
                            indicatorShape: const RoundedRectangleBorder(
                              borderRadius: .all(.circular(16)),
                            ),
                            onDestinationSelected: _mainController.setIndex,
                            selectedIndex: _mainController.selectedIndex.value,
                            children: _mainController.navigationBars
                                .map(
                                  (e) => NavigationDrawerDestination(
                                    label: Text(e.label),
                                    icon: _buildIcon(type: e),
                                    selectedIcon: _buildIcon(
                                      type: e,
                                      selected: true,
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : Obx(
                  () => NavigationRail(
                    groupAlignment: 0.5,
                    selectedIndex: _mainController.selectedIndex.value,
                    onDestinationSelected: _mainController.setIndex,
                    labelType: .selected,
                    leading: userAndSearchVertical(theme),
                    destinations: _mainController.navigationBars
                        .map(
                          (e) => NavigationRailDestination(
                            label: Text(e.label),
                            icon: _buildIcon(type: e),
                            selectedIcon: _buildIcon(type: e, selected: true),
                          ),
                        )
                        .toList(),
                  ),
                )
        : Container(
            width: 80,
            padding: const .only(top: 10),
            child: userAndSearchVertical(theme),
          );
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (_mainController.mainTabBarView) {
      child = CustomTabBarView(
        scrollDirection: _mainController.useBottomNav ? .horizontal : .vertical,
        physics: const NeverScrollableScrollPhysics(),
        controller: _mainController.controller,
        children: _mainController.navigationBars.map((i) => i.page).toList(),
      );
    } else {
      child = PageView(
        physics: const NeverScrollableScrollPhysics(),
        controller: _mainController.controller,
        children: _mainController.navigationBars.map((i) => i.page).toList(),
      );
    }

    // 多页面标签页（方案 C）：主内容之上叠加侧边标签栏（桌面端/手机横屏）
    // 多页面标签页（方案 C）：标签内容始终保活（手机竖屏只隐藏标签栏，
    // 横竖屏切换不重建标签页、状态不丢）
    if (PlatformUtils.isDesktop || PlatformUtils.isMobile) {
      final tabController = TabHostController.instance;
      if (tabController != null) {
        final mainContent = child;
        child = Obx(() {
          final tabs = tabController.tabs;
          final rawCurrent = tabController.currentIndex.value;
          // 兜底：currentIndex 异常（越界 / 指向 hidden 保活层）时按主内容
          // 显示（-1）。hidden 层按 covered 渲染（opacity 0 + Offstage）、
          // 越界则 Stack 无可见层——两者都表现为「整个页面空白」（用户实测：
          // 关闭某个页面后不进入任何标签页、整页空白）。
          // controller.ensureValidCurrent 已在源头修正，这里是渲染层保险。
          final current =
              rawCurrent >= 0 &&
                  rawCurrent < tabs.length &&
                  !tabs[rawCurrent].hidden
              ? rawCurrent
              : -1;
          if (kDebugMode) {
            debugPrint('TAB_OBX rebuild tabs=${tabs.length} cur=$current');
          }
          // 视频全屏时隐藏标签栏，避免挤压视频
          final isFullScreen =
              PlPlayerController.instance?.isFullScreen.value ?? false;
          final isExpanded = tabController.expanded.value;
          // 手机竖屏不显示标签栏（横屏/桌面才显示）
          final showStrip =
              (PlatformUtils.isDesktop || TabHostController.landscapeMode) &&
              !isFullScreen &&
              tabs.isNotEmpty;
          // 预测性返回手势进度：手势中目标页（关闭当前标签后露出的页面）
          // 随手势渐显，与路由 predictiveBackProgress 语义一致。
          // ⚠️ 必须用 ValueListenableBuilder 监听 tabBackGestureProgress
          //（ValueNotifier）——Obx 只监听 Rx（tabs/currentIndex），手势进度
          // 变化不会触发 Obx 重建，目标页渐显会只在松手后（currentIndex
          // 变化）才发生，而非跟手阶段（用户实测反馈）。
          return ValueListenableBuilder<double>(
            valueListenable: tabBackGestureProgress,
            builder: (context, gestureP, _) {
              // 目标页 Stack 坐标（0=主内容，i>=1=标签）：关闭当前标签后显示谁
              // 与 TabHostController.close() 的目标一致：
              // - source 恢复（replaceCurrent 保活下层 A）：目标是 A 的来源层
              //   （A 保活在 tabs 中、位于当前标签之前），手势跟手时 A 作为
              //   下层随手势渐显（与主页渐显同机制，A 一直保活无需重建）。
              // - 普通关闭：唯一标签 → 主内容(0)；否则关当前标签后显示
              //   index>0 ? index-1 : 1（标签索引），Stack 坐标 = index+1。
              final int? srcIdx = (gestureP > 0.001 && current >= 0)
                  ? _sourceLowerIndex(tabs, current)
                  : null;
              final int targetStackIndex = (gestureP > 0.001 && current >= 0)
                  ? (srcIdx != null
                        ? srcIdx + 1
                        : (tabs.length <= 1 ? 0 : (current > 0 ? current : 2)))
                  : -1;
              return _buildTabHostStack(
                context,
                tabController: tabController,
                mainContent: mainContent,
                tabs: tabs,
                current: current,
                gestureP: gestureP,
                targetStackIndex: targetStackIndex,
                showStrip: showStrip,
                isExpanded: isExpanded,
              );
            },
          );
        });
      }
    }

    Widget? bottomNav;
    if (_mainController.useBottomNav) {
      bottomNav = Obx(() {
        // 稳定 Rx 依赖：启动时可能无播放器实例，isFullScreen 的 ?. 会短路
        // 不建立依赖（GetX improper use 警告），用 currentIndex 兜底
        final tabController = TabHostController.instance;
        tabController?.currentIndex.value;
        // 底部 Tab 栏只属于主内容页：
        // ① 标签页显示时（currentIndex >= 0）不显示——无论横竖屏，
        //    否则转竖屏后底栏会叠在标签内容（音频页等）上；
        // ② 视频全屏时不显示（竖屏视频全屏会把设备转成竖屏，
        //    useBottomNav 变 true，底部栏会叠在视频上方）。
        final current = tabController?.currentIndex.value ?? -1;
        final isFullScreen =
            PlPlayerController.instance?.isFullScreen.value ?? false;
        if (current >= 0 || isFullScreen) {
          return const SizedBox.shrink();
        }
        return _bottomNav ?? const SizedBox.shrink();
      });
      if (Pref.circularScreen) {
        // 圆形屏幕：限制宽度 + 保持在底部，避免内容在有效显示区域外
        bottomNav = Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: 360,
            child: bottomNav,
          ),
        );
      }
      child = Row(children: [Expanded(child: child)]);
    } else {
      // 桌面横窗：侧栏 + 内容区；视频全屏时隐藏侧栏（标签栏已在上面隐藏）
      final tabController = TabHostController.instance;
      if (tabController != null) {
        final content = child;
        child = Obx(() {
          // 稳定 Rx 依赖：启动时可能无播放器实例，isFullScreen 的 ?. 会短路
          // 不建立依赖（GetX improper use 警告），用 currentIndex 兜底
          tabController.currentIndex.value;
          final isFullScreen =
              PlPlayerController.instance?.isFullScreen.value ?? false;
          return Row(
            children: [
              if (!isFullScreen) _sideBar(theme),
              if (!isFullScreen)
                VerticalDivider(
                  width: 1,
                  endIndent: _padding.bottom,
                  color: theme.colorScheme.outline.withValues(alpha: 0.06),
                ),
              Expanded(child: content),
            ],
          );
        });
      } else {
        child = Row(
          children: [
            _sideBar(theme),
            VerticalDivider(
              width: 1,
              endIndent: _padding.bottom,
              color: theme.colorScheme.outline.withValues(alpha: 0.06),
            ),
            Expanded(child: child),
          ],
        );
      }
    }

    child = Scaffold(
      extendBody: true,
      resizeToAvoidBottomInset: false,
      appBar: AppBar(toolbarHeight: 0),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 背景已统一由 main.dart 的 GlobalBackgroundLayer 渲染
          const SizedBox.shrink(),
          Padding(
            padding: EdgeInsets.only(
              left: _mainController.useBottomNav ? _padding.left : 0.0,
              right: _padding.right,
            ),
            child: child,
          ),
        ],
      ),
      bottomNavigationBar: bottomNav,
    );

    if (PlatformUtils.isMobile) {
      child = AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: theme.brightness.reverse,
        ),
        child: child,
      );
    }

    return child;
  }

  /// 当前标签的保活来源层 index（replaceCurrent 前进时旧标签 A 保活为
  /// hidden 下层、位于 B 之前）：返回 A 在 tabs 中的 index，供手势跟手时
  /// 将 A 作为目标层渐显。无来源层返回 null（普通关闭/无来源）。
  int? _sourceLowerIndex(List<TabItem> tabs, int current) {
    if (current < 0 || current >= tabs.length) return null;
    final tab = tabs[current];
    final source = tab.source;
    if (source == null) return null;
    final idx = tabs.indexOf(source);
    return idx >= 0 ? idx : null;
  }

  /// 标签宿主布局：标签栏 + 内容区（Stack 保活 + 切换动画）。
  /// 抽成方法供 Obx+ValueListenableBuilder 复用（手势进度变化时
  /// 只重建本方法，不重建整个 Obx）。
  static String? _lastTabHostLog;

  /// 标签栏的 GlobalKey：横竖屏切换会改变 useBottomNav 分支、祖先结构变化，
  /// 用 GlobalKey 让 TabStrip 元素被搬移而非重建，从而保住其显隐宽度动画
  /// 的动画状态（ValueKey 保不住 → 旋转时硬切，2026-09-24 实测）。
  final GlobalKey _tabStripKey = GlobalKey();

  Widget _buildTabHostStack(
    BuildContext context, {
    required TabHostController tabController,
    required Widget mainContent,
    required List<TabItem> tabs,
    required int current,
    required double gestureP,
    required int targetStackIndex,
    required bool showStrip,
    required bool isExpanded,
  }) {
    if (kDebugMode) {
      debugPrint(
        'TAB_STACK build tabs=${tabs.length} ids=${tabs.map((t) => t.id).join(",")} cur=$current '
        'mainTarget=${current == -1 ? 1.0 : (targetStackIndex == 0 ? gestureP : 0.0)} '
        'tgt=$targetStackIndex p=$gestureP',
      );
    }
    // 标签栏动画目标宽度：隐藏 0 / 收起 52 / 展开 200
    final double stripTargetWidth = showStrip
        ? (isExpanded ? TabStrip.expandedWidth : TabStrip.collapsedWidth)
        : 0.0;
    // ⚠️ 布局改造要点（用户需求：展开/收起动画不要再实时挤压内容，否则卡顿）：
    // ① 内容区**一次性**按「动画终态」定尺寸（winW - 目标栏宽），动画期间
    //    尺寸不变 → 视频页等重内容不再逐帧重排（卡顿根因）；
    // ② 标签栏宽度动画 + 内容区位移都在此层完成：宽度由 TweenAnimationBuilder
    //    逐帧给出，内容区用 Transform.translate 被"推动/拉回"（Transform 只
    //    影响绘制与命中测试，不触发子树重排）；
    // ③ 重内容以 child 传入 TweenAnimationBuilder，每帧只重建位移与标签栏，
    //    不重建页面本身。
    return LayoutBuilder(
      builder: (context, outerC) {
        final double winW = outerC.maxWidth;
        final double winH = outerC.maxHeight;
        final double contentW = (winW - stripTargetWidth).clamp(0.0, winW);
        // 标签内页面（视频页等）感知实际可用宽度：标签栏/侧栏占用后实际宽度
        // ≠ MediaQuery.size（窗口宽度），视频页横向分栏按窗口宽度布局时右侧
        //（相关视频/评论）会被挤出屏外。
        // 注意：主内容（mainContent）保持窗口尺寸（原有布局行为），否则主
        // 界面布局会受影响（曾导致"什么都没有了"）。
        final Widget tabContent = Listener(
          // 手机端：触控标签栏以外的区域自动折叠标签栏
          onPointerDown: PlatformUtils.isMobile
              ? (_) => tabController.setExpanded(false)
              : null,
          child: _buildTabHostContent(
            context,
            mainContent: mainContent,
            tabs: tabs,
            current: current,
            gestureP: gestureP,
            targetStackIndex: targetStackIndex,
            contentWidth: contentW,
            contentHeight: winH,
            showStrip: showStrip,
          ),
        );
        return ClipRect(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: stripTargetWidth),
            duration: TabStrip.animDuration,
            curve: Curves.easeOutCubic,
            child: tabContent,
            builder: (context, stripW, child) => Stack(
              fit: StackFit.expand,
              children: [
                // 内容区：尺寸固定为动画终态，整体按标签栏当前宽度平移
                //（被标签栏推动/拉回——只重绘，不重排）
                Positioned(
                  left: 0,
                  top: 0,
                  width: contentW,
                  height: winH,
                  child: Transform.translate(
                    offset: Offset(stripW, 0),
                    child: child,
                  ),
                ),
                // 标签栏浮于上层（宽度由动画值驱动；GlobalKey 保证横竖屏切换
                // 改变 useBottomNav 分支时元素被搬移而非重建，动画不中断）
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: TabStrip(
                    key: _tabStripKey,
                    controller: tabController,
                    isExpanded: isExpanded,
                    width: stripW,
                    onExpandedChanged: tabController.setExpanded,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 标签内容区（MediaQuery 覆盖 + 各标签层 Stack）。
  /// [contentWidth]/[contentHeight] 为**动画终态**尺寸：刻意在动画开始时就
  /// 按终态定尺寸并保持不变，动画期间仅由外层 Transform 平移，从而避免
  /// 逐帧重排视频页等重内容（用户实测"展开/收起比较卡顿"即源于此）。
  Widget _buildTabHostContent(
    BuildContext context, {
    required Widget mainContent,
    required List<TabItem> tabs,
    required int current,
    required double gestureP,
    required int targetStackIndex,
    required double contentWidth,
    required double contentHeight,
    required bool showStrip,
  }) {
    final originalMq = MediaQuery.of(context);
    // 覆盖 size（标签内容实际可用宽高）的同时，清掉左右安全区：
    // 标签栏/侧栏已占左侧，内容区不再有系统刘海/圆角安全区。
    // 只改 size 不改 viewPadding 时，横屏左侧刘海安全区仍残留，
    // 音频页等叠加 padding 后会整体右偏。
    final mq = originalMq.copyWith(
      size: Size(
        contentWidth,
        contentHeight,
      ),
      viewPadding: originalMq.viewPadding.copyWith(
        left: 0,
        right: 0,
      ),
      padding: originalMq.padding.copyWith(
        left: 0,
        right: 0,
      ),
    );
    // 临时布局诊断日志（release 同样输出到 logcat，tag=flutter）：
    // 标签内容区的实际尺寸 —— 排查"标签页里播放器占满屏幕"时
    // 需要知道标签页拿到的 MediaQuery 尺寸。排查结束可删除。
    final logMsg =
        'strip=$showStrip win=${originalMq.size.width.toStringAsFixed(1)}'
        'x${originalMq.size.height.toStringAsFixed(1)} '
        'content=${contentWidth.toStringAsFixed(1)}'
        'x${contentHeight.toStringAsFixed(1)} '
        'tabs=${tabs.length} cur=$current '
        'landscapeMode=${TabHostController.landscapeMode}';
    if (logMsg != _lastTabHostLog) {
      _lastTabHostLog = logMsg;
      // ignore: avoid_print
      print('[PL_TABHOST] $logMsg');
    }
    return MediaQuery(
      data: mq,
      // Stack 保活 + 标签切换过渡动画：
      // 主内容（i==0）淡入淡出；标签页（i>=1）应用设置的
      // 页面过渡动画（Pref.pageTransition）——新标签进入动画、
      // 旧标签退出动画，所有页面实例保活不销毁。
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (var i = 0; i <= tabs.length; i++)
            IgnorePointer(
              ignoring: i != current + 1,
              child: i == 0
                  ? AnimatedOpacity(
                      opacity: i == current + 1
                          ? 1
                          : (targetStackIndex == 0 ? gestureP : 0),
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      child: KeyedSubtree(
                        key: const ValueKey('main-content'),
                        child: MediaQuery(
                          data: originalMq,
                          child: mainContent,
                        ),
                      ),
                    )
                  : TabTransition(
                      key: ValueKey('tab-anim-${tabs[i - 1].id}'),
                      active: i == current + 1,
                      // replaceCurrent 保活下层（hidden）：
                      // 被覆盖 → 纯透明度快速淡出到 0（无位移
                      // 退出动画）；返回手势 gestureReveal 渐显
                      covered: tabs[i - 1].hidden,
                      // 普通 add 覆盖（viaAdd，如收藏夹文件夹
                      // →视频）被顶掉的下层：同样纯透明度淡出
                      // 到 0，不走 buildPiliPageTransition 位移
                      // 退场（与 covered 一致）
                      fadeExit: tabs[i - 1].fadeExit,
                      // 替换类返回（source 恢复）时：
                      // active 仍 true 但 closing=true，
                      // 强制播退出动画再替换
                      closing: tabs[i - 1].closing,
                      // 手势目标页渐显：本标签是目标页时
                      // 随手势进度渐显（否则 0）
                      gestureReveal: targetStackIndex == i ? gestureP : 0,
                      child: KeyedSubtree(
                        key: ValueKey(tabs[i - 1].id),
                        child: tabs[i - 1].child,
                      ),
                    ),
            ),
        ],
      ),
    );
  }

  /// 根据当前 tab 渲染背景图（单页背景优先，未设置则用全局背景）。
  /// 单层 Obx：同时订阅 tab 切换(selectedIndex) 与 背景刷新(revision)。
  Widget _buildIcon({required NavigationBarType type, bool selected = false}) {
    final icon = selected ? type.selectIcon : type.icon;
    return type == .dynamics
        ? Obx(
            () {
              final dynCount = _mainController.dynCount.value;
              return Badge(
                isLabelVisible: dynCount > 0,
                label: _mainController.dynamicBadgeMode == .number
                    ? Text(dynCount.toString())
                    : null,
                padding: const .symmetric(horizontal: 6),
                child: icon,
              );
            },
          )
        : icon;
  }

  Widget userAndSearchVertical(ThemeData theme) {
    return Column(
      children: [
        userAvatar(theme: theme, mainController: _mainController),
        const SizedBox(height: 8),
        msgBadge(_mainController),
        IconButton(
          tooltip: '搜索',
          icon: const Icon(
            Icons.search_outlined,
            semanticLabel: '搜索',
          ),
          onPressed: () => PageUtils.toSearchPage(),
        ),
      ],
    );
  }
}
