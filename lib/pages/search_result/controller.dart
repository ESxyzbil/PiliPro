import 'package:PiliPlus/models/common/search/search_type.dart';
import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';

class SearchResultController extends GetxController {
  /// 显式传参（桌面端标签页模式）；为 null 时回退读取路由参数 Get.parameters['keyword']
  final String? keywordParam;

  SearchResultController({this.keywordParam});

  late String keyword = keywordParam ?? Get.parameters['keyword'] ?? '';

  /// 顶部搜索框：就地编辑关键词，回车以新关键词重新搜索
  late final TextEditingController textController = TextEditingController(
    text: keyword,
  );
  final focusNode = FocusNode();

  RxList<int> count = List.filled(SearchType.values.length, -1).obs;

  RxInt toTopIndex = (-1).obs;

  @override
  void onClose() {
    textController.dispose();
    focusNode.dispose();
    toTopIndex.close();
    super.onClose();
  }
}
