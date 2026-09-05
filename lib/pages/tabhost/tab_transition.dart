import 'dart:ui' show clampDouble;

import 'package:PiliPlus/common/widgets/flutter/build_page_transition.dart';
import 'package:PiliPlus/common/widgets/flutter/root_back_gesture_observer.dart'
    show
        gTabBackCommitProgress,
        gTabBackCurrentEvent,
        gTabBackStartEvent,
        tabBackGestureProgress;
import 'package:flutter/foundation.dart' show kDebugMode;
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
    this.covered = false,
    this.fadeExit = false,
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

  /// 是否被上层覆盖保活（replaceCurrent 前进时的下层来源页）：
  /// **始终完整显示**（不因 active 变化播退出/进入动画），被上层标签
  /// 覆盖其上；返回（上层关闭）时直接露出——与路由下层页一致，
  /// 无需重建/渐显（用户实测：前进时 A 播了退出动画、返回时 A 空，
  /// 因为把保活层当普通标签 reverse 隐藏了）。
  final bool covered;

  /// 本次失去 active 是否因"add 新标签覆盖"（viaAdd，如收藏夹文件夹
  /// →视频）：退出走**纯透明度淡出**（200ms，无 buildPiliPageTransition
  /// 位移退场动画），与 covered 下层/路由 opaque 遮挡一致；false 时
  /// （标签条切换/关闭）保留 buildPiliPageTransition 滑动退出。
  final bool fadeExit;

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

  /// 上一帧的 active 快照（供 didUpdateWidget 判定 active 是否变化）。
  /// ⚠️ 不能声明为 `late bool _active = widget.active;`——late 惰性求值：
  /// 它在**首次被读取**时才初始化，而首次读取发生在 didUpdateWidget 的
  /// `widget.active != _active` 比较处，此刻 widget.active 已是新值（false），
  /// 导致 _active 被错误初始化为新值、比较恒 false、普通切换（active
  /// true→false、closing=false）的 reverse 永不触发（下层 opacity 卡 1.0
  /// 透出，用户实测"透过视频页看到收藏夹"）。必须在 initState 显式快照。
  bool _active = false;

  /// 本次失去 active 是否走纯透明度淡出（fadeExit=add 覆盖）。置 true 后
  /// build 用纯 Opacity 而非 buildPiliPageTransition 位移退场。
  bool _fadeExiting = false;

  // ---- 探针（仅调试打印，不改行为）----
  DateTime? _probeLast;

  String get _probeKey {
    final k = widget.key;
    return k is ValueKey<String> ? k.value : '$k';
  }

  void _probe(String tag) {
    if (!kDebugMode) return;
    final now = DateTime.now();
    if (_probeLast != null &&
        now.difference(_probeLast!) < const Duration(milliseconds: 200)) {
      return;
    }
    _probeLast = now;
    debugPrint(
      'TT_P $tag key=$_probeKey covered=${widget.covered} '
      'active=${widget.active} closing=${widget.closing} '
      'ctrl=${_controller.value.toStringAsFixed(3)} '
      'animating=${_controller.isAnimating} commitFin=$_commitFinished',
    );
  }

  @override
  void initState() {
    super.initState();
    // ⚠️ 必须在 initState 立即快照 widget.active（不能靠 late 惰性初始化，
    // 见 _active 字段注释——否则首次读取发生在 didUpdateWidget 时已拿新值）
    _active = widget.active;
    if (widget.covered) {
      // 覆盖保活层初始：透明（等同 opaque 下层不可见），等返回手势渐显
      _controller.value = 0.0;
    } else if (widget.active) {
      // 手势 commit 后重建（source 恢复替换：tabs[index]=source → key 变化
      // → State 重建走 initState）：目标页（来源标签）从手势位置续播进入
      // 动画，而不是从 0 重播（否则"返回松手后目标页又播一次完整进入动画"
      // 跳变，用户实测反馈）。⚠️ gTabBackCommitProgress 专供进入方消费，
      // 退出方（_startCommit）用 _lastDrag 不碰它，两者不竞争。
      if (gTabBackCommitProgress >= 0) {
        _controller.value = gTabBackCommitProgress;
        gTabBackCommitProgress = -1.0;
        _controller.forward();
      } else {
        _controller.forward(from: 0);
      }
    } else {
      _controller.value = 0;
    }
    tabBackGestureProgress.addListener(_onGestureProgress);
    _probe('init');
    // commit 动画播完：页面保持完全透明（等待 450ms 后真正移除），
    // 并清零手势残留（防下次普通切换误判为手势 commit）。
    // ⚠️ 清零必须等动画播完：commit 动画期间 _lastDrag/_lastBounce 是
    // 续播起点（从手势位置原地滑出），提前清零会闪现回原位再飞出。
    _commitCtrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _lastBounce = 0.0;
        _lastDrag = Offset.zero;
        _commitFinished = true;
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
    if (kDebugMode) {
      debugPrint(
        'TT_DU key=$_probeKey '
        'oldAct=${oldWidget.active} newAct=${widget.active} '
        'oldCov=${oldWidget.covered} newCov=${widget.covered} '
        'oldCls=${oldWidget.closing} newCls=${widget.closing} '
        '_active=$_active bounce=$_lastBounce gCommit=$gTabBackCommitProgress '
        'ctrl=${_controller.value.toStringAsFixed(3)} anim=${_controller.isAnimating}',
      );
    }
    // covered（被覆盖保活层）：这是"replaceCurrent 前进后仍留在下层"的页，
    // 不是标签切换。它不应走 buildPiliPageTransition 位移动画（用户明确
    // 不要"A 播放退出过渡动画"），而是**纯透明度**控制：
    // - 刚被覆盖（covered false→true）：透明度快速淡出到 0（controller reverse）
    // - 平时透明（不渲染/不播放，等同 opaque 下层）
    // - 返回手势跟手：gestureReveal 渐显（MainApp 传 gestureP）
    // - 返回松手恢复（covered true→false 且 active）：从手势位置续播到 1
    if (widget.covered != oldWidget.covered) {
      if (widget.covered) {
        // 被覆盖：快速淡出（不进 buildPiliPageTransition 位移）
        _controller.duration = const Duration(milliseconds: 200);
        _controller.reverse();
      } else {
        _controller.duration = const Duration(milliseconds: 400);
        // 解除覆盖（恢复为当前页）：从手势进度续播淡入
        if (gTabBackCommitProgress >= 0) {
          _controller.value = gTabBackCommitProgress;
          gTabBackCommitProgress = -1.0;
          _controller.forward();
        } else {
          _controller.forward();
        }
      }
      _active = widget.active;
      _probe('covered-toggle');
      return;
    }
    if (widget.covered) {
      // 保持覆盖态：不因 active/closing 变化做任何动画（纯由手势渐显）
      _active = widget.active;
      return;
    }
    if (widget.active != _active) {
      _active = widget.active;
      if (widget.active) {
        _fadeExiting = false;
        // 进入：若刚发生手势 commit（目标页从手势位置续播渐显）。
        // ⚠️ gTabBackCommitProgress 专供进入方使用——退出方（当前标签）
        // 用 _lastDrag/_lastBounce 原地续播，两者不竞争同一个值。
        if (gTabBackCommitProgress >= 0) {
          if (kDebugMode) {
            debugPrint('TT enter-from-commit progress=$gTabBackCommitProgress');
          }
          _controller.value = gTabBackCommitProgress;
          gTabBackCommitProgress = -1.0;
          _controller.forward();
        } else {
          _controller.forward(from: 0);
        }
        _probe('active-false-to-true');
      } else {
        // 退出：
        // ① add 覆盖（fadeExit）：纯透明度快速淡出（200ms），
        //    不走 buildPiliPageTransition 位移退场（用户实测：普通
        //    add 前进后下层页播了"退出过渡动画"而不是透明度归 0，
        //    与 covered 下层/路由 opaque 遮挡不一致）。
        // ② 否则：手势 commit（预测性返回，_lastBounce 记录了手势位置）
        //    → 从手势位置原地续播滑出；或普通 reverse（标签条切换）。
        if (widget.fadeExit && !widget.closing && _lastBounce <= 0.001) {
          _fadeExiting = true;
          _controller.duration = const Duration(milliseconds: 200);
          _controller.reverse();
        } else if (_lastBounce > 0.001) {
          _fadeExiting = false;
          _startCommit();
        } else {
          _fadeExiting = false;
          _controller.reverse();
        }
        _probe('active-true-to-false fadeExit=${widget.fadeExit} fadeExiting=$_fadeExiting');
      }
    } else if (widget.closing && !oldWidget.closing) {
      // active 未变化但被标记关闭（替换类返回）：同样区分手势 commit
      if (_lastBounce > 0.001) {
        _startCommit();
      } else {
        if (kDebugMode) {
          debugPrint('TT closing no-gesture reverse');
        }
        _controller.reverse();
      }
    }
  }

  /// commit 动画是否已完成（完成后保持完全透明，等待 450ms 后标签被移除/
  /// 替换——否则 active 仍 true 时普通分支 opacity=1.0 会闪回完整页面，
  /// 用户实测"被返回页播完动画又出现"）
  bool _commitFinished = false;

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
    if (kDebugMode) {
      debugPrint(
          'TT startCommit drag=$_lastDrag bounce=$_lastBounce sign=$_commitSign');
    }
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
    // ---- 覆盖保活层（replaceCurrent 前进后留在下层的 A）----
    // 纯透明度控制（用户需求）：点 B 时 A 快速淡出到 0（不播位移动画）；
    // 返回手势跟手时 gestureReveal 渐显；松手后 controller 续播到 1。
    // 透明时 Offstage 摘除（不渲染/不播放/纹理不合成，等同 opaque 下层）。
    // fadeExiting（普通 add 覆盖的下层，viaAdd）同样走纯透明度淡出，
    // 视觉与 covered 一致（用户实测：add 前进后下层播了 buildPiliPageTransition
    // 位移退场动画而非透明度归 0，要求统一为透明度淡出）。
    if (widget.covered || _fadeExiting) {
      return AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final double v = _controller.value;
          // 手势跟手渐显：跟手值取手势进度；松手恢复由 controller 续播
          final double opacity =
              widget.gestureReveal > v ? widget.gestureReveal : v;
          Widget result = Opacity(opacity: opacity, child: child);
          if (opacity <= 0.001 && !_controller.isAnimating) {
            // 完全透明且动画已停：offstage 摘除（媒体纹理不合成）
            result = Offstage(offstage: true, child: result);
          }
          _probe('covered-build v=$v gesture=${widget.gestureReveal} '
              'opacity=$opacity offstage=${opacity <= 0.001 && !_controller.isAnimating}');
          return result;
        },
        child: TickerMode(
          enabled: widget.active || widget.gestureReveal > 0.001,
          child: widget.child,
        ),
      );
    }

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

    // 4) 普通切换动画（无手势、非覆盖层）
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final animation = _controller;
        // commit 动画已完成：保持完全透明（等待 450ms 后被移除/替换）——
        // 否则 active 仍 true 时 baseOpacity=1.0 会闪回完整页面
        final bool hidden = _commitFinished;
        // 非当前页：动画完成后完全透明；目标页（gestureReveal>0）随手势渐显
        final double baseOpacity =
            hidden ? 0.0 : (widget.active ? 1.0 : animation.value);
        final double opacity =
            baseOpacity > widget.gestureReveal ? baseOpacity : widget.gestureReveal;
        final animated = buildPiliPageTransition(
          route: null,
          context: context,
          animation: animation,
          secondaryAnimation: kAlwaysDismissedAnimation,
          child: child!,
        );
        _probe('norm-build v=${animation.value} base=$baseOpacity '
            'opacity=$opacity gesture=${widget.gestureReveal} hidden=$hidden');
        return Opacity(opacity: opacity, child: animated);
      },
      child: TickerMode(
        enabled: widget.active,
        child: widget.child,
      ),
    );
  }
}
