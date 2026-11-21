import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pbenum.dart'
    show ListOrder;

/// 音频页播放顺序的展示名（无序/正序/倒序/随机）
extension ListOrderExt on ListOrder {
  String get title => const ['无序', '正序', '倒序', '随机'][value];
}
