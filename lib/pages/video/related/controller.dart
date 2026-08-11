import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:get/get.dart';

class RelatedController
    extends CommonListController<List<HotVideoItemModel>?, HotVideoItemModel> {
  RelatedController({this.autoQuery = true, String? bvid})
      : bvid = bvid ?? _defaultBvid();
  String bvid;
  final bool autoQuery;

  /// Get.arguments 可能为 null 或缺少 'bvid'（如 Windows 直接打开视频页），
  /// 此时用空串兜底，避免构造时抛异常
  static String _defaultBvid() {
    final args = Get.arguments;
    if (args is Map && args['bvid'] is String) {
      return args['bvid'] as String;
    }
    return '';
  }

  @override
  void onInit() {
    super.onInit();
    if (autoQuery) {
      queryData();
    }
  }

  @override
  Future<LoadingState<List<HotVideoItemModel>?>> customGetData() =>
      VideoHttp.relatedVideoList(bvid: bvid);
}
