import 'dart:ui' show clampDouble;

import 'package:PiliPlus/common/widgets/flutter/build_page_transition.dart';
import 'package:PiliPlus/common/widgets/flutter/root_back_gesture_observer.dart'
    show
        gTabBackCommitProgress,
        gTabBackCurrentEvent,
        gTabBackStartEvent,
        tabBackGestureProgress;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SwipeEdge;

/// 标签页切换过渡动画（复用项目统一的过渡动画实现
/// buildPiliPageTransition——即用户设置里的"页面过渡动画"，与普通路由
/// 页面完全一致）。
///
/// 新标签（变为当前）播放进入动画，旧标签（不再是当前）播放退出动画，
/// 其余页面保持透明不可见。所有标签页在 Stack 中保活，仅动画包裹层切换，
/// 页面实例不销毁。
///
/// 预测性返回（侧滑手势，完整复刻路由页面的
/// _PredictiveBackSharedElementPageTransition）：
/// - 手势跟手：当前标签随手势 scale 1→0.9、X 位移 ±(w/20-8)*progress
///   （方向随 swipeEdge：左边缘→右移、右边缘→左移）、Y 位移
///   （随触摸点纵移 easeOut，±(h/20-8)）、圆角 0→32；
/// - 松手 commit：独立 _commitCtrl（200ms）从手势最后位置（_lastDrag）
///   继续滑出屏幕外（±1.5w），scale 从手势值续到 0.9，opacity 1→0，
///   **原地续播不回弹**；
/// - 手势取消：_bounceCtrl（200ms）从手势位置回弹到完整；
/// - 目标页（关闭后露出的主内容/下一标签）手势中随手势渐显，
///   由 MainApp 传入 [gestureReveal]。
///
/// 注意：
/// 1. 本组件必须带稳定 key（如标签 id）——否则 Stack 中元素按位置匹配，
///    切换时 State 会被重建（走 initState 而非 didUpdateWidget），
///    进入/退出动画不触发；
/// 2. TickerMode 只包 child（页面自身动画随激活暂停），切换动画的
///    AnimationController 不受其影响；
/// 3. [closing] 为 true 时即使 active 仍为 true 也强制播退出动画
///    （reverse）——用于"替换类返回"（如相关视频/分P 替换当前标签后
///    返回恢复来源标签）：来源标签替换回原位前，当前标签先淡出，
///    替换后 key 变化自动播来源页进入动画，与路由 pop/push 体验一致。
class TabTransition extends StatefulWidget {
  const TabTransition({
    super.key,
    required this.active,
    this.closing = false,
    this.gestureReveal = 0.0,
    required this.child,
  });

  /// 是否为当前选中的标签页
  final bool active;

  /// 是否正在关闭（强制播退出动画，即使 active 仍为 true）
  final bool closing;

  /// 预测性返回手势中目标页渐显进度（0-1，非手势时 0）。
  /// 手势跟手时目标页（关闭当前标签后露出的页）随手势渐显，
  /// 与路由 predictiveBackProgress 的语义一致。
  final double gestureReveal;

  final Widget child;

  @override
  State<TabTransition> createState() => _TabTransitionState();
}

class _TabTransitionState extends State<TabTransition>
    with TickerProviderStateMixin {
  // ---- 预测性返回跟手动画参数（与路由 SharedElement 一致）----
  static const double _kMinScale = 0.90;
  static const double _kDivisionFactor = 20.0;
  static const double _kMargin = 8.0;
  static const Duration _kCommitDuration = Duration(milliseconds: 200);
  static const Duration _kCancelDuration = Duration(milliseconds: 200);
  static const double _kDeviceBorderRadius = 32.0;

  /// 标签切换动画（进入/退出）
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );

  /// 预测性返回 commit 动画：松手后从手势位置原地续播滑出（200ms）
  late final AnimationController _commitCtrl = AnimationController(
    vsync: this,
    duration: _kCommitDuration,
  );

  /// 预测性返回 cancel 回弹动画（200ms）
  late final AnimationController _bounceCtrl = AnimationController(
    vsync: this,
    duration: _kCancelDuration,
  );

  /// 手势最后位移（commit 续播起点；跟手阶段每帧记录）
  Offset _lastDrag = Offset.zero;

  /// 手势最后 scale 值（bounce，0-1；commit 从该值续到 1）
  double _lastBounce = 0.0;

  /// commit 滑出方向：左边缘手势（向右滑）→ 右移出屏 +1；右边缘 → -1
  double _commitSign = 1.0;

  late bool _active = widget.active;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      _controller.forward(from: 0);
    } else {
      _controller.value = 0;
    }
    tabBackGestureProgress.addListener(_onGestureProgress);
    // commit 动画播完：页面保持完全透明（等待 450ms 后真正移除），
    // 并清零手势残留（防下次普通切换误判为手势 commit）。
    // ⚠️ 清零必须等动画播完：commit 动画期间 _lastDrag/_lastBounce 是
    // 续播起点（从手势位置原地滑出），提前清零会闪现回原位再飞出。
    _commitCtrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _lastBounce = 0.0;
        _lastDrag = Offset.zero;
        if (mounted) {
          _controller.value = 0.0;
          setState(() {});
        }
      }
    });
    // cancel 回弹播完：清零手势残留，防止下次普通切换误判为手势 commit
    _bounceCtrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _lastBounce = 0.0;
        _lastDrag = Offset.zero;
      }
    });
  }

  /// 手势进度变化：跟手阶段 setState 实时重建；
  /// progress 归 0 且非 commit（observer 已清 gTabBackCommitProgress）→
  /// 是取消：从手势位置回弹到完整。
  void _onGestureProgress() {
    final double p = tabBackGestureProgress.value;
    if (p <= 0.001 && _lastBounce > 0.001 && gTabBackCommitProgress < 0 &&
        !_commitCtrl.isAnimating) {
      _bounceCtrl.forward(from: 0);
    }
    if (mounted) setState(() {});
  }

  /// 跟手 Y 位移：随触摸点纵移（currentTouchY - startTouchY），
  /// easeOut 曲线，clamp ±(h/20-8)。与路由 _getYShiftPosition 一致。
  double _getYShiftPosition(double screenHeight) {
    final double startTouchY = gTabBackStartEvent?.touchOffset?.dy ?? 0;
    final double currentTouchY = gTabBackCurrentEvent?.touchOffset?.dy ?? 0;
    final double yShiftMax = (screenHeight / _kDivisionFactor) - _kMargin;
    final double rawYShift = currentTouchY - startTouchY;
    final double easedYShift =
        Curves.easeOut.transform(clampDouble(rawYShift.abs() / screenHeight, 0.0, 1.0)) *
        rawYShift.sign *
        yShiftMax;
    return clampDouble(easedYShift, -yShiftMax, yShiftMax);
  }

  /// 手势方向：start 事件 swipeEdge 决定（左边缘→右移 +1，右边缘→左移 -1）
  double get _swipeSign =>
      gTabBackStartEvent?.swipeEdge == SwipeEdge.right ? -1.0 : 1.0;

  /// 计算跟手位移（X = ±xShift*progress，Y = 触摸点纵移）
  Offset _gestureOffset(Size size, double progress) {
    final double xShift = (size.width / _kDivisionFactor) - _kMargin;
    return Offset(_swipeSign * xShift * progress, _getYShiftPosition(size.height));
  }

  /// 预测性返回跟手/commit/cancel 的视觉变换包裹（复刻 SharedElement）：
  /// scale + translate + ClipRRect 圆角 + opacity。
  Widget _wrapGesture(
    BuildContext context,
    Widget child, {
    required double scale,
    required Offset offset,
    required double radius,
    required double opacity,
  }) {
    return Transform.scale(
      scale: scale,
      child: Transform.translate(
        offset: offset,
        child: Opacity(
          opacity: opacity,
          child: ClipRRect(
            borderRadius: MediaQuery.displayCornerRadiiOf(context) ??
                BorderRadius.circular(radius),
            child: child,
          ),
        ),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant TabTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != _active) {
      _active = widget.active;
      if (widget.active) {
        // 进入：若刚发生手势 commit（目标页从手势位置续播渐显）。
        // ⚠️ gTabBackCommitProgress 专供进入方使用——退出方（当前标签）
        // 用 _lastDrag/_lastBounce 原地续播，两者不竞争同一个值。
        if (gTabBackCommitProgress >= 0) {
          _controller.value = gTabBackCommitProgress;
          gTabBackCommitProgress = -1.0;
          _controller.forward();
        } else {
          _controller.forward(from: 0);
        }
      } else {
        // 退出：手势 commit（预测性返回，_lastBounce 记录了手势位置）
        // → 从手势位置原地续播滑出；否则普通 reverse（切换动画）
        if (_lastBounce > 0.001) {
          _startCommit();
        } else {
          _controller.reverse();
        }
      }
    } else if (widget.closing && !oldWidget.closing) {
      // active 未变化但被标记关闭（替换类返回）：同样区分手势 commit
      if (_lastBounce > 0.001) {
        _startCommit();
      } else {
        _controller.reverse();
      }
    }
  }

  /// 手势 commit：从手势最后位置（_lastDrag）原地续播滑出屏幕外。
  /// ⚠️ commit 方向 = 跟手位移方向（_lastDrag.dx < 0 → 向左飞，否则向右飞），
  /// 与原版 SharedElement 的 `(_lastDrag.dx < 0 ? -1.0 : 1.0)` 一致。
  /// 不能用 gTabBackStartEvent.swipeEdge：observer 在 handleCommitBackGesture
  /// 里调用 handleBack() 之前已清空全局事件，commit 时读到 null 会退化为
  /// 默认 +1.0 → 固定向右飞（用户实测反馈）。
  /// ⚠️ 不能在这里清零 _lastDrag/_lastBounce：commit 动画（build 分支）
  /// 用它们作为续播起点，立即清零会导致页面从原位+完整大小开始飞出
  /// （闪现回原位再飞出，用户实测反馈）。清零移到 commit 动画播完的
  /// completed 回调里。
  void _startCommit() {
    _commitSign = _lastDrag.dx < 0 ? -1.0 : 1.0;
    _commitCtrl.forward(from: 0);
  }

  @override
  void dispose() {
    tabBackGestureProgress.removeListener(_onGestureProgress);
    _commitCtrl.dispose();
    _bounceCtrl.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ---- 预测性返回手势视觉（优先级高于切换动画）----
    final double progress = tabBackGestureProgress.value;
    final Size size = MediaQuery.sizeOf(context);
    final double commitV = _commitCtrl.isAnimating ? _commitCtrl.value : -1.0;
    final double bounceV = _bounceCtrl.isAnimating ? _bounceCtrl.value : -1.0;

    // 1) commit：从手势位置原地续播（scale 续到 0.9、位移续到 ±1.5w、淡出）
    if (commitV >= 0) {
      return AnimatedBuilder(
        animation: _commitCtrl,
        builder: (context, _) {
          final double v = _commitCtrl.value;
          final double b = _lastBounce + (1.0 - _lastBounce) * v;
          final double s = 1.0 - (1.0 - _kMinScale) * b;
          final double x =
              _lastDrag.dx + (_commitSign * size.width * 1.5 - _lastDrag.dx) * v;
          return _wrapGesture(
            context,
            widget.child,
            scale: s,
            offset: Offset(x, _lastDrag.dy),
            radius: _kDeviceBorderRadius * b,
            opacity: 1.0 - v,
          );
        },
      );
    }

    // 2) cancel 回弹：从手势位置回弹到完整
    if (bounceV >= 0) {
      return AnimatedBuilder(
        animation: _bounceCtrl,
        builder: (context, _) {
          final double v = _bounceCtrl.value;
          final double b = _lastBounce * (1.0 - v);
          final double s = 1.0 - (1.0 - _kMinScale) * b;
          return _wrapGesture(
            context,
            widget.child,
            scale: s,
            offset: _lastDrag * (1.0 - v),
            radius: _kDeviceBorderRadius * b,
            opacity: 1.0,
          );
        },
      );
    }

    // 3) 跟手阶段：progress > 0 且是当前标签且非 closing
    if (progress > 0.001 && widget.active && !widget.closing) {
      final double scale = 1.0 - (1.0 - _kMinScale) * progress;
      final Offset offset = _gestureOffset(size, progress);
      _lastDrag = offset;
      _lastBounce = progress;
      return _wrapGesture(
        context,
        widget.child,
        scale: scale,
        offset: offset,
        radius: _kDeviceBorderRadius * progress,
        opacity: 1.0,
      );
    }

    // 4) 普通切换动画（无手势）
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final animation = _controller;
        // 非当前页：动画完成后完全透明；目标页（gestureReveal>0）随手势渐显
        final double baseOpacity = widget.active ? 1.0 : animation.value;
        final double opacity =
            baseOpacity > widget.gestureReveal ? baseOpacity : widget.gestureReveal;
        final animated = buildPiliPageTransition(
          route: null,
          context: context,
          animation: animation,
          secondaryAnimation: kAlwaysDismissedAnimation,
          child: child!,
        );
        return Opacity(opacity: opacity, child: animated);
      },
      child: TickerMode(
        enabled: widget.active,
        child: widget.child,
      ),
    );
  }
}
