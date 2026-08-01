import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// 根路由（主页）返回手势消费器。
///
/// 问题背景：Flutter 引擎的预测性返回手势进度只转发给「可 pop 的 route」，
/// 主页是根路由（`popGestureEnabled` 为 false），引擎不消费返回手势，
/// 于是 ColorOS 等系统不会播放「返回桌面」的预测性跟手动画（窗口缩小 + 露出桌面），
/// 松手后只会直接退出。
///
/// 处理方式：在根路由时主动消费手势（handleStartBackGesture 返回 true），
/// 让系统进入预测性返回流程（显示窗口缩小动画）；
/// 手势提交（handleCommitBackGesture）时调 SystemNavigator.pop() 退出 app，
/// 手势取消（handleCancelBackGesture）时什么都不做（app 保持前台）。
///
/// 注意：WidgetsBinding 的预测性返回流程中，谁消费了 start 手势，
/// 后续的 update/cancel/commit 就只回调谁，所以三个回调都要实现。
class RootBackGestureObserver with WidgetsBindingObserver {
  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    // 硬件返回键事件不是手势，不消费（返回键本来就没有跟手动画）
    if (backEvent.isButtonEvent) return false;
    final navigator = Get.key.currentState;
    final bool canPop = navigator?.canPop() ?? true;
    // 调试：确认根路由手势是否到达 Dart（release 用 print 输出到 logcat）
    print('[RootBackGestureObserver] start gesture: canPop=$canPop');
    // 只有根路由（没有任何可 pop 的 route）才消费；
    // 二级页面交给 Navigator/route 的 PredictiveBack 处理。
    if (navigator != null && !canPop) {
      return true;
    }
    return false;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    // 根路由没有 route 动画可驱动，进度无需处理
  }

  @override
  void handleCancelBackGesture() {
    print('[RootBackGestureObserver] gesture canceled');
  }

  @override
  void handleCommitBackGesture() {
    print('[RootBackGestureObserver] gesture committed, exiting');
    // 手势提交（松手确认返回桌面）：退出 app，系统播放返回桌面动画
    SystemNavigator.pop();
  }
}
