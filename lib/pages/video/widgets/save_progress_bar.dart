import 'package:PiliPlus/services/video_save_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// 保存任务进度条：只在有任务时出现，非模态、不挡操作。
///
/// 状态来自全局 [VideoSaveService]，所以切页/切标签回来仍能看到进度。
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
      if (!_svc.busy.value) {
        return const SizedBox.shrink();
      }
      final scheme = ColorScheme.of(context);
      final p = _svc.progress.value;
      final detail = _svc.detail.value;
      return Material(
        color: scheme.surface,
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
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
              Text(
                detail.isEmpty
                    ? _svc.stageLabel
                    : '${_svc.stageLabel} · $detail',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}
