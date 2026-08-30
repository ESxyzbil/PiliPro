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
    // 手机端横屏时启用标签页功能
    if (PlatformUtils.isMobile) {
      // 手机端始终走标签（竖屏标签栏隐藏、标签内容全屏），横竖屏切换
      // 只是标签栏显隐，页面/播放状态不销毁重建（零重载）——不再需要
      // 竖屏↔横屏的路由/标签互转（那会销毁重建导致重载）
      TabHostController.landscapeMode = !MediaQuery.sizeOf(context).isPortrait;
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
          final current = tabController.currentIndex.value;
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
              // 与 TabHostController.close() 的 next 逻辑一致：
              // 唯一标签 → 主内容(0)；否则 next = index>0 ? index-1 : 1（标签索引），
              // Stack 坐标 = next+1 = index>0 ? index : 2
              final int targetStackIndex = (gestureP > 0.001 && current >= 0)
                  ? (tabs.length <= 1
                        ? 0
                        : (current > 0 ? current : 2))
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

  /// 标签宿主布局：标签栏 + 内容区（Stack 保活 + 切换动画）。
  /// 抽成方法供 Obx+ValueListenableBuilder 复用（手势进度变化时
  /// 只重建本方法，不重建整个 Obx）。
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
    return Row(
      children: [
        if (showStrip)
          TabStrip(
            key: const ValueKey('tab-strip'),
            controller: tabController,
            isExpanded: isExpanded,
            onExpandedChanged: tabController.setExpanded,
          ),
        Expanded(
          key: const ValueKey('tab-host-content'),
          child: Listener(
            // 手机端：触控标签栏以外的区域自动折叠标签栏
            onPointerDown: PlatformUtils.isMobile
                ? (_) => tabController.setExpanded(false)
                : null,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 标签内页面（视频页等）感知实际可用宽度：标签栏/侧栏占用后
                // 实际宽度 ≠ MediaQuery.size（窗口宽度），视频页横向分栏按
                // 窗口宽度布局时右侧（相关视频/评论）会被挤出屏外。
                // 注意：主内容（mainContent）保持窗口尺寸（原有布局行为），
                // 否则主界面布局会受影响（曾导致"什么都没有了"）。
                final originalMq = MediaQuery.of(context);
                // 覆盖 size（标签内容实际可用宽高）的同时，清掉左右安全区：
                // 标签栏/侧栏已占左侧，内容区不再有系统刘海/圆角安全区。
                // 只改 size 不改 viewPadding 时，横屏左侧刘海安全区仍残留，
                // 音频页等叠加 padding 后会整体右偏。
                final mq = originalMq.copyWith(
                  size: Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
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
                                  // 替换类返回（source 恢复）时：
                                  // active 仍 true 但 closing=true，
                                  // 强制播退出动画再替换
                                  closing: tabs[i - 1].closing,
                                  // 手势目标页渐显：本标签是目标页时
                                  // 随手势进度渐显（否则 0）
                                  gestureReveal:
                                      targetStackIndex == i ? gestureP : 0,
                                  child: KeyedSubtree(
                                    key: ValueKey(tabs[i - 1].id),
                                    child: tabs[i - 1].child,
                                  ),
                                ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
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
