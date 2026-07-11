import 'dart:convert';
import 'dart:io';
import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/fav/fav_folder/data.dart';
import 'package:PiliPlus/models_new/fav/fav_folder/list.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class FavController extends CommonListController<FavFolderData, FavFolderInfo> {
  late final account = Accounts.main;
  static const _favListCacheKey = 'fav_folder_list_v2';
  File get _favListCacheFile =>
      File('$tmpDirPath/fav_folder_list.json');

  bool get hasLocalCache => _favListCacheFile.existsSync();

  @override
  void onInit() {
    super.onInit();
    if (hasLocalCache) {
      loadFromCache();
    }
    queryData();
  }

  void loadFromCache() {
    final file = _favListCacheFile;
    if (!file.existsSync()) {
      SmartDialog.showToast('未找到离线缓存');
      return;
    }
    try {
      final raw = file.readAsStringSync();
      if (raw.trim().isEmpty) {
        SmartDialog.showToast('❌ 缓存为空');
        file.deleteSync();
        return;
      }
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final list = (data['list'] as List)
          .map((e) => FavFolderInfo.fromJson(e as Map<String, dynamic>))
          .toList();
      loadingState.value = Success(list);
      isEnd = data['has_more'] != true;
      SmartDialog.showToast('✅ 从缓存加载收藏夹列表 (${list.length}个)');
    } catch (e) {
      SmartDialog.showToast('❌ 缓存损坏: ${e.toString().length > 200 ? e.toString().substring(0, 200) : e.toString()}');
      file.deleteSync();
    }
  }

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (!account.isLogin) {
      loadingState.value = const Error('账号未登录');
      return Future.syncValue(null);
    }
    return super.queryData(isRefresh);
  }

  @override
  List<FavFolderInfo>? getDataList(FavFolderData response) {
    if (response.hasMore == false) {
      isEnd = true;
    }
    return response.list;
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<FavFolderData> res) {
    if (isRefresh && res.response.list != null) {
      _saveFavListCache(res.response);
      SmartDialog.showToast('💾 已缓存收藏夹列表');
    }
    return false;
  }

  @override
  bool handleError(String? errMsg) {
    if (hasLocalCache) {
      SmartDialog.showToast('📡 网络不可用，恢复缓存');
      loadFromCache();
      return true;
    }
    return false;
  }

  void _saveFavListCache(FavFolderData data) {
    final json = {
      'count': data.count,
      'has_more': data.hasMore,
      'list': data.list?.map((e) => {
        'id': e.id,
        'fid': e.fid,
        'mid': e.mid,
        'attr': e.attr,
        'title': e.title,
        'cover': e.cover,
        'intro': e.intro,
        'fav_state': e.favState,
        'media_count': e.mediaCount,
        'upper': e.upper?.toJson(),
      }).toList(),
    };
    final jsonStr = jsonEncode(json);
    _favListCacheFile.parent.createSync(recursive: true);
    _favListCacheFile.writeAsStringSync(jsonStr);
    // 验证
    final _ = jsonDecode(_favListCacheFile.readAsStringSync());
  }

  @override
  Future<LoadingState<FavFolderData>> customGetData() => FavHttp.userfavFolder(
    pn: page,
    ps: 20,
    mid: account.mid,
  );
}
