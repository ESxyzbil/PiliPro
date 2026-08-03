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
import 'package:PiliPlus/common/widgets/glass.dart'
    show glassRevealActive, glassRevealProgress;
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

/// 最近一次 update 手势进度（backEvent.progress，官方语义 = 目标页渐显
/// 进度 0→1）。commit 时用它锁定 gPredictiveBackCommitProgress，_syncProgress
/// 跟手同步也用它。
///
/// ⚠️ 不能取 widget.route.animation.value：Pili 自定义 PBDetector 没有像
/// 官方那样把 route.animation 替换成 _PopGestureProxy（value = progress），
/// 这里拿到的始终是原始 controller（value = 1 - progress）。手势滑到 0.9
/// 时取 animation.value 会锁成 0.1 → 目标页 opacity = max(0.1, oldFade) ≈
/// 0.1 → pop 动画期间目标页几乎全透明 → 露出白色 Navigator 背景
/// （"返回主页闪白一下" 08-02 用户反馈）。
double gLastGestureProgress = 0.0;

/// pop 动画（非手势，按钮返回/程序化 pop）中「目标页渐显」进度：
/// 由被 pop 的当前页驱动（pop 动效结束后 0→1），目标页（被 pop 页的
/// 下一层）读取，让下层页在返回动效结束后渐显（毛玻璃随页面渐显浮现，
/// 与进入时同理）。
///
/// ⚠️ 必须用全局 Notifier 而非 secondaryAnimation：GetPageRouteTransitionMixin
/// 的 canTransitionTo 恒返回 false（nextRoute 非 Cupertino），导致 route 的
/// secondaryAnimation 永远是 kAlwaysDismissedAnimation(0)，无法驱动下层页。
final ValueNotifier<double> popFadeProgress = ValueNotifier<double>(0.0);

/// pop 动画（非手势）进行中标志：由被 pop 页的 _PopFadeWriter 在
/// animation reverse 时置 true。目标页在 pop 动效中保持隐藏，
/// 动效结束后再启动渐显（毛玻璃随页面渐显）。
/// ⚠️ ValueNotifier：目标页的 AnimatedBuilder 需要监听它来强制隐藏。
final ValueNotifier<bool> gPopInProgress = ValueNotifier<bool>(false);

/// 已挂载 route 的栈（从底到顶）：_PopFadeWriter 挂载/卸载维护，
/// 用于 pop 时找目标页（被 pop 页的下一层）。
/// gRouteBelow 原本的设计从未被赋值（全文件只有定义和读取，恒空），
/// 导致目标页永远找不到，故用栈记录替代。
final List<Route<dynamic>> _routeStack = <Route<dynamic>>[];

/// pop 动画的目标页（被 pop 页的下一层）：只有它读 popFadeProgress 渐显，
/// 避免三级返回（A→B→C，pop C）时更下层页面 A 也跟着一起渐显。
Route<dynamic>? gPopFadeTarget;

/// 取消手势时锁定的手势最后进度（-1 = 无待继承）。取消动画的 route.animation
/// 从 0 重播进入（controller 被复位），fallback 用 Tween(begin: 此值, end: 1.0)
/// 让页面从手势位置平滑恢复（而不是从透明重播进入动画）。
double gPredictiveBackCancelProgress = -1.0;

/// commit 时被临时拉长的 controller.duration 原值（保证滑出动画最小时长后
/// 恢复，避免影响后续 push 动画时长）。
Duration? gPiliCommitBaseCtrlDuration;

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
    // 当前页驱动全局 popFadeProgress（pop 动画中 0→1），供下层目标页
    // 渐显。所有页面都包一层，但只有 route.isCurrent 时写入。
    return _PopFadeWriter(
      route: route,
      animation: animation,
      child: _PredictiveBackGestureDetector(
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
              debugPrint('[PBEntrance] t=${t?.name} animDuration=' 
                  '${animation is Animation<double> ? "?" : "?"}');
              // 进入/退出分离：GetX transition 的进入动画在 0-60%
              // （视觉 240ms）内完成，pop 时 reverseCurve（线性）全程
              // （400ms）。native/fallbackBuilder 走 FadePrevious（内部
              // 已自带 Interval(0.6)），这里不再二次包装。
              final Animation<double> entrance =
                  (t == null || t == Transition.native)
                      ? animation
                      : CurvedAnimation(
                          parent: animation,
                          curve: const Interval(
                              0.0, 0.6, curve: Curves.easeOutCubic),
                          reverseCurve: Curves.linear,
                        );
              switch (t) {
                case Transition.noTransition:
                  return NoTransition.buildTransitions(context, Curves.easeOut,
                      Alignment.center, entrance, secondaryAnimation, child);
                case Transition.fade:
                case Transition.fadeIn:
                  return FadeInTransition.buildTransitions(
                      context, entrance, secondaryAnimation, child);
                case Transition.cupertino:
                case Transition.cupertinoDialog:
                  return CupertinoPageTransitionsBuilder().buildTransitions(
                      route, context, entrance, secondaryAnimation, child);
                case Transition.leftToRight:
                  return SlideRightTransition.buildTransitions(
                      context, entrance, secondaryAnimation, child);
                case Transition.downToUp:
                  return SlideTopTransition.buildTransitions(
                      context, entrance, secondaryAnimation, child);
                case Transition.upToDown:
                  return SlideDownTransition.buildTransitions(
                      context, entrance, secondaryAnimation, child);
                case Transition.rightToLeft:
                  return SlideLeftTransition.buildTransitions(
                      context, entrance, secondaryAnimation, child);
                case Transition.zoom:
                case Transition.topLevel:
                  // 自定义缩放（无 scrim，避免官方 ZoomPageTransitionsBuilder
                  // 的半透明白色遮罩层）。下层页渐显由外层 AnimatedBuilder
                  // 的 opacity = max(oldFade, 1-sec) 驱动（pop 动画中随
                  // secondaryAnimation 同步渐显），这里只做本页自己的
                  // 渐显 + 缩放。
                  return FadeTransition(
                    opacity: CurvedAnimation(
                        parent: entrance, curve: Curves.easeInOut),
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                          CurvedAnimation(
                              parent: entrance, curve: Curves.easeInOut)),
                      child: child,
                    ),
                  );
                case Transition.circularReveal:
                  return CircularRevealTransition.buildTransitions(
                      context, entrance, secondaryAnimation, child);
                case Transition.rightToLeftWithFade:
                  return RightToLeftFadeTransition.buildTransitions(
                      context, entrance, secondaryAnimation, child);
                case Transition.leftToRightWithFade:
                  return LeftToRightFadeTransition.buildTransitions(
                      context, entrance, secondaryAnimation, child);
                case Transition.size:
                  return SizeTransitions.buildTransitions(
                      context, entrance, secondaryAnimation, child);
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
            final List<Listenable> listenables = [
              predictiveBackProgress,
              gPopInProgress,
            ];
            if (oldFadeAnim != null) listenables.add(oldFadeAnim);
            // pop 动画结束后目标页随 popFadeProgress（当前页驱动 0→1）渐显：
            // oldFade 的 didPopNext 在 pop 动画完成后才触发，太晚且不可靠；
            // popFadeProgress 让下层页在返回动效结束后渐显（毛玻璃随页面
            // 渐显浮现，与进入时同理）。
            listenables.add(popFadeProgress);
            return AnimatedBuilder(
              animation: Listenable.merge(listenables),
              builder: (context, _) {
                // 手势中只有目标页（gPredictiveBackTargetRoute，手势 route
                // 的下一层）读 predictiveBackProgress：更下层页面若也读 p
                // 会跟着一起渐显（三级返回时露两层，12:59 用户报告）。
                final double p = identical(route, gPredictiveBackTargetRoute)
                    ? predictiveBackProgress.value
                    : 0.0;
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
                final bool isTarget = identical(route, gPopFadeTarget);
                final double popFade = isTarget ? popFadeProgress.value : 0.0;
                // 统一 max(base, popFade)：
                // - base = max(p, oldFade)：手势进度 / oldFade（didPopNext
                //   在 pop 动画开始时触发，400ms easeIn 0→1）→ 返回动效中
                //   目标页随 oldFade 渐显，毛玻璃随页面渐显浮现（与进入时
                //   X 渐显对称）。
                // - popFade：pop 动效结束后 0→1（250ms）兜底，万一 oldFade
                //   未触发也能渐显。
                // 普通 current 页（isTarget=false）popFade=0，无影响。
                final double base = p > oldFade ? p : oldFade;
                final double opacity =
                    (base > popFade ? base : popFade).clamp(0.0, 1.0);
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
      ),
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

/// 当前页驱动全局 popFadeProgress（供下层目标页在 pop 动画中渐显）。
///
/// pop 动画中 animation 1→0 → progress 0→1（目标页渐显）；
/// push 动画中 animation 0→1 → progress 1→0（目标页淡出，与 oldFade
/// 淡出同步）。只有 route.isCurrent 时写入（非当前页的 animation 恒定
/// 1.0，写 0 会覆盖掉当前页的 progress）。
///
/// dispose（被 pop 移除）时复位 progress 与目标页标记。
class _PopFadeWriter extends StatefulWidget {
  const _PopFadeWriter({
    required this.route,
    required this.animation,
    required this.child,
  });

  final Route<dynamic> route;
  final Animation<double> animation;
  final Widget child;

  @override
  State<_PopFadeWriter> createState() => _PopFadeWriterState();
}

class _PopFadeWriterState extends State<_PopFadeWriter> {
  Route<dynamic>? _lockedTarget;

  void _onAnimationStatus(AnimationStatus status) {
    // 手势跟手阶段（gPredictiveBackInProgress）：完全由
    // predictiveBackProgress 驱动，不干预（避免把已渐显到手势进度的
    // 目标页强制隐藏回 0）。commit 后 gPredictiveBackInProgress 已清，
    // predictiveBackProgress 仍锁定手势进度（>0），但不影响下面的处理。
    if (gPredictiveBackInProgress) return;
    if (status == AnimationStatus.forward) {
      // push 开始：清残留的 pop 渐显状态（旧页淡出由 oldFade 负责，
      // 残留的目标页/进度会把旧页 opacity 顶死导致不淡出）
      gPopInProgress.value = false;
      gPopFadeTarget = null;
      if (popFadeProgress.value > 0.0) popFadeProgress.value = 0.0;
      // 毛玻璃渐显复位：push 渐显由 GlassContainer 本地动画驱动
      // （08-02 重构，不再依赖 didPush 全局 Timer），这里必须复位——
      // pop 取消回弹也走 forward，不复位会让 glassRevealActive 卡 true，
      // 目标页被永久遮罩/隐藏（"有时候没有渐显效果"的元凶）。
      glassRevealActive.value = false;
      glassRevealProgress.value = 1.0;
      return;
    }
    if (status == AnimationStatus.reverse) {
      // pop 动画进行中：锁定目标页（栈里本页下面一层），动效中保持隐藏
      gPopInProgress.value = true;
      final int idx = _routeStack.indexOf(widget.route);
      _lockedTarget = idx > 0 ? _routeStack[idx - 1] : null;
      gPopFadeTarget = _lockedTarget;
      // 按钮返回（无手势）：pop 动画期间目标页完整显示（不闪白），
      // 不依赖 oldFade（有时不触发 → 目标页全透明露出白底）。
      // 不设 glassReveal——当前页还在屏幕上，全局卡片遮罩会把正在
      // 滑出的当前页内容也盖成透明（08-02 用户反馈）。
      if (predictiveBackProgress.value <= 0.0) {
        popFadeProgress.value = 1.0;
      }
      return;
    }
    if (status == AnimationStatus.dismissed) {
      // 恢复被临时拉长的 controller.duration（避免影响后续 push 动画时长）
      if (gPiliCommitBaseCtrlDuration != null) {
        final AnimationController? ctrl =
            widget.route is TransitionRoute<dynamic> &&
                (widget.route as TransitionRoute<dynamic>).animation
                    is AnimationController
            ? (widget.route as TransitionRoute<dynamic>).animation!
                as AnimationController
            : null;
        if (ctrl != null) {
          ctrl.duration = gPiliCommitBaseCtrlDuration;
        }
        gPiliCommitBaseCtrlDuration = null;
      }
      // pop 动画完成：启动目标页渐显。无论按钮返回还是手势 commit
      // 都必须启动——目标页 opacity = max(p, oldFade, popFade)，
      // popFade 从 0 渐显、被 p 顶住 → 从手势进度继续平滑渐显，
      // 不会跳变；不启动则依赖不可靠的 oldFade，动效被吞 + 闪烁。
      gPopInProgress.value = false;
      if (gPopFadeTarget == null) {
        final int idx = _routeStack.indexOf(widget.route);
        _lockedTarget = idx > 0 ? _routeStack[idx - 1] : null;
        gPopFadeTarget = _lockedTarget;
      }
      // 返回动效结束后页面直接完整显示（popFade=1.0），不再做任何
      // 渐显（08-02 用户反馈：返回时毛玻璃模糊效果已就绪，无需再过
      // 一遍从 0 显现）。push 进入时的渐显由 GlassContainer 本地动画
      // （infoCard 挂载 450ms）负责，与此无关。
      popFadeProgress.value = 1.0;
    }
  }

  /// 渐显动画：独立 Timer 驱动（不依赖本 state 生命周期）：pop 动画完成瞬间
  /// 当前页的 overlay entry 会被移除（dispose），Timer 仍继续跑完。
  /// - 页面透明度渐显：250ms（用户认可的速度，11:36）
  /// - 毛玻璃/背景模糊渐显（glassReveal）：357ms（250ms / 0.7，
  ///   用户 12:43 要求放慢到当前速率的 0.7x）
  @override
  void initState() {
    super.initState();
    // 维护 route 栈（从底到顶）：用于 pop 时找目标页。
    // 同时补上 gRouteBelow 的赋值（手势路径也在读它）。
    if (!_routeStack.contains(widget.route)) {
      _routeStack.add(widget.route);
      final int idx = _routeStack.indexOf(widget.route);
      if (idx > 0) {
        gRouteBelow[widget.route] = _routeStack[idx - 1];
      }
    }
    // 只挂 status listener，不主动调用：新页挂载时 status=dismissed
    //（动画未开始），不应触发渐显。
    widget.animation.addStatusListener(_onAnimationStatus);
  }

  @override
  void didUpdateWidget(_PopFadeWriter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animation != oldWidget.animation) {
      oldWidget.animation.removeStatusListener(_onAnimationStatus);
      widget.animation.addStatusListener(_onAnimationStatus);
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onAnimationStatus);
    _routeStack.remove(widget.route);
    // ⚠️ 不 cancel _fadeTimer：pop 完成瞬间启动的渐显由 Timer 独立驱动，
    // dispose 后继续跑完 250ms 让目标页渐显完成。
    // 延迟复位：等目标页 oldFade（didPopNext 触发 0→1）接管后再清，
    // 且只在目标页仍是本页锁定的目标时清（防止覆盖新 push 的 progress）。
    final Route<dynamic>? locked = _lockedTarget;
    Future<void>.delayed(const Duration(milliseconds: 450), () {
      if (identical(gPopFadeTarget, locked)) {
        gPopFadeTarget = null;
        if (popFadeProgress.value > 0.0) popFadeProgress.value = 0.0;
      }
      if (identical(gPredictiveBackTargetRoute, locked)) {
        gPredictiveBackTargetRoute = null;
      }
      gPopInProgress.value = false;
      // 毛玻璃遮罩兜底复位（保留：无害，pop 渐显已移除）。
      if (!glassRevealActive.value) {
        glassRevealActive.value = false;
        glassRevealProgress.value = 1.0;
      }
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

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
  /// 手势前的 route animation controller（手势中 route.animation 被换成
  /// _PopGestureProxy，cast 不到 controller；在手势开始前记录）。
  AnimationController? _routeAnimCtrl;

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
    // 记录手势前的 route animation controller（手势中 route.animation 被
    // 替换成 _PopGestureProxy，拿不到 controller；这里趁 proxy 替换前记录）
    final Animation<double>? anim0 = widget.route.animation;
    if (anim0 is AnimationController) _routeAnimCtrl = anim0;
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
    gLastGestureProgress = backEvent.progress;
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
    // 取消手势：目标页不再读 p（避免残留导致后续按钮 pop 时目标页
    // 透明度被旧锁定值顶住）
    gPredictiveBackTargetRoute = null;

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

    // 保证 commit 滑出动画至少 200ms：Navigator 的 reverse 时长 =
    // controller.value（= 1 - progress，剩余动画比例）× controller.duration。
    // 手势滑得远时（progress 接近 1，controller.value 接近 0）剩余动画极短
    // （如 0.09 × 400ms ≈ 36ms）→ "松手后几乎瞬间滑出"。
    // 临时拉长 controller.duration，让 reverse 至少 200ms。
    // （二级返回手势滑得少、剩余 >200ms 时不受影响。）
    if (_routeAnimCtrl != null) {
      final double remain = _routeAnimCtrl!.value;
      final int baseMs = widget.route.transitionDuration.inMilliseconds;
      if (remain > 0.02 && (remain * baseMs).round() < 200) {
        gPiliCommitBaseCtrlDuration = _routeAnimCtrl!.duration;
        _routeAnimCtrl!.duration =
            Duration(milliseconds: (200 / remain).round());
      }
    }

    // 锁定手势最后进度：用 update 阶段记录的 backEvent.progress（官方
    // 语义 = 目标页渐显进度）。⚠️ 不能取 widget.route.animation.value：
    // Pili 自定义 detector 未替换 _PopGestureProxy，animation 是原始
    // controller（value = 1 - progress），取它会把进度锁成 1-progress
    // （≈0.1）→ 目标页 opacity 掉到 0.1 → 返回瞬间露白色背景（闪白）。
    gPredictiveBackCommitProgress = gLastGestureProgress;
    // commit 时锁定全局手势进度：pop 后目标页 opacity = max(progress, oldFade)
    // 兜底，防止 fadeInOldPage 继承前的瞬间黑帧/跳变。
    predictiveBackProgress.value = gLastGestureProgress;
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
    with TickerProviderStateMixin {
  // Constants as per the motion specs
  // https://developer.android.com/design/ui/mobile/guides/patterns/predictive-back#motion-specs
  static const double _kMinScale = 0.90;
  static const double _kDivisionFactor = 20.0;
  static const double _kMargin = 8.0;
  static const double _kYPositionFactor = 0.1;

  /// commit 阶段的独立动画控制器：松手后从手势位置完整滑出屏幕外
  /// （200ms）。不依赖 route 动画的剩余区间——手势滑得远时剩余区间极小
  /// （controller.value 接近 0），用 route 动画驱动位置会被
  /// [_kCommitInterval] clamp 到终点，页面"瞬间消失、动效不见"。
  late final AnimationController _commitCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

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
      // commit 用独立 200ms 控制器（0→1 完整播放），避免 route 动画
      // 剩余区间被 Interval clamp 导致页面瞬间消失。
      _PredictiveBackPhase.commit => _commitCtrl,
      _ => widget.animation,
    };

    _bounceAnimation.parent = switch (widget.phase) {
      // commit 后从手势位置继续缩小滑出（begin=手势最后 bounce，end=1 对应
      // scale 最小 0.9）。官方 begin=0 会在 commit 瞬间跳回完整（scale 1.0）
      // 再缩小，视觉上就是「松手复位」。
      _PredictiveBackPhase.commit => Tween<double>(
        begin: _lastBounceAnimationValue,
        end: 1.0,
      ).animate(_commitCtrl),
      // 非 commit：widget.animation 是 proxy（value=progress），直接用
      // progress 驱动 scale（progress=0 -> 1.0，progress=1 -> 0.9）。
      // ⚠️ 官方用 ReverseAnimation 是假设 animation=controller(1-progress)，
      // 但 proxy 已是 progress，再 Reverse 就变成 1-progress（手势刚开始
      // scale=0.9，滑到底反而恢复 1.0，方向全反）。
      _ => widget.animation,
    };

    _commitAnimation.parent = switch (widget.phase) {
      _PredictiveBackPhase.commit => _commitCtrl,
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
    // 手势中 widget.animation 是官方 _PopGestureProxy（value = 1 - controller =
    // progress，官方代理反向）。但 Pili 自定义 detector 未替换 proxy，
    // widget.animation 是原始 controller（value = 1 - progress），取它会写反
    // （1-progress）→ 目标页 opacity = max(1-progress, ...) 渐隐（动效全反）。
    // 统一用 update 阶段记录的 backEvent.progress（官方语义 = 目标页渐显进度）。
    predictiveBackProgress.value = gLastGestureProgress;
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
      // 松手 commit：独立 200ms 动画从 0→1 完整播放（位置从手势处滑出屏幕外）
      _commitCtrl.forward(from: 0);
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
    _commitCtrl.dispose();
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
