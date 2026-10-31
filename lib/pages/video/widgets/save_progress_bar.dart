import 'package:PiliPlus/services/video_save_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// 保存任务进度条：只在有任务时出现，非模态、不挡操作。
///
/// 状态来自全局 [VideoSaveService]，所以切页/切标签回来仍能看到进度。
/// - 右侧「取消」按钮：下载中立刻中断，合并阶段下一个进度点打断，
///   写入下载目录后不可取消（服务侧会提示并让任务跑完）。
/// - 向下滑：进度条飞出屏幕，任务继续，进度改由 Android 16 实时活动通知展示。
///
/// 两条硬约束（都踩过）：
/// 1. 不能在 build 期间注册服务——Get.put 会触发依赖注入，视频页在恢复播放时
///    随启动一起构建，build 里重入会卡死；
/// 2. 也不能在 build 里「未注册就返回空」——那样这个 widget 根本没订阅任何 Rx，
///    等任务真正开始时不会有任何重建，进度条永远不出现（表现为点了保存毫无反馈，
///    直到最后弹一条已完成）。
/// 所以改成 StatefulWidget：initState 里幂等注册，build 里稳定订阅。
class SaveProgressBar extends StatefulWidget {
  const SaveProgressBar({super.key});

  @override
  State<SaveProgressBar> createState() => _SaveProgressBarState();
}

class _SaveProgressBarState extends State<SaveProgressBar> {
  late final VideoSaveService _svc;

  @override
  void initState() {
    super.initState();
    // initState 不在 build 期间，注册安全；instance 本身幂等（已注册则直接返回）。
    _svc = VideoSaveService.instance;
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (!_svc.busy.value || _svc.uiHidden.value) {
        return const SizedBox.shrink();
      }
      final scheme = ColorScheme.of(context);
      final p = _svc.progress.value;
      final detail = _svc.detail.value;
      final cancelling = _svc.cancelling.value;
      // 每次任务一个新 key：上一次被 dismiss 掉后，下一次仍能正常重建
      return Dismissible(
        key: ValueKey<int>(_svc.taskId.value),
        direction: DismissDirection.down,
        resizeDuration: null,
        dismissThresholds: const {DismissDirection.down: 0.22},
        onDismissed: (_) => _svc.hideUi(),
        background: _buildSwipeBackground(scheme),
        child: Material(
          color: scheme.surface,
          elevation: 8,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.save_alt,
                      size: 16,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _svc.title.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${(p * 100).clamp(0, 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                        fontSize: 12,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 4),
                    _buildCancelButton(scheme, cancelling),
                  ],
                ),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: p,
                    minHeight: 5,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        cancelling
                            ? '正在取消…'
                            : (detail.isEmpty
                                  ? _svc.stageLabel
                                  : '${_svc.stageLabel} · $detail'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: cancelling
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.keyboard_arrow_down,
                      size: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                    Text(
                      '下滑隐藏',
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _buildCancelButton(ColorScheme scheme, bool cancelling) {
    return SizedBox(
      height: 28,
      child: TextButton(
        onPressed: cancelling ? null : _svc.cancel,
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 28),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          foregroundColor: scheme.error,
        ),
        child: Text(
          cancelling ? '取消中' : '取消',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildSwipeBackground(ColorScheme scheme) {
    return Container(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.topCenter,
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.arrow_downward,
            size: 14,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 4),
          Text(
            '隐藏到后台，继续保存',
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSecondaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}
