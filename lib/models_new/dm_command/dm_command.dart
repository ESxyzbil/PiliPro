import 'dart:convert';
import 'dart:typed_data';

import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart';

/// 指令弹幕（播放器内「打分 / 投票」等互动卡片的载体）
///
/// 数据来源：`GET /x/v2/dm/web/view?type=1&oid={cid}&pid={aid}`，
/// 返回 protobuf，其中第 9 号字段为 repeated CommandDm。
/// CommandDm 的第 5 号字段（本工程 pb 里叫 content）为卡片文案，
/// 第 6 号字段（progress）为该卡片的出现时间（ms），
/// 第 9 号字段（extra）为 JSON 载荷。
class DmCommand {
  const DmCommand({
    required this.id,
    required this.command,
    required this.text,
    required this.stime,
    required this.payload,
  });

  /// 弹幕 id 字符串
  final String id;

  /// 指令类型，如 `#GRADE#`（打分）、`#VOTE#`（投票）
  final String command;

  /// 卡片文案（服务端给的标题/口令）
  final String text;

  /// 出现时间，毫秒
  final int stime;

  /// extra 字段解析后的 JSON
  final Map<String, dynamic> payload;

  bool get isGrade => command == '#GRADE#';

  bool get isVote => command == '#VOTE#';

  /// 展示时长，毫秒
  int get duration {
    final d = (payload['duration'] as num?)?.toInt();
    if (d != null && d > 0) return d;
    return isVote ? 7000 : 5000;
  }

  int get end => stime + duration;

  /// 卡片左上角在网页播放器 667x375 逻辑画布上的坐标
  double get posX => (payload['posX'] as num?)?.toDouble() ?? 333;
  double get posY => (payload['posY'] as num?)?.toDouble() ?? 187;

  /// 卡片锚点（相对 0~1）
  ///
  /// 官方 posX_2 / posY_2 实为百分比坐标（播放器 npd.*.js 里
  /// `posX: e.posX_2 || Math.round(e.posX / 667 * 100)` 即此口径），
  /// 缺失时才退回按 667x375 画布换算。
  double get fx {
    final percent = (payload['posX_2'] as num?)?.toDouble();
    if (percent != null && percent > 0) {
      return (percent / 100).clamp(0.0, 1.0);
    }
    return (posX / 667).clamp(0.0, 1.0);
  }

  double get fy {
    final percent = (payload['posY_2'] as num?)?.toDouble();
    if (percent != null && percent > 0) {
      return (percent / 100).clamp(0.0, 1.0);
    }
    return (posY / 375).clamp(0.0, 1.0);
  }

  GradePayload? get grade =>
      isGrade ? GradePayload.fromJson(payload) : null;

  VotePayload? get vote => isVote ? VotePayload.fromJson(payload) : null;
}

/// 打分弹幕载荷
class GradePayload {
  const GradePayload({
    required this.gradeId,
    required this.avgScore,
    required this.count,
    required this.midScore,
    required this.msg,
    required this.icon,
    required this.fontColor,
  });

  factory GradePayload.fromJson(Map<String, dynamic> json) => GradePayload(
    gradeId: (json['grade_id'] as num?)?.toInt() ?? 0,
    avgScore: (json['avg_score'] as num?)?.toDouble() ?? 0,
    count: (json['count'] as num?)?.toInt() ?? 0,
    midScore: (json['mid_score'] as num?)?.toInt() ?? 0,
    msg: json['msg'] as String? ?? '',
    icon: json['icon'] as String? ?? '',
    fontColor: json['skin_font_color'] as String? ?? '#FFEC73',
  );

  final int gradeId;
  final double avgScore;
  final int count;

  /// 当前账号已打的分，0 表示未打分
  final int midScore;
  final String msg;
  final String icon;
  final String fontColor;
}

/// 投票弹幕载荷
class VotePayload {
  const VotePayload({
    required this.voteId,
    required this.voteType,
    required this.question,
    required this.count,
    required this.options,
    required this.myVote,
    required this.icon,
  });

  factory VotePayload.fromJson(Map<String, dynamic> json) {
    final rawOptions = json['options'];
    return VotePayload(
      voteId: (json['vote_id'] as num?)?.toInt() ?? 0,
      voteType: (json['vote_type'] as num?)?.toInt() ?? 0,
      question: json['question'] as String? ?? '',
      count: (json['cnt'] as num?)?.toInt() ?? 0,
      options: rawOptions is List
          ? rawOptions
                .whereType<Map>()
                .map((e) => VoteOption.fromJson(e.cast<String, dynamic>()))
                .toList()
          : const [],
      myVote: (json['my_vote'] as num?)?.toInt() ?? 0,
      icon: json['icon'] as String? ?? '',
    );
  }

  final int voteId;
  final int voteType;
  final String question;
  final int count;
  final List<VoteOption> options;

  /// 当前账号已投的选项下标，0 表示未投票
  final int myVote;
  final String icon;

  int get totalCount =>
      options.isEmpty ? count : options.fold(0, (sum, e) => sum + e.cnt);
}

class VoteOption {
  const VoteOption({
    required this.idx,
    required this.desc,
    required this.cnt,
  });

  factory VoteOption.fromJson(Map<String, dynamic> json) => VoteOption(
    idx: (json['idx'] as num?)?.toInt() ?? 0,
    desc: json['desc'] as String? ?? '',
    cnt: (json['cnt'] as num?)?.toInt() ?? 0,
  );

  final int idx;
  final String desc;
  final int cnt;
}

/// 解析 `/x/v2/dm/web/view` 的返回体，取出全部指令弹幕。
///
/// 该返回体本工程没有对应的 pb 定义，这里只按 protobuf 线格式跳过无关字段，
/// 第 9 号字段（length-delimited）复用工程里已生成的 [CommandDm] 解析。
List<DmCommand> parseDmCommandReply(Uint8List bytes) {
  final commands = <DmCommand>[];
  var pos = 0;

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (pos < bytes.length) {
      final byte = bytes[pos++];
      result |= (byte & 0x7F) << shift;
      if (byte & 0x80 == 0) break;
      shift += 7;
      if (shift > 63) throw const FormatException('varint too long');
    }
    return result;
  }

  try {
    while (pos < bytes.length) {
      final key = readVarint();
      final field = key >> 3;
      final wireType = key & 0x7;
      switch (wireType) {
        case 0: // varint
          readVarint();
        case 1: // 64-bit
          pos += 8;
        case 5: // 32-bit
          pos += 4;
        case 2:
          final length = readVarint();
          if (length < 0 || pos + length > bytes.length) {
            return commands;
          }
          if (field == 9) {
            final elem = CommandDm.fromBuffer(
              Uint8List.sublistView(bytes, pos, pos + length),
            );
            if (elem.command.isNotEmpty) {
              commands.add(
                DmCommand(
                  id: elem.idstr,
                  command: elem.command,
                  text: elem.content,
                  stime: elem.progress,
                  payload: _decodePayload(elem.extra),
                ),
              );
            }
          }
          pos += length;
        default:
          // 未知线型，放弃后续解析（已取到的照常返回）
          return commands;
      }
    }
  } catch (_) {
    // 忽略解析异常，返回已取到的部分
  }
  return commands;
}

Map<String, dynamic> _decodePayload(String extra) {
  if (extra.isEmpty) return const {};
  try {
    final data = jsonDecode(extra);
    return data is Map ? data.cast<String, dynamic>() : const {};
  } catch (_) {
    return const {};
  }
}
