import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get/get_navigation/src/routes/default_transitions.dart';
import 'package:PiliPlus/common/widgets/flutter/predictive_back_page_transitions_builder.dart';

/// 过渡动画：新页面淡入 + 轻微上滑；旧页面先淡出。
/// 错开时序：前 50% 旧页淡出（新页透明），后 50% 新页淡入（旧页已透明），
/// 新旧页面不会同时半透明叠加，避免产生白色混合层。
/// 无 scrim 遮罩，过渡期间露出的区域透明，直接透出背景层。
class FadePreviousPageTransitionsBuilder extends PageTransitionsBuilder {
  const FadePreviousPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      // 上一页淡出：前 50% 完成（1→0），后 50% 保持透明
      opacity: Tween<double>(begin: 1.0, end: 0.0).animate(
        CurvedAnimation(
          parent: secondaryAnimation,
          curve: const _ShiftCurve(out: true),
        ),
      ),
      child: FadeTransition(
        // 新页面淡入：前 50% 保持透明，后 50% 0→1
        opacity: Tween<double>(begin: 0.0, end: 1.0).animate(
          CurvedAnimation(
            parent: animation,
            curve: const _ShiftCurve(out: false),
          ),
        ),
        child: SlideTransition(
          // 新页面轻微上滑
          position: Tween<Offset>(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      ),
    );
  }
}

/// 错开时序曲线：
/// - out=false（新页）：前 50% 保持透明，后 50% 淡入到 1
/// - out=true（旧页）：前 50% 淡出到 0，后 50% 保持透明
/// 正反方向天然对称（pop 时新页前段淡出、旧页后段淡入）。
class _ShiftCurve extends Curve {
  const _ShiftCurve({required this.out});

  final bool out;

  @override
  double transformInternal(double t) {
    if (out) {
      if (t >= 0.5) return 0;
      return 1 - Curves.easeOutCubic.transform(t / 0.5);
    }
    if (t <= 0.5) return 0;
    return Curves.easeOutCubic.transform((t - 0.5) / 0.5);
  }
}


/// 包装 GetX 的 static 过渡函数为 PageTransitionsBuilder，
/// 供 PiliPredictiveBackPageTransitionsBuilder 作为 fallback 使用。
class _GetXFallbackBuilder extends PageTransitionsBuilder {
  const _GetXFallbackBuilder(this.fn);

  final Widget Function(
    BuildContext,
    Animation<double>,
    Animation<double>,
    Widget,
  ) fn;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return fn(context, animation, secondaryAnimation, child);
  }
}

/// 无过渡 fallback（Transition.noTransition 用）。
class _NoTransitionBuilder extends PageTransitionsBuilder {
  const _NoTransitionBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}

mixin GetPageRouteTransitionMixin<T> on PageRoute<T> {
  ValueNotifier<String?>? _previousTitle;

  /// 旧页面淡出控制器：被新页覆盖时 1→0 淡出，新页 pop 后 0→1 淡入。
  /// 不依赖 Navigator 驱动的 secondaryAnimation（opaque=false 时不驱动，
  /// 旧页淡出会失效），由 didChangeNext / NavigatorObserver 主动驱动。
  /// 惰性初始化（首次访问时创建），避免 install 链异常导致未初始化崩溃。
  AnimationController? _oldPageFadeCtl;

  /// 旧页淡出动画（供 PiliPredictiveBack fallback 使用，替代 opaque=false
  /// 时失效的 secondaryAnimation）。
  Animation<double> get oldPageFade => _oldPageFade;

  /// 缓存的动画监听器（旧页淡出 + 全局手势进度）。
  /// 在 buildTransitions 里复用同一个实例，避免每次 build 都新建
  /// Listenable.merge 导致 AnimatedBuilder 反复 remove/add listener。
  Listenable? _fadeListenableCached;

  Listenable get _fadeListenable => _fadeListenableCached ??=
      Listenable.merge([_oldPageFade, predictiveBackProgress]);

  AnimationController get _oldPageFade {
    return _oldPageFadeCtl ??= AnimationController(
      vsync: navigator!,
      duration: transitionDuration,
      value: 1.0,
    );
  }

  @override
  void install() {
    super.install();
    _oldPageFadeCtl = AnimationController(
      vsync: navigator!,
      duration: transitionDuration,
      value: 1.0,
    );
  }

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    super.didChangeNext(nextRoute);
    // push 开始：清全局手势状态残留（上次手势/假 start 可能残留，
    // 会让新页挂 SharedElement -> native 预测样式覆盖 fade/zoom 等设置，
    // 也会让旧页 opacity = max(残留, oldFade) 不淡出）。
    gPredictiveBackInProgress = false;
    if (predictiveBackProgress.value > 0.0) {
      predictiveBackProgress.value = 0.0;
    }
    // 记录层级：nextRoute 的下一层是本 route（供手势时找目标页）。
    gRouteBelow[nextRoute] = (this as Route<dynamic>)!;
    // 只有被不透明页面（PageRoute）覆盖时才淡出旧页；
    // PopupRoute（弹窗/回复框）覆盖时旧页保持显示，不触发淡出。
    if (nextRoute is PageRoute) {
      _oldPageFade.animateTo(
        0.0,
        duration: transitionDuration ~/ 2,
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void didPopNext(Route<dynamic> nextRoute) {
    super.didPopNext(nextRoute);
    // 恢复显示：旧页淡入（与 pop 动画同步 450ms，交叉淡化，
    // 否则 215ms 的淡入会被上层页淡出动画遮住看不到）。
    // 预测性返回手势 commit 时：旧页（目标页）在跟手中已随手势渐显到
    // 手势进度，必须继承该进度继续淡入，否则会跳回 0 从头重播（松手复位）。
    // 用 PBDetector 在 commit 同步瞬间锁定的 gPredictiveBackCommitProgress
    // （一次性消费；didPopNext 异步触发时 predictiveBackProgress 已被覆盖）。
    final double gestureProgress = gPredictiveBackCommitProgress;
    print('[PBFadeIn] didPopNext: gp=$gestureProgress '
        'oldFade=${_oldPageFade.value.toStringAsFixed(3)}');
    if (gestureProgress >= 0.0) {
      gPredictiveBackCommitProgress = -1.0;
      if (gestureProgress > 0.0 &&
          gestureProgress < 1.0 &&
          _oldPageFade.value < gestureProgress) {
        _oldPageFade.value = gestureProgress;
      }
    }
    // ⚠️ 不在此复位 predictiveBackProgress（同 fadeInOldPage）：pop 动画期间
    // 目标页 opacity 用 max(progress, oldFade) 兜底，避免黑帧/跳变。
    print('[PBFadeIn] didPopNext after: fade=${_oldPageFade.value.toStringAsFixed(3)}');
    // pop 开始：清全局手势标志，防止 pop 动画期间下层页被
    // SharedElement（gPredictiveBackInProgress 残留）继续包裹锁死
    // （画面「缩小靠右」停在最后帧）。
    gPredictiveBackInProgress = false;
    // ?? 立即清 predictiveBackProgress（不等 450ms 延迟）：pop 动画期间
    // 目标页（fallback 分支）用 secondaryAnimation 淡入，不依赖 progress；
    // 残留 >0 会让 pop 后根页的 SharedElement（假 start）按残留进度渲染
    // 「缩小靠右」。立即清后 targetOpacity = max(0, 1-sec) 正常淡入。
    if (predictiveBackProgress.value > 0.0) {
      print('[PBFadeIn] didPopNext clear progress: '
          '${predictiveBackProgress.value.toStringAsFixed(3)} -> 0');
      predictiveBackProgress.value = 0.0;
    }
    _oldPageFade.animateTo(
      1.0,
      duration: transitionDuration,
      curve: Curves.easeIn,
    );
    // 兜底：动画结束后再确保清零（防其他路径残留）。
    Future<void>.delayed(transitionDuration, () {
      gPredictiveBackInProgress = false;
      if (predictiveBackProgress.value > 0.0) {
        print('[PBFadeIn] didPopNext delayed clear progress: '
            '${predictiveBackProgress.value.toStringAsFixed(3)} -> 0');
        predictiveBackProgress.value = 0.0;
      }
    });
  }

  @override
  void dispose() {
    _oldPageFadeCtl?.dispose();
    _oldPageFadeCtl = null;
    super.dispose();
  }

  /// 被新页覆盖时调用：旧页淡出（前一半时长，与错开时序对齐）。
  /// 由 NavigatorObserver 在 didPush 时驱动（didChangeNext 不可靠）。
  void fadeOutOldPage() {
    if (_oldPageFade.value > 0.0) {
      _oldPageFade.animateTo(
        0.0,
        duration: transitionDuration ~/ 2,
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// 新页被 pop 后调用：旧页淡入恢复。
  void fadeInOldPage() {
    // 预测性返回手势 commit 时：旧页（目标页）在跟手中已随手势渐显到
    // 手势进度，必须继承该进度继续淡入，否则会跳回 0 从头播返回过渡
    // （松手状态丢失）。
    //
    // 注意：didPopNext 是异步触发的，此时 predictiveBackProgress 可能
    // 已被 commit 动画更新到接近 1，因此用 PBDetector 在 commit 同步瞬间
    // 锁定的 gPredictiveBackCommitProgress（一次性消费）。
    final double gestureProgress = gPredictiveBackCommitProgress;
    print('[PBFadeIn] fadeInOldPage: gp=$gestureProgress '
        'oldFade=${_oldPageFade.value.toStringAsFixed(3)}');
    if (gestureProgress >= 0.0) {
      gPredictiveBackCommitProgress = -1.0; // 一次性消费
      if (gestureProgress > 0.0 &&
          gestureProgress < 1.0 &&
          _oldPageFade.value < gestureProgress) {
        _oldPageFade.value = gestureProgress;
      }
    }
    // 目标页已继承手势进度（_oldPageFade），全局 progress 无条件复位，
    // 防止残留 >0 导致下次 push 时本页不淡出。
    predictiveBackProgress.value = 0.0;
    if (_oldPageFade.value < 1.0) {
      _oldPageFade.animateTo(
        1.0,
        duration: transitionDuration,
        curve: Curves.easeIn,
      );
    }
  }

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  /// Whether a pop gesture can be started by the user.
  ///
  /// Returns true if the user can edge-swipe to a previous route.
  ///
  /// Returns false once [isPopGestureInProgress] is true, but
  /// [isPopGestureInProgress] can only become true if [popGestureEnabled] was
  /// true first.
  ///
  /// This should only be used between frames, not during build.
  @override
  bool get popGestureEnabled {
    // If there's nothing to go back to, then obviously we don't support
    // the back gesture.
    if (isFirst) return false;
    // If the route wouldn't actually pop if we popped it, then the gesture
    // would be really confusing (or would skip internal routes),
    // so disallow it.
    if (willHandlePopInternally) return false;
    // support [PopScope]
    if (popDisposition == RoutePopDisposition.doNotPop) return false;
    // Fullscreen dialogs aren't dismissible by back swipe.
    if (fullscreenDialog) return false;
    // If we're in an animation already, we cannot be manually swiped.
    if (!animation!.isCompleted) return false;
    // If we're being popped into, we also cannot be swiped until the pop above
    // it completes. This translates to our secondary animation being
    // dismissed.
    if (!secondaryAnimation!.isDismissed) return false;
    // If we're in a gesture already, we cannot start another.
    if (popGestureInProgress) return false;

    // Looks like a back gesture would be welcome!
    return true;
  }

  /// True if an iOS-style back swipe pop gesture is currently
  /// underway for this route.
  ///
  /// See also:
  ///
  ///  * [isPopGestureInProgress], which returns true if a Cupertino pop gesture
  ///    is currently underway for specific route.
  ///  * [popGestureEnabled], which returns true if a user-triggered pop gesture
  ///    would be allowed.
  @override
  bool get popGestureInProgress => navigator!.userGestureInProgress;

  /// The title string of the previous [CupertinoPageRoute].
  ///
  /// The [ValueListenable]'s value is readable after the route is installed
  /// onto a [Navigator]. The [ValueListenable] will also notify its listeners
  /// if the value changes (such as by replacing the previous route).
  ///
  /// The [ValueListenable] itself will be null before the route is installed.
  /// Its content value will be null if the previous route has no title or
  /// is not a [CupertinoPageRoute].
  ///
  /// See also:
  ///
  ///  * [ValueListenableBuilder], which can be used to listen and rebuild
  ///    widgets based on a ValueListenable.
  ValueListenable<String?> get previousTitle {
    assert(
      _previousTitle != null,
      '''
Cannot read the previousTitle for a route that has not yet been installed''',
    );
    return _previousTitle!;
  }

  /// {@template flutter.cupertino.CupertinoRouteTransitionMixin.title}
  /// A title string for this route.
  ///
  /// Used to auto-populate [CupertinoNavigationBar] and
  /// [CupertinoSliverNavigationBar]'s `middle`/`largeTitle` widgets when
  /// one is not manually supplied.
  /// {@endtemplate}
  String? get title;

  /// Builds the primary contents of the route.
  @protected
  Widget buildContent(BuildContext context);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: buildContent(context),
    );
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    // [build_out88] 完全绕过自定义包装：theme 的 PiliPredictiveBack 手势
    // 跟手 + fallback 内部用本 route 的 oldPageFade（didChangeNext/didPopNext
    // 主动驱动，不依赖 opaque=false 时失效的 secondaryAnimation）做旧页淡出。
    // 不包 mixin 的 FadeTransition（会破坏系统预测返回/卡死）。
    return Theme.of(context).pageTransitionsTheme.buildTransitions(
      this, context, animation, secondaryAnimation, child,
    );
    // ignore: dead_code
    final page = buildPageTransitions<T>(
        this, context, animation, secondaryAnimation, child);
    // 统一错开时序（对所有过渡效果生效）：
    // - 旧页面：前 50% 淡出（1→0），后 50% 保持透明
    // - 新页面：前 50% 保持透明，后 50% 淡入（0→1）
    // 新旧页面不会同时半透明叠加，避免产生白色混合层。
    // 旧页淡出由 _oldPageFade 驱动（didChangeNext/didPopNext），
    // 不依赖 Navigator 的 secondaryAnimation（opaque=false 时不驱动）。
    if (Get.defaultTransition == Transition.noTransition) {
      return page;
    }
    // 旧页淡出：AnimatedBuilder 直接监听 _oldPageFade，
    // 不依赖 drive 代理链，animateTo 时必定重建。
    // 预测性返回手势中额外监听全局手势进度（predictiveBackProgress），
    // 让目标页（本页作为下层页露出时）随手势渐显。
    return AnimatedBuilder(
      // 监听：旧页淡出控制器 + 全局手势进度（目标页渐显）。
      // 不监听手势 animation：手势中当前页恒不透明无需重建，
      // 目标页由 predictiveBackProgress 驱动（缓存实例避免反复 attach）。
      animation: _fadeListenable,
      builder: (context, child) {
        // 预测性返回手势中：
        // - 当前页（isCurrent）：保持完全不透明，跟手滑动交给
        //   PredictiveBack 内部动画，不再叠加 _ShiftCurve 淡入淡出
        //   （否则手势时会出现「先透明→淡入→再淡出」的非单调效果）
        // - 目标页（下层页）：透明度随手势进度单调渐显（0→1）
        // 非手势时：保持原逻辑（_oldPageFade 旧页淡出 + _ShiftCurve 新页淡入）
        // 预测性返回手势中/后：目标页（下层页）随手势进度渐显。
        // 不依赖 popGestureInProgress（ColorOS 时序问题导致 build 时可能
        // 为 false）：predictiveBackProgress 由 PBDetector 直接同步。
        final double gestureProgress = predictiveBackProgress.value;
        // 用全局手势状态兜底：系统首帧 update(progress=0) 会让 route 内部
        // controller 瞬间 completed，userGestureInProgress 被 Flutter 自动
        // 复位 false，导致这里走 else（FadeTransition 反向 -> 当前页透明）。
        // gPredictiveBackInProgress 由 PBDetector 控制（start=true,
        // cancel/commit=false），不随 route 内部状态变化。
        if (gPredictiveBackInProgress || popGestureInProgress) {
          // 目标页 opacity 也取 max(progress, _oldPageFade)：
          // commit 后 didPopNext 已把 progress 复位成 0，但 popGestureInProgress
          // 复位有延迟（userGestureInProgress 下一帧才 false），此时若直接用
          // progress 会跳回 0（松手复位）。用 _oldPageFade（已继承手势进度）
          // 兜底保持。
          // 统一 max：当前页 oldFade=1 -> 1.0；目标页随 progress 渐显；
          // pop 后瞬间（popGestureInProgress 复位延迟）oldFade 已继承手势
          // 进度 -> 不闪 0。
          final double opacity = gestureProgress > _oldPageFade.value
              ? gestureProgress
              : _oldPageFade.value;
          print('[PBGrad] isCurrent=$isCurrent '
              'p=${gestureProgress.toStringAsFixed(3)} '
              'oldFade=${_oldPageFade.value.toStringAsFixed(3)} '
              'sec=${secondaryAnimation.value.toStringAsFixed(3)} '
              'opacity=$opacity');
          return Opacity(opacity: opacity, child: child);
        }
        // 非手势时：目标页在 progress>0（commit 后短暂保持）或 _oldPageFade
        // 淡入期间取较大值，避免跳回 0。
        // isCurrent 在 pop 动画开始时就已变成 true，但 pop 动画还没播完，
        // 目标页必须继续跟随 _oldPageFade 渐显（继承手势进度），否则会瞬间
        // 跳 100%（松手闪一下）。不能用 secondaryAnimation 判断：pop 瞬间
        // proxy 切回 controller 会让它瞬间跳 1.0。
        // - 当前页（isCurrent=true）：opacity = _oldPageFade（pop 中渐显，
        //   正常为 1.0）
        // - 被覆盖页（isCurrent=false）：max(progress, _oldPageFade)
        final double fadeOpacity = isCurrent
            ? _oldPageFade.value
            : (gestureProgress > _oldPageFade.value
                ? gestureProgress
                : _oldPageFade.value);
        print('[PBFade] isCurrent=$isCurrent '
            'sec=${secondaryAnimation.value.toStringAsFixed(3)} '
            'p=${gestureProgress.toStringAsFixed(3)} '
            'oldFade=${_oldPageFade.value.toStringAsFixed(3)} '
            'opacity=$fadeOpacity');
        return Opacity(
          opacity: fadeOpacity,
          child: FadeTransition(
            opacity: Tween<double>(begin: 0.0, end: 1.0).animate(
              CurvedAnimation(
                parent: animation,
                curve: const _ShiftCurve(out: false),
                reverseCurve: const _ShiftCurve(out: false),
              ),
            ),
            child: child,
          ),
        );
      },
      child: page,
    );
  }

  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) {
    // Don't perform outgoing animation if the next route is a
    // fullscreen dialog.

    return (nextRoute is CupertinoRouteTransitionMixin &&
        !nextRoute.fullscreenDialog);
  }

  @override
  void didChangePrevious(Route<dynamic>? previousRoute) {
    final previousTitleString = previousRoute is CupertinoRouteTransitionMixin
        ? previousRoute.title
        : null;
    if (_previousTitle == null) {
      _previousTitle = ValueNotifier<String?>(previousTitleString);
    } else {
      _previousTitle!.value = previousTitleString;
    }
    super.didChangePrevious(previousRoute);
  }

  /// Returns a [CupertinoFullscreenDialogTransition] if [route] is a full
  /// screen dialog, otherwise a [CupertinoPageTransition] is returned.
  ///
  /// Used by [CupertinoPageRoute.buildTransitions].
  ///
  /// This method can be applied to any [PageRoute], not just
  /// [CupertinoPageRoute]. It's typically used to provide a Cupertino style
  /// horizontal transition for material widgets when the target platform
  /// is [TargetPlatform.iOS].
  ///
  /// See also:
  ///
  ///  * [CupertinoPageTransitionsBuilder], which uses this method to define a
  ///    [PageTransitionsBuilder] for the [PageTransitionsTheme].
  static Widget buildPageTransitions<T>(
    PageRoute<T> rawRoute,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Check if the route has an animation that's currently participating
    // in a back swipe gesture.
    //
    // In the middle of a back gesture drag, let the transition be linear to
    // match finger motions.

    final Widget page;
    final navTransition = Get.defaultTransition;
    switch (navTransition) {
      case Transition.native:
        if (Platform.isIOS || Platform.isMacOS) {
          page = CupertinoRouteTransitionMixin.buildPageTransitions<T>(
            rawRoute,
            context,
            animation,
            secondaryAnimation,
            child,
          );
        } else {
          // Android: 预测性返回（系统手势跟手动画）+ 自定义淡入淡出 fallback；
          // 无 scrim 遮罩，不会盖住背景层。
          page = const PredictiveBackPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );
        }

      case Transition.cupertino || Transition.cupertinoDialog:
        page = const PredictiveBackPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.leftToRight:
        page = const PredictiveBackPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.downToUp:
        page = const PredictiveBackPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.upToDown:
        page = const PredictiveBackPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.noTransition:
        page = const PredictiveBackPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.rightToLeft:
        page = const PredictiveBackPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.zoom:
        // backgroundColor 默认是 colorScheme.surface（白色），过渡期间
        // 会在新页下面淡入淡出 scrim，形成「白色半透明层」→ 改透明
        page = const PredictiveBackPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.fadeIn:
        page = const PredictiveBackPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.rightToLeftWithFade:
        page = const PredictiveBackPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.leftToRightWithFade:
        page = const PredictiveBackPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.size:
        page = const PredictiveBackPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.fade:
        page = const PredictiveBackPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.topLevel:
        page = const PredictiveBackPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.circularReveal:
        page = const PredictiveBackPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );
    }
    return page;
  }
}

