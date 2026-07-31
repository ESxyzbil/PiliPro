import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get/get_navigation/src/routes/default_transitions.dart';

/// 过渡动画：新页面淡入 + 轻微上滑；旧页面同步淡出。
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
      // 上一页淡出：secondaryAnimation 0→1 时 opacity 1→0
      opacity: Tween<double>(begin: 1.0, end: 0.0).animate(
        CurvedAnimation(
          parent: secondaryAnimation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        ),
      ),
      child: FadeTransition(
        // 新页面淡入
        opacity: Tween<double>(begin: 0.0, end: 1.0).animate(curved),
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

mixin GetPageRouteTransitionMixin<T> on PageRoute<T> {
  ValueNotifier<String?>? _previousTitle;

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
    return buildPageTransitions<T>(
        this, context, animation, secondaryAnimation, child);
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
    switch (Get.defaultTransition) {
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
          // Android: 自定义过渡——新页面淡入+轻微上滑，旧页面同步淡出；
          // 无 scrim 遮罩，不会盖住背景层。
          page = const FadePreviousPageTransitionsBuilder().buildTransitions(
            rawRoute,
            context,
            animation,
            secondaryAnimation,
            child,
          );
        }

      case Transition.cupertino || Transition.cupertinoDialog:
        page = CupertinoRouteTransitionMixin.buildPageTransitions<T>(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.leftToRight:
        page = SlideLeftTransition.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.downToUp:
        page = SlideDownTransition.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.upToDown:
        page = SlideTopTransition.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.noTransition:
        page = child;

      case Transition.rightToLeft:
        page = SlideRightTransition.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.zoom:
        page = const ZoomPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.fadeIn:
        page = FadeInTransition.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.rightToLeftWithFade:
        page = RightToLeftFadeTransition.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.leftToRightWithFade:
        page = LeftToRightFadeTransition.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.size:
        page = SizeTransitions.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.fade:
        page = const FadeUpwardsPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.topLevel:
        page = const ZoomPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.circularReveal:
        page = CircularRevealTransition.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        );
    }
    // 统一：旧页面淡出（对所有过渡效果都生效）。
    // 新页面（最上层）secondaryAnimation 恒为 0，opacity 保持 1 不受影响；
    // 被覆盖的旧页面 secondaryAnimation 0→1，opacity 1→0 淡出。
    return FadeTransition(
      opacity: Tween<double>(begin: 1.0, end: 0.0).animate(
        CurvedAnimation(
          parent: secondaryAnimation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        ),
      ),
      child: page,
    );
  }
}

