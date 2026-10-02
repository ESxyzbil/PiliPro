import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/video_card/video_card_h.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/search.dart' show SearchHttp;
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/models_new/video/video_detail/dimension.dart'
    show Dimension;
import 'package:PiliPlus/pages/setting/widgets/info_card_item.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/related/controller.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

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

  /// 打开相关视频：替换当前视频标签（页面内派生操作）。
  /// cid 缺失/为 0 时先 ab2c 解析（B 站 related 接口的 cid 字段不可靠），
  /// 解析失败则不跳转（避免 cid=0 打开空白页）。
  Future<void> _openRelated(HotVideoItemModel item) async {
    if (kDebugMode) {
      debugPrint('RELATED_TAP bvid=${item.bvid} aid=${item.aid} cid=${item.cid}');
    }
    int? cid = item.cid;
    Dimension? dimension = item.dimension;
    if (cid == null || cid == 0) {
      if (await SearchHttp.ab2cWithDimension(
            aid: item.aid,
            bvid: item.bvid,
          )
          case final res?) {
        cid = res.cid;
        dimension = res.dimension;
        if (kDebugMode) {
          debugPrint('RELATED_TAP ab2c resolved cid=$cid');
        }
      }
    }
    if (cid == null || cid == 0) {
      if (kDebugMode) {
        debugPrint('RELATED_TAP cid unresolved, abort');
      }
      // cid 无法解析：不跳转（用户实测直接传 cid=0 会打开空白页）
      return;
    }
    if (kDebugMode) {
      debugPrint('RELATED_TAP open replaceCurrent=true cid=$cid');
    }
    PageUtils.toVideoPage(
      bvid: item.bvid,
      cid: cid,
      cover: item.cover,
      title: item.title,
      dimension: dimension,
      replaceCurrent: true,
    );
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
                      // 相关视频：页面内派生操作 → 替换当前视频标签，而非新开一页。
                      // ⚠️ 不能直接信任 item.cid：B 站 related 接口的 cid 常缺失
                      // 或为 0（该接口主要返回 aid/bvid）——cid==null 时 onTap 为
                      // null 会回退默认逻辑（新开标签且 replaceCurrent 丢失），
                      // cid==0 时直接传 cid! 会加载失败（用户实测"点击相关视频
                      // 无法前进"）。cid 有效才直接替换；缺失/为 0 时先 ab2c
                      // 解析 cid 再替换（与 VideoCardH 默认逻辑一致）。
                      onTap: () => _openRelated(item),
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
