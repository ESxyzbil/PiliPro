import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/model_owner.dart';
import 'package:PiliPlus/models/common/video/audio_quality.dart';
import 'package:PiliPlus/models/common/fav_order_type.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/fav/fav_detail/data.dart';
import 'package:PiliPlus/models_new/fav/fav_detail/media.dart';
import 'package:PiliPlus/models_new/fav/fav_folder/list.dart';
import 'package:PiliPlus/models_new/video/video_detail/arc.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart' as ugc;
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/pages/audio/view.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pbenum.dart'
    show PlaylistSource;
import 'package:PiliPlus/pages/common/multi_select/base.dart';
import 'package:PiliPlus/pages/common/multi_select/multi_select_controller.dart';
import 'package:PiliPlus/pages/fav_sort/view.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;

mixin BaseFavController
    on
        CommonListController<FavDetailData, FavDetailItemModel>,
        DeleteItemMixin<FavDetailData, FavDetailItemModel> {
  bool get isOwner;
  int get mediaId;

  ValueChanged<int>? updateCount;

  void onViewFav(FavDetailItemModel item, int? index);

  Future<void> onPlayAudio(FavDetailItemModel item) async {}

  Future<void> onCancelFav(int index, int id, int type) async {
    final res = await FavHttp.favVideo(
      resources: '$id:$type',
      delIds: mediaId.toString(),
    );
    if (res.isSuccess) {
      loadingState
        ..value.data!.removeAt(index)
        ..refresh();
      updateCount?.call(1);
      SmartDialog.showToast('取消收藏');
    } else {
      res.toast();
    }
  }

  @override
  void onRemove() {
    showConfirmDialog(
      context: Get.context!,
      title: const Text('提示'),
      content: const Text('确认删除所选收藏吗？'),
      onConfirm: () async {
        final removeList = allChecked.toSet();
        final res = await FavHttp.favVideo(
          resources: removeList
              .map((item) => '${item.id}:${item.type}')
              .join(','),
          delIds: mediaId.toString(),
        );
        if (res.isSuccess) {
          updateCount?.call(removeList.length);
          afterDelete(removeList);
          SmartDialog.showToast('取消收藏');
        } else {
          res.toast();
        }
      },
    );
  }
}

class FavDetailController
    extends MultiSelectController<FavDetailData, FavDetailItemModel>
    with BaseFavController {
  /// 显式传参（桌面端标签页模式）；为 null 时回退读取路由参数 Get.parameters
  final String? mediaIdParam;
  final String? heroTagParam;

  FavDetailController({this.mediaIdParam, this.heroTagParam});

  @override
  late int mediaId;
  late String heroTag;
  final Rx<FavFolderInfo> folderInfo = FavFolderInfo().obs;
  final RxBool _isOwner = false.obs;
  final Rx<FavOrderType> order = FavOrderType.mtime.obs;

  @override
  bool get isOwner => _isOwner.value;

  late final account = Accounts.main;

  late double dx = 0;
  late final RxBool isPlayAll = Pref.enablePlayAll.obs;

  /// 离线优先模式：有缓存就走本地，不走网络
  late final RxBool isPlayFromCache = (GStorage.localCache.get(
        'play_from_cache_$mediaId',
        defaultValue: false,
      ) as bool).obs;

  /// 当前收藏夹所有已缓存的条目（供播放列表使用）
  final collectionCachedEntries = RxList<BiliDownloadEntryInfo>([]);

  String get _favCacheKey => 'fav_cache_$mediaId';
  String get _favCachedEntriesKey => 'fav_cached_entries_$mediaId';

  void setIsPlayAll(bool isPlayAll) {
    if (this.isPlayAll.value == isPlayAll) return;
    this.isPlayAll.value = isPlayAll;
    GStorage.setting.put(SettingBoxKey.enablePlayAll, isPlayAll);
  }

  void setIsPlayFromCache(bool value) {
    if (isPlayFromCache.value == value) return;
    isPlayFromCache.value = value;
    GStorage.localCache.put('play_from_cache_$mediaId', value);
  }

  @override
  void onInit() {
    super.onInit();

    mediaId = int.parse(mediaIdParam ?? Get.parameters['mediaId']!);
    heroTag = heroTagParam ?? Get.parameters['heroTag']!;

    if (hasLocalFavCache) {
      // 有离线缓存 → 先显示缓存，再静默尝试在线刷新
      loadFromCache(silent: true);
    }

    // 网络加载（成功后会自动在 customHandleResponse 更新缓存）
    queryData();
  }

  @override
  bool? get hasFooter => true;

  @override
  List<FavDetailItemModel>? getDataList(FavDetailData response) {
    if (response.hasMore == false) {
      isEnd = true;
    }
    return response.medias;
  }

  @override
  void checkIsEnd(int length) {
    if (length >= folderInfo.value.mediaCount) {
      isEnd = true;
    }
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<FavDetailData> response) {
    if (isRefresh) {
      FavDetailData data = response.response;
      folderInfo.value = data.info!;
      _isOwner.value = data.info?.mid == account.mid;
      if (data.medias case final List<FavDetailItemModel> items when items.isNotEmpty) {
        final count = folderInfo.value.mediaCount;
        if (count > items.length) {
          // 还有更多页 → 加载全部再缓存
          isEnd = false;
          _cacheAllPages();
        } else {
          _saveFavCache(items);
          SmartDialog.showToast('💾 已缓存收藏夹内容 (${items.length}条)');
        }
      }
    }
    return false;
  }

  @override
  bool handleError(String? errMsg) {
    if (hasLocalFavCache) {
      SmartDialog.showToast('📡 网络不可用，恢复缓存');
      loadFromCache(silent: true);
      return true;
    }
    SmartDialog.showToast('❌ 加载失败，未找到离线缓存');
    return false;
  }

  @override
  ValueChanged<int>? get updateCount =>
      (count) => folderInfo
        ..value.mediaCount -= count
        ..refresh();

  @override
  Future<LoadingState<FavDetailData>> customGetData() =>
      FavHttp.userFavFolderDetail(
        pn: page,
        ps: 20,
        mediaId: mediaId,
        order: order.value,
      );

  void toViewPlayAll() {
    if (loadingState.value case Success(:final response)) {
      if (response == null || response.isEmpty) return;

      for (FavDetailItemModel element in response) {
        if (element.ugc?.firstCid == null) {
          continue;
        } else {
          onViewFav(element, null);
          break;
        }
      }
    }
  }

  /// 缓存全部视频：弹出画质+音质选择对话框，加载所有页，逐个提交下载
  Future<void> cacheAllVideos() async {
    // 弹出音画质选择
    final result = await _pickQuality();
    if (result == null) return;
    final (VideoQuality videoQa, AudioQuality audioQa) = result;

    if (loadingState.value case Success(:final response)) {
      if (response == null || response.isEmpty) return;
    }
    // 加载所有页
    SmartDialog.showToast('正在加载全部视频列表...');
    while (!isEnd) {
      await queryData(false);
    }
    List<FavDetailItemModel>? allItems;
    if (loadingState.value case Success(:final response)) {
      allItems = response;
    }
    if (allItems == null || allItems.isEmpty) return;

    final ds = Get.find<DownloadService>();

    int restored = 0;
    int queued = 0;

    // 如果用户选了非默认音质，临时保存并下载后恢复
    final oldAudioQa = Pref.defaultAudioQa;
    if (audioQa.code != oldAudioQa) {
      await GStorage.setting.put(SettingBoxKey.defaultAudioQa, audioQa.code);
    }

    for (final item in allItems) {
      final cid = item.ugc?.firstCid;
      final bvid = item.bvid;
      if (cid == null || bvid == null) continue;
      final avid = IdUtils.bv2av(bvid);

      // 已存在于 downloadList（已完成）
      if (ds.downloadList.any((e) => e.cid == cid && e.isCompleted)) {
        continue;
      }
      // 已存在于等待队列
      if (ds.waitDownloadQueue.any((e) => e.cid == cid)) {
        continue;
      }

      // 扫描磁盘（重启后 downloadList 可能为空）
      bool foundOnDisk = false;
      for (final basePath in {downloadPath, defDownloadPath}) {
        final entryDirPath = p.join(basePath, avid.toString(), 'c_$cid');
        final entryFile = File(p.join(entryDirPath, 'entry.json'));
        if (entryFile.existsSync()) {
          try {
            final existingJson = await entryFile.readAsString();
            final existing = BiliDownloadEntryInfo.fromJson(jsonDecode(existingJson))
              ..pageDirPath = p.join(basePath, avid.toString())
              ..entryDirPath = entryDirPath;
            if (existing.isCompleted) {
              if (ds.downloadList.indexWhere((e) => e.cid == cid) < 0) {
                ds.downloadList.add(existing);
              }
              restored++;
              foundOnDisk = true;
              break;
            }
          } catch (_) {}
        }
      }
      if (foundOnDisk) continue;

      // 需要新下载
      final part = Part(
        cid: cid,
        page: 1,
        from: '',
        part: item.title,
        vid: bvid,
        duration: item.duration,
      );
      final episodeItem = ugc.EpisodeItem(
        aid: avid,
        cid: cid,
        bvid: bvid,
        title: item.title,
        arc: Arc(
          aid: avid,
          pic: item.cover,
          title: item.title,
          duration: item.duration,
          author: item.upper != null
              ? Owner(mid: item.upper!.mid, name: item.upper!.name)
              : null,
        ),
        page: part,
        pages: [part],
      );
      ds.downloadVideo(part, null, episodeItem, videoQa);
      queued++;
    }

    // 恢复原始音质设置
    if (audioQa.code != oldAudioQa) {
      await GStorage.setting.put(SettingBoxKey.defaultAudioQa, oldAudioQa);
    }

    // 保存缓存索引
    _saveFavCache(allItems);
    SmartDialog.showToast('缓存完成：新增 $queued，已存在 $restored');
  }

  /// 弹出画质 + 音质选择对话框
  Future<(VideoQuality, AudioQuality)?> _pickQuality() async {
    final defaultVideoCode = Pref.defaultVideoQa;
    final defaultVideo = VideoQuality.values.firstWhereOrNull(
      (q) => q.code == defaultVideoCode,
    ) ?? VideoQuality.high1080;
    final defaultAudio = AudioQuality.fromCode(Pref.defaultAudioQa);

    Rx<VideoQuality> videoQuality = defaultVideo.obs;
    Rx<AudioQuality> audioQuality = defaultAudio.obs;

    return await showDialog<(VideoQuality, AudioQuality)?>(
      context: Get.context!,
      barrierDismissible: false,
      builder: (context) => SimpleDialog(
        title: const Text('选择下载画质和音质'),
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 24, top: 8, bottom: 4),
            child: Text('视频画质', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          for (final q in VideoQuality.values)
            Obx(
              () => RadioListTile<VideoQuality>(
                dense: true,
                title: Text('${q.desc} (${q.shortDesc})'),
                value: q,
                groupValue: videoQuality.value,
                onChanged: (v) {
                  if (v == null) return;
                  videoQuality.value = v;
                },
              ),
            ),
          const Divider(height: 1),
          const Padding(
            padding: EdgeInsets.only(left: 24, top: 8, bottom: 4),
            child: Text('音频音质', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          for (final q in AudioQuality.values)
            Obx(
              () => RadioListTile<AudioQuality>(
                dense: true,
                title: Text('${q.desc} (${q.code})'),
                value: q,
                groupValue: audioQuality.value,
                onChanged: (v) {
                  if (v == null) return;
                  audioQuality.value = v;
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(
                (videoQuality.value, audioQuality.value),
              ),
              child: const Text('开始缓存'),
            ),
          ),
        ],
      ),
    );
  }

  void _saveFavCache(List<FavDetailItemModel> items) {
    final itemsData = items.map((e) => <String, dynamic>{
      'id': e.id,
      'type': e.type,
      'title': e.title,
      'cover': e.cover,
      'intro': e.intro,
      'duration': e.duration,
      'upper': e.upper?.toJson(),
      'attr': e.attr,
      'fav_time': e.favTime,
      'bvid': e.bvid,
      'bv_id': e.bvid,
      'cnt_info': e.cntInfo != null
          ? {'play': e.cntInfo!.play, 'danmaku': e.cntInfo!.danmaku}
          : null,
      'ogv': e.ogv != null
          ? {'type_name': e.ogv!.typeName, 'season_id': e.ogv!.seasonId}
          : null,
      'ugc': e.ugc != null ? {'first_cid': e.ugc!.firstCid} : null,
    }).toList();
    final data = {
      'folderInfo': {
        'title': folderInfo.value.title,
        'cover': folderInfo.value.cover,
        'mediaCount': folderInfo.value.mediaCount,
        'upper': folderInfo.value.upper?.toJson(),
      },
      'items': itemsData,
    };
    // 用文件缓存，彻底绕过 Hive 序列化问题
    final jsonStr = jsonEncode(data);
    final file = File('$tmpDirPath/fav_detail_$mediaId.json');
    file.parent.createSync(recursive: true);
    // 写入 + 立即读回校验
    file.writeAsStringSync(jsonStr, flush: true);
    final verify = file.readAsStringSync();
    if (verify.isEmpty) {
      throw Exception('写入验证失败: 文件为空');
    }
    final verifyParsed = jsonDecode(verify);
    if (verifyParsed is! Map) {
      throw Exception('写入验证失败: 不是Map, 而是${verifyParsed.runtimeType}');
    }
    _updateFavIndex(items);
    // 收集已缓存条目供播放列表使用
    final ds = Get.find<DownloadService>();
    _refreshCollectionCachedEntries(items);
  }

  void _updateFavIndex(List<FavDetailItemModel> items) {
    final index = _loadFavIndex();
    final idx = index.indexWhere((e) => e['mediaId'] == mediaId);
    final entry = {
      'mediaId': mediaId,
      'title': folderInfo.value.title ?? '',
      'cover': folderInfo.value.cover ?? '',
      'count': items.length,
    };
    if (idx >= 0) {
      index[idx] = entry;
    } else {
      index.add(entry);
    }
    GStorage.localCache.put('cached_favs_index', jsonEncode(index));
  }

  static List<Map<String, dynamic>> _loadFavIndex() {
    final raw = GStorage.localCache.get('cached_favs_index') as String?;
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => e as Map<String, dynamic>)
          .toList();
    } catch (_) {
      return [];
    }
  }

  int get itemsCount {
    if (loadingState.value case Success(:final response)) {
      return response?.length ?? 0;
    }
    return 0;
  }

  bool get hasLocalFavCache =>
      File('$tmpDirPath/fav_detail_$mediaId.json').existsSync();

  void loadFromCache({bool silent = false}) {
    final file = File('$tmpDirPath/fav_detail_$mediaId.json');
    if (!file.existsSync()) {
      if (!silent) SmartDialog.showToast('没有离线缓存');
      return;
    }
    try {
      final raw = file.readAsStringSync();
      // 第一步：检查 raw 内容
      final preview = raw.length > 80 ? raw.substring(0, 80) : raw;
      // 不弹 toast 了，直接在 try 内分步捕获
      late Map<String, dynamic> data;
      try {
        data = jsonDecode(raw) as Map<String, dynamic>;
      } catch (e) {
        SmartDialog.showToast('❌ jsonDecode失败: ${e.toString().length > 80 ? e.toString().substring(0, 80) : e.toString()}');
        file.deleteSync();
        return;
      }
      // 第二步：解析 folderInfo
      Map<String, dynamic> fi;
      try {
        fi = data['folderInfo'] as Map<String, dynamic>;
      } catch (e) {
        SmartDialog.showToast('❌ folderInfo解析失败: $e');
        file.deleteSync();
        return;
      }
      folderInfo.value.title = (fi['title'] as String?) ?? '';
      folderInfo.value.cover = (fi['cover'] as String?) ?? '';
      folderInfo.value.mediaCount = (fi['mediaCount'] as int?) ?? 0;
      if (fi['upper'] != null) {
        folderInfo.value.upper = Owner.fromJson(fi['upper'] as Map<String, dynamic>);
      }
      folderInfo.refresh();
      // 第三步：解析 items
      List<FavDetailItemModel> items;
      try {
        final rawList = data['items'] as List;
        items = rawList.map((e) => FavDetailItemModel.fromJson(e as Map<String, dynamic>)).toList();
      } catch (e) {
        SmartDialog.showToast('❌ items解析失败: ${e.toString().length > 80 ? e.toString().substring(0, 80) : e.toString()}');
        file.deleteSync();
        return;
      }
      loadingState.value = Success(items);
      isEnd = true;
      page = 1;
      isPlayFromCache.value = true;
      SmartDialog.showToast('✅ 从缓存加载收藏夹内容 (${items.length}条)');
      _restoreCollectionCachedEntries();
    } catch (e) {
      SmartDialog.showToast('❌ 缓存损坏: ${e.toString().length > 200 ? e.toString().substring(0, 200) : e.toString()}');
      File('$tmpDirPath/fav_detail_$mediaId.json').deleteSync();
    }
  }

  /// 从 downloadList 中筛选当前收藏夹已缓存的条目
  void _refreshCollectionCachedEntries(List<FavDetailItemModel> items) {
    final ds = Get.find<DownloadService>();
    final cached = items.map((item) {
      final itemCid = item.ugc?.firstCid;
      final itemBvid = item.bvid;
      if (itemCid == null || itemBvid == null) return null;
      final avid = IdUtils.bv2av(itemBvid);
      return ds.downloadList.firstWhereOrNull(
        (e) => e.avid == avid && e.cid == itemCid && e.isCompleted,
      );
    }).whereType<BiliDownloadEntryInfo>().toList();
    collectionCachedEntries.value = cached;
    GStorage.localCache.put(
      _favCachedEntriesKey,
      cached.map((e) => {'avid': e.avid, 'cid': e.cid}).toList(),
    );
  }

  /// 从本地持久化恢复收藏夹已缓存条目
  void _restoreCollectionCachedEntries() {
    try {
      final raw = GStorage.localCache.get(_favCachedEntriesKey) as String?;
      if (raw == null) return;
      final ds = Get.find<DownloadService>();
      final entries = <BiliDownloadEntryInfo>[];
      for (final e in jsonDecode(raw) as List) {
        final m = e as Map<String, dynamic>;
        final avid = m['avid'] as int;
        final ci = m['cid'] as int;
        final found = ds.downloadList.firstWhereOrNull(
          (e) => e.avid == avid && e.cid == ci && e.isCompleted,
        );
        if (found != null) entries.add(found);
      }
      collectionCachedEntries.value = entries;
    } catch (_) {}
  }

  Future<void> _cacheAllPages() async {
    SmartDialog.showToast('🔄 正在缓存全部内容...');
    while (!isEnd) {
      await queryData(false);
    }
    if (loadingState.value case Success(:final response)) {
      final allItems = response as List<FavDetailItemModel>?;
      if (allItems != null && allItems.isNotEmpty) {
        _saveFavCache(allItems);
        SmartDialog.showToast('💾 已缓存全部内容 (${allItems.length}条)');
      }
    }
  }

  /// 通过 cid 查找本地缓存（downloadList + 磁盘兜底）
  Future<BiliDownloadEntryInfo?> _findLocalCache(int avid, int cid) async {
    try {
      final ds = Get.find<DownloadService>();
      await ds.waitForInitialization;

      // 1. downloadList
      final inList = ds.downloadList.firstWhereOrNull(
        (e) => e.avid == avid && e.cid == cid && e.isCompleted,
      );
      if (inList != null) return inList;

      // 2. 在等待队列中
      if (ds.waitDownloadQueue.any((e) => e.avid == avid && e.cid == cid)) return null;

      // 3. 扫描磁盘
      for (final basePath in {downloadPath, defDownloadPath}) {
        final entryDirPath = p.join(basePath, avid.toString(), 'c_$cid');
        final entryFile = File(p.join(entryDirPath, 'entry.json'));
        if (entryFile.existsSync()) {
          try {
            final existingJson = await entryFile.readAsString();
            final existing = BiliDownloadEntryInfo.fromJson(jsonDecode(existingJson))
              ..pageDirPath = p.join(basePath, avid.toString())
              ..entryDirPath = entryDirPath;
            if (existing.isCompleted) {
              ds.downloadList.add(existing);
              return existing;
            }
          } catch (_) {}
        }
      }
      return null;
    } catch (e) {
      SmartDialog.showToast('查找缓存出错：$e');
      return null;
    }
  }

  @override
  Future<void> onReload() {
    scrollController.jumpToTop();
    return super.onReload();
  }

  Future<void> onFav(bool isFav) async {
    if (!account.isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final res = isFav
        ? await FavHttp.unfavFavFolder(mediaId)
        : await FavHttp.favFavFolder(mediaId);

    if (res.isSuccess) {
      folderInfo
        ..value.favState = isFav ? 0 : 1
        ..refresh();
      SmartDialog.showToast('${isFav ? '取消' : ''}收藏成功');
    } else {
      res.toast();
    }
  }

  Future<void> cleanFav() async {
    final res = await FavHttp.cleanFav(mediaId: mediaId);
    if (res.isSuccess) {
      SmartDialog.showToast('清除成功');
      Future.delayed(const Duration(milliseconds: 200), onReload);
    } else {
      res.toast();
    }
  }

  void onSort() {
    if (loadingState.value case Success(:final response)) {
      if (response != null && response.isNotEmpty) {
        if (folderInfo.value.mediaCount > 1000) {
          SmartDialog.showToast('内容太多啦！超过1000不支持排序');
          return;
        }
        Get.to(FavSortPage(favDetailController: this));
      }
    }
  }

  @override
  Future<void> onViewFav(FavDetailItemModel item, int? index) async {
    try {
      final folder = folderInfo.value;
      final cid = item.ugc!.firstCid!;
      final avid = item.bvid != null ? IdUtils.bv2av(item.bvid!) : item.id;
      if (avid == null) {
        SmartDialog.showToast('视频ID解析失败');
        return;
      }

      // 离线优先模式：优先查找本地缓存
      if (isPlayFromCache.value) {
        SmartDialog.showToast('正在查找本地缓存...');
        final cached = await _findLocalCache(avid, cid);
        if (cached != null) {
          _ensureCollectionCachedEntries();
          PageUtils.toVideoPage(
            bvid: item.bvid,
            aid: cached.avid,
            cid: cid,
            cover: item.cover,
            title: item.title,
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

      // 在线播放
      PageUtils.toVideoPage(
        bvid: item.bvid,
        aid: avid,
        cid: cid,
        cover: item.cover,
        title: item.title,
        extraArguments: isPlayAll.value
            ? {
                'sourceType': SourceType.fav,
                'mediaId': folder.id,
                'oid': item.id,
                'favTitle': folder.title,
                'count': folder.mediaCount,
                'desc': true,
                if (index != null) 'isContinuePlaying': index != 0,
                'isOwner': isOwner,
              }
            : null,
      );
    } catch (e) {
      SmartDialog.showToast('播放失败：$e');
    }
  }

  /// 音频模式播放：离线优先查找本地缓存
  Future<void> onPlayAudio(FavDetailItemModel item) async {
    _ensureCollectionCachedEntries();
    final avid = item.bvid != null ? IdUtils.bv2av(item.bvid!) : item.id;
    final cid = item.ugc?.firstCid;
    if (avid == null || cid == null) {
      SmartDialog.showToast('视频ID解析失败');
      return;
    }

    // 离线优先模式
    if (isPlayFromCache.value) {
      final cached = await _findLocalCache(avid, cid);
      if (cached != null) {
        final String? audioPath;
        final fileDir = cached.typeTag != null
            ? '${cached.entryDirPath}/${cached.typeTag}'
            : cached.entryDirPath;
        if (cached.mediaType == 1) {
          // Type 1: 合并 mp4，把整个视频当音频播
          audioPath = '$fileDir/${PathUtils.videoNameType1}';
        } else {
          // Type 2: dash 分离，单独音频文件
          audioPath = '$fileDir/${PathUtils.audioNameType2}';
        }
        final audioFile = File(audioPath);
        if (audioFile.existsSync()) {
          // 下载服务已初始化，重新同步离线条目
          _reconcileOfflineEntries();
          AudioPage.toAudioPage(
            oid: avid,
            itemType: 1,
            subId: [cid],
            from: PlaylistSource.UP_ARCHIVE,
            audioUrl: audioPath,
            title: cached.title,
            cover: cached.cover,
            ownerName: cached.ownerName,
            ownerMid: cached.ownerId,
            offlineEntries: collectionCachedEntries.toList(),
          );
          return;
        }
        // 再试试另一种格式
        final altPath = cached.mediaType == 1
            ? '$fileDir/${PathUtils.audioNameType2}'
            : '$fileDir/${PathUtils.videoNameType1}';
        final altFile = File(altPath);
        if (altFile.existsSync()) {
          _reconcileOfflineEntries();
          AudioPage.toAudioPage(
            oid: avid,
            itemType: 1,
            subId: [cid],
            from: PlaylistSource.UP_ARCHIVE,
            audioUrl: altPath,
            title: cached.title,
            cover: cached.cover,
            ownerName: cached.ownerName,
            ownerMid: cached.ownerId,
            offlineEntries: collectionCachedEntries.toList(),
          );
          return;
        }
        SmartDialog.showToast('本地音频缓存不存在');
        return;
      }
      SmartDialog.showToast('本地无缓存，尝试在线播放...');
    }

    // 在线播放
    AudioPage.toAudioPage(
      oid: avid,
      itemType: 1,
      subId: [cid],
      from: PlaylistSource.UP_ARCHIVE,
      title: item.title,
      cover: item.cover,
      ownerName: item.upper?.name,
      ownerMid: item.upper?.mid,
    );
  }

  void _ensureCollectionCachedEntries() {
    // 尝试从持久化缓存恢复
    if (collectionCachedEntries.isEmpty) {
      _restoreCollectionCachedEntries();
    }
    if (collectionCachedEntries.isEmpty) {
      if (loadingState.value case Success(:final response)
          when response != null) {
        _refreshCollectionCachedEntries(response);
      }
    }
    // 如果缓存条目数少于收藏夹总数 → 用 fav cache 文件扫全量
    final totalCount = folderInfo.value.mediaCount;
    if (totalCount > 0 && collectionCachedEntries.length < totalCount) {
      final ds = Get.find<DownloadService>();
      final cached = _loadFavCacheItems();
      if (cached != null && cached.length > collectionCachedEntries.length) {
        final matched = cached.map((item) {
          final itemCid = item.ugc?.firstCid;
          final itemBvid = item.bvid;
          if (itemCid == null || itemBvid == null) return null;
          final avid = IdUtils.bv2av(itemBvid);
          return ds.downloadList.firstWhereOrNull(
            (e) => e.avid == avid && e.cid == itemCid && e.isCompleted,
          );
        }).whereType<BiliDownloadEntryInfo>().toList();
        if (matched.length > collectionCachedEntries.length) {
          collectionCachedEntries.value = matched;
          GStorage.localCache.put(
            _favCachedEntriesKey,
            matched.map((e) => {'avid': e.avid, 'cid': e.cid}).toList(),
          );
        }
      }
    }
  }

  /// 从 fav cache 文件读取完整条目列表，null 表示文件不存在或损坏
  List<FavDetailItemModel>? _loadFavCacheItems() {
    final file = File('$tmpDirPath/fav_detail_$mediaId.json');
    if (!file.existsSync()) return null;
    try {
      final raw = file.readAsStringSync();
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final rawList = data['items'] as List;
      return rawList
          .map((e) => FavDetailItemModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// 在下载服务初始化后重新构建离线条目列表
  void _reconcileOfflineEntries() {
    final ds = Get.find<DownloadService>();

    // 1. 优先用 fav cache 全量扫描
    final allItems = _loadFavCacheItems();
    if (allItems != null && allItems.isNotEmpty) {
      final matched = allItems.map((item) {
        final itemCid = item.ugc?.firstCid;
        final itemBvid = item.bvid;
        if (itemCid == null || itemBvid == null) return null;
        final avid = IdUtils.bv2av(itemBvid);
        return ds.downloadList.firstWhereOrNull(
          (e) => e.avid == avid && e.cid == itemCid && e.isCompleted,
        );
      }).whereType<BiliDownloadEntryInfo>().toList();
      if (matched.isNotEmpty) {
        collectionCachedEntries.value = matched;
        GStorage.localCache.put(
          _favCachedEntriesKey,
          matched.map((e) => {'avid': e.avid, 'cid': e.cid}).toList(),
        );
        return;
      }
    }

    // 2. 退而求其次用当前页数据扫描
    if (loadingState.value case Success(:final response) when response != null) {
      _refreshCollectionCachedEntries(response);
    }
  }
}
