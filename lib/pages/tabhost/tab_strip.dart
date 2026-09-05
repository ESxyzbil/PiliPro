import 'package:PiliPlus/pages/audio/controller.dart';
import 'package:PiliPlus/pages/tabhost/tab_controller.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// 侧边标签栏（方案 C）：默认只显示图标；桌面悬停 / 手机触控展开
class TabStrip extends StatefulWidget {
  const TabStrip({
    super.key,
    required this.controller,
    required this.isExpanded,
    required this.onExpandedChanged,
  });

  final TabHostController controller;
  final bool isExpanded;
  final ValueChanged<bool> onExpandedChanged;

  @override
  State<TabStrip> createState() => _TabStripState();
}

class _TabStripState extends State<TabStrip> {
  static const double _collapsedWidth = 52;
  static const double _expandedWidth = 200;

  /// 当前是否有音频页在后台播放（优先于视频播放判断）
  bool get _audioPlaying => AudioController.isBackgroundPlaying;

  /// 当前选中标签的 heroTag（视频标签才有）
  void _togglePlay() {
    if (_audioPlaying) {
      final c = Get.isRegistered<AudioController>()
          ? Get.find<AudioController>()
          : null;
      if (c != null) {
        if (c.isPlaying()) {
          c.onPause();
        } else {
          c.onPlay();
        }
      }
      return;
    }
    final pc = PlPlayerController.instance;
    if (pc != null) {
      if (pc.playerStatus.value.isPlaying) {
        pc.pause();
      } else {
        pc.play();
      }
    }
  }

  /// 按 tab 对象实时取索引（闭包内不能用过期的 index）
  int _idxOf(TabItem tab) => widget.controller.tabs.indexOf(tab);

  /// 音频标签的独立 controller（按 oid tag 查找；找不到回退全局单例）
  AudioController? _audioCtrOf(TabItem tab) {
    if (tab.isAudio) {
      final id = tab.id; // 形如 'audio_123456'
      final oid = id.startsWith('audio_') ? id.substring(6) : null;
      if (oid != null && oid.isNotEmpty) {
        final tag = 'audio_$oid';
        if (Get.isRegistered<AudioController>(tag: tag)) {
          return Get.find<AudioController>(tag: tag);
        }
      }
    }
    return Get.isRegistered<AudioController>()
        ? Get.find<AudioController>()
        : null;
  }

  void _selectTab(TabItem tab) {
    final i = _idxOf(tab);
    if (i >= 0) widget.controller.select(i);
  }

  void _closeTab(TabItem tab) {
    final i = _idxOf(tab);
    if (i >= 0) widget.controller.close(i);
  }

  /// 构建单个展开态标签项（全量重建，index/tab 都是本次 build 的实时值）
  Widget _buildTabTile(TabItem tab, int index, int curIdx) {
    final isCurrent = curIdx == index;
    // 仅媒体标签（视频/音频）才显示播放控制
    final isMediaTab = tab.isVideo || tab.isAudio;
    final videoPlaying =
        PlPlayerController.instance?.playerStatus.value.isPlaying ?? false;
    // 音频播放状态走各自独立 controller 的 playingState（多音频标签并存）
    final audioPlaying =
        _audioCtrOf(tab)?.playingState.value ?? false;
    // 播放/暂停按钮展示真实播放状态：
    // - 音频标签：跟随该标签自己的 AudioController 播放状态
    // - 视频标签：当前选中标签（全局播放器）或 后台独立音频播放器在播
    final bgPlaying = tab.isVideo && widget.controller.isBgPlaying(tab);
    final isPlaying = tab.isAudio
        ? audioPlaying
        : (isCurrent ? videoPlaying : bgPlaying);
    return _TabTile(
      icon: tab.icon,
      title: tab.title,
      selected: isCurrent,
      onTap: () => _selectTab(tab),
      onClose: () => _closeTab(tab),
      // 第二行：仅媒体标签显示该标签的播放控制（居中、分开排列）
      controls: isMediaTab
          ? Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  tooltip: '上一首',
                  onPressed: () => _prevFor(tab),
                  icon: const Icon(
                    Icons.skip_previous_outlined,
                    size: 24,
                  ),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                ),
                IconButton(
                  tooltip: isPlaying ? '暂停' : '播放',
                  onPressed: () => _togglePlayFor(tab),
                  icon: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 24,
                  ),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                ),
                IconButton(
                  tooltip: '下一首',
                  onPressed: () => _nextFor(tab),
                  icon: const Icon(
                    Icons.skip_next_outlined,
                    size: 24,
                  ),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                ),
              ],
            )
          : null,
    );
  }

  /// 每个标签的播放/暂停：直接对目标标签执行播放/暂停（不切换标签页）
  void _togglePlayFor(TabItem tab) {
    final tc = widget.controller;
    final index = _idxOf(tab);
    if (index < 0) return;
    final isCurrent = tc.currentIndex.value == index;
    if (tab.isAudio) {
      // 音频标签：直接控制该标签的独立 AudioController
      final c = _audioCtrOf(tab);
      if (c != null) {
        if (c.isPlaying()) {
          c.onPause();
        } else {
          c.onPlay();
        }
      }
      return;
    }
    if (!isCurrent) {
      // 非当前视频标签：操作该标签的后台音频播放器（不切换页面）
      if (tab.bgPlayer != null) {
        tc.toggleBgPlay(tab);
      }
      return;
    }
    _togglePlay();
  }

  /// 每个标签的上一首：直接对目标标签执行上一曲（不切换标签页）
  void _prevFor(TabItem tab) {
    if (tab.isAudio) {
      _audioCtrOf(tab)?.playPrev();
      return;
    }
    final tag = tab.videoHeroTag;
    if (tag == null) return;
    try {
      Get.find<UgcIntroController>(tag: tag).prevPlay();
    } catch (_) {
      try {
        Get.find<PgcIntroController>(tag: tag).prevPlay();
      } catch (_) {}
    }
  }

  /// 每个标签的下一首：直接对目标标签执行下一曲（不切换标签页）
  void _nextFor(TabItem tab) {
    if (tab.isAudio) {
      _audioCtrOf(tab)?.playNext();
      return;
    }
    final tag = tab.videoHeroTag;
    if (tag == null) return;
    try {
      Get.find<UgcIntroController>(tag: tag).nextPlay();
    } catch (_) {
      try {
        Get.find<PgcIntroController>(tag: tag).nextPlay();
      } catch (_) {}
    }
  }


  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isExpanded = widget.isExpanded;
    // 桌面：悬停展开/移出折叠；手机：触控标签栏展开
    final child = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      width: isExpanded ? _expandedWidth : _collapsedWidth,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLowest.withValues(alpha: 0.6),
        border: Border(
          right: BorderSide(
            color: colorScheme.outline.withValues(alpha: 0.08),
          ),
        ),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        // 关键：切换动画期间旧子树（淡出中）仍在 Stack 中叠放并接收点击，
        // 鼠标点击会落到正在消失的旧布局上（收起/展开位置不同）→
        // 桌面"时好时坏"根因。旧子树必须 IgnorePointer 不接收指针事件。
        layoutBuilder: (currentChild, previousChildren) => Stack(
          fit: StackFit.expand,
          children: [
            ...previousChildren.map(
              (c) => IgnorePointer(child: c),
            ),
            if (currentChild != null) currentChild,
          ],
        ),
        child: isExpanded
            ? _buildExpanded(colorScheme)
            : _buildCollapsed(colorScheme),
      ),
    );
    if (PlatformUtils.isMobile) {
      // 手机：触控标签栏区域即展开（无悬停）
      return Listener(
        onPointerDown: (_) => widget.onExpandedChanged(true),
        child: child,
      );
    }
    return MouseRegion(
      onEnter: (_) => widget.onExpandedChanged(true),
      onExit: (_) => widget.onExpandedChanged(false),
      child: child,
    );
  }

  /// 收起态：只显示图标列
  Widget _buildCollapsed(ColorScheme colorScheme) {
    return KeyedSubtree(
      key: const ValueKey('tab-strip-collapsed'),
      child: Obx(() {
        final controller = widget.controller;
        final curIdx = controller.currentIndex.value;
        return Column(
          children: [
            const SizedBox(height: 10),
            _CollapsedTab(
              tooltip: '主页面',
              icon: const Icon(Icons.home_outlined, size: 18),
              selected: curIdx == -1,
              onTap: controller.selectMain,
            ),
            const SizedBox(height: 4),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  // 只显示可见标签（hidden 保活层不出现在标签条）
                  for (final tab in controller.visibleTabs)
                    _CollapsedTab(
                      tooltip: tab.title,
                      icon: tab.icon,
                      selected: curIdx >= 0 && controller.tabs[curIdx] == tab,
                      onTap: () => controller.select(controller.tabs.indexOf(tab)),
                    ),
                ],
              ),
            ),
          ],
        );
      }),
    );
  }

  /// 展开态：主页面入口 + 标签列表 + 关闭全部
  Widget _buildExpanded(ColorScheme colorScheme) {
    return KeyedSubtree(
      key: const ValueKey('tab-strip-expanded'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 主页面入口
          Obx(
            () => _TabTile(
              icon: const Icon(Icons.home_outlined, size: 16),
              title: '主页面',
              selected: widget.controller.currentIndex.value == -1,
              onTap: widget.controller.selectMain,
              onClose: null,
            ),
          ),
          Divider(
            height: 1,
            color: colorScheme.outline.withValues(alpha: 0.08),
          ),
          // 标签列表（最多 8 个，全量重建——不依赖 ListView.builder 元素
          // 复用，彻底避免 key 复用导致的过期闭包/操作错位）
          Expanded(
            child: Obx(
              () {
                final tabs = widget.controller.tabs;
                final curIdx = widget.controller.currentIndex.value;
                return ListView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                    // 只显示可见标签（hidden 保活层不出现在标签条）
                    for (final tab in widget.controller.visibleTabs)
                      _buildTabTile(tab, tabs.indexOf(tab), curIdx),
                  ],
                );
              },
            ),
          ),
          // 关闭全部：圆形图标按钮（无文字）
          Obx(
            () => widget.controller.tabs.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Center(
                      child: IconButton(
                        tooltip: '关闭全部标签',
                        onPressed: widget.controller.closeAll,
                        icon: const Icon(Icons.clear_all_outlined, size: 20),
                        style: IconButton.styleFrom(
                          shape: const CircleBorder(),
                          side: BorderSide(
                            color: Theme.of(context)
                                .colorScheme
                                .outline
                                .withValues(alpha: 0.4),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 长标题横向自动滚动（超出时 Marquee 滚动显示全标题）
class _MarqueeText extends StatefulWidget {
  const _MarqueeText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    // 滚动速度：原 4500ms 的约 0.4x（更慢）
    duration: const Duration(milliseconds: 11000),
  );

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _controller.reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewWidth = constraints.maxWidth;
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout();
        final textWidth = painter.width;
        if (textWidth <= viewWidth) {
          _controller.stop();
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }
        if (!_controller.isAnimating) {
          _controller.repeat();
        }
        // 双文本无缝循环（文字向左流动、从右滚出）：
        // displayText = 标题+标题（直接拼接，无间隔）。dx 从 0 平滑移动到
        // -textWidth：第一段从右缘进入、向左滚出，第二段（内容相同）接上，
        // 循环点处显示内容完全相同 → 跳变无感、无缝。任意时刻框内都有
        // 连续文本（窗口始终落在双文本范围内）。
        //
        // 关键：必须用 Stack+Positioned 让 Text 保持完整宽度（2×标题宽）。
        // 不能用 Align/Row/Expanded——它们会给 Text 施加 maxWidth=viewWidth
        // 约束，长标题被裁剪/换行，滚动完全错乱（曾致"闪现/截断"）。
        final displayText = '${widget.text}${widget.text}';
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final dx = -_controller.value * textWidth;
            return ClipRect(
              child: SizedBox(
                width: viewWidth,
                height: (widget.style.fontSize ?? 13) * 1.4,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: dx,
                      top: 0,
                      child: Text(
                        displayText,
                        maxLines: 1,
                        style: widget.style,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 收起态图标按钮
class _CollapsedTab extends StatelessWidget {
  const _CollapsedTab({
    required this.tooltip,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String tooltip;
  final Widget icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: selected
                  ? colorScheme.secondaryContainer.withValues(alpha: 0.55)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: IconButton(
              tooltip: tooltip,
              onPressed: onTap,
              icon: IconTheme(
                data: IconThemeData(
                  size: 18,
                  color: selected
                      ? colorScheme.onSecondaryContainer
                      : colorScheme.onSurfaceVariant,
                ),
                child: icon,
              ),
              padding: EdgeInsets.zero,
              splashRadius: 16,
            ),
          ),
        ),
      ),
    );
  }
}

/// 展开态标签项：第一行图标+标题+关闭，第二行播放控制
class _TabTile extends StatelessWidget {
  const _TabTile({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
    required this.onClose,
    this.controls,
  });

  final Widget icon;
  final String title;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onClose;
  final Widget? controls;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foreground = selected
        ? colorScheme.onSecondaryContainer
        : colorScheme.onSurfaceVariant;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        color: selected
            ? colorScheme.secondaryContainer.withValues(alpha: 0.55)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Column(
              // stretch 让第二行播放控制可占满宽度（spaceEvenly 居中分开）
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 第一行：图标 + 标题 + 关闭
                Row(
                  children: [
                    IconTheme(
                      data: IconThemeData(color: foreground, size: 16),
                      child: icon,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MarqueeText(
                        text: title,
                        style: TextStyle(
                          fontSize: 13,
                          color: foreground,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                    if (onClose != null)
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: onClose,
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            Icons.close,
                            size: 14,
                            color: colorScheme.onSurfaceVariant.withValues(
                              alpha: 0.7,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                // 第二行：播放控制（该标签的 上一首/播放暂停/下一首）
                if (controls != null) ...[
                  const SizedBox(height: 2),
                  controls!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
