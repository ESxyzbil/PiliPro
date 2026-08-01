// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// @docImport 'package:flutter/cupertino.dart';
///
/// @docImport 'page.dart';
library;

import 'dart:async';

import 'dart:ui' show clampDouble;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:PiliPlus/common/widgets/flutter/fade_previous_page_transitions_builder.dart';
import 'package:get/get.dart' show Get, Transition;
import 'package:get/get_navigation/src/extension_navigation.dart';
import 'package:get/get_navigation/src/routes/default_transitions.dart';
import 'package:get/get_navigation/src/routes/get_transition_mixin.dart'
    show GetPageRouteTransitionMixin;

import 'package:flutter/src/material/page_transitions_theme.dart';

/// 全局预测性返回手势进度（0 = 无手势/已取消，1 = 已提交）。
///
/// 由当前页的手势动画（[_PredictiveBackSharedElementPageTransition]）写入，
/// 下层目标页（被 pop 露出的上一页）的过渡读取，用于实现「目标页随手势渐显」。
final ValueNotifier<double> predictiveBackProgress = ValueNotifier<double>(0.0);

/// 预测性返回 commit 时的手势最后进度（-1 = 无待继承）。
///
/// didPopNext -> fadeInOldPage 是异步触发的，此时 predictiveBackProgress
/// 可能已被 commit 动画（_syncProgress）更新到接近 1，导致 fadeInOldPage
/// 读不到手势位置而从 0 重播透明度。因此在 PBDetector.handleCommitBackGesture
/// 的同步瞬间锁定手势进度，fadeInOldPage 一次性消费它来继承松手状态。
double gPredictiveBackCommitProgress = -1.0;

/// 取消手势时锁定的手势最后进度（-1 = 无待继承）。取消动画的 route.animation
/// 从 0 重播进入（controller 被复位），fallback 用 Tween(begin: 此值, end: 1.0)
/// 让页面从手势位置平滑恢复（而不是从透明重播进入动画）。
double gPredictiveBackCancelProgress = -1.0;

/// 全局预测返回手势状态（PBDetector 控制）：
/// start 消费时置 true，cancel/commit 时置 false。
/// 不能用 route.popGestureInProgress 判断：系统首帧 update(progress=0) 会让
/// route 内部 controller 瞬间 completed，userGestureInProgress 被 Flutter
/// 自动复位成 false，导致 mixin 走 else 分支（FadeTransition 反向 ->
/// 当前页透明）、SharedElement 挂成 idle（无跟手缩小位移）。
bool gPredictiveBackInProgress = false;

/// 当前手势的目标页（被 pop 露出的上一页）。手势中只有它随手势渐显，
/// 更下层页面保持隐藏（避免三级返回时一级页跟着一起渐显）。
/// handleStartBackGesture 从 gRouteBelow 查出手势 route 的下一层设置。
Route<dynamic>? gPredictiveBackTargetRoute;

/// route 层级映射：push nextRoute 时被覆盖的 route 记录
/// gRouteBelow[nextRoute] = this，供手势时找目标页。
final Map<Route<dynamic>?, Route<dynamic>?> gRouteBelow = {};


/// Used by [PageTransitionsTheme] to define a [MaterialPageRoute] page
/// transition animation that looks like the default page transition used on
/// Android U and above when using predictive back.
///
/// Predictive back is only supported on Android U and above, and if this
/// [PageTransitionsBuilder] is used by any other platform, it will fall back to
/// [FadeForwardsPageTransitionsBuilder].
///
/// When used on Android U and above, animates along with the back gesture to
/// reveal the destination route. Can be canceled by dragging back towards the
/// edge of the screen.
///
/// See also:
///
///  * [PredictiveBackFullscreenPageTransitionsBuilder], which is another
///    variant of Android's predictive back page transition.
///  * [FadeForwardsPageTransitionsBuilder], which defines the default page transition
///    that's similar to the one provided in Android 16.
///  * [ZoomPageTransitionsBuilder], which defines the default page transition
///    that's similar to the one provided in Android 10.
///  * [OpenUpwardsPageTransitionsBuilder], which defines a page transition
///    that's similar to the one provided by Android 9.
///  * [FadeUpwardsPageTransitionsBuilder], which defines a page transition
///    that's similar to the one provided by Android 8.
///  * [CupertinoPageTransitionsBuilder], which defines a horizontal page
///    transition that matches native iOS page transitions.
///  * https://developer.android.com/design/ui/mobile/guides/patterns/predictive-back#shared-element-transition,
///    which is the Android spec for this page transition, called the Shared
///    Element page transition.
class PiliPredictiveBackPageTransitionsBuilder extends PageTransitionsBuilder {
  /// Creates an instance of a [PageTransitionsBuilder] that matches Android U's
  /// predictive back transition.
  const PiliPredictiveBackPageTransitionsBuilder({
    this.fallbackColor,
    this.fallbackBuilder = const FadePreviousPageTransitionsBuilder(),
  });

  /// The color of the scrim (background) when the predictive back transition is
  /// not supported.
  ///
  /// If not provided, the background color of a default
  /// [FadeForwardsPageTransitionsBuilder] will be used.
  final Color? fallbackColor;

  /// 非手势返回（按钮返回/程序化 pop/低版本系统）时使用的过渡动画。
  /// 默认为项目自定义的淡入淡出（FadePreviousPageTransitionsBuilder）。
  final PageTransitionsBuilder fallbackBuilder;

  @override
  Duration get transitionDuration =>
      const Duration(milliseconds: 200);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 监听 predictiveBackProgress：pop 动画结束后的 delayed clear（progress -> 0）
    // 触发重建，重算挂载条件（gPredictiveBackInProgress 已清 -> fallback），
    // 卸载可能残留的 SharedElement（画面「缩小靠右」锁死）。
    return _PredictiveBackGestureDetector(
      route: route,
      builder:
          (
            BuildContext context,
            _PredictiveBackPhase phase,
            PredictiveBackEvent? startBackEvent,
            PredictiveBackEvent? currentBackEvent,
          ) {
            // Only do a predictive back transition when the user is performing a
            // pop gesture. Otherwise, for things like button presses or other
            // programmatic navigation, fall back to
            // FadeForwardsPageTransitionsBuilder.
            //
            // ⚠️ 必须限定 route.isCurrent（只对当前页挂 SharedElement）：
            // gPredictiveBackInProgress 是全局标志，手势中下层页（非 current）
            // 的 buildTransitions 也会走到这个分支 -> 下层页被 SharedElement
            // 包裹（scale 被压到 0.9）。手势结束后下层页 detector 的 _phase
            // 没变（idle）不会 rebuild，SharedElement 锁死在最后帧（scale 0.9
            // + 偏移），画面就「整个页面停在过渡动画最后帧的位置」。
            // 下层页永远走 fallback（完整显示，透明度由 mixin 的
            // predictiveBackProgress/oldFade 驱动）。
            // ?? phase==start 不挂 SharedElement：pop 后系统会给新 current 发
            // 「假 start」（无 update），若挂载会把页面 animation 拉到 0 ->
            // 缩小偏右锁死直到 watchdog cancel。真手势 start 后 1-2 帧必有
            // update（phase=update）才挂载，start 阶段 1-2 帧 fallback 无感。
            // ?? commit 阶段不要求 isCurrent：pop 动画开始后二级页 isCurrent
            // 立即变 false，若不挂 SharedElement 会回落 fallback -> commit
            // 动画从手势位置「复位重播」。commit 必须继续挂 SharedElement
            // 从 _lastBounceAnimationValue 续播缩小滑出。
            if (phase != _PredictiveBackPhase.cancel &&
                (route.isCurrent || phase == _PredictiveBackPhase.commit) &&
                phase != _PredictiveBackPhase.start &&
                (gPredictiveBackInProgress ||
                    route.popGestureInProgress ||
                    phase == _PredictiveBackPhase.commit)) {
              print('[PBTrans] mount: name=${route.settings.name} '
                  'isCurrent=${route.isCurrent} phase=$phase');
              return _PredictiveBackSharedElementPageTransition(
                isDelegatedTransition: true,
                animation: animation,
                phase: phase,
                secondaryAnimation: secondaryAnimation,
                startBackEvent: startBackEvent,
                currentBackEvent: currentBackEvent,
                child: child,
              );
            }

            // 用户设置的过渡类型（GetX 全局默认，完整映射所有 Transition）。
            Widget _buildFallback(
              BuildContext context,
              Animation<double> animation,
              Animation<double> secondaryAnimation,
              Widget child,
            ) {
              final Transition? t = Get.defaultTransition;
              switch (t) {
                case Transition.noTransition:
                  return NoTransition.buildTransitions(context, Curves.easeOut,
                      Alignment.center, animation, secondaryAnimation, child);
                case Transition.fade:
                case Transition.fadeIn:
                  return FadeInTransition.buildTransitions(
                      context, animation, secondaryAnimation, child);
                case Transition.cupertino:
                case Transition.cupertinoDialog:
                  return CupertinoPageTransitionsBuilder().buildTransitions(
                      route, context, animation, secondaryAnimation, child);
                case Transition.leftToRight:
                  return SlideRightTransition.buildTransitions(
                      context, animation, secondaryAnimation, child);
                case Transition.downToUp:
                  return SlideTopTransition.buildTransitions(
                      context, animation, secondaryAnimation, child);
                case Transition.upToDown:
                  return SlideDownTransition.buildTransitions(
                      context, animation, secondaryAnimation, child);
                case Transition.rightToLeft:
                  return SlideLeftTransition.buildTransitions(
                      context, animation, secondaryAnimation, child);
                case Transition.zoom:
                case Transition.topLevel:
                  // 自定义缩放（无 scrim，避免官方 ZoomPageTransitionsBuilder
                  // 的半透明白色遮罩层）。
                  return FadeTransition(
                    opacity: CurvedAnimation(
                        parent: animation, curve: Curves.easeInOut),
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                          CurvedAnimation(
                              parent: animation, curve: Curves.easeInOut)),
                      child: child,
                    ),
                  );
                case Transition.circularReveal:
                  return CircularRevealTransition.buildTransitions(
                      context, animation, secondaryAnimation, child);
                case Transition.rightToLeftWithFade:
                  return RightToLeftFadeTransition.buildTransitions(
                      context, animation, secondaryAnimation, child);
                case Transition.leftToRightWithFade:
                  return LeftToRightFadeTransition.buildTransitions(
                      context, animation, secondaryAnimation, child);
                case Transition.size:
                  return SizeTransitions.buildTransitions(
                      context, animation, secondaryAnimation, child);
                case Transition.native:
                  // 官方 PredictiveBackPageTransitionsBuilder 在 material src，
                  // 不引入避免耦合；native 回落为默认自定义淡入淡出。
                  return fallbackBuilder.buildTransitions(
                      route, context, animation, secondaryAnimation, child);
                default:
                  return fallbackBuilder.buildTransitions(
                    route, context, animation, secondaryAnimation, child,
                  );
              }
            }

            // 非手势（当前页之外的 route / pop 完成后）：
            // 旧页淡出由本 route 的 oldPageFade 驱动（GetPageRoute 的
            // secondaryAnimation 在 opaque=false 时不驱动）；目标页渐显由
            // 全局 predictiveBackProgress 驱动（手势中 0->1）。
            // opacity = max(p, oldFade)。监听 oldFade 变化（didChangeNext/
            // didPopNext 驱动 1->0 / 0->1 时持续 rebuild）。
            Animation<double>? oldFadeAnim;
            final dynamic mixinRoute = route;
            if (mixinRoute is GetPageRouteTransitionMixin) {
              oldFadeAnim = mixinRoute.oldPageFade;
            }
            final List<Listenable> listenables = [predictiveBackProgress];
            if (oldFadeAnim != null) listenables.add(oldFadeAnim);
            return AnimatedBuilder(
              animation: Listenable.merge(listenables),
              builder: (context, _) {
                final double p = predictiveBackProgress.value;
                double oldFade = 1.0;
                if (oldFadeAnim != null) oldFade = oldFadeAnim.value;
                // 手势中（全局 progress 活动）：目标页随手势渐显读 p。
                // 非手势（pop 动画）：只有 current（真正的目标页）读 p
                // （p 已被 didPopNext 清 0，实际走 oldFade 渐显）；
                // 下层页（非 current）只读 oldFade（被覆盖期间恒 0），
                // 避免三级返回时一级页跟着残留 progress 一起渐显。
                // ?? 只用 gPredictiveBackInProgress（commit 后已被 handleCommit
                // 清 false）：route.popGestureInProgress 在 pop 动画中会残留
                // true，导致下层页也误判为手势中 -> 读 p=1.0 完整显示，
                // pop 结束又变 0（「渐显后消失」）。
                // 手势中只让目标页（手势 route 的下一层）渐显：更下层页面
                // 若也读 p 会跟着一起渐显（三级返回时露两层）。
                final bool gestureActive = gPredictiveBackInProgress &&
                    identical(route, gPredictiveBackTargetRoute);
                final double opacity = (gestureActive || route.isCurrent)
                    ? (p > oldFade ? p : oldFade).clamp(0.0, 1.0)
                    : oldFade.clamp(0.0, 1.0);
                // ?? 取消手势动画：不播放任何动画，页面直接回到完整。
                // 之前试过 animation（0.797->1.0 淡入，像进入动画）、
                // Reverse（淡出缩小，像返回动画）都不对——取消时页面
                // 本就没变，播任何动画都显得多余。恒 1.0 立即恢复。
                final Animation<double> anim =
                    (phase == _PredictiveBackPhase.cancel)
                        ? AlwaysStoppedAnimation<double>(1.0)
                        : animation;
                return Opacity(
                  opacity: opacity,
                  child: _buildFallback(
                    context, anim, secondaryAnimation, child),
                );
              },
            );
          },
    );
  }
}

/// Used by [PageTransitionsTheme] to define a [MaterialPageRoute] page
/// transition animation that looks like Android's Full Screen page transition.
///
/// Predictive back is only supported on Android U and above, and if this
/// [PageTransitionsBuilder] is used by any other platform, it will fall back to
/// [ZoomPageTransitionsBuilder].
///
/// When used on Android U and above, animates along with the back gesture to
/// reveal the destination route. Can be canceled by dragging back towards the
/// edge of the screen.
///
/// See also:
///
///  * [PiliPredictiveBackPageTransitionsBuilder], which is the default Android
///    predictive back page transition.
///  * [FadeForwardsPageTransitionsBuilder], which defines the default page
///  transition that's similar to the one provided in Android 16.
///  * [ZoomPageTransitionsBuilder], which defines the default page transition
///    that's similar to the one provided in Android 10.
///  * [OpenUpwardsPageTransitionsBuilder], which defines a page transition
///    that's similar to the one provided by Android 9.
///  * [FadeUpwardsPageTransitionsBuilder], which defines a page transition
///    that's similar to the one provided by Android 8.
///  * [CupertinoPageTransitionsBuilder], which defines a horizontal page
///    transition that matches native iOS page transitions.
///  * https://developer.android.com/design/ui/mobile/guides/patterns/predictive-back#full-screen-surfaces,
///    which is the native Android docs for this page transition.
class PredictiveBackFullscreenPageTransitionsBuilder extends PageTransitionsBuilder {
  /// Creates an instance of a [PageTransitionsBuilder] that matches Android U's
  /// full screen predictive back transition.
  const PredictiveBackFullscreenPageTransitionsBuilder({this.fallbackColor});

  /// The color of the scrim (background) when the predictive back transition is
  /// not supported.
  ///
  /// If not provided, the background color of a default
  /// [ZoomPageTransitionsBuilder] will be used.
  final Color? fallbackColor;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _PredictiveBackGestureDetector(
      route: route,
      builder:
          (
            BuildContext context,
            _PredictiveBackPhase phase,
            PredictiveBackEvent? startBackEvent,
            PredictiveBackEvent? currentBackEvent,
          ) {
            // Only do a predictive back transition when the user is performing a
            // pop gesture. Otherwise, for things like button presses or other
            // programmatic navigation, fall back to ZoomPageTransitionsBuilder.
            if (route.popGestureInProgress) {
              return _PredictiveBackFullscreenPageTransition(
                animation: animation,
                secondaryAnimation: secondaryAnimation,
                getIsCurrent: () => route.isCurrent,
                phase: phase,
                child: child,
              );
            }

            return ZoomPageTransitionsBuilder(
              backgroundColor: fallbackColor,
            ).buildTransitions(route, context, animation, secondaryAnimation, child);
          },
    );
  }
}

typedef _PredictiveBackGestureDetectorWidgetBuilder =
    Widget Function(
      BuildContext context,
      _PredictiveBackPhase phase,
      PredictiveBackEvent? startBackEvent,
      PredictiveBackEvent? currentBackEvent,
    );

/// The phases of a predictive back gesture.
enum _PredictiveBackPhase {
  /// There is no active predictive back gesture in progress.
  idle,

  /// The user pointer has contacted the screen.
  start,

  /// The user pointer has moved.
  update,

  /// The user pointer has released in a position in which Android has
  /// determined that the back gesture is successful and the current route
  /// should be popped.
  commit,

  /// The user pointer has released in a position in which Android has
  /// determined that the back gesture should be canceled and the original route
  /// should be shown.
  cancel,
}

class _PredictiveBackGestureDetector extends StatefulWidget {
  const _PredictiveBackGestureDetector({required this.route, required this.builder});

  final _PredictiveBackGestureDetectorWidgetBuilder builder;
  final PageRoute<dynamic> route;

  @override
  State<_PredictiveBackGestureDetector> createState() => _PredictiveBackGestureDetectorState();
}

class _PredictiveBackGestureDetectorState extends State<_PredictiveBackGestureDetector>
    with WidgetsBindingObserver {
  /// 手势序号（诊断用）：每次 start 递增，跨实例累计。
  static int _gestureSeq = 0;

  /// True when the predictive back gesture is enabled.
  bool get _isEnabled {
    return widget.route.isCurrent && widget.route.popGestureEnabled;
  }

  _PredictiveBackPhase get phase => _phase;
  _PredictiveBackPhase _phase = _PredictiveBackPhase.idle;
  set phase(_PredictiveBackPhase phase) {
    if (_phase != phase && mounted) {
      setState(() => _phase = phase);
    }
  }

  /// The back event when the gesture first started.
  PredictiveBackEvent? get startBackEvent => _startBackEvent;
  PredictiveBackEvent? _startBackEvent;
  set startBackEvent(PredictiveBackEvent? startBackEvent) {
    if (_startBackEvent != startBackEvent && mounted) {
      setState(() => _startBackEvent = startBackEvent);
    }
  }

  /// The most recent back event during the gesture.
  PredictiveBackEvent? get currentBackEvent => _currentBackEvent;
  PredictiveBackEvent? _currentBackEvent;
  set currentBackEvent(PredictiveBackEvent? currentBackEvent) {
    if (_currentBackEvent != currentBackEvent && mounted) {
      setState(() => _currentBackEvent = currentBackEvent);
    }
  }

  // 手势看门狗：ColorOS 等系统有时手势中断后不发 cancel/commit
  // （比如侧滑到一半回边缘松手），导致 route.userGestureInProgress
  // 卡 true、route 动画停在中间值，Navigator 手势状态冻结，
  // 后续 pop/点击全部无响应、页面半途残留。
  // 2 秒无任何手势事件则强制「模拟回弹 + cancel」完整复位：
  // 1) 用手势 progress API 把 route 动画平滑拉回原位（1.0）
  // 2) 再走正常 cancel 清理（proxy 切回 + userGestureInProgress=false）
  Timer? _gestureWatchdog;
  Timer? _bounceTimer;

  void _armWatchdog() {
    _gestureWatchdog?.cancel();
    // ColorOS 手势事件不稳定（只发 start + progress=0 后消失），
    // 缩短到 1 秒：在用户按返回键之前就把卡住的手势状态复位掉，
    // 避免 route._animationProxy 一直挂着手势控制器导致 pop 动画不播。
    _gestureWatchdog = Timer(const Duration(seconds: 2), _onGestureStale);
  }

  void _onGestureStale() {
    if (!mounted) return;
    if (_phase != _PredictiveBackPhase.start &&
        _phase != _PredictiveBackPhase.update) {
      return;
    }
    print('[PBDetector] watchdog: gesture stalled, bounce back & cancel');
    final double from = widget.route.animation?.value ?? 1.0;
    int step = 0;
    _bounceTimer?.cancel();
    _bounceTimer = Timer.periodic(const Duration(milliseconds: 16), (t) {
      step++;
      final double p = step / 15.0; // ~240ms 回弹
      if (!mounted || p >= 1.0) {
        t.cancel();
        _bounceTimer = null;
        if (mounted) {
          handleCancelBackGesture();
        }
        return;
      }
      final double target = from + (1.0 - from) * Curves.easeOutCubic.transform(p);
      widget.route.handleUpdateBackGestureProgress(progress: target.clamp(0.0, 0.999));
    });
  }

  // Begin WidgetsBindingObserver.

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    phase = _PredictiveBackPhase.start;
    final bool gestureInProgress = !backEvent.isButtonEvent && _isEnabled;
    _gestureSeq++;
    print('[PBDetector] start#${"_gestureSeq"}: isCurrent=${widget.route.isCurrent} '
        'popGestureEnabled=${widget.route.popGestureEnabled} '
        'isFirst=${widget.route.isFirst} canPop=${widget.route.navigator?.canPop()} '
        'enabled=${_isEnabled} '
        'anim=${widget.route.animation != null} '
        'animVal=${widget.route.animation?.value.toStringAsFixed(3)} '
        'sec=${widget.route.secondaryAnimation != null} '
        'popInProgress=${widget.route.popGestureInProgress} '
        'fullscreen=${widget.route.fullscreenDialog} '
        'willHandle=${widget.route.willHandlePopInternally}');
    if (!gestureInProgress) {
      // 未消费：不 arm watchdog。否则 2 秒后触发 handleCancelBackGesture
      // 会把 userGestureInProgress 复位成 false，打断消费页的 commit 动画
      // （effectivePhase 从 commit 跳回 idle -> 页面跳回复位）。
      if (backEvent.isButtonEvent) {
        print('[PBDbg] button event, not consuming');
      } else {
        print('[PBDbg] not enabled: isFirst=${widget.route.isFirst} '
            'willHandle=${widget.route.willHandlePopInternally} '
            'fullscreen=${widget.route.fullscreenDialog} '
            'animDone=${widget.route.animation?.isCompleted} '
            'secDismissed=${widget.route.secondaryAnimation?.isDismissed} '
            'popInProgress=${widget.route.popGestureInProgress} '
            'animNull=${widget.route.animation == null} '
            'secNull=${widget.route.secondaryAnimation == null} '
            'isCurrent=${widget.route.isCurrent}');
      }
      return false;
    }

    // 手势开始：目标页从透明渐显（避免上次手势残留的进度导致闪变）
    predictiveBackProgress.value = 0.0;
    // ⚠️ progress 参数 = 目标页渐显进度（官方语义），route 内部会 1-progress
    // 设当前页动画。之前传 1-progress 导致 start 时当前页动画瞬间 dismissed
    // （controller=0），系统检测异常放弃预测 -> 触发率低。
    // 锁定目标页（手势 route 的下一层）：手势中只有它随手势渐显。
    gPredictiveBackTargetRoute = gRouteBelow[widget.route];
    gPredictiveBackInProgress = true;
    widget.route.handleStartBackGesture(progress: backEvent.progress);
    startBackEvent = currentBackEvent = backEvent;
    _armWatchdog();
    return true;
  }

  DateTime _lastUpdateLog = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    phase = _PredictiveBackPhase.update;
    print('[PBDetector] update#${"_gestureSeq"}: progress=${backEvent.progress.toStringAsFixed(3)} '
        'swipe=${backEvent.swipeEdge} enabled=$_isEnabled '
        'animVal=${widget.route.animation?.value.toStringAsFixed(3)}');
    // 直接同步全局手势进度（不依赖 transition 挂载）：目标页渐显
    // 由 predictiveBackProgress 驱动。popGestureInProgress 在 build 时
    // 可能为 false（ColorOS 时序问题），此时 transition 不挂载，
    // _syncProgress 不跑，必须在这里直接更新。
    // backEvent.progress 即目标页渐显进度（0→1）。
    predictiveBackProgress.value = backEvent.progress;
    // ⚠️ 同 start：传目标页渐显进度，不要 1-progress（否则当前页动画位置全错）
    widget.route.handleUpdateBackGestureProgress(progress: backEvent.progress);
    currentBackEvent = backEvent;
    _armWatchdog();
  }

  @override
  void handleCancelBackGesture() {
    _gestureWatchdog?.cancel();
    _bounceTimer?.cancel();
    print('[PBGESTURE] #${"_gestureSeq"} cancel animVal=${widget.route.animation?.value.toStringAsFixed(3)}');
    phase = _PredictiveBackPhase.cancel;
    // 手势取消：锁定手势最后进度（供 fallback 从手势位置恢复），
    // 然后目标页渐显进度复位（目标页回到完全隐藏）
    gPredictiveBackCancelProgress = predictiveBackProgress.value;
    predictiveBackProgress.value = 0.0;
    gPredictiveBackInProgress = false;

    widget.route.handleCancelBackGesture();
    startBackEvent = currentBackEvent = null;
    // 取消动画结束后重置 phase（避免残留 cancel 导致 fallback 一直用
    // Reverse(animation)：proxy 移除后 animation=controller(1.0) ->
    // Reverse=0 页面缩小锁死）。
    final Duration cancelDur = widget.route.transitionDuration;
    Future<void>.delayed(cancelDur, () {
      if (mounted && _phase == _PredictiveBackPhase.cancel) {
        phase = _PredictiveBackPhase.idle;
      }
    });
  }

  @override
  void handleCommitBackGesture() {
    _gestureWatchdog?.cancel();
    _bounceTimer?.cancel();
    print('[PBGESTURE] #${"_gestureSeq"} commit animVal=${widget.route.animation?.value.toStringAsFixed(3)}');
    phase = _PredictiveBackPhase.commit;

    // 锁定手势最后进度：route.animation 是 _PopGestureProxy（value = 1 -
    // controller = progress），所以直接取 animation.value 就是手势进度。
    // ⚠️ 不能 1-animation：proxy 已是 progress，取补会继承 1-progress（反）。
    gPredictiveBackCommitProgress = widget.route.animation?.value ?? 0.0;
    // commit 时锁定全局手势进度：pop 后目标页 opacity = max(progress, oldFade)
    // 兜底，防止 fadeInOldPage 继承前的瞬间黑帧/跳变。
    predictiveBackProgress.value = gPredictiveBackCommitProgress;
    gPredictiveBackInProgress = false;
    widget.route.handleCommitBackGesture();
    startBackEvent = currentBackEvent = null;
  }

  // End WidgetsBindingObserver.

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 监听全局手势进度：pop 后 delayed clear（progress -> 0）触发重建，
    // 重算挂载条件（gPredictiveBackInProgress 已清 -> fallback），
    // 卸载可能残留的 SharedElement（画面「缩小靠右」锁死）。
    predictiveBackProgress.addListener(_onPredictiveProgressChanged);
  }

  void _onPredictiveProgressChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    // 兜底：手势消费后还没收到 cancel/commit 就销毁（route 被 pop），
    // 强制复位 route 手势状态，避免 _animationProxy 卡死导致下层页点不动。
    if (_phase == _PredictiveBackPhase.start ||
        _phase == _PredictiveBackPhase.update) {
      if (widget.route.navigator != null) {
        try {
          widget.route.handleCancelBackGesture();
        } catch (_) {}
      }
    }
    _gestureWatchdog?.cancel();
    _bounceTimer?.cancel();
    predictiveBackProgress.removeListener(_onPredictiveProgressChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    print('[PBDetector] build: phase=$phase '
        'popInProgress=${widget.route.popGestureInProgress} '
        'isCurrent=${widget.route.isCurrent}');
    // commit 后 userGestureInProgress 被 route 复位成 false，但 commit 动画
    // 必须保持 transition（phase=commit），否则被 fallback 替换会从头重播。
    final _PredictiveBackPhase effectivePhase =
        (gPredictiveBackInProgress || widget.route.popGestureInProgress)
        ? phase
        : (phase == _PredictiveBackPhase.commit ||
                phase == _PredictiveBackPhase.cancel
            ? phase
            : _PredictiveBackPhase.idle);
    return widget.builder(context, effectivePhase, startBackEvent, currentBackEvent);
  }
}

/// Android's predictive back page shared element transition.
///
/// See also:
///
///  * <https://developer.android.com/design/ui/mobile/guides/patterns/predictive-back#shared-element-transition>,
///    which is the Android spec for this transition.
class _PredictiveBackSharedElementPageTransition extends StatefulWidget {
  const _PredictiveBackSharedElementPageTransition({
    required this.isDelegatedTransition,
    required this.animation,
    required this.secondaryAnimation,
    required this.phase,
    required this.startBackEvent,
    required this.currentBackEvent,
    required this.child,
  });

  final bool isDelegatedTransition;
  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final _PredictiveBackPhase phase;
  final PredictiveBackEvent? startBackEvent;
  final PredictiveBackEvent? currentBackEvent;
  final Widget child;

  @override
  State<_PredictiveBackSharedElementPageTransition> createState() =>
      _PredictiveBackSharedElementPageTransitionState();
}

class _PredictiveBackSharedElementPageTransitionState
    extends State<_PredictiveBackSharedElementPageTransition>
    with SingleTickerProviderStateMixin {
  // Constants as per the motion specs
  // https://developer.android.com/design/ui/mobile/guides/patterns/predictive-back#motion-specs
  static const double _kMinScale = 0.90;
  static const double _kDivisionFactor = 20.0;
  static const double _kMargin = 8.0;
  static const double _kYPositionFactor = 0.1;

  // The duration of the commit transition.
  //
  // This is not the same as PiliPredictiveBackPageTransitionsBuilder's duration,
  // which is the duration of widget.animation, so an Interval is used.
  //
  // Eyeballed on a Pixel 9 running Android 16.
  static const int _kCommitMilliseconds = 400;
  static const Curve _kCurve = Curves.easeInOutCubicEmphasized;
  static const Interval _kCommitInterval = Interval(
    0.0,
    _kCommitMilliseconds / FadeForwardsPageTransitionsBuilder.kTransitionMilliseconds,
    curve: _kCurve,
  );

  // A fallback corner radius used when the display corner radii are
  // unavailable (e.g., on Android API levels below 31, iOS, and other
  // platforms). This is a best-guess value that looks reasonable on most
  // devices.
  // See https://github.com/flutter/flutter/issues/97349.
  static const double _kDeviceBorderRadius = 32.0;

  // Provides a smooth transition between the default radius and the
  // _kDeviceBorderRadius, when the display corner radii are unavailable.
  final Tween<double> _borderRadiusTween = Tween<double>(begin: 0.0, end: _kDeviceBorderRadius);

  // The route fades out after commit.
  final Tween<double> _opacityTween = Tween<double>(begin: 1.0, end: 0.0);

  // The route shrinks during the gesture and animates back to normal after
  // commit.
  final Tween<double> _scaleTween = Tween<double>(begin: 1.0, end: _kMinScale);

  // An animation that stays constant at zero before the commit, and after the
  // commit goes from zero to one.
  final ProxyAnimation _commitAnimation = ProxyAnimation();

  // An animation that goes from zero to a maximum of one during a predictive
  // back gesture, and then at commit, it goes from its current value to zero.
  // Used for animations that follow the gesture and then animate back to their
  // original value after commit.
  final ProxyAnimation _bounceAnimation = ProxyAnimation();
  double _lastBounceAnimationValue = 0.0;

  // An animation that proxies to widget.animation during the gesture and then
  // to _commitAnimation after the commit. So, it goes from zero to a maximum of
  // one before commit, and then after commit goes from zero to one again.
  final ProxyAnimation _animation = ProxyAnimation();

  /// The same as widget.animation but with a curve applied.
  CurvedAnimation? _curvedAnimation;

  /// The reverse of _curvedAnimation.
  CurvedAnimation? _curvedAnimationReversed;

  late Animation<Offset> _positionAnimation;

  Offset _lastDrag = Offset.zero;

  DateTime _lastCommitLog = DateTime.fromMillisecondsSinceEpoch(0);

  // This isn't done as an animation because it's based on the vertical drag
  // amount, not the progression of the back gesture like widget.animation is.
  double _getYShiftPosition(double screenHeight) {
    final double startTouchY = widget.startBackEvent?.touchOffset?.dy ?? 0;
    final double currentTouchY = widget.currentBackEvent?.touchOffset?.dy ?? 0;

    final double yShiftMax = (screenHeight / _kDivisionFactor) - _kMargin;

    final double rawYShift = currentTouchY - startTouchY;
    final double easedYShift =
        // This curve was eyeballed on a Pixel 9 running Android 16.
        Curves.easeOut.transform(clampDouble(rawYShift.abs() / screenHeight, 0.0, 1.0)) *
        rawYShift.sign *
        yShiftMax;

    return clampDouble(easedYShift, -yShiftMax, yShiftMax);
  }

  void _updateAnimations(Size screenSize) {
    _animation.parent = switch (widget.phase) {
      _PredictiveBackPhase.commit => _curvedAnimationReversed,
      _ => widget.animation,
    };

    _bounceAnimation.parent = switch (widget.phase) {
      // commit 后从手势位置继续缩小滑出（begin=手势最后 bounce，end=1 对应
      // scale 最小 0.9）。官方 begin=0 会在 commit 瞬间跳回完整（scale 1.0）
      // 再缩小，视觉上就是「松手复位」。
      _PredictiveBackPhase.commit => Tween<double>(
        begin: _lastBounceAnimationValue,
        end: 1.0,
      ).animate(_curvedAnimation!),
      // 非 commit：widget.animation 是 proxy（value=progress），直接用
      // progress 驱动 scale（progress=0 -> 1.0，progress=1 -> 0.9）。
      // ⚠️ 官方用 ReverseAnimation 是假设 animation=controller(1-progress)，
      // 但 proxy 已是 progress，再 Reverse 就变成 1-progress（手势刚开始
      // scale=0.9，滑到底反而恢复 1.0，方向全反）。
      _ => widget.animation,
    };

    _commitAnimation.parent = switch (widget.phase) {
      _PredictiveBackPhase.commit => _animation,
      _ => kAlwaysDismissedAnimation,
    };

    final double xShift = (screenSize.width / _kDivisionFactor) - _kMargin;
    // 非 commit 用 ReverseAnimation(_animation) 驱动：_animation=proxy=progress，
    // 反向得到 1-progress -> progress=0 时 position=end（居中），progress 增大
    // 时往 begin 偏移（跟手方向）。官方直接 drive(_animation) 会导致 progress=0
    // 时页面就在 begin 偏移位（ColorOS start progress=0 时尤为明显）。
    _positionAnimation = (switch (widget.phase) {
          _PredictiveBackPhase.commit => _animation,
          _ => ReverseAnimation(_animation),
        }).drive(switch (widget.phase) {
      _PredictiveBackPhase.commit => Tween<Offset>(
        begin: _lastDrag,
        // ?? 方向必须跟随手势来源：left 边缘（向右滑）-> 往右滑出；
        // right 边缘（向左滑）-> 往左滑出。之前固定 +1.5width 导致
        // 无论从左还是从右侧滑，动效都往右。
        end: Offset(
          (_lastDrag.dx < 0 ? -1.0 : 1.0) * screenSize.width * 1.5,
          _lastDrag.dy,
        ),
      ),
      _ => Tween<Offset>(
        // The y position before commit is given by the vertical drag, not by an
        // animation.
        begin: switch (widget.currentBackEvent?.swipeEdge) {
          SwipeEdge.left => Offset(xShift, _getYShiftPosition(screenSize.height)),
          SwipeEdge.right => Offset(-xShift, _getYShiftPosition(screenSize.height)),
          null => Offset(xShift, _getYShiftPosition(screenSize.height)),
        },
        end: Offset.zero,
      ),
    });
  }

  void _updateCurvedAnimations() {
    _curvedAnimation?.dispose();
    _curvedAnimationReversed?.dispose();
    _curvedAnimation = CurvedAnimation(parent: widget.animation, curve: _kCommitInterval);
    _curvedAnimationReversed = CurvedAnimation(
      parent: ReverseAnimation(widget.animation),
      curve: _kCommitInterval,
    );
  }

  // TODO(justinmc): Should have a delegatedTransition to animate the incoming
  // route regardless of its page transition.
  // https://github.com/flutter/flutter/issues/153577

  /// 同步全局手势进度（供目标页渐显）。在手势动画 tick 期间调用，
  /// 不在 build 中写入 ValueNotifier，避免触发「setState during build」。
  void _syncProgress() {
    // ⚠️ 只在手势跟手阶段（start/update）同步。
    // commit 动画（pop 450ms）期间 animation 从 0.98→0，如果在这里同步
    // 会把 predictiveBackProgress 一路拉到 1.0 并残留，导致下次 push 时
    // 旧页 opacity = max(1.0, oldFade) 恒 1.0 不淡出。
    // cancel 动画同理（progress 已在 handleCancelBackGesture 复位 0）。
    // ⚠️ idle（push/pop 普通动画）期间同步会污染 progress：
    // pop 动画 controller 反向（1→0），v 递减 -> 旧页 opacity =
    // max(递减 progress, oldFade) 被压暗到接近 0，动画结束画面就
    // 「停在过渡动画最后帧」（暗/黑）。只有手势跟手阶段 progress
    // 才是真实手势进度。
    if (widget.phase != _PredictiveBackPhase.update) {
      return;
    }
    // commit 后 1-2 帧 SharedElement 的 phase 仍残留 update，此时若同步会把
    // didPopNext 刚清 0 的 progress 又拉回 1.0（commit 动画 proxy 滑向 1），
    // pop 期间目标页 opacity = max(1.0, oldFade) 恒 1.0 -> 松手后渐显截断。
    // commit/cancel 后 g 已清 false，用它判定手势进行中更可靠。
    if (!gPredictiveBackInProgress) {
      return;
    }
    // 手势中 widget.animation 是 _PopGestureProxy（value = 1 - controller =
    // progress，官方代理反向），所以 progress = animation.value 本身（0→1）。
    // ⚠️ 不能写 1 - animation：proxy 已经是 progress，再取补就是 1-progress，
    // 导致目标页 opacity = max(1-progress, 0) 渐隐（动效全反）。
    final double v = widget.animation.value;
    predictiveBackProgress.value = v;
  }

  @override
  void initState() {
    super.initState();
    widget.animation.addListener(_syncProgress);
  }

  @override
  void didUpdateWidget(_PredictiveBackSharedElementPageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.animation != oldWidget.animation) {
      oldWidget.animation.removeListener(_syncProgress);
      widget.animation.addListener(_syncProgress);
      _updateCurvedAnimations();
    }
    if (widget.phase != oldWidget.phase && widget.phase == _PredictiveBackPhase.commit) {
      _updateAnimations(MediaQuery.sizeOf(context));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateCurvedAnimations();
    _updateAnimations(MediaQuery.sizeOf(context));
  }

  @override
  void dispose() {
    widget.animation.removeListener(_syncProgress);
    _curvedAnimation!.dispose();
    _curvedAnimationReversed!.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (BuildContext context, Widget? child) {
        _lastBounceAnimationValue = _bounceAnimation.value;
        if (widget.phase == _PredictiveBackPhase.commit) {
          final now = DateTime.now();
          if (now.difference(_lastCommitLog) > const Duration(milliseconds: 90)) {
            _lastCommitLog = now;
            print('[PBCommit] anim=${widget.animation.value.toStringAsFixed(3)} '
                'bounce=${_bounceAnimation.value.toStringAsFixed(3)} '
                'pos=${_positionAnimation.value.dx.toStringAsFixed(0)},'
                '${_positionAnimation.value.dy.toStringAsFixed(0)} '
                'opacity=${_opacityTween.evaluate(_commitAnimation).toStringAsFixed(2)} '
                'lastDrag=${_lastDrag.dx.toStringAsFixed(0)},${_lastDrag.dy.toStringAsFixed(0)}');
          }
        }
        return Transform.scale(
          scale: _scaleTween.evaluate(_bounceAnimation),
          child: Transform.translate(
            offset: switch (widget.phase) {
              _PredictiveBackPhase.commit => _positionAnimation.value,
              _ => _lastDrag = Offset(
                _positionAnimation.value.dx,
                _getYShiftPosition(MediaQuery.heightOf(context)),
              ),
            },
            child: Opacity(
              opacity: _opacityTween.evaluate(_commitAnimation),
              child: ClipRRect(
                borderRadius:
                    MediaQuery.displayCornerRadiiOf(context) ??
                    BorderRadius.circular(_borderRadiusTween.evaluate(_bounceAnimation)),
                child: child,
              ),
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// Android's predictive back page transition for full screen surfaces.
///
/// See also:
///
///  * <https://developer.android.com/design/ui/mobile/guides/patterns/predictive-back#full-screen-surfaces>,
///    which is the Android spec for this transition.
class _PredictiveBackFullscreenPageTransition extends StatefulWidget {
  const _PredictiveBackFullscreenPageTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.getIsCurrent,
    required this.phase,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final _PredictiveBackPhase phase;
  final ValueGetter<bool> getIsCurrent;
  final Widget child;

  @override
  State<_PredictiveBackFullscreenPageTransition> createState() =>
      _PredictiveBackFullscreenPageTransitionState();
}

class _PredictiveBackFullscreenPageTransitionState
    extends State<_PredictiveBackFullscreenPageTransition> {
  // These values were eyeballed to match the Android spec for the Full Screen
  // page transition:
  // https://developer.android.com/design/ui/mobile/guides/patterns/predictive-back#full-screen-surfaces
  static const double _kScaleStart = 1.0;
  static const double _kScaleCommit = 0.95;
  static const double _kOpacityFullyOpened = 1.0;
  static const double _kOpacityStartTransition = 0.95;
  // The point at which the drag would cause a commit instead of a cancel if it
  // were released.
  static const double _kCommitAt = 0.65;
  static const double _kWeightPreCommit = _kCommitAt;
  static const double _kWeightPostCommit = 1 - _kWeightPreCommit;
  static const double _kScreenWidthDivisionFactor = 20.0;
  static const double _kXShiftAdjustment = 8.0;
  static const Duration _kCommitDuration = Duration(milliseconds: 100);

  final Animatable<double> _primaryOpacityTween = Tween<double>(
    begin: _kOpacityStartTransition,
    end: _kOpacityFullyOpened,
  );

  final Animatable<double> _primaryScaleTween = TweenSequence<double>(<TweenSequenceItem<double>>[
    TweenSequenceItem<double>(
      tween: Tween<double>(begin: _kScaleStart, end: _kScaleStart),
      weight: _kWeightPreCommit,
    ),
    TweenSequenceItem<double>(
      tween: Tween<double>(begin: _kScaleCommit, end: _kScaleStart),
      weight: _kWeightPostCommit,
    ),
  ]);

  final ConstantTween<double> _secondaryScaleTweenCurrent = ConstantTween<double>(_kScaleStart);
  final TweenSequence<double> _secondaryTweenScale =
      TweenSequence<double>(<TweenSequenceItem<double>>[
        TweenSequenceItem<double>(
          tween: Tween<double>(begin: _kScaleCommit, end: _kScaleStart),
          weight: _kWeightPreCommit,
        ),
        TweenSequenceItem<double>(
          tween: Tween<double>(begin: _kScaleStart, end: _kScaleStart),
          weight: _kWeightPostCommit,
        ),
      ]);

  final ConstantTween<double> _secondaryOpacityTweenCurrent = ConstantTween<double>(
    _kOpacityFullyOpened,
  );
  final TweenSequence<double> _secondaryOpacityTween =
      TweenSequence<double>(<TweenSequenceItem<double>>[
        TweenSequenceItem<double>(
          tween: Tween<double>(begin: _kOpacityFullyOpened, end: _kOpacityStartTransition),
          weight: _kWeightPreCommit,
        ),
        TweenSequenceItem<double>(
          tween: Tween<double>(begin: _kOpacityFullyOpened, end: _kOpacityFullyOpened),
          weight: _kWeightPostCommit,
        ),
      ]);

  late Animatable<Offset> _primaryPositionTween;
  late Animatable<Offset> _secondaryPositionTween;
  late Animatable<Offset> _secondaryCurrentPositionTween;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final double screenWidth = MediaQuery.widthOf(context);
    final double xShift = (screenWidth / _kScreenWidthDivisionFactor) - _kXShiftAdjustment;
    _primaryPositionTween = TweenSequence<Offset>(<TweenSequenceItem<Offset>>[
      TweenSequenceItem<Offset>(
        tween: Tween<Offset>(begin: Offset.zero, end: Offset.zero),
        weight: _kWeightPreCommit,
      ),
      TweenSequenceItem<Offset>(
        tween: Tween<Offset>(begin: Offset(xShift, 0.0), end: Offset.zero),
        weight: _kWeightPostCommit,
      ),
    ]);

    _secondaryCurrentPositionTween = ConstantTween<Offset>(Offset.zero);
    _secondaryPositionTween = Tween<Offset>(begin: Offset(xShift, 0.0), end: Offset.zero);
  }

  Widget _secondaryAnimatedBuilder(BuildContext context, Widget? child) {
    final bool isCurrent = widget.getIsCurrent();

    return Transform.translate(
      offset: isCurrent
          ? _secondaryCurrentPositionTween.evaluate(widget.secondaryAnimation)
          : _secondaryPositionTween.evaluate(widget.secondaryAnimation),
      child: Transform.scale(
        scale: isCurrent
            ? _secondaryScaleTweenCurrent.evaluate(widget.secondaryAnimation)
            : _secondaryTweenScale.evaluate(widget.secondaryAnimation),
        child: Opacity(
          opacity: isCurrent
              ? _secondaryOpacityTweenCurrent.evaluate(widget.secondaryAnimation)
              : _secondaryOpacityTween.evaluate(widget.secondaryAnimation),
          child: child,
        ),
      ),
    );
  }

  Widget _primaryAnimatedBuilder(BuildContext context, Widget? child) {
    return Transform.translate(
      offset: _primaryPositionTween.evaluate(widget.animation),
      child: Transform.scale(
        scale: _primaryScaleTween.evaluate(widget.animation),
        // A slight change in opacity before reaching the commit point.
        child: Opacity(
          opacity: _primaryOpacityTween.evaluate(widget.animation),
          // A sudden fadeout at the commit point, driven by time and not the
          // gesture.
          child: AnimatedOpacity(
            opacity: switch (widget.phase) {
              _PredictiveBackPhase.commit => 0.0,
              _ => widget.animation.value < _kCommitAt ? 0.0 : 1.0,
            },
            duration: _kCommitDuration,
            child: child,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.secondaryAnimation,
      builder: _secondaryAnimatedBuilder,
      child: AnimatedBuilder(
        animation: widget.animation,
        builder: _primaryAnimatedBuilder,
        child: ClipRRect(
          borderRadius:
              MediaQuery.displayCornerRadiiOf(context) ??
              const BorderRadius.all(
                Radius.circular(
                  _PredictiveBackSharedElementPageTransitionState._kDeviceBorderRadius,
                ),
              ),
          child: widget.child,
        ),
      ),
    );
  }
}