import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/http/danmaku.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/dm_command/dm_command.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

/// 播放器上的「打分 / 投票」弹幕卡片浮层
///
/// 数据来自指令弹幕（`#GRADE#` / `#VOTE#`），按其 stime 到点出现、
/// 持续 duration 毫秒后消失；位置取服务端给的 posX / posY
/// （720x405 逻辑画布）换算成相对锚点。卡片可点击打分 / 投票。
class DmCommandOverlay extends StatefulWidget {
  const DmCommandOverlay({
    super.key,
    required this.aid,
    required this.cid,
    required this.playerController,
  });

  final int aid;
  final int cid;
  final PlPlayerController playerController;

  @override
  State<DmCommandOverlay> createState() => _DmCommandOverlayState();
}

class _DmCommandOverlayState extends State<DmCommandOverlay> {
  final ValueNotifier<List<DmCommand>> _visible = ValueNotifier(const []);

  /// 提交后本地更新的载荷（key 为指令弹幕 id）
  final Map<String, Map<String, dynamic>> _overrides = {};

  List<DmCommand> _commands = const [];

  PlPlayerController get playerController => widget.playerController;

  @override
  void initState() {
    super.initState();
    playerController.addPositionListener(_onPosition);
    _load();
  }

  @override
  void dispose() {
    playerController.removePositionListener(_onPosition);
    _visible.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final res = await DanmakuHttp.commandDms(
      aid: widget.aid,
      cid: widget.cid,
    );
    if (!mounted) return;
    if (res case Success(:final response)) {
      _commands = response.where((e) => e.isGrade || e.isVote).toList()
        ..sort((a, b) => a.stime.compareTo(b.stime));
      _onPosition(
        Duration(milliseconds: playerController.positionInMilliseconds),
      );
    }
  }

  void _onPosition(Duration position) {
    // 独立开关：关闭后只隐藏打分/投票卡片，不影响普通弹幕
    if (!Pref.showDmCommand) {
      if (_visible.value.isNotEmpty) {
        _visible.value = const [];
      }
      return;
    }
    if (_commands.isEmpty) {
      return;
    }
    final ms = position.inMilliseconds;
    final next = <DmCommand>[
      for (final e in _commands)
        if (ms >= e.stime && ms < e.end) e,
    ];
    if (!listEquals(next, _visible.value)) {
      _visible.value = next;
    }
  }

  DmCommand _effective(DmCommand e) {
    final payload = _overrides[e.id];
    if (payload == null) {
      return e;
    }
    return DmCommand(
      id: e.id,
      command: e.command,
      text: e.text,
      stime: e.stime,
      payload: payload,
    );
  }

  void _toast(String msg) => SmartDialog.showToast(msg);

  /// 官方要求 progress 落在卡片时间窗内、且不晚于结束前 100ms
  int _progressOf(DmCommand e) {
    final now = playerController.positionInMilliseconds;
    final upper = e.end - 100;
    if (upper <= 1) {
      return 1;
    }
    return now.clamp(1, upper);
  }

  Future<void> _submitGrade(DmCommand e, int stars) async {
    if (!Accounts.main.isLogin) {
      _toast('请先登录后再打分');
      return;
    }
    // UI 为 5 星，接口用 10 分制（官方 grade_score 上限 10）
    final value = stars * 2;
    final grade = e.grade!;
    final res = await DanmakuHttp.gradeScore(
      aid: widget.aid,
      cid: widget.cid,
      gradeId: grade.gradeId,
      gradeScore: value,
      progress: _progressOf(e),
    );
    if (!mounted) return;
    if (res is Success) {
      final prev = grade.midScore;
      final count = grade.count + (prev == 0 ? 1 : 0);
      final sum = grade.avgScore * grade.count - (prev == 0 ? 0 : prev) + value;
      setState(() {
        _overrides[e.id] = {
          ...e.payload,
          'count': count,
          'avg_score': count > 0
              ? double.parse((sum / count).toStringAsFixed(1))
              : 0,
          'mid_score': value,
        };
      });
      _toast('打分成功：$stars 星');
    } else {
      _toastError(res);
    }
  }

  Future<void> _submitVote(DmCommand e, VoteOption option) async {
    if (!Accounts.main.isLogin) {
      _toast('请先登录后再投票');
      return;
    }
    final vote = e.vote!;
    final res = await DanmakuHttp.voteOption(
      aid: widget.aid,
      cid: widget.cid,
      // 官方以弹幕自身时间作为 progress，故直接用卡片出现时间
      progress: e.stime,
      voteId: vote.voteId,
      voteType: vote.voteType,
      optionId: option.idx,
      cmdIdStr: e.id.isEmpty ? null : e.id,
    );
    if (!mounted) return;
    if (res is Success) {
      final prev = vote.myVote;
      var total = vote.count;
      final options = <Map<String, dynamic>>[];
      for (final item in vote.options) {
        var cnt = item.cnt;
        if (item.idx == prev) {
          cnt -= 1;
        }
        if (item.idx == option.idx) {
          cnt += 1;
        }
        if (cnt < 0) cnt = 0;
        options.add({'idx': item.idx, 'desc': item.desc, 'cnt': cnt});
      }
      if (prev == 0) {
        total += 1;
      }
      setState(() {
        _overrides[e.id] = {
          ...e.payload,
          'cnt': total,
          'options': options,
          'my_vote': option.idx,
        };
      });
      _toast('投票成功');
    } else {
      _toastError(res);
    }
  }

  void _toastError(LoadingState<void> res) {
    if (res case Error(:final errMsg, :final code)) {
      _toast('${errMsg ?? '提交失败'}${code == null ? '' : '（$code）'}');
    } else {
      _toast('提交失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<DmCommand>>(
      valueListenable: _visible,
      builder: (context, list, _) {
        if (list.isEmpty) {
          return const SizedBox.shrink();
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : 720.0;
            return MediaQuery.withNoTextScaling(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  for (final raw in list)
                    Align(
                      alignment: _alignmentOf(raw),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: (width * 0.66).clamp(140.0, 260.0),
                        ),
                        child: switch (_effective(raw)) {
                          final e when e.isGrade => _GradeCard(
                            data: e.grade!,
                            onScore: (score) => _submitGrade(raw, score),
                          ),
                          final e => _VoteCard(
                            data: e.vote!,
                            onVote: (option) => _submitVote(raw, option),
                          ),
                        },
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 把 720x405 逻辑画布上的坐标换算成 Alignment（-1 ~ 1）
  Alignment _alignmentOf(DmCommand e) {
    final ax = (e.fx * 2 - 1).clamp(-0.92, 0.92);
    final ay = (e.fy * 2 - 1).clamp(-0.92, 0.92);
    return Alignment(ax, ay);
  }
}

const _cardDecoration = BoxDecoration(
  color: Color(0xC7000000),
  borderRadius: BorderRadius.all(Radius.circular(10)),
  border: Border.fromBorderSide(BorderSide(color: Color(0x33FFFFFF))),
);

class _GradeCard extends StatefulWidget {
  const _GradeCard({required this.data, required this.onScore});

  final GradePayload data;
  final Future<void> Function(int score) onScore;

  @override
  State<_GradeCard> createState() => _GradeCardState();
}

class _GradeCardState extends State<_GradeCard> {
  bool _expanded = false;
  bool _submitting = false;

  Future<void> _submit(int score) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      await widget.onScore(score);
      if (mounted) {
        setState(() => _expanded = false);
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final color = _parseColor(data.fontColor) ?? const Color(0xFFFFEC73);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: _cardDecoration,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (data.icon.isNotEmpty) ...[
                  NetworkImgLayer(
                    src: data.icon,
                    width: 26,
                    height: 32,
                    fit: BoxFit.contain,
                    borderRadius: const BorderRadius.all(Radius.circular(4)),
                    getPlaceHolder: () => const SizedBox(
                      width: 26,
                      height: 32,
                      child: Icon(
                        Icons.star_rounded,
                        color: Color(0xFFFFEC73),
                        size: 22,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ] else ...[
                  const Icon(
                    Icons.star_rounded,
                    color: Color(0xFFFFEC73),
                    size: 20,
                  ),
                  const SizedBox(width: 4),
                ],
                Text(
                  data.avgScore.toStringAsFixed(1),
                  style: TextStyle(
                    color: color,
                    fontSize: 20,
                    height: 1.1,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 2, bottom: 1),
                  child: Text(
                    '/10',
                    style: TextStyle(
                      color: color.withValues(alpha: 0.8),
                      fontSize: 10,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                const Text(
                  '打分',
                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${NumUtils.numFormat(data.count)}人参与',
              style: const TextStyle(color: Colors.white60, fontSize: 10),
            ),
            const SizedBox(height: 4),
            if (_expanded)
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (var i = 1; i <= 5; i++)
                    GestureDetector(
                      onTap: _submitting ? null : () => _submit(i),
                      child: Container(
                        width: 22,
                        height: 20,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: i * 2 == data.midScore
                              ? const Color(0xFF00AEEC)
                              : const Color(0x33FFFFFF),
                          borderRadius: const BorderRadius.all(
                            Radius.circular(4),
                          ),
                        ),
                        child: Icon(
                          Icons.star_rounded,
                          size: 14,
                          color: i * 2 == data.midScore
                              ? Colors.white
                              : const Color(0xB3FFFFFF),
                        ),
                      ),
                    ),
                ],
              )
            else
              Text(
                data.midScore > 0
                    ? '你打了 ${data.midScore ~/ 2} 星'
                    : '点击评分（5 星）',
                style: const TextStyle(color: Colors.white38, fontSize: 9),
              ),
          ],
        ),
      ),
    );
  }
}

class _VoteCard extends StatefulWidget {
  const _VoteCard({required this.data, required this.onVote});

  final VotePayload data;
  final Future<void> Function(VoteOption option) onVote;

  @override
  State<_VoteCard> createState() => _VoteCardState();
}

class _VoteCardState extends State<_VoteCard> {
  late bool _showRatio = Pref.showDmVoteRatio;

  void _toggleRatio() {
    setState(() => _showRatio = !_showRatio);
    Pref.setShowDmVoteRatio(_showRatio);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final total = data.totalCount;
    // 未投票时默认不揭示票型；己方已投或手动勾选「比例」才显示
    final showRatio = _showRatio || data.myVote > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: _cardDecoration,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: const BoxDecoration(
                  color: Color(0xFF00AEEC),
                  borderRadius: BorderRadius.all(Radius.circular(3)),
                ),
                child: const Text(
                  '投票',
                  style: TextStyle(color: Colors.white, fontSize: 9),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  data.question,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final option in data.options) ...[
            _VoteOptionBar(
              option: option,
              total: total,
              isMine: option.idx == data.myVote,
              showRatio: showRatio,
              onTap: () => widget.onVote(option),
            ),
            const SizedBox(height: 4),
          ],
          Row(
            children: [
              Text(
                '${NumUtils.numFormat(total)}人参与',
                style: const TextStyle(color: Colors.white60, fontSize: 10),
              ),
              const Spacer(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleRatio,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _showRatio
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 13,
                      color: Colors.white70,
                    ),
                    const SizedBox(width: 2),
                    const Text(
                      '比例',
                      style: TextStyle(color: Colors.white70, fontSize: 9),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _VoteOptionBar extends StatelessWidget {
  const _VoteOptionBar({
    required this.option,
    required this.total,
    required this.isMine,
    required this.showRatio,
    required this.onTap,
  });

  final VoteOption option;
  final int total;
  final bool isMine;
  final bool showRatio;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ratio = total <= 0 ? 0.0 : (option.cnt / total).clamp(0.0, 1.0);
    final percent = (ratio * 100).toStringAsFixed(0);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        child: Stack(
          children: [
            Container(height: 20, color: const Color(0x33FFFFFF)),
            if (showRatio)
              FractionallySizedBox(
                widthFactor: ratio,
                child: Container(
                  height: 20,
                  color: isMine
                      ? const Color(0xFF00AEEC)
                      : const Color(0x8000AEEC),
                ),
              ),
            SizedBox(
              height: 20,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        option.desc,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: isMine ? FontWeight.bold : null,
                        ),
                      ),
                    ),
                    if (showRatio)
                      Text(
                        '$percent% · ${NumUtils.numFormat(option.cnt)}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 9,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Color? _parseColor(String hex) {
  final value = hex.replaceFirst('#', '');
  if (value.length != 6 && value.length != 8) {
    return null;
  }
  final parsed = int.tryParse(value, radix: 16);
  if (parsed == null) {
    return null;
  }
  return Color(value.length == 6 ? 0xFF000000 | parsed : parsed);
}
