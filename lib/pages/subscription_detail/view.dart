import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/sub/sub/list.dart';
import 'package:PiliPlus/models_new/sub/sub_detail/media.dart';
import 'package:PiliPlus/pages/subscription_detail/controller.dart';
import 'package:PiliPlus/pages/tabhost/tab_controller.dart';
import 'package:PiliPlus/pages/subscription_detail/widget/sub_video_card.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class SubDetailPage extends StatefulWidget {
  const SubDetailPage({
    super.key,
    this.id,
    this.subInfo,
    this.heroTag,
    this.coverKey,
    this.coverVisible,
  });

  /// 显式传参（标签页模式）；为 null 时回退读取 Get.arguments / 路由参数
  final int? id;
  final SubItemModel? subInfo;
  final String? heroTag;

  /// 封面飞行：目标封面的 key，以及「飞行期间是否显示该封面」
  final GlobalKey? coverKey;
  final ValueNotifier<bool>? coverVisible;

  @override
  State<SubDetailPage> createState() => _SubDetailPageState();

  static void toSubDetailPage(
    int id, {
    String? heroTag,
    SubItemModel? subInfo,
  }) {
    Get.toNamed(
      '/subDetail',
      arguments: {
        'id': id,
        'subInfo': subInfo,
        'heroTag': heroTag,
      },
    );
  }
}

class _SubDetailPageState extends State<SubDetailPage> with GridMixin {
  late final SubDetailController _subDetailController;

  @override
  void initState() {
    super.initState();
    _subDetailController = Get.put(
      SubDetailController(
        idParam: widget.id,
        subInfoParam: widget.subInfo,
        heroTagParam: widget.heroTag,
      ),
      tag: Utils.makeHeroTag(widget.id ?? Get.parameters['id']),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final padding = MediaQuery.viewPaddingOf(context);
    return Material(
      color: theme.colorScheme.surface,
      child: refreshIndicator(
        onRefresh: _subDetailController.onRefresh,
        child: CustomScrollView(
          controller: _subDetailController.scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            _appBar(theme, padding),
            SliverToBoxAdapter(
              child: _cacheBar(theme, padding),
            ),
            SliverPadding(
              padding: EdgeInsets.only(
                top: 7,
                left: padding.left,
                right: padding.right,
                bottom: padding.bottom + 100,
              ),
              sliver: Obx(
                () => _buildBody(_subDetailController.loadingState.value),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 离线优先开关 + 缓存全部（与收藏夹详情页一致）
  Widget _cacheBar(ThemeData theme, EdgeInsets padding) {
    return Obx(() {
      final isCache = _subDetailController.isPlayFromCache.value;
      return Container(
        padding: EdgeInsets.symmetric(horizontal: 12 + padding.left),
        color: isCache
            ? theme.colorScheme.primaryContainer.withOpacity(0.4)
            : null,
        child: Row(
          children: [
            Text('离线优先', style: theme.textTheme.labelMedium),
            const SizedBox(width: 16),
            Switch(
              value: isCache,
              onChanged: (v) => _subDetailController.setIsPlayFromCache(v),
            ),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.download, size: 18),
              label: const Text('缓存全部'),
              onPressed: () => _subDetailController.cacheAllVideos(),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildBody(LoadingState<List<SubDetailItemModel>?> loadingState) {
    return switch (loadingState) {
      Loading() => gridSkeleton,
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? SliverGrid.builder(
                gridDelegate: gridDelegate,
                itemBuilder: (context, index) {
                  if (index == response.length - 1) {
                    _subDetailController.onLoadMore();
                  }
                  return SubVideoCardH(
                    videoItem: response[index],
                    ctr: _subDetailController,
                    index: index,
                  );
                },
                itemCount: response.length,
              )
            : HttpError(onReload: _subDetailController.onReload),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: _subDetailController.onReload,
      ),
    };
  }

  Widget _appBar(ThemeData theme, EdgeInsets padding) {
    final info = _subDetailController.subInfo;
    if (info != null) return _buildAppBar(theme, padding, info);
    return Obx(() {
      return switch (_subDetailController.loadingState.value) {
        Loading() || Error() => const SliverAppBar(),
        Success() => _buildAppBar(
          theme,
          padding,
          _subDetailController.subInfo!,
        ),
      };
    });
  }

  Widget _buildAppBar(ThemeData theme, EdgeInsets padding, SubItemModel info) {
    final style = TextStyle(
      height: 1,
      fontSize: 12.5,
      color: theme.colorScheme.outline,
    );
    Widget cover = NetworkImgLayer(
      width: 176,
      height: 110,
      src: info.cover,
    );
    // 封面飞行：目标封面挂 key，飞行期间由 CoverFlight 置为不可见
    if (widget.coverKey != null) {
      cover = KeyedSubtree(key: widget.coverKey, child: cover);
    }
    if (widget.coverVisible != null) {
      cover = ValueListenableBuilder<bool>(
        valueListenable: widget.coverVisible!,
        builder: (_, visible, child) =>
            Opacity(opacity: visible ? 1 : 0, child: child),
        child: cover,
      );
    }
    if (_subDetailController.heroTag != null) {
      cover = Hero(
        tag: _subDetailController.heroTag!,
        child: cover,
      );
    }
    return SliverAppBar.medium(
      expandedHeight: kToolbarHeight + 132,
      pinned: true,
      // 标签承载时 AppBar 不会自动生成返回箭头，显式补一个
      leading: TabHostController.isTabHostedPage
          ? IconButton(
              tooltip: '返回',
              onPressed: () {
                if (TabHostController.handleBack()) return;
                Get.back();
              },
              icon: const Icon(Icons.arrow_back_outlined),
            )
          : null,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            info.title!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium,
          ),
          Text(
            '共${info.mediaCount}条视频',
            style: theme.textTheme.labelMedium,
          ),
        ],
      ),
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.2),
              ),
            ),
          ),
          padding: EdgeInsets.only(
            top: kToolbarHeight + padding.top + 10,
            left: 12 + padding.left,
            right: 12,
            bottom: 12,
          ),
          child: Row(
            spacing: 12,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              cover,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        info.title!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () =>
                          PageUtils.toMemberPage(mid: info.upper!.mid),
                      child: Text(
                        info.upper!.name!,
                        style: TextStyle(color: theme.colorScheme.primary),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text('共${info.mediaCount}条视频', style: style),
                    const SizedBox(height: 4),
                    Text(
                      '${NumUtils.numFormat(info.viewCount ?? info.cntInfo?.play)}次播放',
                      style: style,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
