import 'package:PiliPlus/common/widgets/flutter/page/tabs.dart';
import 'package:PiliPlus/common/widgets/gesture/horizontal_drag_gesture_recognizer.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart' hide TabBarView;

Widget tabBarView({
  required List<Widget> children,
  TabController? controller,
}) => TabBarView<CustomHorizontalDragGestureRecognizer>(
  controller: controller,
  physics: clampingScrollPhysics,
  horizontalDragGestureRecognizer: CustomHorizontalDragGestureRecognizer.new,
  children: children,
);

SpringDescription _customSpringDescription() {
  final List<double> springDescription = Pref.springDescription;
  return SpringDescription(
    mass: springDescription[0],
    stiffness: springDescription[1],
    damping: springDescription[2],
  );
}

const clampingScrollPhysics = CustomTabBarViewScrollPhysics(
  parent: ClampingScrollPhysics(),
);

class CustomTabBarViewScrollPhysics extends ScrollPhysics {
  const CustomTabBarViewScrollPhysics({super.parent});

  @override
  CustomTabBarViewScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return CustomTabBarViewScrollPhysics(parent: buildParent(ancestor));
  }

  static final _springDescription = _customSpringDescription();

  @override
  SpringDescription get spring => _springDescription;
}

mixin ReloadMixin {
  late bool reload = false;
}

class ReloadScrollPhysics extends AlwaysScrollableScrollPhysics {
  const ReloadScrollPhysics({super.parent, required this.controller});

  final ReloadMixin controller;

  @override
  ReloadScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return ReloadScrollPhysics(
      parent: buildParent(ancestor),
      controller: controller,
    );
  }

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    if (controller.reload) {
      controller.reload = false;
      return 0;
    }
    return super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
  }
}


/// 禁用 Android 12+ 的 overscroll stretch（列表边界拉伸变形）。
///
/// 滚动到边界时直接钳制停止：不拉伸（避免信息流卡片变形 + 毛玻璃
/// 在拉伸变换下采样异常）、不画光晕（GlowingOverscrollIndicator 在
/// 毛玻璃列表上合成开销大，08-03 实测卡顿）。零额外合成开销。
///
/// [getScrollPhysics] 返回 [ClampingScrollPhysics]：Android 传统"硬停"
/// 手感；[buildOverscrollIndicator] 直接返回 child：不绘制任何指示器。
class NoStretchScrollBehavior extends MaterialScrollBehavior {
  const NoStretchScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const ClampingScrollPhysics();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}
