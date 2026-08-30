import 'package:PiliPlus/common/widgets/flutter/fade_previous_page_transitions_builder.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get/get_navigation/src/routes/default_transitions.dart';

/// 项目统一的页面过渡动画（依据用户设置 Get.defaultTransition 完整映射
/// 所有 Transition 类型）。供两类场景复用：
/// 1. 路由页面：PiliPredictiveBackPageTransitionsBuilder 的非手势回落
///    （传 route，cupertino/native 走官方/自定义 builder）；
/// 2. 标签页切换：MainApp 的 TabTransition（route 传 null，cupertino/native
///    走等效手写动画，保证与路由页面样式一致）。
///
/// 进入/退出分离：进入动画在 0-60%（视觉 240ms）内完成，退出
/// （pop/切换离开）用 reverseCurve（线性）全程。
Widget buildPiliPageTransition({
  PageRoute<dynamic>? route,
  required BuildContext context,
  required Animation<double> animation,
  required Animation<double> secondaryAnimation,
  required Widget child,
  PageTransitionsBuilder fallbackBuilder =
      const FadePreviousPageTransitionsBuilder(),
}) {
  final Transition? t = Get.defaultTransition;
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
      if (route != null) {
        return CupertinoPageTransitionsBuilder().buildTransitions(
            route, context, entrance, secondaryAnimation, child);
      }
      // 无 route（标签页）：等效 Cupertino 右滑进入
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1.0, 0.0),
          end: Offset.zero,
        ).animate(entrance),
        child: child,
      );
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
      return _buildNativeEquivalent(
        route: route,
        context: context,
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: child,
        fallbackBuilder: fallbackBuilder,
      );
    default:
      return _buildNativeEquivalent(
        route: route,
        context: context,
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: child,
        fallbackBuilder: fallbackBuilder,
      );
  }
}

/// native/默认：有 route 走 fallbackBuilder（FadePrevious），
/// 无 route（标签页）用等效手写淡入上滑，保证样式一致。
Widget _buildNativeEquivalent({
  required PageRoute<dynamic>? route,
  required BuildContext context,
  required Animation<double> animation,
  required Animation<double> secondaryAnimation,
  required Widget child,
  required PageTransitionsBuilder fallbackBuilder,
}) {
  if (route != null) {
    return fallbackBuilder.buildTransitions(
        route, context, animation, secondaryAnimation, child);
  }
  // 等效 FadePrevious：新页淡入 + 轻微上滑（无 route 场景）
  final curved = CurvedAnimation(
    parent: animation,
    curve: const Interval(0.0, 0.6, curve: Curves.easeOutCubic),
    reverseCurve: Curves.easeInCubic,
  );
  return FadeTransition(
    opacity: Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: animation,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOutCubic),
        reverseCurve: Curves.linear,
      ),
    ),
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 0.04),
        end: Offset.zero,
      ).animate(curved),
      child: child,
    ),
  );
}
