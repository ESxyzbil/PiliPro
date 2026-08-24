import 'package:PiliPlus/common/widgets/progress_bar/audio_video_progress_bar.dart';
import 'package:PiliPlus/common/widgets/progress_bar/segment_progress_bar.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/view/view.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class BottomControl extends StatelessWidget {
  const BottomControl({
    super.key,
    required this.maxWidth,
    required this.isFullScreen,
    required this.controller,
    required this.buildBottomControl,
    required this.videoDetailController,
  });

  final double maxWidth;
  final bool isFullScreen;
  final PlPlayerController controller;
  final ValueGetter<Widget> buildBottomControl;
  final VideoDetailController videoDetailController;

  void onDragStart(ThumbDragDetails duration) {
    feedBack();
    controller.onChangedSliderStart(duration.timeStamp);
  }

  void onDragUpdate(ThumbDragDetails duration) {
    if (!controller.isFileSource && controller.showSeekPreview) {
      controller.updatePreviewIndex(duration.timeStamp.inSeconds);
    }
    controller.onUpdatedSliderProgress(duration.timeStamp);
  }

  void onSeek(Duration duration) {
    if (controller.showSeekPreview) {
      controller.showPreview.value = false;
    }
    controller
      ..onChangedSliderEnd()
      ..onChangedSlider(duration.inSeconds)
      ..seekTo(Duration(seconds: duration.inSeconds), isSeek: false);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final primary = colorScheme.isLight
        ? colorScheme.inversePrimary
        : colorScheme.primary;
    final thumbGlowColor = primary.withAlpha(80);
    final bufferedBarColor = primary.withValues(alpha: 0.4);
    // 圆屏适配 + 全屏时，底栏与进度条改为半圆环
    final arc = Pref.circularScreen && isFullScreen;

    Widget progressStack() {
      return Obx(
        () => Offstage(
          offstage: !controller.showControls.value,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              Obx(() {
                final int value = controller.sliderPositionSeconds.value;
                final int max = controller.duration.value.inSeconds;
                return ProgressBar(
                  progress: Duration(seconds: value),
                  buffered: Duration(
                    seconds: controller.bufferedSeconds.value,
                  ),
                  total: Duration(seconds: max),
                  progressBarColor: primary,
                  baseBarColor: const Color(0x33FFFFFF),
                  bufferedBarColor: bufferedBarColor,
                  thumbColor: primary,
                  thumbGlowColor: thumbGlowColor,
                  barHeight: 7,
                  thumbRadius: 8,
                  thumbGlowRadius: 25,
                  onDragStart: onDragStart,
                  onDragUpdate: onDragUpdate,
                  onSeek: onSeek,
                  arcMode: arc,
                );
              }),
              // 分段/看点条：非弧模式下保持原水平布局；弧模式下已由
              // 主进度条的覆盖层绘制，避免重复。
              if (!arc &&
                  controller.enableBlock &&
                  videoDetailController.segmentProgressList.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 5.25,
                  child: SegmentProgressBar(
                    segments: videoDetailController.segmentProgressList,
                  ),
                ),
              if (!arc &&
                  controller.showViewPoints &&
                  videoDetailController.viewPointList.isNotEmpty &&
                  videoDetailController.showVP.value)
                Padding(
                  padding: const .only(bottom: 8.75),
                  child: ViewPointSegmentProgressBar(
                    segments: videoDetailController.viewPointList,
                    onSeek: PlatformUtils.isDesktop
                        ? (position) =>
                              controller.seekTo(position, isSeek: false)
                        : null,
                  ),
                ),
              if (videoDetailController.showDmTrendChart.value)
                if (videoDetailController.dmTrend.value?.dataOrNull
                    case final list?)
                  buildDmChart(primary, list, videoDetailController, 4.5),
            ],
          ),
        ),
      );
    }

    // 圆屏 + 全屏：底栏成为半圆环——半圆进度环铺满底部半圆区域，控制按钮沿环分布。
    if (arc) {
      return SizedBox(
        width: double.infinity,
        height: maxWidth / 2,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // 最底层：半圆内空白点按收起上下栏。因在 Stack 底层最后命中，
            // 进度环/按钮（上层）会优先处理，空白处才由此层收起。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => controller.controls = false,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned.fill(child: progressStack()),
            Positioned.fill(child: buildBottomControl()),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 7),
            child: progressStack(),
          ),
          buildBottomControl(),
        ],
      ),
    );
  }
}
