import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pb.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/dynamics/result.dart';
import 'package:PiliPlus/pages/article/view.dart';
import 'package:PiliPlus/pages/audio/controller.dart';
import 'package:PiliPlus/pages/audio/view.dart';
import 'package:PiliPlus/pages/video/reply_reply/view.dart'
    show VideoReplyReplyPanel;
import 'package:PiliPlus/pages/video/view.dart';
import 'package:PiliPlus/pages/webview/view.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart'
    show PlPlayerController;
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';

/// 单个标签页条目
class TabItem {
  TabItem({
    required this.id,
    required this.title,
    required this.icon,
    required this.child,
    required this.stateKey,
    this.isVideo = false,
    this.isAudio = false,
    this.videoHeroTag,
    this.arguments,
  });

  /// 唯一 id（用于 IndexedStack 子节点 key 与去重）
  final String id;

  /// 标签标题（连播换源时更新）
  String title;

  /// 标签图标
  final Widget icon;

  /// 标签页内容组件
  final Widget child;

  /// 页面 State 的 GlobalKey（直接挂在页面组件上，用于手动触发 RouteAware 生命周期）
  final GlobalKey stateKey;

  /// 是否为视频页（切走时自动转音频模式）
  final bool isVideo;

  /// 是否为音频页
  final bool isAudio;

  /// 视频页的 heroTag（用于路由级 didPopNext 的"仅当前标签恢复"守卫）
  final String? videoHeroTag;

  /// 打开该标签时的原始参数（横屏切竖屏时用于还原为全屏路由页面）
  final Map? arguments;

  /// 该标签的后台音频播放器（切走后独立续播，不占用全局单例播放器）。
  /// 有值 = 该标签正在后台听视频播放中。
  Player? bgPlayer;

  /// 后台音频源（videoUrl 的音频流），切换/恢复时复用
  String? bgAudioUrl;

  /// 后台音频播放位置（切回标签时写回视频页续播）
  Duration bgPosition = Duration.zero;

  /// 关闭动画进行中（close 后先播退出动画，动画结束才真正移除）
  bool closing = false;

  /// 来源标签：本标签是被"替换当前标签"打开时，被替换掉的旧标签。
  /// 返回（handleBack）时优先恢复来源标签（回到上一个页面）。
  TabItem? source;

  /// 是否被覆盖保活（replaceCurrent 前进时旧标签不销毁，保留为下层
  /// 保活标签）：仍在 Stack 中渲染保活（返回时可直接渐显、无需重建），
  /// 但不在标签条显示、不参与常规切换。返回（恢复）时置 false 重新显示。
  bool hidden = false;

  /// 本次失去 active 是否因"add 新标签覆盖"（页面内打开新标签压上来，
  /// 如收藏夹文件夹→视频）：true 时退出走**纯透明度淡出**（与 covered
  /// 下层一致，无 buildPiliPageTransition 位移动画）；false（用户点
  /// 标签条切换离开）保留滑动退出动画。由 select(viaAdd:) 在切换前
  /// 设置，随后 Obx rebuild 时 MainApp 读取并传给 TabTransition。
  bool fadeExit = false;
}

/// 桌面端多页面标签页控制器（方案 C：侧边标签栏）
class TabHostController extends GetxController {
  static const int maxTabs = 8;

  static TabHostController? get instance =>
      Get.isRegistered<TabHostController>()
      ? Get.find<TabHostController>()
      : null;

  /// 设备当前是否为横向（由 MainApp 按窗口 width >= height 检测，方形屏
  /// 视为横向）。手机端据此显示/隐藏侧边标签栏——**只跟方向走，不绑定
  /// 「横屏适配」设置**（用户实测：手表横屏不显示标签栏，根因是旧写法
  /// 把它与 Pref.useHorizontalLayout 绑定，而该手表横屏适配为关）。
  static bool landscapeMode = false;

  /// 标签页功能是否实际启用：桌面端始终；手机端**始终**（竖屏也走标签，
  /// 竖屏标签栏隐藏、标签内容全屏显示——横竖屏切换只是标签栏显隐，
  /// 不销毁重建页面，避免转化时重载）。
  static bool get tabsEnabled =>
      (PlatformUtils.isDesktop || PlatformUtils.isMobile) && Pref.desktopTabs;

  /// 当前页面是否为「标签承载的二级页」：标签模式已启用，且页面不是
  /// 独立路由（Navigator 无可 pop 路由 → AppBar 不会自动生成返回箭头）。
  /// 这类页面（收藏夹列表/fav_detail 等以标签打开的页）需要显式返回
  /// 按钮（调 handleBack 关标签/回上一级），而非依赖路由自动返回。
  static bool get isTabHostedPage =>
      tabsEnabled &&
      !(Get.key.currentState?.canPop() ?? false) &&
      Get.currentRoute == '/';

  final RxList<TabItem> tabs = <TabItem>[].obs;

  /// 当前选中的标签索引；-1 表示主内容页
  final RxInt currentIndex = (-1).obs;

  /// 标签栏是否展开（桌面悬停 / 手机触控控制）
  final RxBool expanded = false.obs;

  void setExpanded(bool v) {
    if (expanded.value != v) {
      expanded.value = v;
    }
  }

  /// 更新标签标题（连播换源等场景）。
  /// [videoHeroTag] 非空时更新对应视频标签（而非当前标签），避免后台
  /// 标签连播时错误更新别的标签；[audioOid] 非空时仅更新该 oid 对应的
  /// 音频标签（多音频标签并存时各自更新，不能更新所有音频标签）。
  void updateCurrentTabTitle(
    String title, {
    String? videoHeroTag,
    bool isAudio = false,
    int? audioOid,
  }) {
    if (isAudio) {
      // 多音频标签并存时，只更新对应 oid 的标签；无 oid 时不更新
      // （避免一个音频页的切歌/连播串改所有音频标签标题）
      if (audioOid == null) return;
      final id = 'audio_$audioOid';
      for (var i = 0; i < tabs.length; i++) {
        if (tabs[i].isAudio && tabs[i].id == id && tabs[i].title != title) {
          tabs[i].title = title;
          tabs.refresh();
        }
      }
      return;
    }
    int? idx;
    if (videoHeroTag != null) {
      idx = tabs.indexWhere((t) => t.videoHeroTag == videoHeroTag);
    }
    if (idx == null || idx < 0) {
      idx = currentIndex.value;
    }
    if (idx >= 0 && idx < tabs.length) {
      if (tabs[idx].title != title) {
        tabs[idx].title = title;
        tabs.refresh();
      }
    }
  }

  bool get hasTabs => tabs.isNotEmpty;

  /// 可见标签（不含 hidden 保活层）：标签条只显示这些。
  List<TabItem> get visibleTabs =>
      tabs.where((t) => !t.hidden).toList(growable: false);

  /// 打开视频标签页（桌面端由 PageUtils.toVideoPage 调用）
  /// [replaceCurrent] 为 true 时：当前有标签则直接替换当前标签
  /// （相关视频/分P 等"页面内派生"场景，而非新开一页）
  void openVideo(Map arguments, {bool replaceCurrent = false}) {
    final id = 'video_${arguments['aid']}_${arguments['cid']}';
    final title =
        (arguments['title'] as String?) ??
        (arguments['bvid'] as String?) ??
        '视频';
    _open(
      id: id,
      title: title,
      icon: const Icon(Icons.play_circle_outline, size: 16),
      isVideo: true,
      videoHeroTag: arguments['heroTag'] as String?,
      arguments: arguments,
      replaceCurrent: replaceCurrent,
      childBuilder: (key) => VideoDetailPageV(key: key, arguments: arguments),
    );
  }

  /// 打开专栏/文章标签页
  void openArticle({required String id, required String type}) {
    _open(
      id: 'article_${type}_$id',
      title: type == 'read' ? '文章 cv$id' : '专栏 $id',
      icon: const Icon(Icons.article_outlined, size: 16),
      isVideo: false,
      arguments: {'id': id, 'type': type},
      childBuilder: (key) => ArticlePage(key: key, id: id, type: type),
    );
  }

  /// 打开音频页标签页
  /// [replaceCurrent] 为 true 时替换当前标签（视频页内"听音频"场景）
  void openAudio(Map arguments, {bool replaceCurrent = false}) {
    final title =
        (arguments['title'] as String?) ??
        (arguments['bvid'] as String?) ??
        '音频';
    _open(
      id: 'audio_${arguments['oid']}',
      title: title,
      icon: const Icon(Icons.music_note_outlined, size: 16),
      isVideo: false,
      isAudio: true,
      arguments: arguments,
      replaceCurrent: replaceCurrent,
      childBuilder: (key) => AudioPage(key: key, arguments: arguments),
    );
  }

  /// 打开内置网页标签页（由 PageUtils.toWebview 调用）。
  /// 同一个 url 复用同一个标签：已存在则切回它，不重复打开。
  void openWebview({required String url, String? userAgent}) {
    final id = 'web_$url';
    _open(
      id: id,
      title: '网页',
      icon: const Icon(Icons.public_outlined, size: 16),
      isVideo: false,
      arguments: {'url': url},
      childBuilder: (key) => WebviewPage(
        key: key,
        url: url,
        tabId: id,
        userAgent: userAgent,
      ),
    );
  }

  /// 按标签 id 更新标题（内容页自己拿到标题时用，如内置网页的
  /// onTitleChanged）。不能复用 updateCurrentTabTitle：后台网页标签
  /// 也要能更新自己的标题，而后者只会改"当前标签"。
  void updateTabTitle(String id, String title) {
    if (title.isEmpty) return;
    final idx = tabs.indexWhere((t) => t.id == id);
    if (idx >= 0 && tabs[idx].title != title) {
      tabs[idx].title = title;
      tabs.refresh();
    }
  }

  /// 打开通用页面标签（搜索/用户主页/收藏夹等）
  void openPage({
    required String id,
    required String title,
    required Widget icon,
    required Widget Function(GlobalKey key) childBuilder,
  }) {
    _open(
      id: id,
      title: title,
      icon: icon,
      isVideo: false,
      childBuilder: childBuilder,
    );
  }

  void _open({
    required String id,
    required String title,
    required Widget icon,
    required bool isVideo,
    bool isAudio = false,
    String? videoHeroTag,
    Map? arguments,
    bool replaceCurrent = false,
    required Widget Function(GlobalKey key) childBuilder,
  }) {
    // 只对可见标签去重（hidden 保活层不算"打开的标签"）
    final existing = tabs.indexWhere((t) => !t.hidden && t.id == id);
    if (existing >= 0) {
      select(existing);
      return;
    }
    final key = GlobalKey();
    final item = TabItem(
      id: id,
      title: title,
      icon: icon,
      isVideo: isVideo,
      isAudio: isAudio,
      videoHeroTag: videoHeroTag,
      arguments: arguments,
      stateKey: key,
      child: childBuilder(key),
    );
    // 替换当前标签（相关视频/听音频等页面内派生操作）
    if (replaceCurrent && currentIndex.value >= 0) {
      if (kDebugMode) {
        debugPrint('_open replaceCurrent idx=${currentIndex.value} id=$id');
      }
      _replaceTab(currentIndex.value, item);
      return;
    }
    if (kDebugMode) {
      debugPrint('_open add new tab id=$id curIdx=${currentIndex.value}');
    }
    // 插入位置（用户需求：新标签插在"上一个页面"之后，而不是追加到末尾）：
    // - 当前有标签：插入到当前标签之后（父子相邻，标签顺序与浏览路径一致，
    //   返回时关掉本标签即回到来源页；标签条上也紧挨着来源页）
    // - 当前是主内容（currentIndex == -1）：插入到最前面（第一个标签位）
    final int cur = currentIndex.value;
    if (cur >= 0 && cur < tabs.length) {
      tabs.insert(cur + 1, item);
      select(cur + 1, viaAdd: true);
    } else {
      tabs.insert(0, item);
      select(0, viaAdd: true);
    }
  }

  /// 用新标签替换指定位置的旧标签——旧标签**保活为下层**（不销毁，
  /// 标记 hidden：仍在 Stack 渲染保活、标签条不显示）。返回时旧标签
  /// 作为下层被 currentIndex 切回，直接渐显无需重建（与主页渐显同机制，
  /// 避免"来源页销毁重建 → 重播完整进入动画"）。
  void _replaceTab(int index, TabItem newTab) {
    if (kDebugMode) {
      debugPrint(
        '_replaceTab idx=$index old=${index < tabs.length ? tabs[index].id : "OOB"} new=${newTab.id}',
      );
    }
    final old = tabs[index];
    // 来源链：返回时恢复到被覆盖的下层（old 自身保活，逐层返回）
    newTab.source = old;
    // 旧标签保活为下层：不销毁、隐藏（标签条不显示）。
    // ⚠️ 必须立即 _notifyHide(old)：被覆盖的 A 要**完全暂停**（等同 opaque
    // 下层被遮挡时不渲染不播放）——否则 A 的视频一直播放、有声音
    // （用户实测"A 会保持在那里甚至一直播放有声音"）。autoAudio:false
    // 防止触发"切走转后台音频"（用户正在 B 上，不是主动切走）。
    _notifyHide(old, autoAudio: false);
    old.hidden = true;
    // 旧标签若正在后台听视频则停止（保活层不播放）
    _stopBgAudio(old);
    old.bgPlayer?.dispose();
    old.bgPlayer = null;
    // 新标签插入旧标签之后（下层在上层前，Stack 顺序正确）
    tabs.insert(index + 1, newTab);
    tabs.refresh();
    currentIndex.value = index + 1;
    _notifyShow(newTab);
    // 防御：确保 currentIndex 仍指向可见标签
    ensureValidCurrent();
    if (kDebugMode) {
      debugPrint('_replaceTab done now=${tabs.length} tabs cur=$currentIndex');
    }
  }

  /// 判断某个视频 heroTag 对应的标签是否为当前选中的标签。
  /// 非标签模式（无此标签）视为活跃，保持路由模式原有行为。
  bool isActiveVideoTab(String? heroTag) {
    if (heroTag == null) return true;
    final tabIndex = tabs.indexWhere((t) => t.videoHeroTag == heroTag);
    if (tabIndex < 0) return true;
    return currentIndex.value == tabIndex;
  }

  /// 选中标签；-1 表示切回主内容页。hidden（被覆盖保活）层不可选。
  /// [viaAdd] 为 true 表示本次选中由"add 新标签覆盖"触发（页面内打开
  /// 新页压上来，如收藏夹→视频）：被顶掉的旧标签退出走**纯透明度淡出**
  /// （等同 covered 下层），而不是标签条切换的滑动退出动画。
  void select(int index, {bool viaAdd = false}) {
    if (index < -1 || index >= tabs.length) return;
    if (index >= 0 && tabs[index].hidden) return;
    // 复活：选中仍在关闭动画中(closing)的标签（450ms 移除定时器触发前
    // 用户又点它/再次打开同 id）——取消关闭、允许重新激活。否则残留
    // closing/commitFinished 会让页面透明或稍后被定时器误删。
    if (index >= 0 && tabs[index].closing) {
      tabs[index].closing = false;
      tabs.refresh();
    }
    final old = currentIndex.value;
    if (old == index) return;
    if (old >= 0 && old < tabs.length) {
      tabs[old].fadeExit = viaAdd;
      _notifyHide(tabs[old]);
    }
    currentIndex.value = index;
    if (index >= 0) {
      // 重新成为当前：清除 fadeExit 残留（下次被切走时走滑动退出，
      // 除非再次被 viaAdd 顶掉）
      tabs[index].fadeExit = false;
      _notifyShow(tabs[index]);
    }
  }

  /// 切回主内容页
  void selectMain() => select(-1);

  /// 关闭 [index] 后应显示的标签：按标签条**显示顺序**取它前面的最近一个
  /// **可见**标签；不存在（它是第一个可见标签，或前面全是 hidden 保活层）
  /// 则返回 -1（主内容页）。
  /// ⚠️ 用户需求：当前标签被销毁时回到列表顺序上的「前一个标签」，
  /// **不回退到后面的标签**。必须跳过 hidden 保活层——hidden 层按 covered
  /// 渲染（opacity 0 + Offstage），若 currentIndex 落在它上面会「整个页面
  /// 空白」（用户实测：关闭某个页面后不进入任何标签页、整页空白）；也必须
  /// 排除被关闭标签自身（否则 currentIndex 不变、退出动画不触发）。
  int _visibleNeighborForClose(int index) {
    for (var i = index - 1; i >= 0; i--) {
      if (!tabs[i].hidden) return i;
    }
    return -1;
  }

  /// 离 [from] 最近的可见（非 hidden）标签索引（先左后右）；无则 -1。
  int nearestVisibleIndex(int from) {
    if (tabs.isEmpty) return -1;
    final start = from < 0 ? 0 : (from >= tabs.length ? tabs.length - 1 : from);
    for (var d = 0; d < tabs.length; d++) {
      final left = start - d;
      if (left >= 0 && !tabs[left].hidden) return left;
      final right = start + d;
      if (right < tabs.length && !tabs[right].hidden) return right;
    }
    return -1;
  }

  /// 保证 currentIndex 恒为合法值：-1（主内容页）或指向**可见**标签。
  /// ⚠️ 任何改动 tabs（移除/插入/隐藏）之后都必须调用：否则 currentIndex
  /// 可能落在 hidden 保活层（渲染透明 → 整页空白）、越界（Stack 无可见层
  /// → 整页空白）或指向空列表（主内容 opacity 判定失配 → 整页空白）。
  void ensureValidCurrent() {
    final cur = currentIndex.value;
    if (tabs.isEmpty) {
      if (cur != -1) currentIndex.value = -1;
      return;
    }
    final bool visible = cur >= 0 && cur < tabs.length && !tabs[cur].hidden;
    if (visible) return;
    if (cur == -1) {
      // 主内容页：顺手清理孤儿 hidden 层（不再被任何标签的 source 引用）
      _pruneOrphanHidden();
      return;
    }
    // 越界或指向 hidden 层：修正到最近的可见标签；没有可见标签则回主内容
    final fixed = nearestVisibleIndex(cur < 0 ? 0 : cur);
    if (fixed >= 0) {
      currentIndex.value = fixed;
      _notifyShow(tabs[fixed]);
    } else {
      currentIndex.value = -1;
      _pruneOrphanHidden();
    }
  }

  /// 清理"孤儿 hidden 保活层"：hidden 层是 replaceCurrent 前进时被覆盖的
  /// 来源页，正常由后继标签的 source 引用、返回时恢复；若已无任何标签引用
  /// 它（source 链断裂，例如后继标签被直接关闭），它永远不会恢复——属于
  /// 泄漏（占内存、干扰索引计算），直接移除。
  void _pruneOrphanHidden() {
    if (tabs.isEmpty) return;
    final referenced = <TabItem>{};
    for (final t in tabs) {
      final s = t.source;
      if (s != null && s != t) referenced.add(s);
    }
    final orphans = tabs
        .where((t) => t.hidden && !referenced.contains(t))
        .toList();
    if (orphans.isEmpty) return;
    for (final o in orphans) {
      _notifyHide(o, autoAudio: false);
      _stopBgAudio(o);
      o.bgPlayer?.dispose();
      o.bgPlayer = null;
      tabs.remove(o);
    }
    tabs.refresh();
    if (kDebugMode) {
      debugPrint('_pruneOrphanHidden removed=${orphans.length}');
    }
  }

  /// 关闭标签（先播退出动画，动画结束后再暂停页面并真正移除）
  void close(int index) {
    if (index < 0 || index >= tabs.length) return;
    final tab = tabs[index];
    if (tab.closing) return; // 已在关闭动画中
    // 有来源标签（被 replaceCurrent 覆盖保活的下层 A）：返回 = 关闭本标签、
    // 让下层 A 恢复显示（A 一直保活在 tabs 中，active=false 透明；返回时
    // currentIndex 切到 A → TabTransition 从手势位置续播/直接渐显，无需重建，
    // 不重播完整进入动画）。
    if (tab.source != null) {
      final source = tab.source!;
      source.source = null; // 防止返回链循环
      tab.closing = true;
      // 下层来源可能不在 tabs（旧逻辑遗留）：兜底恢复（插入替换）
      if (!tabs.contains(source)) {
        // 原销毁重建路径已废弃；若 source 被移除则直接按普通关闭处理
      }
      tabs.refresh();
      // 若下层来源在 tabs 中且隐藏，先恢复显示（unhidden + 作为当前）
      final int srcIdx = tabs.indexOf(source);
      if (srcIdx >= 0) {
        source.hidden = false;
        // 立即切到来源层（当前标签退出动画与其渐显并行）
        currentIndex.value = srcIdx;
      } else {
        currentIndex.value = index;
      }
      _notifyShow(source);
      // 退出动画结束后：暂停本页 + 真正移除
      // ⚠️ 若期间该标签被复活（select 取消 closing），不再移除
      Future<void>.delayed(const Duration(milliseconds: 450), () {
        if (!tabs.contains(tab) || !tab.closing) return;
        _notifyHide(tab, autoAudio: false);
        final removedAt = tabs.indexOf(tab);
        if (currentIndex.value > removedAt) {
          currentIndex.value--;
        }
        tabs.remove(tab);
        // 移除后统一校验 currentIndex（越界/hidden/空表 → 修正），
        // 否则可能停在 hidden 保活层或空列表 → 整页空白
        ensureValidCurrent();
      });
      return;
    }
    tab.closing = true;
    final wasCurrent = currentIndex.value == index;
    if (wasCurrent) {
      // ⚠️ 不立即 _notifyHide：它会让视频页 didPushNext → videoState=false
      // 立即隐藏画面，退出动画期间页面就"消失"了，看不到淡出效果。
      // 先切走 currentIndex 触发 TabTransition reverse，动画结束后再暂停。
      if (tabs.length <= 1) {
        currentIndex.value = -1;
      } else {
        // 切到最近的**可见**标签（index==0 时切到下一个）。
        // 注意不能用 (index+1).clamp(0, len-1)：关闭最后一个标签时
        // next==index，currentIndex 不变，active 不变 → reverse 不触发，
        // 退出动画根本不会播（用户实测"返回后没有动画，片刻后删除"）。
        // ⚠️ 也不能直接用 index-1/1：左侧邻居可能是 replaceCurrent 保活的
        // hidden 层（covered 渲染 opacity 0）→ 关闭后整页空白（用户实测）；
        // 没有其他可见标签时回主内容页。
        final next = _visibleNeighborForClose(index);
        if (next < 0) {
          currentIndex.value = -1;
        } else {
          currentIndex.value = next;
          _notifyShow(tabs[next]);
        }
      }
    } else {
      // 关闭的是后台标签：停止并销毁其后台音频播放器。
      // ⚠️ 不要在这里改 currentIndex：关闭的标签此刻还在列表里，
      // 提前改动会让 active 判定（i == current+1）失配——当前选中的
      // 标签会错误地淡出又淡入。索引修正统一放到移除后的回调里做。
      _stopBgAudio(tab);
      tab.bgPlayer?.dispose();
      tab.bgPlayer = null;
    }
    // 触发重建：TabTransition active 变 false → reverse 播退出动画
    tabs.refresh();
    // 动画结束后：暂停页面（切走逻辑）+ 真正移除
    // ⚠️ 若期间该标签被复活（select 取消 closing），不再移除
    Future<void>.delayed(const Duration(milliseconds: 450), () {
      if (!tabs.contains(tab) || !tab.closing) return;
      _notifyHide(tab, autoAudio: false);
      // 先修正索引再移除：若当前选中在关闭标签之后，移除后整体左移
      // 一位，currentIndex 同步减一（否则会指向错误的标签，且 Obx
      // 重建时 active 判定失配导致新选中标签先 reverse 再 forward 闪烁）。
      final removedAt = tabs.indexOf(tab);
      if (currentIndex.value > removedAt) {
        currentIndex.value--;
      }
      tabs.remove(tab);
      // 移除后统一校验 currentIndex（越界/hidden/空表 → 修正），
      // 否则可能停在 hidden 保活层（透明）或空列表 → 整页空白
      ensureValidCurrent();
    });
  }

  /// 关闭全部标签（返回主页）
  void closeAll() {
    final current = currentIndex.value;
    // 当前标签播退出动画（延迟暂停+移除），其余立即清掉
    final keep = <TabItem>[];
    for (var i = 0; i < tabs.length; i++) {
      final tab = tabs[i];
      _stopBgAudio(tab);
      tab.bgPlayer?.dispose();
      tab.bgPlayer = null;
      if (i == current && !tab.closing) {
        // 当前标签：不立即 _notifyHide（否则画面立即消失看不到退出
        // 动画），延迟到移除回调里统一暂停
        tab.closing = true;
        keep.add(tab);
      } else {
        _notifyHide(tab, autoAudio: false);
      }
    }
    currentIndex.value = -1;
    if (keep.isEmpty) {
      tabs.clear();
      return;
    }
    // 仅保留当前标签播退出动画，其余立即移除
    final closing = keep.first;
    tabs
      ..clear()
      ..add(closing);
    tabs.refresh();
    Future<void>.delayed(const Duration(milliseconds: 450), () {
      if (tabs.contains(closing)) {
        _notifyHide(closing, autoAudio: false);
        tabs.remove(closing);
      }
    });
  }

  /// 标签模式下处理"返回"语义：非标签模式返回 false（调用方走原 Get.back）。
  /// [closeAll] 为 true 时关闭全部标签（对应"返回主页"）。
  static bool handleBack({bool closeAll = false}) {
    final tc = instance;
    final bool tabMode = tc != null && tabsEnabled;
    // ⚠️ 评论详情 bottom sheet（showBottomSheet 非 modal，不参与 Navigator
    // 路由）打开时：返回键不会自动关闭它，事件会直达这里——先关闭评论
    // 详情，不关标签不退桌面（用户实测：评论区点评论详情后返回直接退桌面）。
    // 再按一次返回才关标签/退桌面。
    if (tabMode && VideoReplyReplyPanel.closeSheet()) {
      return true;
    }
    // "返回主页"（显式按钮意图）：优先于全屏取消，直接关全部标签
    if (closeAll) {
      if (!tabMode) return false;
      tc.closeAll();
      return true;
    }
    // ⚠️ 视频全屏/控制锁/桌面 PIP 的返回优先级（用户需求：全屏播放时返回
    // 应**取消全屏**，而不是退出当前页面/退桌面）。优先级与
    // PlPlayerController.onPopInvokedWithResult 一致：控制锁 → PIP → 全屏。
    // ⚠️ 必须在 tabsEnabled 判定之前：路由模式（非标签）的左上角返回按钮
    // 与预测性返回手势同样经过这里，否则全屏时返回会直接退出页面/退桌面。
    final player = PlPlayerController.instance;
    if (player != null) {
      if (player.controlsLock.value) {
        player.onLockControl(false);
        return true;
      }
      if (player.isDesktopPip) {
        player.exitDesktopPip();
        return true;
      }
      if (player.isFullScreen.value) {
        player.triggerFullScreen(status: false);
        return true;
      }
    }
    if (tc == null) return false;
    // 标签功能未启用（手机竖屏等）时：即使有残留标签也不参与返回
    // （竖屏标签栏隐藏，按返回应退出/走正常路由，而非关残留标签）
    if (!tabsEnabled) return false;
    // ⚠️ 有可 pop 的二级路由（前台全屏页，如通知页/设置页）时：返回应
    // 交给 GetX 正常 pop 该路由，不能关标签——否则前台全屏页与标签页
    // 同时响应返回（用户实测：侧栏开通知页后按返回，通知页和标签页
    // 前台页面同时响应）。标签页不是独立路由（MainApp Stack 内），
    // 有标签但无二级路由时 canPop 仍为 false，不受影响。
    if (Get.key.currentState?.canPop() ?? false) {
      return false;
    }
    // 防御：currentIndex 可能因异常路径落在 hidden 保活层/越界（表现为
    // "整页空白"）——先修正到可见标签或主内容，再决定返回行为
    tc.ensureValidCurrent();
    if (tc.currentIndex.value >= 0) {
      tc.close(tc.currentIndex.value);
      return true;
    }
    return false;
  }

  /// 开标签前确保主界面可见：若当前有二级路由覆盖（搜索/收藏/动态详情等），
  /// 先退回主界面，否则标签开在 MainApp 里被当前路由挡住，
  /// 看起来"页面留在原地、必须手动返回才进入"。
  static void ensureMainVisible() {
    if (Get.currentRoute != '/' && Get.key.currentState?.canPop() == true) {
      Get.until((route) => route.isFirst);
    }
  }

  /// 手机竖屏进入的二级路由页面，横屏后转化为标签页：
  /// 读取当前路由（视频/文章/音频/动态详情）的参数并走对应的标签化入口
  /// （toXxxPage 内部会 ensureMainVisible 退回主界面 + openXxx 开标签）。
  /// 返回是否成功转化（当前确实在可转化的二级路由上）。
  /// 注意：必须延迟到帧后执行（didChangeDependencies 期间不能动 Navigator）。
  static bool adoptCurrentRoute() {
    if (!tabsEnabled) return false;
    final route = Get.currentRoute;
    if (route == '/' || route.isEmpty) return false;
    final arguments = Get.arguments;
    final parameters = Get.parameters;
    final navigator = Get.key.currentState;
    if (navigator == null || !navigator.canPop()) return false;
    switch (route) {
      case '/videoV':
        if (arguments is Map) {
          PageUtils.toVideoPage(
            videoType: (arguments['videoType'] as VideoType?) ?? VideoType.ugc,
            aid: arguments['aid'] as int?,
            bvid: arguments['bvid'] as String?,
            cid: (arguments['cid'] as int?) ?? 0,
            seasonId: arguments['seasonId'] as int?,
            epId: arguments['epId'] as int?,
            pgcType: arguments['pgcType'] as int?,
            cover: arguments['cover'] as String?,
            title: arguments['title'] as String?,
            progress: arguments['progress'] as int?,
            isVertical: arguments['isVertical'] as bool? ?? false,
          );
          return true;
        }
        return false;
      case '/articlePage':
        final id = parameters['id'] ?? (arguments as Map?)?['id'];
        final type = parameters['type'] ?? (arguments as Map?)?['type'];
        if (id != null && type != null) {
          PageUtils.toArticlePage(id: id as String, type: type as String);
          return true;
        }
        return false;
      case '/audio':
        if (arguments is Map) {
          AudioPage.toAudioPage(
            id: arguments['id'] as int?,
            oid: (arguments['oid'] as int?) ?? 0,
            subId: (arguments['subId'] as List?)?.cast<int>(),
            itemType: (arguments['itemType'] as int?) ?? 1,
            from:
                (arguments['from'] as PlaylistSource?) ??
                PlaylistSource.DEFAULT,
            heroTag: arguments['heroTag'] as String?,
            start: arguments['start'] as Duration?,
            audioUrl: arguments['audioUrl'] as String?,
            extraId: arguments['extraId'] as int?,
            title: arguments['title'] as String?,
            cover: arguments['cover'] as String?,
            ownerName: arguments['ownerName'] as String?,
            ownerMid: arguments['ownerMid'] as int?,
            bvid: arguments['bvid'] as String?,
          );
          return true;
        }
        return false;
      case '/dynamicDetail':
        final item = (arguments as Map?)?['item'];
        if (item is DynamicItemModel) {
          PageUtils.pushDynDetail(item);
          return true;
        }
        return false;
    }
    return false;
  }

  /// 手机横屏→竖屏：把当前前台的标签页转化为全屏路由页面
  /// （adoptCurrentRoute 的反向：竖屏无标签栏，当前标签应回到全屏页面）。
  /// 返回是否成功转化；无当前标签或非可转化类型返回 false。
  /// 注意：必须延迟到帧后执行（didChangeDependencies 期间不能动 Navigator）。
  static bool releaseCurrentAsRoute() {
    final tc = instance;
    if (tc == null) return false;
    final index = tc.currentIndex.value;
    if (index < 0 || index >= tc.tabs.length) return false;
    final tab = tc.tabs[index];
    final args = tab.arguments;
    switch (tab.id.split('_').first) {
      case 'video':
        if (args is Map && args['cid'] != null) {
          PageUtils.toVideoPage(
            videoType: (args['videoType'] as VideoType?) ?? VideoType.ugc,
            aid: args['aid'] as int?,
            bvid: args['bvid'] as String?,
            cid: (args['cid'] as int?) ?? 0,
            seasonId: args['seasonId'] as int?,
            epId: args['epId'] as int?,
            pgcType: args['pgcType'] as int?,
            cover: args['cover'] as String?,
            title: args['title'] as String?,
            progress: args['progress'] as int?,
            isVertical: args['isVertical'] as bool? ?? false,
          );
        } else {
          Get.toNamed('/videoV', arguments: args ?? const {});
        }
        break;
      case 'article':
        final id = args?['id'] as String?;
        final type = args?['type'] as String?;
        if (id != null && type != null) {
          PageUtils.toArticlePage(id: id, type: type);
        } else {
          return false;
        }
        break;
      case 'audio':
        if (args is Map) {
          AudioPage.toAudioPage(
            id: args['id'] as int?,
            oid: (args['oid'] as int?) ?? 0,
            subId: (args['subId'] as List?)?.cast<int>(),
            itemType: (args['itemType'] as int?) ?? 1,
            from: (args['from'] as PlaylistSource?) ?? PlaylistSource.DEFAULT,
            heroTag: args['heroTag'] as String?,
            start: args['start'] as Duration?,
            audioUrl: args['audioUrl'] as String?,
            extraId: args['extraId'] as int?,
            title: args['title'] as String?,
            cover: args['cover'] as String?,
            ownerName: args['ownerName'] as String?,
            ownerMid: args['ownerMid'] as int?,
            bvid: args['bvid'] as String?,
          );
        } else {
          return false;
        }
        break;
      case 'dyn':
        final item = args?['item'];
        if (item is DynamicItemModel) {
          PageUtils.pushDynDetail(item);
        } else {
          return false;
        }
        break;
      default:
        // 普通页面标签（搜索/收藏等）无全屏路由对应，不转化
        return false;
    }
    // 转化成功后关闭所有标签（竖屏无标签栏，标签数据不再保留）
    tc.closeAll();
    return true;
  }

  /// 标签页被覆盖：触发 RouteAware.didPushNext（暂停/保存状态）。
  /// 正在播放的视频可选启动该标签的独立后台音频播放器继续播
  /// （对应播放器顶栏更多设置→听视频：只拉音频流，不占用全局单例
  /// 播放器——这样多个标签各自独立播放，互不干扰）。
  void _notifyHide(TabItem tab, {bool autoAudio = true}) {
    final state = tab.stateKey.currentState;
    bool wasPlaying = false;
    if (state is RouteAware) {
      // 在 didPushNext（会暂停）之前判断是否在播放
      if (autoAudio && tab.isVideo && Pref.tabAutoAudio) {
        try {
          final dynamic pc = (state as dynamic).plPlayerController;
          wasPlaying = pc != null && pc.playerStatus.value.isPlaying;
        } catch (_) {}
      }
      (state as RouteAware).didPushNext();
    }
    if (wasPlaying && autoAudio && tab.isVideo && Pref.tabAutoAudio) {
      try {
        final dynamic vc = (state as dynamic).videoDetailController;
        final dynamic pc = (state as dynamic).plPlayerController;
        final dynamic audioUrl = vc?.audioUrl;
        if (audioUrl is String &&
            audioUrl.isNotEmpty &&
            !AudioController.isBackgroundPlaying) {
          // 记录当前播放位置，后台音频从该位置续播
          tab.bgPosition = (pc?.position as Duration?) ?? tab.bgPosition;
          _startBgAudio(tab, audioUrl);
        }
      } catch (_) {
        // 动态访问失败时静默跳过（如页面尚未初始化）
      }
    }
  }

  /// 启动标签的后台音频播放器（独立 media_kit Player，不占用全局播放器）
  Future<void> _startBgAudio(TabItem tab, String audioUrl) async {
    tab.bgAudioUrl = audioUrl;
    try {
      var player = tab.bgPlayer;
      if (player == null) {
        player = await Player.create(
          configuration: PlayerConfiguration(
            options: {'volume-max': '100'},
          ),
        );
        tab.bgPlayer = player;
        player.stream.position.listen((p) => tab.bgPosition = p);
        player.stream.playing.listen((_) => tabs.refresh());
        player.stream.completed.listen((_) => tabs.refresh());
      }
      player.setMediaHeader(
        userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
        headers: {'Referer': 'https://www.bilibili.com'},
      );
      await player.open(
        Media(
          audioUrl,
          start: tab.bgPosition,
        ),
        play: true,
      );
      tabs.refresh();
    } catch (_) {
      // 后台音频启动失败静默（网络异常/URL 失效等）
    }
  }

  /// 停止标签的后台音频播放器（切回前台/关闭标签时调用）
  Future<void> _stopBgAudio(TabItem tab) async {
    final player = tab.bgPlayer;
    if (player == null) return;
    try {
      await player.pause();
    } catch (_) {}
  }

  /// 标签页回到前台：先停止该标签的后台音频（若在播），
  /// 再触发 RouteAware.didPopNext（恢复/续播全局播放器视频）。
  void _notifyShow(TabItem tab) {
    if (tab.isVideo) {
      _stopBgAudio(tab);
      tab.bgAudioUrl = null;
      final state = tab.stateKey.currentState;
      if (state is RouteAware) {
        try {
          final dynamic vc = (state as dynamic).videoDetailController;
          // 把后台音频进度写回视频页，切回时从该位置续播
          if (vc != null && tab.bgPosition > Duration.zero) {
            vc.playedTime = tab.bgPosition;
          }
        } catch (_) {}
        try {
          final dynamic pc = (state as dynamic).plPlayerController;
          pc?.onlyPlayAudio.value = false;
        } catch (_) {}
      }
      tabs.refresh();
    }
    final state = tab.stateKey.currentState;
    if (state is RouteAware) {
      (state as RouteAware).didPopNext();
    }
  }

  /// 某标签是否有正在播放的后台音频（标签条按钮展示真实状态）
  bool isBgPlaying(TabItem tab) {
    final p = tab.bgPlayer;
    if (p == null) return false;
    try {
      return p.state.playing;
    } catch (_) {
      return false;
    }
  }

  /// 标签条播放/暂停按钮：切换该标签的后台音频播放状态
  Future<void> toggleBgPlay(TabItem tab) async {
    final p = tab.bgPlayer;
    if (p == null) return;
    try {
      if (p.state.playing) {
        await p.pause();
      } else {
        await p.play();
      }
      tabs.refresh();
    } catch (_) {}
  }
}
