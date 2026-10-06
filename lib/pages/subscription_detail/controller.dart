import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/sub/sub/list.dart';
import 'package:PiliPlus/models_new/sub/sub_detail/data.dart';
import 'package:PiliPlus/models_new/sub/sub_detail/media.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/services/download/download_batch.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:collection/collection.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 订阅合集详情：在收藏夹详情页的基础上补齐「离线优先 + 缓存全部」能力
class SubDetailController
    extends CommonListController<SubDetailData, SubDetailItemModel> {
  /// 显式传参（标签页模式）；为 null 时回退读取 Get.arguments / 路由参数
  final int? idParam;
  final SubItemModel? subInfoParam;
  final String? heroTagParam;

  SubDetailController({this.idParam, this.subInfoParam, this.heroTagParam});

  late int id;
  String? heroTag;
  SubItemModel? subInfo;

  /// 离线优先模式：有缓存就走本地，不走网络（默认开启，可按合集记忆）
  late final RxBool isPlayFromCache =
      (GStorage.localCache.get(
            _playFromCacheKey,
            defaultValue: true,
          )
          as bool)
          .obs;

  /// 当前合集所有已缓存的条目（供离线播放列表使用）
  final collectionCachedEntries = RxList<BiliDownloadEntryInfo>([]);

  /// 正在加载全部分页的计数（避免并发重复拉取）
  int _loadingAllPages = 0;

  String get _playFromCacheKey => 'play_from_cache_sub_$id';
  String get _cachedEntriesKey => 'sub_cached_entries_$id';
  String get _cacheFilePath => '$tmpDirPath/sub_detail_$id.json';

  bool get hasLocalCache => File(_cacheFilePath).existsSync();

  List<SubDetailItemModel>? get _allItems {
    if (loadingState.value case Success(:final response)) {
      return response;
    }
    return null;
  }

  @override
  void onInit() {
    super.onInit();
    final args = Get.arguments;
    if (idParam != null) {
      id = idParam!;
    } else if (args is Map && args['id'] is int) {
      id = args['id'] as int;
    } else {
      id = int.parse(Get.parameters['id']!);
    }
    subInfo = subInfoParam ?? (args is Map ? args['subInfo'] as SubItemModel? : null);
    heroTag = heroTagParam ?? (args is Map ? args['heroTag'] as String? : null);

    if (hasLocalCache) {
      // 有离线缓存 → 先显示缓存，再静默尝试在线刷新
      loadFromCache(silent: true);
    }
    queryData();
  }

  void setIsPlayFromCache(bool value) {
    if (isPlayFromCache.value == value) return;
    isPlayFromCache.value = value;
    GStorage.localCache.put(_playFromCacheKey, value);
  }

  @override
  List<SubDetailItemModel>? getDataList(SubDetailData response) {
    subInfo = response.info ?? subInfo;
    return response.medias;
  }

  @override
  void checkIsEnd(int length) {
    final count = subInfo?.mediaCount;
    if (count != null && length >= count) {
      isEnd = true;
    }
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<SubDetailData> response) {
    if (isRefresh) {
      final data = response.response;
      if (data.info != null) {
        subInfo = data.info;
      }
      final items = data.medias;
      if (items != null && items.isNotEmpty) {
        final count = subInfo?.mediaCount ?? 0;
        if (count > items.length) {
          // 还有更多页 → 加载全部再缓存
          isEnd = false;
          _cacheAllPages();
        } else {
          _saveCache(items);
          SmartDialog.showToast('💾 已缓存合集内容 (${items.length}条)');
        }
      }
    }
    return false;
  }

  @override
  bool handleError(String? errMsg) {
    if (hasLocalCache) {
      SmartDialog.showToast('📡 网络不可用，恢复缓存');
      loadFromCache(silent: true);
      return true;
    }
    SmartDialog.showToast('❌ 加载失败，未找到离线缓存');
    return false;
  }

  @override
  Future<LoadingState<SubDetailData>> customGetData() => FavHttp.favSeasonList(
    id: id,
    ps: 20,
    pn: page,
  );

  // ══════════════════════ 离线缓存读写 ══════════════════════

  void _saveCache(List<SubDetailItemModel> items) {
    final info = subInfo;
    final data = {
      'info': info == null
          ? null
          : {
              'id': info.id,
              'fid': info.fid,
              'mid': info.mid,
              'attr': info.attr,
              'title': info.title,
              'cover': info.cover,
              'upper': info.upper?.toJson(),
              'intro': info.intro,
              'state': info.state,
              'fav_state': info.favState,
              'media_count': info.mediaCount,
              'view_count': info.viewCount,
              'type': info.type,
              'cnt_info': info.cntInfo == null
                  ? null
                  : {
                      'play': info.cntInfo!.play,
                      'danmaku': info.cntInfo!.danmaku,
                    },
            },
      'items': items.map((e) => e.toJson()).toList(),
    };
    // 用文件缓存，彻底绕过 Hive 序列化问题
    final file = File(_cacheFilePath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(data), flush: true);
    // 写入 + 立即读回校验
    final verify = file.readAsStringSync();
    if (verify.isEmpty) {
      throw Exception('写入验证失败: 文件为空');
    }
    if (jsonDecode(verify) is! Map) {
      throw Exception('写入验证失败: 不是Map');
    }
    _refreshCollectionCachedEntries(items);
  }

  void loadFromCache({bool silent = false}) {
    final file = File(_cacheFilePath);
    if (!file.existsSync()) {
      if (!silent) SmartDialog.showToast('没有离线缓存');
      return;
    }
    try {
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      if (data['info'] case final Map<String, dynamic> info) {
        subInfo = SubItemModel.fromJson(info);
      }
      final items = (data['items'] as List)
          .map((e) => SubDetailItemModel.fromJson(e as Map<String, dynamic>))
          .toList();
      loadingState.value = Success(items);
      isEnd = true;
      page = 1;
      isPlayFromCache.value = true;
      if (!silent) {
        SmartDialog.showToast('✅ 从缓存加载合集内容 (${items.length}条)');
      }
      _restoreCollectionCachedEntries();
    } catch (e) {
      SmartDialog.showToast(
        '❌ 缓存损坏: ${e.toString().length > 200 ? e.toString().substring(0, 200) : e.toString()}',
      );
      file.deleteSync();
    }
  }

  /// 从缓存文件读取条目列表（不改变当前列表状态）
  List<SubDetailItemModel>? _loadCacheItems() {
    final file = File(_cacheFilePath);
    if (!file.existsSync()) return null;
    try {
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return (data['items'] as List)
          .map((e) => SubDetailItemModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// 从 downloadList 中筛选当前合集已缓存的条目（按合集顺序排列）
  ///
  /// 以 bvid 为主键匹配：合集列表接口不返回 cid、缓存文件里也可能尚未解析 cid，
  /// 只按 cid 匹配会漏掉绝大多数条目（表现为播放列表只剩第一条）。
  void _refreshCollectionCachedEntries(List<SubDetailItemModel> items) {
    final ds = Get.find<DownloadService>();
    final cached = items
        .map((item) {
          final bvid = item.bvid;
          final cid = item.cid;
          if (bvid == null && cid == null) return null;
          return ds.downloadList.firstWhereOrNull(
            (e) =>
                e.isCompleted &&
                ((bvid != null && e.bvid == bvid) ||
                    (cid != null && e.cid == cid)),
          );
        })
        .whereType<BiliDownloadEntryInfo>()
        .toList();
    if (cached.isEmpty && collectionCachedEntries.isNotEmpty) return;
    collectionCachedEntries.value = cached;
    GStorage.localCache.put(
      _cachedEntriesKey,
      jsonEncode(cached.map((e) => {'avid': e.avid, 'cid': e.cid}).toList()),
    );
  }

  /// 从本地持久化恢复合集已缓存条目
  void _restoreCollectionCachedEntries() {
    try {
      final raw = GStorage.localCache.get(_cachedEntriesKey);
      if (raw == null) return;
      final list = raw is String ? jsonDecode(raw) : raw;
      if (list is! List) return;
      final ds = Get.find<DownloadService>();
      final entries = <BiliDownloadEntryInfo>[];
      for (final e in list) {
        if (e is! Map) continue;
        final avid = e['avid'];
        final ci = e['cid'];
        if (avid is! int || ci is! int) continue;
        final found = ds.downloadList.firstWhereOrNull(
          (entry) => entry.avid == avid && entry.cid == ci && entry.isCompleted,
        );
        if (found != null) entries.add(found);
      }
      if (entries.isNotEmpty) {
        collectionCachedEntries.value = entries;
      }
    } catch (_) {}
  }

  /// 离线播放列表：每次都按最新缓存状态重新匹配（下载是异步完成的，
  /// 早先持久化的索引可能只含当时已完成的一两条，不能拿来短路）
  void _ensureCollectionCachedEntries({BiliDownloadEntryInfo? current}) {
    final cacheItems = _loadCacheItems();
    final items = (cacheItems != null &&
            cacheItems.length >= (_allItems?.length ?? 0))
        ? cacheItems
        : _allItems;
    if (items != null && items.isNotEmpty) {
      _refreshCollectionCachedEntries(items);
    } else if (collectionCachedEntries.isEmpty) {
      _restoreCollectionCachedEntries();
    }
    // 兜底：至少保证当前正在播放的这一条在列表里
    if (current != null &&
        collectionCachedEntries.every((e) => e.cid != current.cid)) {
      collectionCachedEntries.add(current);
    }
  }

  // ══════════════════════ 缓存全部 ══════════════════════

  /// 加载全部分页（缓存全部 / 打开页面自动整页缓存共用）
  Future<void> _loadAllPages() async {
    if (_loadingAllPages > 0) return;
    _loadingAllPages++;
    try {
      // 等待当前请求结束，避免在 isLoading 期间空转
      while (isLoading) {
        await Future.delayed(const Duration(milliseconds: 30));
      }
      // guard 兜底，避免 mediaCount 异常时死循环；列表不再增长即认为到底/请求失败
      var guard = 0;
      var lastLength = _allItems?.length ?? 0;
      while (!isEnd && guard++ < 500) {
        await queryData(false);
        final length = _allItems?.length ?? 0;
        if (length == lastLength) break;
        lastLength = length;
      }
    } finally {
      _loadingAllPages--;
    }
  }

  /// 打开页面时若缓存不完整 → 静默补齐整份列表
  void _cacheAllPages() {
    if (_loadingAllPages > 0) return;
    SmartDialog.showToast('🔄 正在缓存全部内容...');
    unawaited(
      _loadAllPages().then((_) {
        final allItems = _allItems;
        if (allItems != null && allItems.isNotEmpty) {
          _saveCache(allItems);
          SmartDialog.showToast('💾 已缓存全部内容 (${allItems.length}条)');
        }
      }),
    );
  }

  /// 缓存全部视频：弹出画质 + 音质选择，加载所有页，逐个提交下载
  Future<void> cacheAllVideos() async {
    final result = await pickDownloadQuality();
    if (result == null) return;
    final (videoQa, audioQa) = result;

    final current = _allItems;
    if (current == null || current.isEmpty) return;

    // 加载所有页
    SmartDialog.showToast('正在加载全部视频列表...');
    await _loadAllPages();

    final allItems = _allItems;
    if (allItems == null || allItems.isEmpty) return;

    // 合集列表接口不返回 cid，逐个解析（已解析过的直接复用）
    final targets = <BatchCacheTarget>[];
    var failed = 0;
    for (var i = 0; i < allItems.length; i++) {
      if (i % 10 == 0) {
        SmartDialog.showToast('正在解析视频信息... (${i + 1}/${allItems.length})');
      }
      final target = await _buildTarget(allItems[i]);
      if (target == null) {
        failed++;
        continue;
      }
      targets.add(target);
    }
    if (targets.isEmpty) {
      SmartDialog.showToast('没有解析到可缓存的视频');
      return;
    }

    final res = await queueBatchDownload(
      targets,
      videoQa: videoQa,
      audioQa: audioQa,
    );

    _saveCache(allItems);
    SmartDialog.showToast(
      '缓存完成：新增 ${res.queued}，已存在 ${res.restored}'
      '${failed > 0 ? '，$failed 条解析失败' : ''}',
    );
  }

  /// 组装单个批量缓存目标；cid 缺失时通过 ab2c 解析并回写
  Future<BatchCacheTarget?> _buildTarget(SubDetailItemModel item) async {
    final bvid = item.bvid;
    if (bvid == null) return null;
    var cid = item.cid;
    if (cid == null) {
      cid = (await SearchHttp.ab2cWithDimension(bvid: bvid))?.cid;
      if (cid == null) return null;
      item.cid = cid;
    }
    return BatchCacheTarget(
      avid: IdUtils.bv2av(bvid),
      cid: cid,
      bvid: bvid,
      title: item.title ?? '',
      cover: item.cover,
      duration: item.duration,
      owner: subInfo?.upper,
    );
  }

  // ══════════════════════ 离线优先播放 ══════════════════════

  /// 点击视频：离线优先模式下命中本地缓存则播放本地文件，否则在线播放
  /// [coverFrom] 为列表项封面的屏幕矩形，供封面飞行取源位置
  Future<void> onViewItem(
    SubDetailItemModel item,
    int? index, {
    Rect? coverFrom,
  }) async {
    final bvid = item.bvid;
    if (bvid == null) {
      SmartDialog.showToast('视频ID解析失败');
      return;
    }
    final avid = IdUtils.bv2av(bvid);

    if (isPlayFromCache.value) {
      final cid =
          item.cid ?? (await SearchHttp.ab2cWithDimension(bvid: bvid))?.cid;
      if (cid != null) {
        item.cid = cid;
        SmartDialog.showToast('正在查找本地缓存...');
        final cached = await findLocalCache(avid, cid);
        if (cached != null) {
          _ensureCollectionCachedEntries(current: cached);
          PageUtils.toVideoPage(
            bvid: bvid,
            aid: cached.avid,
            cid: cid,
            cover: item.cover,
            title: item.title,
            coverFrom: coverFrom,
            extraArguments: {
              'sourceType': SourceType.file,
              'entry': cached,
              'dirPath': cached.entryDirPath,
              'collectionEntries': collectionCachedEntries.toList(),
            },
          );
          return;
        }
        SmartDialog.showToast('本地无缓存，尝试在线播放...');
      }
    }

    // 在线播放
    final res = await SearchHttp.ab2cWithDimension(bvid: bvid);
    final cid = res?.cid ?? item.cid;
    if (cid == null) {
      SmartDialog.showToast('视频信息解析失败');
      return;
    }
    item.cid = cid;
    PageUtils.toVideoPage(
      bvid: bvid,
      cid: cid,
      cover: item.cover,
      title: item.title,
      dimension: res?.dimension,
      coverFrom: coverFrom,
    );
  }
}
