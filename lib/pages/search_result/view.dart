import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/scroll_physics.dart' show tabBarView;
import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:PiliPlus/models/common/search/search_type.dart';
import 'package:PiliPlus/pages/search/controller.dart';
import 'package:PiliPlus/pages/search_panel/all/view.dart';
import 'package:PiliPlus/pages/search_panel/article/view.dart';
import 'package:PiliPlus/pages/search_panel/live/view.dart';
import 'package:PiliPlus/pages/search_panel/pgc/view.dart';
import 'package:PiliPlus/pages/search_panel/user/view.dart';
import 'package:PiliPlus/pages/search_panel/video/view.dart';
import 'package:PiliPlus/pages/search_result/controller.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class SearchResultPage extends StatefulWidget {
  const SearchResultPage({
    super.key,
    this.keyword,
    this.tag,
    this.fromSearch,
    this.initIndex,
  });

  /// 显式传参（桌面端标签页模式）；为 null 时回退读取路由参数
  final String? keyword;
  final String? tag;
  final bool? fromSearch;
  final int? initIndex;

  @override
  State<SearchResultPage> createState() => _SearchResultPageState();
}

class _SearchResultPageState extends State<SearchResultPage>
    with SingleTickerProviderStateMixin {
  late SearchResultController _searchResultController;
  late TabController _tabController;
  final String _tag = DateTime.now().millisecondsSinceEpoch.toString();
  late final bool _isFromSearch =
      widget.fromSearch ?? (Get.arguments?['fromSearch'] ?? false);
  SSearchController? sSearchController;

  @override
  void initState() {
    super.initState();
    _searchResultController = Get.put(
      SearchResultController(keywordParam: widget.keyword),
      tag: _tag,
    );

    _tabController = TabController(
      vsync: this,
      initialIndex: widget.initIndex ?? (Get.arguments?['initIndex'] ?? 0),
      length: SearchType.values.length,
    );

    if (_isFromSearch) {
      try {
        sSearchController = Get.find<SSearchController>(
          tag: widget.tag ?? Get.parameters['tag'],
        );
        _tabController.addListener(listener);
      } catch (_) {}
    }
  }

  void listener() {
    sSearchController?.initIndex = _tabController.index;
  }

  /// 就地改词后重新搜索（回车触发）：开一个新的结果标签（旧结果标签保留，
  /// 可切回），与搜索页提交的行为一致。
  void _onSubmitKeyword(String value) {
    final keyword = value.trim();
    _searchResultController.focusNode.unfocus();
    if (keyword.isEmpty || keyword == _searchResultController.keyword) {
      return;
    }
    if (Pref.recordSearchHistory) {
      final history =
          List<String>.from(
              GStorage.historyWord.get('cacheList') ?? const <String>[],
            )
            ..remove(keyword)
            ..insert(0, keyword);
      GStorage.historyWord.put('cacheList', history);
    }
    PageUtils.toSearchResultPage(
      keyword: keyword,
      tag: widget.tag,
      initIndex: _tabController.index,
      fromSearch: _isFromSearch,
    );
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(listener)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SimpleScaffold(
      appBar: AppBar(
        shape: Border(
          bottom: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.08),
            width: 1,
          ),
        ),
        // 顶部搜索框：就地可编辑，回车以新关键词重新搜索。
        // （旧写法是 GestureDetector + Text，点击试图 Get.back()/offNamed，
        //   在标签页模式下两者都不生效 = "点了没反应"。）
        title: TextField(
          controller: _searchResultController.textController,
          focusNode: _searchResultController.focusNode,
          style: theme.textTheme.titleMedium,
          textInputAction: TextInputAction.search,
          maxLines: 1,
          decoration: const InputDecoration(
            border: InputBorder.none,
            isDense: true,
            hintText: '搜索',
          ),
          onSubmitted: _onSubmitKeyword,
        ),
      ),
      body: ViewSafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TabBar(
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              splashFactory: NoSplash.splashFactory,
              padding: const EdgeInsets.only(top: 4, left: 8, right: 8),
              controller: _tabController,
              tabs: SearchType.values
                  .map(
                    (item) => Obx(
                      () {
                        int count = _searchResultController.count[item.index];
                        return Tab(
                          text:
                              '${item.label}${count != -1 ? ' ${count > 99 ? '99+' : count}' : ''}',
                        );
                      },
                    ),
                  )
                  .toList(),
              isScrollable: true,
              indicatorWeight: 0,
              indicatorPadding: const EdgeInsets.symmetric(
                horizontal: 3,
                vertical: 8,
              ),
              indicator: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: const BorderRadius.all(Radius.circular(20)),
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              labelColor: theme.colorScheme.onSecondaryContainer,
              labelStyle:
                  TabBarTheme.of(
                    context,
                  ).labelStyle?.copyWith(fontSize: 13) ??
                  const TextStyle(fontSize: 13),
              dividerColor: Colors.transparent,
              dividerHeight: 0,
              unselectedLabelColor: theme.colorScheme.outline,
              tabAlignment: TabAlignment.start,
              onTap: (index) {
                if (!_tabController.indexIsChanging) {
                  if (_searchResultController.toTopIndex.value == index) {
                    _searchResultController.toTopIndex.refresh();
                  } else {
                    _searchResultController.toTopIndex.value = index;
                  }
                }
              },
            ),
            Expanded(
              child: tabBarView(
                controller: _tabController,
                children: SearchType.values
                    .map(
                      (item) => switch (item) {
                        .all => SearchAllPanel(
                          tag: _tag,
                          searchType: item,
                          keyword: _searchResultController.keyword,
                        ),
                        .video => SearchVideoPanel(
                          tag: _tag,
                          searchType: item,
                          keyword: _searchResultController.keyword,
                        ),
                        .media_bangumi || .media_ft => SearchPgcPanel(
                          tag: _tag,
                          searchType: item,
                          keyword: _searchResultController.keyword,
                        ),
                        .live_room => SearchLivePanel(
                          tag: _tag,
                          searchType: item,
                          keyword: _searchResultController.keyword,
                        ),
                        .bili_user => SearchUserPanel(
                          tag: _tag,
                          searchType: item,
                          keyword: _searchResultController.keyword,
                        ),
                        .article => SearchArticlePanel(
                          tag: _tag,
                          searchType: item,
                          keyword: _searchResultController.keyword,
                        ),
                      },
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
