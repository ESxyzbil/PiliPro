import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:PiliPlus/pages/tabhost/tab_controller.dart' show TabHostController;
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 标签页打开时的「封面飞行」参数：由源列表页构造，交给标签宿主执行。
///
/// 背景：标签页是根路由 '/' 内的 Stack（无嵌套 Navigator、无路由转场），
/// Flutter 的 Hero 动画不会触发；要让"封面移动到目标位置"的观感保留下来，
/// 就用 rootOverlay 手工补一段飞行。
class CoverFlightSpec {
  const CoverFlightSpec({
    required this.from,
    this.fromKey,
    this.destKey,
    this.destRect,
    this.cover,
    this.destVisible,
    this.stripWidthFinal = 0,
    this.square = false,
    this.destAliveKey,
    this.returnFlight = false,
    this.duration = const Duration(milliseconds: 400),
  }) : assert(destKey != null || destRect != null);

  /// 本次打开**最终**会占用的标签栏宽度（0 = 本次不影响内容区布局）。
  /// 由点击时按“标签栏显示条件 + 是否已有标签 + 当前展开态”算出，
  /// 飞行据此把终点一次算准（当前宽度实时读取，见 CoverFlight.stripLiveWidth）。
  final double stripWidthFinal;

  /// 目标是否为矩形（打开视频时播放器是矩形，飞行中的封面也去圆角）
  final bool square;

  /// 目标页“存活锚点”：该 key 的 context 消失即代表目标页已关闭。
  /// 不能用 _measure() 判断——视频目标的测量链带兜底公式，永远测得到矩形，
  /// 于是“目标消失”永远不成立，打断回位从不触发（实测踩过）。
  final GlobalKey? destAliveKey;

  /// 是否为“归位”飞行（关闭页面时从落点飞回源封面）：无需等目标出现
  final bool returnFlight;

  /// 源封面所挂的 GlobalKey（有则起飞时**重新测量**源矩形）：
  /// 打开标签会让标签栏出现并整体横移，点击时记下的源矩形可能已过期。
  final GlobalKey? fromKey;

  /// 源封面在屏幕上的矩形（由源页面 localToGlobal 取到）
  final Rect from;

  /// 目标封面所挂的 GlobalKey（目标页把它包在封面上）
  final GlobalKey? destKey;

  /// 或者：动态计算的目标区域（如视频页的播放器区域，没有固定封面部件时用）
  final Rect? Function()? destRect;

  /// 封面地址（飞行过程中显示的那张图）
  final String? cover;

  /// 飞行期间隐藏目标封面、结束时置 true，避免同图重影
  final ValueNotifier<bool>? destVisible;

  /// 飞行时长（与标签转场 400ms 对齐）
  final Duration duration;
}

/// 把封面登记进全局台账：点击跳转时按触点找"被点封面"的精确矩形，
/// 这样任何卡片只要包一层就能获得准确的飞行起点，无需把矩形透传到
/// 每个 toVideoPage / 页面跳转调用点（通解）。
class CoverFlightSource extends StatefulWidget {
  const CoverFlightSource({super.key, required this.child, this.cover});

  final Widget child;

  /// 该封面地址（飞行图用；可为 null）
  final String? cover;

  @override
  State<CoverFlightSource> createState() => _CoverFlightSourceState();
}

class _CoverFlightSourceState extends State<CoverFlightSource> {
  final _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    CoverFlight.sources[_key] = widget.cover;
  }

  @override
  void didUpdateWidget(CoverFlightSource oldWidget) {
    super.didUpdateWidget(oldWidget);
    CoverFlight.sources[_key] = widget.cover;
  }

  @override
  void dispose() {
    CoverFlight.sources.remove(_key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: _key, child: widget.child);
}

/// 封面飞行执行器：插入 rootOverlay，把封面从源矩形补间到目标矩形
/// 飞行动画诊断日志：写入外部存储（发布版 logcat 缓冲小、易被刷掉，
/// 用文件更可靠；adb 可经 /storage/emulated/0/Android/data/（包名）/files 读取）
void _flightLog(String msg) {
  // ignore: avoid_print
  print('[CoverFlight] $msg');
  try {
    File('$downloadPath/flight_debug.log').writeAsStringSync(
      '${DateTime.now().toIso8601String()} $msg\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}

/// 矩形便于读日志的格式化
String _fmtRect(Rect? r) => r == null
    ? 'null'
    : '${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)},'
          '${r.right.toStringAsFixed(1)},${r.bottom.toStringAsFixed(1)}';

/// 封面飞行执行器：插入 rootOverlay，把封面从源矩形补间到目标矩形
abstract final class CoverFlight {
  /// 等待目标封面完成布局的最长时间（目标页可能要先拉数据才渲染封面）
  static const Duration waitLayout = Duration(milliseconds: 900);

  /// 最近一次按下位置：给"没有明确源封面"的入口（点开视频等）做通用兜底，
  /// 从手指位置飞出一张小封面，而不是干脆没有动画。
  static Offset? _lastTap;
  static int _lastTapAt = 0;



  /// 兜底时间窗：只有"刚点完就跳转"才用触点兜底，
  /// 避免连播/播放全部等程序化跳转从很久以前的点击位置飞出。
  /// 取 5s：不少视频卡片要先 await 拿 cid 再跳转，1.2s 会把它们全部筛掉。
  static const int _tapWindowMs = 5000;

  static void onPointerDown(PointerDownEvent event) {
    _lastTap = event.position;
    _lastTapAt = DateTime.now().millisecondsSinceEpoch;

  }

  /// 已登记的封面台账（key -> 封面地址），由 CoverFlightSource 维护
  static final Map<GlobalKey, String?> sources = <GlobalKey, String?>{};

  /// 诊断用：App 根部的 RepaintBoundary（main.dart 的 builder 里挂上），
  /// 飞行落地瞬间与之后各截一帧，用于量“落点 vs 最终位置”的实际差
  static final GlobalKey debugBoundaryKey = GlobalKey();

  /// 标签栏当前（动画中）宽度——实时读它的渲染盒，避免用到过期数值
  static double get stripLiveWidth =>
      rectOf(TabHostController.stripKey.currentContext)?.width ?? 0;

  /// 当前正在进行的飞行若要被打断（返回关页）时的回调；
  /// 由飞行控件在动效期间挂上、落地/归位后清除。
  /// 用确定事件触发，避免“页面已关闭”判据被兜底公式/退场动画拖住。
  static VoidCallback? interruptActive;

  /// 最近一次飞行的源与落点：关闭该页面时用于播放"归位"动画
  static Rect? lastFrom;
  static Rect? lastTo;
  static String? lastCover;
  static bool lastSquare = false;

  /// 关闭带飞行的页面时播放**归位**动画（从落点飞回源封面原位）
  static void playReturn() {
    final from = lastTo;
    final to = lastFrom;
    lastFrom = null;
    lastTo = null;
    if (from == null || to == null || from.isEmpty || to.isEmpty) return;
    if (!Pref.coverFlight) return;
    final overlay = Get.key.currentState?.overlay;
    if (overlay == null) return;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _CoverFlightWidget(
        spec: CoverFlightSpec(
          from: from,
          destRect: () => to,
          cover: lastCover,
          square: lastSquare,
          returnFlight: true,
          duration: const Duration(milliseconds: 300),
        ),
        onDone: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
  }

  /// 截图序号（区分同一次会话里的多次飞行）
  static int _shotSeq = 0;

  /// 当前视频页「播放器盒」的锚点（由视频页在 initState 注册）。
  /// 视频页有竖屏/横屏/分栏等多套布局，盒子的尺寸位置只能实测；
  /// 这样封面飞行的终点在任何布局下都能对准真实播放区域。
  static GlobalKey? videoPlayerKey;

  /// 取走最近一次按下位置（一次点击只兜底一次，避免被程序化跳转复用）
  static Offset? _takeTap() {
    final pos = _lastTap;
    _lastTap = null;
    if (pos == null) return null;
    if (DateTime.now().millisecondsSinceEpoch - _lastTapAt > _tapWindowMs) {
      return null;
    }
    return pos;
  }

  /// 该上下文是否位于当前可见的标签层（隐藏/被覆盖的标签不作候选，
  /// 否则"最近封面"会命中别的标签里同坐标的卡片）
  static bool _visible(BuildContext context) {
    var visible = true;
    context.visitAncestorElements((element) {
      final w = element.widget;
      if ((w is IgnorePointer && w.ignoring) ||
          (w is Opacity && w.opacity == 0)) {
        visible = false;
        return false;
      }
      return true;
    });
    return visible;
  }

  /// 按触点找被点的封面：
  /// ①触点落在封面矩形内 → 直接用它；
  /// ②否则优先取"纵向覆盖触点"（同一行卡片）的最近封面——
  ///   点在卡片任意位置都从该卡封面起飞；
  /// ③再退一步取 220px 内最近封面。
  static ({Rect rect, String? cover, GlobalKey key})? _sourceNear(Offset tap) {
    Rect? sameRow;
    String? sameRowCover;
    GlobalKey? sameRowKey;
    var sameRowDistance = double.infinity;
    Rect? nearest;
    String? nearestCover;
    GlobalKey? nearestKey;
    var nearestDistance = double.infinity;
    for (final entry in sources.entries) {
      final context = entry.key.currentContext;
      if (context == null || !context.mounted) continue;
      final rect = rectOf(context);
      if (rect == null || !_visible(context)) continue;
      if (rect.contains(tap)) {
        return (rect: rect, cover: entry.value, key: entry.key);
      }
      final distance = (rect.center - tap).distance;
      if (rect.top <= tap.dy &&
          rect.bottom >= tap.dy &&
          distance < sameRowDistance) {
        sameRowDistance = distance;
        sameRow = rect;
        sameRowCover = entry.value;
        sameRowKey = entry.key;
      } else if (distance < nearestDistance && distance < 220) {
        nearestDistance = distance;
        nearest = rect;
        nearestCover = entry.value;
        nearestKey = entry.key;
      }
    }
    if (sameRow != null) {
      return (rect: sameRow, cover: sameRowCover, key: sameRowKey!);
    }
    return nearest == null
        ? null
        : (rect: nearest, cover: nearestCover, key: nearestKey!);
  }

  /// 解析封面飞行的起点：
  /// ①调用方给的矩形 ＞ ②触点命中的已登记封面 ＞ ③触点兜底小矩形
  static ({Rect rect, String? cover, GlobalKey? key})? resolveSource({
    Rect? from,
    String? cover,
  }) {
    if (from != null) return (rect: from, cover: cover, key: null);
    final tap = _takeTap();
    if (tap == null) return null;
    final hit = _sourceNear(tap);
    if (hit != null) return (rect: hit.rect, cover: cover ?? hit.cover, key: hit.key);
    return (
      rect: Rect.fromCenter(center: tap, width: 120, height: 68),
      cover: cover,
      key: null,
    );
  }

  /// 取某上下文对应渲染盒的屏幕矩形（用于取源封面位置）
  ///
  /// findRenderObject 会向下找最近一个挂载了 RenderObject 的子元素，
  /// 因此把 key/Builder 放在封面外层即可拿到封面本身的矩形。
  /// 注意换算到 **rootOverlay 的坐标系**：overlay 里的 Positioned 用的是
  /// overlay 局部坐标，而 localToGlobal 给的是全局坐标——两者之间若存在
  /// 缩放/平移（PPI 缩放、外层 Transform 等），直接当矩形用会整体偏移。
  static Rect? rectOf(BuildContext? context) {
    if (context == null || !context.mounted) return null;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize || box.size.isEmpty) {
      return null;
    }
    var topLeft = box.localToGlobal(Offset.zero);
    final overlayBox =
        Get.key.currentState?.overlay?.context.findRenderObject() as RenderBox?;
    if (overlayBox != null && overlayBox.attached) {
      topLeft -= overlayBox.localToGlobal(Offset.zero);
    }
    return topLeft & box.size;
  }

  static void play(CoverFlightSpec spec) {
    final visible = spec.destVisible;
    // 动画开关关闭：不做飞行，直接显示目标封面
    if (!Pref.coverFlight) {
      visible?.value = true;
      return;
    }
    final overlay = Get.key.currentState?.overlay;
    if (overlay == null || spec.from.isEmpty) {
      visible?.value = true;
      return;
    }
    visible?.value = false;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) =>
          _CoverFlightWidget(spec: spec, onDone: () => entry.remove()),
    );
    overlay.insert(entry);
  }
}

class _CoverFlightWidget extends StatefulWidget {
  const _CoverFlightWidget({required this.spec, required this.onDone});

  final CoverFlightSpec spec;
  final VoidCallback onDone;

  @override
  State<_CoverFlightWidget> createState() => _CoverFlightWidgetState();
}

class _CoverFlightWidgetState extends State<_CoverFlightWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: widget.spec.duration,
  );
  late final Animation<double> _progress = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.fastOutSlowIn,
  );

  /// 源矩形：能拿到源 key 时会在起飞前**重新测量**（打开标签后标签栏
  /// 出现、内容区整体横移，点击那一刻记下的矩形可能已过期）
  late final Rect _from = widget.spec.from;

  /// 最近一次测到的目标（目标消失后仍保留，供“原路飞回”使用）
  Rect? _lastTo;

  /// 是否已进入“被打断 → 原路飞回”流程
  bool _returning = false;

  /// 诊断用：路径日志节流时间戳
  int _lastPathLogAt = 0;


  /// 封面只按源尺寸绘制一次，飞行中仅由 FittedBox 缩放——
  /// 逐帧用新宽高重建图片会让 CachedNetworkImage 重新解析，出现"闪一下"
  late final Size _baseSize = _from.size.isEmpty
      ? const Size(176, 110)
      : _from.size;
  /// 图片只建一次（尺寸固定），圆角交给外层 ClipRRect 逐帧插值，
  /// 既不会重建图片（避免闪），又能让圆角随动效渐变
  late final Widget _cover = NetworkImgLayer(
    src: widget.spec.cover,
    width: _baseSize.width,
    height: _baseSize.height,
    borderRadius: BorderRadius.zero,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  /// 目标矩形：**每帧重新测量**。标签进场动画期间页面本身仍在位移
  /// （约屏高 4% 的上滑），只测一次会把当时的偏移当成终点，表现为
  /// "起点对、终点总往右下偏"。
  Rect? _measure() {
    final dynamicRect = widget.spec.destRect;
    if (dynamicRect != null) {
      final rect = dynamicRect();
      if (rect != null && !rect.isEmpty) return rect;
    }
    final key = widget.spec.destKey;
    return key == null ? null : CoverFlight.rectOf(key.currentContext);
  }

  /// 终点一次算准：实测目标 ＋ “标签栏尚未把内容区推到位”的差值。
  /// 最终栏宽在**点击时**算好，当前栏宽实时读标签栏自身渲染宽度，
  /// 二者同一帧取，故与动画进行到哪一帧无关；此后终点不再改变。
  Rect _finalTarget(Rect measured) {
    // 直接用**布局自己声明的目标栏宽**（MainApp 写入 stripTargetWidth：
    // 隐藏 0 / 收起 52 / 展开 200），不再由我推测；拿不到才退回 spec 传入值
    final declared = TabHostController.instance?.stripTargetWidth ?? 0;
    final finalWidth = declared > widget.spec.stripWidthFinal
        ? declared
        : widget.spec.stripWidthFinal;
    if (finalWidth <= 0) return measured;
    final delta = finalWidth - CoverFlight.stripLiveWidth;
    return delta.abs() < 0.5 ? measured : measured.translate(delta, 0);
  }

  /// 打断：返回（目标页被关掉）→ 原路飞回起点再消失。
  /// 动效进行中被打断时从当前进度直接反向；已落地（overlay 已移除）后
  /// 被打断时，由 [_aftercare] 重新拉起封面，从落点飞回起点。
  Future<void> _return() async {
    if (_returning) return;
    _returning = true;
    CoverFlight.interruptActive = null;
    _flightLog('interrupted → fly back (progress=${_ctrl.value.toStringAsFixed(2)})');
    // ⚠️ 必须显式给时长：AnimationController 在不给时长时会把时长
    // 按“剩余进度”缩放（animation_controller.dart:661-666），快到终点才
    // 打断时只回退十几毫秒，看着就是"抖一下就没了"。
    try {
      await _ctrl.animateBack(
        0.0,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    } catch (_) {}
    widget.spec.destVisible?.value = true;
    widget.onDone();
  }

  /// 诊断：把当前整屏存成 PNG（外部存储，adb 可读），
  /// 用于对比"落地瞬间"与"最终位置"的实际差
  Future<void> _capture(String tag) async {
    try {
      final boundary = CoverFlight.debugBoundaryKey.currentContext
          ?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null || !boundary.attached) return;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      File('$downloadPath/flight_${CoverFlight._shotSeq}_$tag.png').writeAsBytesSync(
        data.buffer.asUint8List(),
        flush: true,
      );
      _flightLog('capture ${CoverFlight._shotSeq}_$tag ok');
    } catch (e) {
      _flightLog('capture $tag failed: $e');
    }
  }

  Future<void> _run() async {
    if (widget.spec.returnFlight) {
      _lastTo = _measure() ?? _from;
      await _ctrl.forward();
      if (mounted) widget.onDone();
      return;
    }
    // ① 立即起飞：只等目标出现，不做任何“等布局”的前置等待
    final appearDeadline = DateTime.now().add(CoverFlight.waitLayout);
    while (mounted && _measure() == null) {
      if (DateTime.now().isAfter(appearDeadline)) {
        widget.spec.destVisible?.value = true;
        widget.onDone();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    if (!mounted) return;
    // ② 终点**一次算准**（含本次打开会带来的标签栏位移），此后不再改变
    final measured = _measure();
    if (measured == null) {
      widget.spec.destVisible?.value = true;
      widget.onDone();
      return;
    }
    // 起点＝点击那一刻卡片所在原位（不做任何补偿）
    _lastTo = _finalTarget(measured);
    // 记录本次飞行的源与落点：关闭该页面时用于播放“归位”动画
    CoverFlight.lastFrom = _from;
    CoverFlight.lastTo = _lastTo;
    CoverFlight.lastCover = widget.spec.cover;
    CoverFlight.lastSquare = widget.spec.square;
    _flightLog(
      'from=${_fmtRect(_from)}'
      ' measured=${_fmtRect(measured)}'
      ' to=${_fmtRect(_lastTo)}'
      ' stripFinal=${widget.spec.stripWidthFinal.toStringAsFixed(1)}'
      ' stripNow=${CoverFlight.stripLiveWidth.toStringAsFixed(1)}'
      ' content=${_fmtRect(TabHostController.contentRect)}'
      ' square=${widget.spec.square}'
      ' hasDestKey=${widget.spec.destKey != null}',
    );
    // 打断入口①：由 TabHostController.close() 确定触发（最可靠）
    CoverFlight.interruptActive = () => unawaited(_return());
    // 打断监听②：动效途中目标页被关掉（返回）→ 原路飞回起点再消失
    final watchdog = Timer.periodic(const Duration(milliseconds: 16), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      // 目标页关闭的判据：存活锚点消失（而不是"测不到目标矩形"）
      final aliveKey = widget.spec.destAliveKey ?? widget.spec.destKey;
      final alive = aliveKey == null
          ? _measure() == null
          : CoverFlight.rectOf(aliveKey.currentContext) == null;
      if (alive) {
        t.cancel();
        unawaited(_return());
      }
    });
    await _ctrl.forward();
    watchdog.cancel();
    CoverFlight.interruptActive = null;
    if (!mounted || _returning) return;
    _flightLog('end target=${_fmtRect(_measure())}');
    setState(() {});
    await Future<void>.delayed(const Duration(milliseconds: 16));
    widget.spec.destVisible?.value = true;
    widget.onDone();
    // ③ 取证：落地瞬间 + 900ms 各截一帧
    CoverFlight._shotSeq++;
    await _capture('land');
    await Future<void>.delayed(const Duration(milliseconds: 900));
    _flightLog('post+900ms target=${_fmtRect(_measure())}');
    await _capture('after');
  }

  @override
  void dispose() {
    // 兜底：飞行被打断（页面销毁/标签关闭）时也要恢复目标可见，
    // 否则被隐藏的播放器/封面会一直不出现
    widget.spec.destVisible?.value = true;
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, _) {
        // ⚠️ 终点必须在 **builder 内部**读取：AnimatedBuilder 每帧只跑 builder，
        // 不会再跑外层 build，若把 to 算在 build 里，它会停留在"起飞前"那次
        // 构建捕获的旧值（未补偿的 121.3），于是整段动画都飞向错的位置，
        // 直到最后 setState 才"闪现"到正确落点（用户实测原话）。
        final to = _lastTo ?? _measure() ?? _from;
        // 轨迹：曲线 = Material 标准弧线（与普通路由 Hero 同款），直线 = RectTween
        final RectTween tween = Pref.coverFlightCurve
            ? MaterialRectArcTween(begin: _from, end: to)
            : RectTween(begin: _from, end: to);
        final rect = tween.transform(_progress.value) ?? to;
        // 诊断：每 50ms 记一次实际渲染矩形，用于判断是"平滑飞抵"还是"末段闪现"
        if (_ctrl.isAnimating) {
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          if (nowMs - _lastPathLogAt >= 50) {
            _lastPathLogAt = nowMs;
            _flightLog(
              'path p=${_progress.value.toStringAsFixed(2)}'
              ' rect=${_fmtRect(rect)}'
              ' from=${_fmtRect(_from)}'
              ' to=${_fmtRect(to)}',
            );
          }
        }
        // 圆角随动效**渐变**：打开视频时由卡片圆角过渡到播放器直角；
        // 收藏夹/订阅目标保持固定圆角不变
        final radius = widget.spec.square
            ? (BorderRadius.lerp(
                    Style.mdRadius,
                    BorderRadius.zero,
                    _progress.value,
                  ) ??
                  BorderRadius.zero)
            : Style.mdRadius;
        return Positioned.fromRect(
          rect: rect,
          child: IgnorePointer(
            child: FittedBox(
              fit: BoxFit.fill,
              child: ClipRRect(
                borderRadius: radius,
                child: SizedBox(
                  width: _baseSize.width,
                  height: _baseSize.height,
                  child: _cover,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
