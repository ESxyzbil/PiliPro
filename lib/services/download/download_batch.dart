import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models/common/video/audio_quality.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/model_owner.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/video/video_detail/arc.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart' as ugc;
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:collection/collection.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

/// 批量缓存目标：收藏夹 / 订阅合集等列表页共用的最小信息集合
class BatchCacheTarget {
  const BatchCacheTarget({
    required this.avid,
    required this.cid,
    required this.bvid,
    required this.title,
    this.cover,
    this.duration,
    this.owner,
  });

  final int avid;
  final int cid;
  final String bvid;
  final String title;
  final String? cover;
  final int? duration;
  final Owner? owner;
}

/// 弹出「选择下载画质和音质」对话框，取消返回 null
Future<(VideoQuality, AudioQuality)?> pickDownloadQuality() async {
  final defaultVideo =
      VideoQuality.values.firstWhereOrNull(
        (q) => q.code == Pref.defaultVideoQa,
      ) ??
      VideoQuality.high1080;
  final defaultAudio = AudioQuality.fromCode(Pref.defaultAudioQa);

  final videoQuality = defaultVideo.obs;
  final audioQuality = defaultAudio.obs;

  return await showDialog<(VideoQuality, AudioQuality)?>(
    context: Get.context!,
    barrierDismissible: false,
    builder: (context) => SimpleDialog(
      title: const Text('选择下载画质和音质'),
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 24, top: 8, bottom: 4),
          child: Text('视频画质', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        for (final q in VideoQuality.values)
          Obx(
            () => RadioListTile<VideoQuality>(
              dense: true,
              title: Text('${q.desc} (${q.shortDesc})'),
              value: q,
              groupValue: videoQuality.value,
              onChanged: (v) {
                if (v == null) return;
                videoQuality.value = v;
              },
            ),
          ),
        const Divider(height: 1),
        const Padding(
          padding: EdgeInsets.only(left: 24, top: 8, bottom: 4),
          child: Text('音频音质', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        for (final q in AudioQuality.values)
          Obx(
            () => RadioListTile<AudioQuality>(
              dense: true,
              title: Text('${q.desc} (${q.code})'),
              value: q,
              groupValue: audioQuality.value,
              onChanged: (v) {
                if (v == null) return;
                audioQuality.value = v;
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(
              (videoQuality.value, audioQuality.value),
            ),
            child: const Text('开始缓存'),
          ),
        ),
      ],
    ),
  );
}

/// 通过 avid + cid 查找本地已完成缓存（downloadList + 磁盘兜底）
Future<BiliDownloadEntryInfo?> findLocalCache(int avid, int cid) async {
  try {
    final ds = Get.find<DownloadService>();
    await ds.waitForInitialization;

    // 1. downloadList
    final inList = ds.downloadList.firstWhereOrNull(
      (e) => e.avid == avid && e.cid == cid && e.isCompleted,
    );
    if (inList != null) return inList;

    // 2. 在等待队列中
    if (ds.waitDownloadQueue.any((e) => e.avid == avid && e.cid == cid)) {
      return null;
    }

    // 3. 扫描磁盘
    for (final basePath in {downloadPath, defDownloadPath}) {
      final entryDirPath = p.join(basePath, avid.toString(), 'c_$cid');
      final entryFile = File(p.join(entryDirPath, 'entry.json'));
      if (entryFile.existsSync()) {
        try {
          final existingJson = await entryFile.readAsString();
          final existing = BiliDownloadEntryInfo.fromJson(
            jsonDecode(existingJson),
          )
            ..pageDirPath = p.join(basePath, avid.toString())
            ..entryDirPath = entryDirPath;
          if (existing.isCompleted) {
            if (ds.downloadList.indexWhere((e) => e.cid == cid) < 0) {
              ds.downloadList.add(existing);
            }
            return existing;
          }
        } catch (_) {}
      }
    }
    return null;
  } catch (e) {
    SmartDialog.showToast('查找缓存出错：$e');
    return null;
  }
}

/// 批量提交下载：跳过已完成与已在队列的条目，返回 (新增, 已存在)
Future<({int queued, int restored})> queueBatchDownload(
  List<BatchCacheTarget> targets, {
  required VideoQuality videoQa,
  required AudioQuality audioQa,
}) async {
  final ds = Get.find<DownloadService>();

  int restored = 0;
  int queued = 0;

  // 如果用户选了非默认音质，临时保存并下载后恢复
  final oldAudioQa = Pref.defaultAudioQa;
  final needRestoreAudioQa = audioQa.code != oldAudioQa;
  if (needRestoreAudioQa) {
    await GStorage.setting.put(SettingBoxKey.defaultAudioQa, audioQa.code);
  }

  for (final target in targets) {
    final cid = target.cid;
    final bvid = target.bvid;

    // 已存在于 downloadList（已完成）
    if (ds.downloadList.any((e) => e.cid == cid && e.isCompleted)) {
      continue;
    }
    // 已存在于等待队列
    if (ds.waitDownloadQueue.any((e) => e.cid == cid)) {
      continue;
    }

    // 扫描磁盘（重启后 downloadList 可能为空）
    bool foundOnDisk = false;
    for (final basePath in {downloadPath, defDownloadPath}) {
      final entryDirPath = p.join(basePath, target.avid.toString(), 'c_$cid');
      final entryFile = File(p.join(entryDirPath, 'entry.json'));
      if (entryFile.existsSync()) {
        try {
          final existingJson = await entryFile.readAsString();
          final existing = BiliDownloadEntryInfo.fromJson(
            jsonDecode(existingJson),
          )
            ..pageDirPath = p.join(basePath, target.avid.toString())
            ..entryDirPath = entryDirPath;
          if (existing.isCompleted) {
            if (ds.downloadList.indexWhere((e) => e.cid == cid) < 0) {
              ds.downloadList.add(existing);
            }
            restored++;
            foundOnDisk = true;
            break;
          }
        } catch (_) {}
      }
    }
    if (foundOnDisk) continue;

    // 需要新下载
    final part = Part(
      cid: cid,
      page: 1,
      from: '',
      part: target.title,
      vid: bvid,
      duration: target.duration,
    );
    final episodeItem = ugc.EpisodeItem(
      aid: target.avid,
      cid: cid,
      bvid: bvid,
      title: target.title,
      arc: Arc(
        aid: target.avid,
        pic: target.cover,
        title: target.title,
        duration: target.duration,
        author: target.owner,
      ),
      page: part,
      pages: [part],
    );
    ds.downloadVideo(part, null, episodeItem, videoQa);
    queued++;
  }

  // 恢复原始音质设置
  if (needRestoreAudioQa) {
    await GStorage.setting.put(SettingBoxKey.defaultAudioQa, oldAudioQa);
  }

  return (queued: queued, restored: restored);
}
