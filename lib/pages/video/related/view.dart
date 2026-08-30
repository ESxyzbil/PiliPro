import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/video_card/video_card_h.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/pages/setting/widgets/info_card_item.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/related/controller.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class RelatedVideoPanel extends StatefulWidget {
  const RelatedVideoPanel({super.key, required this.heroTag});
  final String heroTag;
  @override
  State<RelatedVideoPanel> createState() => _RelatedVideoPanelState();
}

class _RelatedVideoPanelState extends State<RelatedVideoPanel> with GridMixin {
  late final RelatedController _relatedController;

  @override
  void initState() {
    super.initState();
    _relatedController = Get.putOrFind(
      () => RelatedController(bvid: _findBvid()),
      tag: widget.heroTag,
    );
  }

  /// 桌面端标签模式下 Get.arguments 为 null，RelatedController 无参构造
  /// 会拿到空 bvid 导致相关视频请求错误；从视频控制器显式取 bvid。
  String _findBvid() {
    try {
      return Get.find<VideoDetailController>(tag: widget.heroTag).bvid;
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.only(top: 7, bottom: 100),
      sliver: Obx(() => _buildBody(_relatedController.loadingState.value)),
    );
  }

  Widget _buildBody(LoadingState<List<HotVideoItemModel>?> loadingState) {
    return switch (loadingState) {
      Loading() => gridSkeleton,
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? SliverGrid.builder(
                gridDelegate: gridDelegate,
                itemBuilder: (context, index) {
                  final item = response[index];
                  return buildInfoCard(
                    VideoCardH(
                      videoItem: item,
                      onRemove: () => _relatedController.loadingState
                        ..value.data!.removeAt(index)
                        ..refresh(),
                      // 相关视频：替换当前视频标签，而非新开一页
                      onTap: item.cid == null
                          ? null
                          : () => PageUtils.toVideoPage(
                                bvid: item.bvid,
                                cid: item.cid!,
                                cover: item.cover,
                                title: item.title,
                                dimension: item.dimension,
                                replaceCurrent: true,
                              ),
                    ),
                  );
                },
                itemCount: response.length,
              )
            : const SliverToBoxAdapter(),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: _relatedController.onReload,
      ),
    };
  }
}
