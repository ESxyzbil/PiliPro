import 'package:PiliPlus/pages/tabhost/tab_controller.dart';
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
  }

  @override
  void handleCommitBackGesture() {
    // 锁定手势最后进度：TabTransition 从手势位置续播退出动画
    // （progress 复位前取值，随后复位让 TabTransition 退出跟手模式）
    gTabBackCommitProgress = tabBackGestureProgress.value;
    tabBackGestureProgress.value = 0.0;
    // 清空触摸事件（commit 续播只需要锁定的 progress，不再需要触摸点）
    gTabBackStartEvent = null;
    gTabBackCurrentEvent = null;
    // 标签模式有标签：先关标签/恢复来源，不退出（界面保持前台）
    if (TabHostController.handleBack()) {
      return;
    }
    // 无标签（主内容页）：退出 app，系统播放返回桌面动画
    SystemNavigator.pop();
  }
}
