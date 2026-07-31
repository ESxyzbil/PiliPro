import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get/get_navigation/src/routes/default_transitions.dart';

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

    switch (Get.defaultTransition) {
      case Transition.native:
        if (Platform.isIOS || Platform.isMacOS) {
          return CupertinoRouteTransitionMixin.buildPageTransitions<T>(
            rawRoute,
            context,
            animation,
            secondaryAnimation,
            child,
          );
        }
        return const ZoomPageTransitionsBuilder(
          backgroundColor: Colors.transparent,
        ).buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.cupertino || Transition.cupertinoDialog:
        return CupertinoRouteTransitionMixin.buildPageTransitions<T>(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.leftToRight:
        return SlideLeftTransition.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.downToUp:
        return SlideDownTransition.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.upToDown:
        return SlideTopTransition.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.noTransition:
        return child;

      case Transition.rightToLeft:
        return SlideRightTransition.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.zoom:
        return const ZoomPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.fadeIn:
        return FadeInTransition.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.rightToLeftWithFade:
        return RightToLeftFadeTransition.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.leftToRightWithFade:
        return LeftToRightFadeTransition.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.size:
        return SizeTransitions.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.fade:
        return const FadeUpwardsPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.topLevel:
        return const ZoomPageTransitionsBuilder().buildTransitions(
          rawRoute,
          context,
          animation,
          secondaryAnimation,
          child,
        );

      case Transition.circularReveal:
        return CircularRevealTransition.buildTransitions(
          context,
          animation,
          secondaryAnimation,
          child,
        );
    }
  }
}

