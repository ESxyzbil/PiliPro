import 'package:PiliPlus/models/common/search/search_type.dart';
import 'package:get/get.dart';

class SearchResultController extends GetxController {
  /// 显式传参（桌面端标签页模式）；为 null 时回退读取路由参数 Get.parameters['keyword']
  final String? keywordParam;

  SearchResultController({this.keywordParam});

  late String keyword = keywordParam ?? Get.parameters['keyword'] ?? '';

  RxList<int> count = List.filled(SearchType.values.length, -1).obs;

  RxInt toTopIndex = (-1).obs;

  @override
  void onClose() {
    toTopIndex.close();
    super.onClose();
  }
}
