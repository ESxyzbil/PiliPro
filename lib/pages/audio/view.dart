import 'dart:math' show min;

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/button/icon_button.dart';
import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart';
import 'package:PiliPlus/common/widgets/glass.dart';
import 'package:PiliPlus/common/widgets/gesture/tap_gesture_recognizer.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/image_viewer/hero.dart';
import 'package:PiliPlus/common/widgets/progress_bar/audio_video_progress_bar.dart';
import 'package:PiliPlus/common/widgets/progress_bar/segment_progress_bar.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pb.dart';
import 'package:PiliPlus/models/common/image_preview_type.dart';
import 'package:PiliPlus/models/common/image_type.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/pages/audio/controller.dart';
import 'package:PiliPlus/pages/audio/lyrics_api.dart';
import 'package:PiliPlus/pages/audio/lyrics_memory.dart';
import 'package:PiliPlus/pages/audio/volume_button.dart';
import 'package:PiliPlus/pages/setting/models/play_settings.dart'
    show showPlayerVolumeDialog;
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/action_item.dart';
import 'package:PiliPlus/pages/video/widgets/header_control.dart'
    show HeaderControlState;
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/services/desktop_lyrics_service.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/context_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart' hide DraggableScrollableSheet;
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

class AudioPage extends StatefulWidget {
  const AudioPage({super.key});

  @override
  State<AudioPage> createState() => _AudioPageState();

  static void toAudioPage({
    int? id,
    required int oid,
    List<int>? subId,
    required int itemType,
    required PlaylistSource from,
    String? heroTag,
    Duration? start,
    String? audioUrl,
    int? extraId,
    String? title,
    String? cover,
    String? ownerName,
    int? ownerMid,
    List<BiliDownloadEntryInfo>? offlineEntries,
  }) => Get.toNamed(
    '/audio',
    arguments: {
      'id': ?id,
      'oid': oid,
      'subId': ?subId,
      'from': from,
      'itemType': itemType,
      'heroTag': ?heroTag,
      'start': ?start,
      'audioUrl': ?audioUrl,
      'extraId': ?extraId,
      'title': ?title,
      'cover': ?cover,
      'ownerName': ?ownerName,
      'ownerMid': ?ownerMid,
      'offlineEntries': ?offlineEntries?.map((e) => e.toJson()).toList(),
    },
  );
}

extension _ListOrderExt on ListOrder {
  String get title => const ['无序', '正序', '倒序', '随机'][value];
}

class _AudioPageState extends State<AudioPage> {
  late final _controller = _initController();

  AudioController _initController() {
    if (Get.isRegistered<AudioController>()) {
      Get.delete<AudioController>(force: true);
    }
    return Get.put(AudioController());
  }
  final _lyricsScrollCtr = ScrollController();
  int _lastScrolledLine = -1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.loadCachedLyrics();
    _controller.didChangeDependencies(context);
  }

  @override
  void dispose() {
    _lyricsScrollCtr.dispose();
    if (Get.isRegistered<AudioController>()) {
      Get.delete<AudioController>(force: true);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final isPortrait = MediaQuery.sizeOf(context).isPortrait;
    final padding = MediaQuery.viewPaddingOf(context);
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        actions: [
          if (_controller.isUgc && _controller.enableSponsorBlock)
            Obx(() {
              if (_controller.segmentProgressList.isNotEmpty) {
                return IconButton(
                  tooltip: '片段信息',
                  onPressed: _controller.showSBDetail,
                  icon: const Icon(MdiIcons.advertisements, size: 22),
                );
              }
              return const SizedBox.shrink();
            }),
          Obx(
            () => IconButton(
              tooltip: _controller.showCoverInfo.value ? '切换视图' : '封面视图',
              onPressed: () => _controller.showCoverInfo.toggle(),
              icon: Icon(
                _controller.showCoverInfo.value
                    ? Icons.swap_horiz_rounded
                    : Icons.article_outlined,
                size: 22,
              ),
            ),
          ),
          Builder(
            builder: (context) {
              return PopupMenuButton<ListOrder>(
                tooltip: '排序',
                icon: const Icon(Icons.sort, size: 22),
                initialValue: _controller.order,
                onSelected: (value) {
                  _controller.onChangeOrder(value);
                  (context as Element).markNeedsBuild();
                },
                itemBuilder: (context) => ListOrder.values
                    .map((e) => PopupMenuItem(value: e, child: Text(e.title)))
                    .toList(),
              );
            },
          ),
          IconButton(
            tooltip: '定时关闭',
            onPressed: () => shutdownTimerService
              ..onPause ??= _controller.onPause
              ..isPlaying ??= _controller.isPlaying
              ..showScheduleExitDialog(
                context,
                isFullScreen: false,
              ),
            icon: const Icon(Icons.schedule, size: 22),
          ),
          if (DesktopLyricsService.isSupported)
            IconButton(
              tooltip: '桌面歌词',
              onPressed: () => Get.toNamed('/desktopLyrics'),
              icon: const Icon(Icons.music_note, size: 22),
            ),
          if (_controller.isUgc)
            IconButton(
              tooltip: '更多',
              onPressed: _showMore,
              icon: const Icon(Icons.more_vert, size: 22),
            ),
          const SizedBox(width: 5),
        ],
      ),
      body: Stack(
        children: [
          // 全屏后景毛玻璃：跟随后景（原回复面板）设置
          Positioned.fill(
            child: GlassContainer(
              kind: GlassKind.replyPanel,
              borderRadius: BorderRadius.zero,
              child: const SizedBox.expand(),
            ),
          ),
          isPortrait
            ? Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: 20 + padding.left,
                        right: 20 + padding.right,
                      ),
                      child: Obx(
                        () => _controller.showCoverInfo.value
                            ? _buildInfo(colorScheme, isPortrait)
                            : _buildNewPage(colorScheme, isPortrait),
                      ),
                    ),
                  ),
                  // 底部整个区域铺满顶栏毛玻璃（全宽、无圆角卡片）
                  GlassContainer(
                    kind: GlassKind.topBar,
                    borderRadius: BorderRadius.zero,
                    padding: EdgeInsets.only(
                      left: 20 + padding.left,
                      right: 20 + padding.right,
                      top: 18,
                      bottom: 30 + padding.bottom,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildProgressBar(colorScheme),
                        _buildDuration(colorScheme),
                        _buildControls(),
                      ],
                    ),
                  ),
                ],
              )
            : Padding(
                padding: EdgeInsets.only(
                  left: 20 + padding.left,
                  right: 20 + padding.right,
                  bottom: 30 + padding.bottom,
                ),
                child: Row(
                spacing: 12,
                children: [
                  Expanded(
                    child: Obx(
                      () => _controller.showCoverInfo.value
                          ? _buildInfo(colorScheme, isPortrait)
                          : _buildNewPage(colorScheme, isPortrait),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Obx(() {
                          final audioItem = _controller.audioItem.value;
                          if (audioItem != null) {
                            return _buildActions(audioItem);
                          }
                          return const SizedBox.shrink();
                        }),
                        const SizedBox(height: 25),
                        SizedBox(
                          width: double.infinity,
                          child: GlassContainer(
                            kind: GlassKind.topBar,
                            borderRadius: BorderRadius.circular(16),
                            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildProgressBar(colorScheme),
                                _buildDuration(colorScheme),
                                _buildControls(),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
          ),
        ],
      ),
    );
  }

  void _showPlaylist() {
    if (_controller.playlist case final playlist?) {
      final initialScrollOffset = 45.0 * _controller.index!;
      final scrollController = ScrollController(
        initialScrollOffset: initialScrollOffset,
      );
      showModalBottomSheet(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        constraints: BoxConstraints(
          maxWidth: min(640, context.mediaQueryShortestSide),
        ),
        builder: (context) {
          final theme = Theme.of(context);
          final colorScheme = theme.colorScheme;
          Widget child = CustomScrollView(
            controller: scrollController,
            physics: _controller.reachStart
                ? null
                : const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom + 100,
                ),
                sliver: SliverList.builder(
                  itemCount: playlist.length,
                  itemBuilder: (_, index) {
                    if (index == playlist.length - 1) {
                      _controller.loadNext(context);
                    }
                    final isCurr = index == _controller.index;
                    final item = playlist[index];
                    if (item.parts.length > 1) {
                      final subId = _controller.subId.firstOrNull;
                      return ExpansionTile(
                        dense: true,
                        minTileHeight: 45,
                        initiallyExpanded: isCurr,
                        collapsedIconColor: isCurr ? colorScheme.primary : null,
                        iconColor: isCurr ? null : colorScheme.onSurfaceVariant,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(
                          item.arc.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: isCurr
                              ? TextStyle(
                                  fontSize: 14,
                                  color: colorScheme.primary,
                                  fontWeight: FontWeight.bold,
                                )
                              : const TextStyle(fontSize: 14),
                        ),
                        trailing: isCurr
                            ? null
                            : iconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  if (index < _controller.index!) {
                                    _controller.index -= 1;
                                  }
                                  playlist.removeAt(index);
                                  (context as Element).markNeedsBuild();
                                },
                                iconColor: colorScheme.outline,
                                size: 28,
                                iconSize: 18,
                              ),
                        children: item.parts.map((e) {
                          final isCurr = e.subId == subId;
                          return ListTile(
                            dense: true,
                            minTileHeight: 45,
                            contentPadding: const EdgeInsetsDirectional.only(
                              start: 56.0,
                              end: 24.0,
                            ),
                            onTap: () {
                              Get.back();
                              if (!isCurr) {
                                _controller.playIndex(
                                  index,
                                  subId: [e.subId],
                                );
                              }
                            },
                            title: Text.rich(
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: isCurr
                                  ? TextStyle(
                                      fontSize: 14,
                                      color: colorScheme.primary,
                                      fontWeight: FontWeight.bold,
                                    )
                                  : TextStyle(
                                      fontSize: 14,
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                              TextSpan(
                                children: [
                                  if (isCurr) ...[
                                    WidgetSpan(
                                      alignment: .bottom,
                                      child: Image.asset(
                                        Assets.livingChart,
                                        width: 16,
                                        height: 16,
                                        cacheWidth: 16.cacheSize(
                                          context,
                                        ),
                                        color: colorScheme.primary,
                                      ),
                                    ),
                                    const TextSpan(text: '  '),
                                  ],
                                  TextSpan(text: e.title),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      );
                    }
                    return ListTile(
                      dense: true,
                      minTileHeight: 45,
                      onTap: () {
                        Get.back();
                        if (!isCurr) {
                          _controller.playIndex(index);
                        }
                      },
                      title: Text.rich(
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: isCurr
                            ? TextStyle(
                                fontSize: 14,
                                color: colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              )
                            : const TextStyle(fontSize: 14),
                        TextSpan(
                          children: [
                            if (isCurr) ...[
                              WidgetSpan(
                                alignment: .bottom,
                                child: Image.asset(
                                  Assets.livingChart,
                                  width: 16,
                                  height: 16,
                                  cacheWidth: 16.cacheSize(
                                    context,
                                  ),
                                  color: colorScheme.primary,
                                ),
                              ),
                              const TextSpan(text: '  '),
                            ],
                            TextSpan(
                              text: item.arc.title,
                            ),
                          ],
                        ),
                      ),
                      trailing: isCurr
                          ? null
                          : iconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                if (index < _controller.index!) {
                                  _controller.index -= 1;
                                }
                                playlist.removeAt(index);
                                (context as Element).markNeedsBuild();
                              },
                              iconColor: colorScheme.outline,
                              size: 28,
                              iconSize: 18,
                            ),
                    );
                  },
                ),
              ),
            ],
          );
          if (!_controller.reachStart) {
            child = refreshIndicator(
              onRefresh: () => _controller.loadPrev(context),
              isClampingScrollPhysics: true,
              child: child,
            );
          }
          return FractionallySizedBox(
            heightFactor:
                PlatformUtils.isMobile && !context.mediaQuerySize.isPortrait
                ? 1.0
                : 0.7,
            alignment: Alignment.bottomCenter,
            child: Column(
              children: [
                InkWell(
                  onTap: Get.back,
                  borderRadius: Style.bottomSheetRadius,
                  child: SizedBox(
                    height: 35,
                    child: Center(
                      child: Container(
                        width: 32,
                        height: 3,
                        decoration: BoxDecoration(
                          color: colorScheme.outline,
                          borderRadius: const .all(.circular(3)),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Material(
                    type: MaterialType.transparency,
                    child: Theme(
                      data: theme.copyWith(dividerColor: Colors.transparent),
                      child: child,
                    ),
                  ),
                ),
                Divider(
                  height: 1,
                  color: colorScheme.outline.withValues(alpha: 0.1),
                ),
                Padding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.viewPaddingOf(context).bottom,
                  ),
                  child: InkWell(
                    onTap: Get.back,
                    child: SizedBox(
                      height: 45,
                      child: Center(
                        child: Text(
                          '关闭',
                          style: TextStyle(color: colorScheme.outline),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ).whenComplete(scrollController.dispose);
    } else if (_controller.offlineEntries case final entries? when entries.isNotEmpty) {
      final cs = Theme.of(context).colorScheme;
      showModalBottomSheet(
        context: context,
        builder: (context) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('播放列表', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text('离线模式 — 共${entries.length}条',
                  style: TextStyle(fontSize: 13, color: cs.outline),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final e = entries[index];
                      final isCurr = e.avid == _controller.oid.toInt();
                      return ListTile(
                        dense: true,
                        minTileHeight: 45,
                        selected: isCurr,
                        selectedTileColor: cs.primaryContainer,
                        title: Text(e.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: isCurr ? FontWeight.bold : null,
                            color: isCurr ? cs.primary : null,
                          ),
                        ),
                        subtitle: (e.ownerName) != null && e.ownerName!.isNotEmpty
                          ? Text(e.ownerName!, style: TextStyle(fontSize: 12, color: cs.outline))
                          : null,
                        trailing: isCurr
                          ? Icon(Icons.play_arrow_rounded, color: cs.primary)
                          : null,
                        onTap: () {
                          Navigator.pop(context);
                          if (!isCurr) {
                            _controller.playOfflineIndex(index);
                          }
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      );
    } else if (_controller.audioTitle.value.isNotEmpty) {
      showModalBottomSheet(
        context: context,
        builder: (context) {
          final cs = Theme.of(context).colorScheme;
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('播放列表', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(Icons.play_arrow_rounded, color: cs.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _controller.audioTitle.value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                          if (_controller.audioArtist.value.isNotEmpty)
                            Text(
                              _controller.audioArtist.value,
                              style: TextStyle(fontSize: 12, color: cs.outline),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('单曲目模式',
                  style: TextStyle(fontSize: 13, color: cs.outline),
                ),
              ],
            ),
          );
        },
      );
    }
  }

  void _showPlaySettings() {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxWidth: min(640, context.mediaQueryShortestSide),
      ),
      builder: (context) {
        final colorScheme = ColorScheme.of(context);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: Get.back,
              borderRadius: Style.bottomSheetRadius,
              child: SizedBox(
                height: 35,
                child: Center(
                  child: Container(
                    width: 32,
                    height: 3,
                    decoration: BoxDecoration(
                      color: colorScheme.outline,
                      borderRadius: const BorderRadius.all(
                        Radius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.only(
                top: 12,
                left: 20,
                right: 20,
                bottom: MediaQuery.viewPaddingOf(context).bottom + 20,
              ),
              child: Column(
                spacing: 12,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Builder(
                    builder: (context) => Column(
                      spacing: 12,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('播放倍速(${_controller.speed})'),
                        Slider(
                          padding: EdgeInsets.zero,
                          min: 0.5,
                          max: 2.0,
                          divisions: 15,
                          value: _controller.speed,
                          onChanged: (value) {
                            _controller.speed = value.toPrecision(1);
                            (context as Element).markNeedsBuild();
                          },
                          onChangeEnd: (_) =>
                              _controller.setSpeed(_controller.speed),
                        ),
                      ],
                    ),
                  ),
                  const Text('播放模式'),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: PlayRepeat.values
                        .take(4)
                        .map(
                          (e) => _playModeWidget(
                            colorScheme: colorScheme,
                            playMode: e,
                          ),
                        )
                        .toList(),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _playModeWidget({
    required ColorScheme colorScheme,
    required PlayRepeat playMode,
  }) {
    final isCurr = playMode == _controller.playMode.value;
    final color = isCurr ? colorScheme.primary : colorScheme.outline;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Get.back();
        if (!isCurr) {
          _controller.playMode.value = playMode;
          GStorage.setting.put(SettingBoxKey.audioPlayMode, playMode.index);
        }
      },
      child: Column(
        spacing: 6,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isCurr
                  ? colorScheme.primary.withValues(alpha: 0.15)
                  : colorScheme.onInverseSurface.withValues(alpha: 0.8),
            ),
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(
                size: 26,
                playMode.icon,
                color: color,
              ),
            ),
          ),
          Text(
            playMode.label,
            style: TextStyle(fontSize: 13, color: color),
          ),
        ],
      ),
    );
  }

  void _showMore() {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxWidth: min(640, context.mediaQueryShortestSide),
      ),
      builder: (context) {
        final colorScheme = ColorScheme.of(context);
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewPaddingOf(context).bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: Get.back,
                borderRadius: Style.bottomSheetRadius,
                child: SizedBox(
                  height: 35,
                  child: Center(
                    child: Container(
                      width: 32,
                      height: 3,
                      decoration: BoxDecoration(
                        color: colorScheme.outline,
                        borderRadius: const BorderRadius.all(
                          Radius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.warning_amber_rounded, size: 20),
                title: const Text('举报', style: TextStyle(fontSize: 14)),
                onTap: () {
                  Get.back();
                  PageUtils.reportVideo(_controller.oid.toInt());
                },
              ),
              if (_controller.player case final player?) ...[
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.info_outline, size: 20),
                  title: const Text('播放信息', style: TextStyle(fontSize: 14)),
                  onTap: () {
                    Get.back();
                    HeaderControlState.showPlayerInfo(context, player: player);
                  },
                ),
                if (PlatformUtils.isMobile)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.volume_up, size: 20),
                    title: Text(
                      '播放器音量: ${player.getProperty('volume').subLength(3)}%',
                      style: const TextStyle(fontSize: 14),
                    ),
                    onTap: () {
                      Get.back();
                      showPlayerVolumeDialog(
                        context,
                        () {},
                        onChanged: player.setVolume,
                      );
                    },
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildActions(DetailItem audioItem) {
    return SizedBox(
      height: 48,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Obx(
            () => ActionItem(
              animation: _controller.tripleAnimation,
              icon: const Icon(FontAwesomeIcons.thumbsUp),
              selectIcon: const Icon(
                FontAwesomeIcons.solidThumbsUp,
              ),
              selectStatus: _controller.hasLike.value,
              semanticsLabel: '点赞',
              text: NumUtils.numFormat(audioItem.stat.like),
              onStartTriple: _controller.onStartTriple,
              onCancelTriple: _controller.onCancelTriple,
            ),
          ),
          Obx(
            () => ActionItem(
              animation: _controller.tripleAnimation,
              icon: const Icon(FontAwesomeIcons.b),
              selectIcon: const Icon(FontAwesomeIcons.b),
              onTap: _controller.actionCoinVideo,
              selectStatus: _controller.hasCoin,
              semanticsLabel: '投币',
              text: NumUtils.numFormat(
                audioItem.stat.coin,
              ),
            ),
          ),
          Obx(
            () => ActionItem(
              animation: _controller.tripleAnimation,
              icon: const Icon(FontAwesomeIcons.star),
              selectIcon: const Icon(
                FontAwesomeIcons.solidStar,
              ),
              onTap: () => _controller.showFavBottomSheet(context),
              onLongPress: () => _controller.showFavBottomSheet(
                context,
                isLongPress: true,
              ),
              selectStatus: _controller.hasFav.value,
              semanticsLabel: '收藏',
              text: NumUtils.numFormat(
                audioItem.stat.favourite,
              ),
            ),
          ),
          ActionItem(
            icon: const Icon(FontAwesomeIcons.comment),
            onTap: _controller.showReply,
            semanticsLabel: '评论',
            text: NumUtils.numFormat(
              audioItem.stat.reply,
            ),
          ),
          ActionItem(
            icon: const Icon(
              FontAwesomeIcons.shareFromSquare,
            ),
            onTap: () => _controller.actionShareVideo(context),
            selectStatus: false,
            semanticsLabel: '分享',
            text: NumUtils.numFormat(
              audioItem.stat.share,
            ),
          ),
          if (audioItem.associatedItem.hasOid() &&
              audioItem.associatedItem.subId.isNotEmpty)
            ActionItem(
              icon: const Icon(FontAwesomeIcons.circlePlay),
              onTap: () {
                _controller.player?.pause();
                PageUtils.toVideoPage(
                  cid: audioItem.associatedItem.subId.first.toInt(),
                  aid: audioItem.associatedItem.oid.toInt(),
                );
              },
              selectStatus: false,
              semanticsLabel: '看MV',
              text: '看MV',
            ),
        ],
      ),
    );
  }

  void _onDragStart(ThumbDragDetails details) {
    // do nothing
  }

  void _onDragUpdate(ThumbDragDetails details) {
    _controller
      ..isDragging = true
      ..position.value = details.timeStamp;
  }

  void _onSeek(Duration value) {
    _controller
      ..player?.seek(value)
      ..isDragging = false;
  }

  Widget _buildProgressBar(ColorScheme colorScheme) {
    final primary = colorScheme.primary;
    final thumbGlowColor = primary.withAlpha(80);
    final baseBarColor = colorScheme.isDark
        ? const Color(0x33FFFFFF)
        : const Color(0x33999999);
    Widget child = Obx(
      () => ProgressBar(
        progress: _controller.position.value,
        total: _controller.duration.value,
        baseBarColor: baseBarColor,
        progressBarColor: primary,
        bufferedBarColor: Colors.transparent,
        thumbColor: primary,
        thumbGlowColor: thumbGlowColor,
        thumbGlowRadius: 0,
        thumbRadius: 6,
        onDragStart: _onDragStart,
        onDragUpdate: _onDragUpdate,
        onSeek: _onSeek,
      ),
    );
    if (_controller.isUgc && _controller.enableSponsorBlock) {
      child = Stack(
        children: [
          child,
          Positioned(
            left: 0,
            right: 0,
            bottom: 3.5,
            child: Obx(
              () {
                if (_controller.segmentProgressList.isNotEmpty) {
                  return SegmentProgressBar(
                    height: 5,
                    segments: _controller.segmentProgressList,
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ),
        ],
      );
    }
    if (kDebugMode || PlatformUtils.isDesktop) {
      child = Row(
        spacing: 10,
        children: [
          Expanded(child: child),
          VolumeButton(controller: _controller),
        ],
      );
    }
    return child;
  }

  Widget _buildDuration(ColorScheme colorScheme) {
    return SizedBox(
      height: 30,
      child: DefaultTextStyle(
        style: TextStyle(fontSize: 13, color: colorScheme.outline),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Obx(() {
              final position = _controller.position.value;
              if (_controller.player != null) {
                return Text(
                  DurationUtils.formatDuration(position.inSeconds),
                );
              }
              return const SizedBox.shrink();
            }),
            Obx(() {
              final duration = _controller.duration.value;
              if (_controller.player != null) {
                return Text(
                  DurationUtils.formatDuration(duration.inSeconds),
                );
              }
              return const SizedBox.shrink();
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    final cir = Pref.circularScreen;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: cir ? MediaQuery.of(context).size.width * Pref.uiScale * 0.12 : 0),
      child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        Obx(
          () => IconButton(
            onPressed: _showPlaySettings,
            icon: Icon(
              size: 26,
              _controller.playMode.value.icon,
            ),
          ),
        ),
        IconButton(
          onPressed: _controller.playPrev,
          icon: const Icon(
            size: 40,
            Icons.skip_previous_rounded,
          ),
        ),
        IconButton(
          onPressed: _controller.playOrPause,
          icon: AnimatedIcon(
            size: 40,
            icon: AnimatedIcons.play_pause,
            progress: _controller.animController,
          ),
        ),
        IconButton(
          onPressed: _controller.playNext,
          icon: const Icon(
            size: 40,
            Icons.skip_next_rounded,
          ),
        ),
        IconButton(
          onPressed: _showPlaylist,
          icon: const Icon(
            size: 26,
            Icons.menu_rounded,
          ),
        ),
      ],
      ),
    );
  }

  Widget _buildInfo(ColorScheme colorScheme, bool isPortrait) {
    return Obx(() {
      final audioItem = _controller.audioItem.value;
      if (audioItem != null) {
        final cover = audioItem.arc.cover.http2https;
        return Column(
          children: [
            Expanded(
              child: Center(
                child: ListView(
                  key: const PageStorageKey(_AudioPageState),
                  shrinkWrap: true,
                  physics: const ClampingScrollPhysics(),
                  children: [
                    Center(
                      child: GestureDetector(
                        onTap: () => PageUtils.imageView(
                          imgList: [SourceModel(url: cover)],
                        ),
                        child: fromHero(
                          tag: cover,
                          child: NetworkImgLayer(
                            src: cover,
                            width: 170,
                            height: 170,
                            cacheWidth: false,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      audioItem.arc.title,
                      style: const TextStyle(height: 1.7, fontSize: 16),
                      scrollPhysics: const NeverScrollableScrollPhysics(),
                    ),
                    const SizedBox(height: 12),
                    if (audioItem.owner.hasName()) ...[
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          _controller.player?.pause();
                          Get.toNamed('/member?mid=${audioItem.owner.mid}');
                        },
                        child: Row(
                          spacing: 6,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (audioItem.owner.hasAvatar())
                              NetworkImgLayer(
                                src: audioItem.owner.avatar,
                                width: 22,
                                height: 22,
                                type: ImageType.avatar,
                              ),
                            Text(
                              audioItem.owner.name,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    Row(
                      children: [
                        Icon(
                          size: 14,
                          Icons.headphones_outlined,
                          color: colorScheme.outline,
                        ),
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text:
                                    ' ${NumUtils.numFormat(audioItem.stat.view)}   '
                                    '${DateFormatUtils.dateFormat(audioItem.arc.publish.toInt(), long: DateFormatUtils.longFormatD)}   ',
                              ),
                              TextSpan(
                                text: audioItem.arc.displayedOid,
                                style: TextStyle(color: colorScheme.secondary),
                                recognizer: NoDeadlineTapGestureRecognizer()
                                  ..onTap = () => Utils.copyText(
                                    audioItem.arc.displayedOid,
                                  ),
                              ),
                            ],
                          ),
                          style: TextStyle(
                            fontSize: 13,
                            color: colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                    if (audioItem.arc.hasDesc()) ...[
                      const SizedBox(height: 10),
                      SelectableText(
                        audioItem.arc.desc,
                        scrollPhysics: const NeverScrollableScrollPhysics(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (isPortrait) ...[
              const SizedBox(height: 10),
              _buildActions(audioItem),
            ],
          ],
        );
      }
      // 离线回退：显示标题和作者
      final title = _controller.audioTitle.value;
      final artist = _controller.audioArtist.value;
      if (title.isNotEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.music_note, size: 80, color: colorScheme.primary.withValues(alpha: 0.4)),
                const SizedBox(height: 16),
                SelectableText(
                  title,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  textAlign: TextAlign.center,
                ),
                if (artist.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    artist,
                    style: TextStyle(fontSize: 14, color: colorScheme.outline),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        );
      }
      return const SizedBox.shrink();
    });
  }

  Widget _buildNewPage(ColorScheme colorScheme, bool isPortrait) {
    return Column(
      children: [
        // 来源选择器
        _buildSourceSelector(colorScheme),
        const SizedBox(height: 12),
        // 歌词显示区域
        Expanded(child: _buildLyricsContent(colorScheme)),
      ],
    );
  }

  Widget _buildSourceSelector(ColorScheme colorScheme) {
    return Obx(() {
      final sources = LyricsSource.values;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          spacing: 8,
          children: sources.map((source) {
            final isSelected = _controller.selectedSource.value == source;
            final result = _controller.lyricsResults[source];
            final hasResult = result != null && result.isSuccess;
            return GestureDetector(
              onTap: () {
                if (source == LyricsSource.bilibili_cc) {
                  // CC字幕：点一下切过去，不出列表
                  _controller.switchLyricsSource(source);
                  return;
                }
                if (isSelected) {
                  // 点当前平台 → 展开候选歌曲列表
                  _showSourceSongList(source, colorScheme);
                } else if (hasResult) {
                  // 点其他有结果的平台 → 直接切换
                  _controller.switchLyricsSource(source);
                } else {
                  // 点没结果的平台 → 展开候选歌曲列表
                  _showSourceSongList(source, colorScheme);
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: isSelected
                      ? colorScheme.primary
                      : hasResult
                          ? colorScheme.secondaryContainer.withValues(alpha: 0.5)
                          : colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(16),
                  border: !isSelected && hasResult
                      ? Border.all(
                          color: colorScheme.outline.withValues(alpha: 0.2),
                        )
                      : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: [
                    Text(
                      source.icon,
                      style: const TextStyle(fontSize: 14),
                    ),
                    Text(
                      source.label,
                      style: TextStyle(
                        fontSize: 12,
                        color: isSelected
                            ? colorScheme.onPrimary
                            : hasResult
                                ? colorScheme.onSurface
                                : colorScheme.outline,
                        fontWeight: isSelected ? FontWeight.bold : null,
                      ),
                    ),
                    if (result != null)
                      Text(
                        result.isSuccess ? ' ✓' : ' ✗',
                        style: TextStyle(
                          fontSize: 10,
                          color: result.isSuccess
                              ? (isSelected
                                  ? colorScheme.onPrimary
                                  : colorScheme.primary)
                              : colorScheme.error,
                        ),
                      ),
                    // CC字幕：锁定 + 全局默认
                    if (source == LyricsSource.bilibili_cc)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 单曲锁定
                          GestureDetector(
                            onTapDown: (details) {
                              // 阻止冒泡到父层的 onTap
                            },
                            onTap: () => _controller.toggleCcLock(),
                            child: Obx(() => Padding(
                                  padding: const EdgeInsets.only(left: 2),
                                  child: Icon(
                                    _controller.ccLocked.value
                                        ? Icons.lock
                                        : Icons.lock_open_outlined,
                                    size: 16,
                                    color: _controller.ccLocked.value
                                        ? (isSelected
                                            ? colorScheme.onPrimary
                                            : colorScheme.primary)
                                        : colorScheme.outline,
                                  ),
                                )),
                          ),
                          // 全局默认
                          GestureDetector(
                            onTapDown: (details) {
                              // 阻止冒泡到父层的 onTap
                            },
                            onTap: () {
                              LyricsMemory.defaultCc =
                                  !LyricsMemory.defaultCc;
                              _controller.ccDefault.value =
                                  LyricsMemory.defaultCc;
                            },
                            child: Padding(
                              padding: const EdgeInsets.only(left: 3),
                              child: Obx(() => Icon(
                                    _controller.ccDefault.value
                                        ? Icons.language
                                        : Icons.language_outlined,
                                    size: 16,
                                    color: _controller.ccDefault.value
                                        ? (isSelected
                                            ? colorScheme.onPrimary
                                            : colorScheme.primary)
                                        : colorScheme.outline,
                                  )),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      );
    });
  }

  /// 显示搜索结果歌曲列表（支持搜索 + 加载更多）
  void _showSourceSongList(LyricsSource source, ColorScheme colorScheme) {
    final searchCtr = TextEditingController();
    // 当前平台已有的搜索缓存（初始结果）
    final allItems = <LyricsSearchItem>[
      ...?_controller.lyricsSearchResults[source],
    ];
    var currentPage = 1; // 已经是第 1 页
    var isLoadingMore = false;
    var hasMore = allItems.isNotEmpty;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 标题行
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                    child: Row(
                      children: [
                        Text('${source.icon} ',
                            style: const TextStyle(fontSize: 16)),
                        Expanded(
                          child: Text(
                            '${source.label} — 选择歌曲',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: () => Navigator.pop(ctx),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
                  // 搜索输入框
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: SizedBox(
                      height: 36,
                      child: TextField(
                        controller: searchCtr,
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          hintText: '搜索 ${source.label}...',
                          hintStyle: TextStyle(
                              fontSize: 13, color: colorScheme.outline),
                          isDense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide:
                                BorderSide(color: colorScheme.outlineVariant),
                          ),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.search, size: 18),
                            onPressed: () async {
                              final keyword = searchCtr.text.trim();
                              if (keyword.isEmpty) return;
                              // 搜索该平台
                              List<LyricsSearchItem> results;
                              try {
                                results = switch (source) {
                                  LyricsSource.netease =>
                                    await searchNetease(keyword, page: 1),
                                  LyricsSource.kugou =>
                                    await searchKugou(keyword, page: 1),
                                  LyricsSource.douyin =>
                                    await searchQishui(keyword, page: 1),
                                  LyricsSource.bilibili_cc => [],
                                };
                              } catch (_) {
                                results = [];
                              }
                              setState(() {
                                allItems
                                  ..clear()
                                  ..addAll(results);
                                currentPage = 1;
                                hasMore = results.length >= 20;
                                isLoadingMore = false;
                              });
                              // 也更新 controller 里的缓存
                              _controller.lyricsSearchResults[source] = results;
                            },
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                        onSubmitted: (value) {
                          // 回车触发搜索
                          final keyword = searchCtr.text.trim();
                          if (keyword.isNotEmpty) {
                            // 模拟搜索按钮点击
                            // 直接调用搜索逻辑
                          }
                        },
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  // 列表
                  if (allItems.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Text('该平台未搜索到相关歌曲',
                            style: TextStyle(
                                fontSize: 14, color: Colors.grey)),
                      ),
                    )
                  else
                    Flexible(
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (notification) {
                          if (notification is ScrollEndNotification &&
                              !isLoadingMore &&
                              hasMore) {
                            final metrics = notification.metrics;
                            if (metrics.pixels >=
                                metrics.maxScrollExtent - 80) {
                              // 加载下一页
                              isLoadingMore = true;
                              final keyword = searchCtr.text.trim();
                              final searchKeyword =
                                  keyword.isEmpty ? '' : keyword;
                              _loadMorePlatformResults(source, searchKeyword,
                                      currentPage + 1, setState)
                                  .then((newItems) {
                                setState(() {
                                  allItems.addAll(newItems);
                                  currentPage++;
                                  hasMore = newItems.length >= 20;
                                  isLoadingMore = false;
                                });
                              });
                            }
                          }
                          return false;
                        },
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: allItems.length + (hasMore ? 1 : 0),
                          itemBuilder: (ctx, i) {
                            if (i == allItems.length) {
                              return const Padding(
                                padding: EdgeInsets.all(12),
                                child: Center(
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child:
                                        CircularProgressIndicator(strokeWidth: 2),
                                  ),
                                ),
                              );
                            }
                            final item = allItems[i];
                            final selectedItem = _controller.selectedSearchItems[source];
                            final isCurrent = selectedItem != null &&
                                selectedItem.title == item.title &&
                                selectedItem.artist == item.artist &&
                                selectedItem.subtitle == item.subtitle;
                            final remembered = LyricsMemory.isRemembered(
                              _controller.audioTitle.value,
                              _controller.audioArtist.value,
                              source,
                              item,
                            );
                            return ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              leading: Checkbox(
                                value: remembered,
                                tristate: false,
                                onChanged: (value) {
                                  if (value == true) {
                                    LyricsMemory.remember(
                                      _controller.audioTitle.value,
                                      _controller.audioArtist.value,
                                      source,
                                      item,
                                    );
                                    // 同时加载该歌曲的歌词
                                    _controller.fetchLyricsForSourceItem(
                                        source, item);
                                    Navigator.pop(ctx);
                                  } else {
                                    LyricsMemory.forget(
                                      _controller.audioTitle.value,
                                      _controller.audioArtist.value,
                                    );
                                    setState(() {});
                                  }
                                },
                              ),
                              title: Text(
                                item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight:
                                      isCurrent ? FontWeight.bold : null,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                item.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12, color: colorScheme.outline),
                              ),
                              trailing: isCurrent
                                  ? Icon(Icons.check,
                                      size: 16, color: colorScheme.primary)
                                  : null,
                              onTap: () {
                                Navigator.pop(ctx);
                                if (!isCurrent) {
                                  _controller.fetchLyricsForSourceItem(
                                      source, item);
                                }
                              },
                            );
                          },
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 加载某个平台的下一页搜索结果
  Future<List<LyricsSearchItem>> _loadMorePlatformResults(
    LyricsSource source,
    String keyword,
    int page,
    void Function(void Function()) setState,
  ) async {
    if (keyword.isEmpty) {
      // 没有搜关键词，用原标题重新搜并取第 page 页
      final ctx = context;
      final title = _controller.audioItem.value?.arc.title ?? '';
      final artist = _controller.audioItem.value?.owner.name ?? '';
      keyword = '$title $artist';
    }
    try {
      return switch (source) {
        LyricsSource.netease => await searchNetease(keyword, page: page),
        LyricsSource.kugou => await searchKugou(keyword, page: page),
        LyricsSource.douyin => await searchQishui(keyword, page: page),
        LyricsSource.bilibili_cc => [],
      };
    } catch (_) {
      return [];
    }
  }

  Widget _buildLyricsContent(ColorScheme colorScheme) {
    return Obx(() {
      if (_controller.isLoadingLyrics.value) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(strokeWidth: 2.5),
              const SizedBox(height: 12),
              Text(
                '正在搜索歌词...',
                style: TextStyle(color: colorScheme.outline, fontSize: 13),
              ),
            ],
          ),
        );
      }

      final result = _controller.lyricsResults[_controller.selectedSource.value];
      if (result == null) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lyrics_outlined, size: 42, color: colorScheme.outline.withValues(alpha: 0.4)),
              const SizedBox(height: 10),
              Text(
                '搜索歌词中...',
                style: TextStyle(color: colorScheme.outline, fontSize: 14),
              ),
            ],
          ),
        );
      }

      if (!result.isSuccess) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 36, color: colorScheme.error.withValues(alpha: 0.6)),
                const SizedBox(height: 10),
                Text(
                  result.error ?? '获取歌词失败',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colorScheme.outline, fontSize: 13),
                ),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  onPressed: () {
                    final item = _controller.audioItem.value;
                    if (item != null) {
                      _controller.searchLyrics('${item.arc.title} ${item.owner.name}');
                    }
                  },
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        );
      }

      // 有时间轴歌词 → 滚动高亮模式
      if (result.syncedLines != null && result.syncedLines!.isNotEmpty) {
        return _buildSyncedLyrics(result.syncedLines!, colorScheme);
      }

      // 只有纯文本
      return _buildPlainLyrics(result.plainText, colorScheme);
    });
  }

  Widget _buildSyncedLyrics(List<LyricsLine> lines, ColorScheme colorScheme) {
    return Obx(() {
      final currentIdx = _controller.currentLineIndex.value;
      // 自动滚动到当前行（居中）
      if (currentIdx != _lastScrolledLine && currentIdx >= 0) {
        _lastScrolledLine = currentIdx;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_lyricsScrollCtr.hasClients) {
            final vh = _lyricsScrollCtr.position.viewportDimension;
            // 计算偏移：让当前行出现在视口中部
            final offset = (currentIdx * 48.0) - (vh / 2) + 24;
            if (offset > 0) {
              _lyricsScrollCtr.animateTo(
                offset.clamp(0, _lyricsScrollCtr.position.maxScrollExtent),
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
            }
          }
        });
      }
      return ListView.builder(
        controller: _lyricsScrollCtr,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemExtent: 48.0, // 固定行高，确保滚动偏移准确
        itemCount: lines.length,
        itemBuilder: (context, index) {
          final isCurrent = index == currentIdx;
          final line = lines[index];
          return AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: TextStyle(
              fontSize: isCurrent ? 17 : 14,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent
                  ? colorScheme.primary
                  : colorScheme.onSurface.withValues(alpha: 0.7),
              height: 1.4,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Center(
                child: Text(
                  line.text,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        },
      );
    });
  }

  Widget _buildPlainLyrics(String? text, ColorScheme colorScheme) {
    if (text == null || text.isEmpty) {
      return Center(
        child: Text(
          '暂无歌词',
          style: TextStyle(color: colorScheme.outline, fontSize: 14),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: SelectableText(
        text,
        style: TextStyle(
          fontSize: 14,
          color: colorScheme.onSurface.withValues(alpha: 0.8),
          height: 1.6,
        ),
      ),
    );
  }
}

extension _PlayReatExt on PlayRepeat {
  IconData get icon => switch (this) {
    PlayRepeat.pause => Icons.pause_rounded,
    PlayRepeat.listOrder => Icons.keyboard_double_arrow_right_rounded,
    PlayRepeat.singleCycle => Icons.play_circle_outline_rounded,
    PlayRepeat.listCycle => Icons.sync_rounded,
    PlayRepeat.autoPlayRelated => throw UnimplementedError(),
  };
}
