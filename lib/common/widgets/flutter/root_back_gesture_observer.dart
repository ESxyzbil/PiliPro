import 'dart:async';

import 'package:PiliPlus/pages/tabhost/tab_controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart' show PlPlayerController;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// 标签模式预测性返回手势进度（0 = 无手势，1 = 滑动到底）。
///
/// RootBackGestureObserver 在 handleUpdateBackGestureProgress 写入，
/// TabTransition 读取它驱动「当前标签随手势缩小+右移」的跟手动画
/// （与路由页面的预测性返回 SharedElement 效果一致）。
/// cancel 复位 0（TabTransition 回弹），commit 前锁定到
/// [gTabBackCommitProgress] 再复位。
final ValueNotifier<double> tabBackGestureProgress = ValueNotifier<double>(0.0);

/// 标签模式手势起点事件（触摸点纵坐标 startTouchY，跟手 Y 位移用）。
/// handleStartBackGesture 记录，cancel/commit 后清空。
PredictiveBackEvent? gTabBackStartEvent;

/// 标签模式手势最近一次事件（触摸点纵坐标 currentTouchY，跟手 Y 位移用）。
/// handleUpdateBackGestureProgress 持续更新，cancel/commit 后清空。
PredictiveBackEvent? gTabBackCurrentEvent;

/// 标签模式手势 commit 时锁定的最后进度（-1 = 无待继承）。
///
/// handleCommitBackGesture 同步瞬间锁定（此时 tabBackGestureProgress 还是
/// 手势进度），随后 progress 复位 0。TabTransition 的 didUpdateWidget
/// （active/closing 变化）读取它把 controller 起点设为 1-进度——退出动画
/// 从手势位置续播（而不是从完整状态重播），与路由 pop 的「松手续播」一致。
double gTabBackCommitProgress = -1.0;

/// 标签预测性返回「整窗卡片」动画进行中（含松手后的 commit / cancel 回弹）。
///
/// 状态栏那一段平时由 MainApp 的静态色带承托；手势期间静态色带必须让位，
/// 改由随手势缩放/裁圆的卡片自己绘制顶部色带——否则卡片缩小时，屏幕最
/// 上方会残留一条不跟着动的色带，上方的圆角就贴不住屏幕四角（用户反馈）。
/// 松手后的续播动画约 200ms，这里多留 120ms 再恢复静态色带，避免交接闪烁。
final ValueNotifier<bool> tabBackWindowAnimating = ValueNotifier<bool>(false);

/// 松手后的续播动画（commit/cancel）结束后恢复静态色带
Timer? _tabBackWindowSettleTimer;

/// 兜底：系统偶尔只发 start 就不再发 cancel/commit（ColorOS 等），
/// 若手势进度仍是 0，说明卡片没动过，直接恢复静态色带，避免状态栏
/// 一直露出背景图。
Timer? _tabBackWindowIdleTimer;

void _setTabBackWindowAnimating(bool active) {
  _tabBackWindowSettleTimer?.cancel();
  _tabBackWindowSettleTimer = null;
  _tabBackWindowIdleTimer?.cancel();
  _tabBackWindowIdleTimer = null;
  if (active) {
    tabBackWindowAnimating.value = true;
    _tabBackWindowIdleTimer = Timer(const Duration(seconds: 2), () {
      _tabBackWindowIdleTimer = null;
      // 进度仍为 0：没有任何跟手变形，静态色带和卡片色带外观一致，
      // 可以安全地切回去。
      if (tabBackGestureProgress.value <= 0.001 &&
          gTabBackCommitProgress < 0) {
        tabBackWindowAnimating.value = false;
      }
    });
    return;
  }
  if (!tabBackWindowAnimating.value) return;
  _tabBackWindowSettleTimer = Timer(const Duration(milliseconds: 320), () {
    _tabBackWindowSettleTimer = null;
    tabBackWindowAnimating.value = false;
  });
}

/// 本次返回手势是否在「视频全屏」状态下消费：true 时只消费手势
/// （避免系统直接播放返回桌面动画/退出），但**不驱动应用内跟手动画**
/// （不缩小当前标签页）——commit 时 TabHostController.handleBack 会先
/// 退出全屏（用户需求：全屏返回 = 取消全屏，而不是退出页面）。
bool gTabBackFullScreenGesture = false;

/// 根路由（主页）返回手势消费器。
///
/// 问题背景：Flutter 引擎的预测性返回手势进度只转发给「可 pop 的 route」，
/// 主页是根路由（`popGestureEnabled` 为 false），引擎不消费返回手势，
/// 于是 ColorOS 等系统不会播放「返回桌面」的预测性跟手动画（窗口缩小 + 露出桌面），
/// 松手后只会直接退出。
///
/// 处理方式：在根路由时主动消费手势（handleStartBackGesture 返回 true），
/// 让系统进入预测性返回流程（显示窗口缩小动画）；
/// 手势提交（handleCommitBackGesture）时：
///   - 标签模式有标签 → 先关标签/恢复来源（不退出，界面保持前台）
///   - 无标签 → 调 SystemNavigator.pop() 退出 app
/// 手势取消（handleCancelBackGesture）时什么都不做（app 保持前台）。
///
/// 标签模式下，update 阶段把手势进度写入 [tabBackGestureProgress]，
/// 供当前标签页（TabTransition）随手势缩小右移（应用内跟手动画）。
///
/// 注意：WidgetsBinding 的预测性返回流程中，谁消费了 start 手势，
/// 后续的 update/cancel/commit 就只回调谁，所以三个回调都要实现。
/// 也正因如此：手机全面屏/侧滑返回走的是本类（预测性返回），
/// 不走 GlobalBackInterceptor 的 didPopRoute——返回拦截必须在此接入。
class RootBackGestureObserver with WidgetsBindingObserver {
  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    // 硬件返回键事件不是手势，不消费（返回键本来就没有跟手动画，
    // 走 didPopRoute → GlobalBackInterceptor 拦截）
    if (backEvent.isButtonEvent) return false;
    // 视频全屏：消费手势（避免系统直接退桌面），但应用内不播跟手动画
    // —— 全屏返回语义 = 取消全屏（commit 时 handleBack 退出全屏）。
    final player = PlPlayerController.instance;
    if (player != null && player.isFullScreen.value) {
      gTabBackFullScreenGesture = true;
      tabBackGestureProgress.value = 0.0;
      gTabBackCommitProgress = -1.0;
      return true;
    }
    gTabBackFullScreenGesture = false;
    final navigator = Get.key.currentState;
    final bool canPop = navigator?.canPop() ?? true;
    // 标签模式启用且有标签：消费手势（显示跟手动画），commit 时关标签不退出。
    // ⚠️ 必须同时要求 !canPop（无二级路由）：若前台有全屏二级路由（通知页等，
    // 已 push 在栈顶），返回手势应交给该路由的预测性返回处理，不能在这里
    // 消费——否则 commit 时 handleBack 因 canPop=true 返回 false，会误走
    // SystemNavigator.pop() 退出应用，且通知页与标签页同时响应返回。
    if (!canPop &&
        TabHostController.tabsEnabled &&
        (TabHostController.instance?.hasTabs ?? false)) {
      tabBackGestureProgress.value = 0.0;
      gTabBackCommitProgress = -1.0;
      // 记录手势起点事件（跟手 Y 位移用 currentTouchY - startTouchY）
      gTabBackStartEvent = backEvent;
      gTabBackCurrentEvent = backEvent;
      // 整窗卡片动画开始：静态状态栏色带让位给卡片自绘色带
      _setTabBackWindowAnimating(true);
      return true;
    }
    // 只有根路由（没有任何可 pop 的 route）才消费；
    // 二级页面交给 Navigator/route 的 PredictiveBack 处理。
    if (navigator != null && !canPop) {
      return true;
    }
    return false;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    // 全屏返回手势：不驱动应用内跟手动画（页面不缩小），松手只退出全屏
    if (gTabBackFullScreenGesture) return;
    // 兜底：看门狗/系统漏事件导致整窗卡片状态被复位后，只要还有进度
    // 事件就重新进入卡片模式，否则跟手到一半静态色带会突然露出来。
    if (!tabBackWindowAnimating.value) {
      _setTabBackWindowAnimating(true);
    }
    // 标签模式：写入全局手势进度，当前标签页（TabTransition）读取它
    // 做应用内跟手动画（缩小+右移）；系统窗口动画由系统呈现。
    // 非标签模式（根路由返回桌面）：无需应用内驱动。
    tabBackGestureProgress.value = backEvent.progress;
    // 更新最近一次事件（跟手 Y 位移用）
    gTabBackCurrentEvent = backEvent;
  }

  @override
  void handleCancelBackGesture() {
    // 手势取消：进度复位 0，TabTransition 检测到后回弹到完整显示
    tabBackGestureProgress.value = 0.0;
    gTabBackCommitProgress = -1.0;
    gTabBackStartEvent = null;
    gTabBackCurrentEvent = null;
    gTabBackFullScreenGesture = false;
    // 回弹动画播完后恢复静态状态栏色带
    _setTabBackWindowAnimating(false);
  }

  @override
  void handleCommitBackGesture() {
    // 全屏返回：只需退出全屏（handleBack 内部处理优先级），不驱动
    // 标签退出动画/不关标签、也不退桌面
    if (gTabBackFullScreenGesture) {
      gTabBackFullScreenGesture = false;
      tabBackGestureProgress.value = 0.0;
      gTabBackCommitProgress = -1.0;
      gTabBackStartEvent = null;
      gTabBackCurrentEvent = null;
      _setTabBackWindowAnimating(false);
      if (TabHostController.handleBack()) {
        return;
      }
      SystemNavigator.pop();
      return;
    }
    // 锁定手势最后进度：TabTransition 从手势位置续播退出动画
    // （progress 复位前取值，随后复位让 TabTransition 退出跟手模式）
    gTabBackCommitProgress = tabBackGestureProgress.value;
    // ⚠️ 必须先触发 handleBack（置 closing → didUpdateWidget → _startCommit
    // 启动 commit 动画），再复位 progress：若先复位 progress，_onGestureProgress
    // 触发 rebuild 时 closing 还是 false → 当前标签走普通分支完整显示
    // → 闪回充满屏幕，然后 commit 动画才从错误状态启动（用户实测
    // "松手后页面直接跳回充满屏幕然后瞬间消失"）。
    final bool handled = TabHostController.handleBack();
    tabBackGestureProgress.value = 0.0;
    // 清空触摸事件（commit 续播只需要锁定的 progress，不再需要触摸点）
    gTabBackStartEvent = null;
    gTabBackCurrentEvent = null;
    // commit 滑出动画播完后恢复静态状态栏色带
    _setTabBackWindowAnimating(false);
    if (handled) {
      return;
    }
    // 无标签（主内容页）：退出 app，系统播放返回桌面动画
    SystemNavigator.pop();
  }
}
