import 'package:PiliPlus/models_new/fav/fav_detail/cnt_info.dart';

class SubDetailItemModel {
  int? id;
  String? title;
  String? cover;
  int? duration;
  int? pubtime;
  String? bvid;

  /// 首个分P的 cid（列表接口不一定返回，播放/缓存时会解析并回写）
  int? cid;
  CntInfo? cntInfo;

  SubDetailItemModel({
    this.id,
    this.title,
    this.cover,
    this.duration,
    this.pubtime,
    this.bvid,
    this.cid,
    this.cntInfo,
  });

  factory SubDetailItemModel.fromJson(Map<String, dynamic> json) =>
      SubDetailItemModel(
        id: json['id'] as int?,
        title: json['title'] as String?,
        cover: json['cover'] as String?,
        duration: json['duration'] as int?,
        pubtime: json['pubtime'] as int?,
        bvid: json['bvid'] as String?,
        cid: json['cid'] as int? ?? _firstCid(json['ugc']),
        cntInfo: json['cnt_info'] == null
            ? null
            : CntInfo.fromJson(json['cnt_info'] as Map<String, dynamic>),
      );

  /// 部分接口把首个分P放在 ugc.first_cid
  static int? _firstCid(Object? ugc) {
    if (ugc is Map) {
      final firstCid = ugc['first_cid'];
      if (firstCid is int) return firstCid;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'cover': cover,
    'duration': duration,
    'pubtime': pubtime,
    'bvid': bvid,
    'cid': cid,
    'cnt_info': cntInfo == null
        ? null
        : {'play': cntInfo!.play, 'danmaku': cntInfo!.danmaku},
  };
}
