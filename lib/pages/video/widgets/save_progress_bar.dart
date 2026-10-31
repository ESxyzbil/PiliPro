import 'package:PiliPlus/services/video_save_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// 保存任务进度条：只在有任务时出现，非模态、不挡操作。
///
/// 状态来自全局 [VideoSaveService]，所以切页/切标签回来仍能看到进度。
class SaveProgressBar extends StatelessWidget {
  const SaveProgressBar({super.key});

  @override
  Widget build(BuildContext context) {
    // 注意：这里绝不能在 build 期间注册服务（Get.put 会触发依赖注入，视频页
    // 在恢复播放时随启动一起构建，容易在 build 里重入卡死）。只在已注册时展示。
    if (!Get.isRegistered<VideoSaveService>()) {
      return const SizedBox.shrink();
    }
    return Obx(() {
      final svc = Get.find<VideoSaveService>();
      if (!svc.busy.value) {
        return const SizedBox.shrink();
      }
      final scheme = ColorScheme.of(context);
      final p = svc.progress.value;
      final detail = svc.detail.value;
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
                      svc.title.value,
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
                    ? svc.stageLabel
                    : '${svc.stageLabel} · $detail',
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
