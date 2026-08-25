import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io' show Directory, File;

import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/http/download.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/download/bili_download_media_file_info.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart' as pgc;
import 'package:PiliPlus/models_new/pgc/pgc_info_model/result.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart' as ugc;
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/pages/danmaku/controller.dart';
import 'package:PiliPlus/services/download/download_manager.dart';
import 'package:PiliPlus/services/download/download_progress_channel.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/extension/file_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;
import 'package:synchronized/synchronized.dart';

// ref https://github.com/10miaomiao/bilimiao2/blob/master/bilimiao-download/src/main/java/cn/a10miaomiao/bilimiao/download/DownloadService.kt

class DownloadService extends GetxService {
  static const _entryFile = 'entry.json';
  static const _indexFile = 'index.json';

  /// 同时下载的最大任务数（缓存多个视频时并行下载的并发上限）
  static const int maxConcurrentDownloads = 3;

  /// 失败后自动重新激活（重试）的次数上限；超过后保持失败状态等待手动重试
  static const int maxAutoRetries = 3;

  /// 失败后自动重试的延迟
  static const Duration retryDelay = Duration(seconds: 3);

  final _lock = Lock();

  final flagNotifier = SetNotifier();
  final waitDownloadQueue = RxList<BiliDownloadEntryInfo>();
  final downloadList = <BiliDownloadEntryInfo>[];

  /// 正在下载（含获取弹幕/播放地址/下载中/下载音频）的条目，驱动界面实时进度
  final activeList = RxList<BiliDownloadEntryInfo>();

  /// 进行中的下载任务，key = cid
  final _tasks = <int, _DownloadTask>{};

  /// 失败自动重试计数（cid -> 已连续失败重试次数）
  final _retryCounts = <int, int>{};

  /// 失败自动重试定时器（cid -> Timer）
  final _retryTimers = <int, Timer>{};

  /// 通知刷新节流时间戳
  DateTime _lastNotifAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool isActive(int? cid) => cid != null && _tasks.containsKey(cid);

  late Future<void> waitForInitialization;

  @override
  void onInit() {
    super.onInit();
    initDownloadList();
  }

  void initDownloadList() {
    waitForInitialization = _readDownloadList();
  }

  Future<void> _readDownloadList() async {
    downloadList.clear();
    final downloadDir = Directory(await _getDownloadPath());
    await for (final dir in downloadDir.list()) {
      if (dir is Directory) {
        downloadList.addAll(await _readDownloadDirectory(dir));
      }
    }
    downloadList.sort((a, b) => b.timeUpdateStamp.compareTo(a.timeUpdateStamp));
    // 重启后自动重新激活之前未完成的缓存任务
    if (waitDownloadQueue.isNotEmpty) {
      unawaited(_scheduleDownloads());
    }
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<List<BiliDownloadEntryInfo>> _readDownloadDirectory(
    Directory pageDir,
  ) async {
    final result = <BiliDownloadEntryInfo>[];

    if (!pageDir.existsSync()) {
      return result;
    }

    await for (final entryDir in pageDir.list()) {
      if (entryDir is Directory) {
        final entryFile = File(path.join(entryDir.path, _entryFile));
        if (entryFile.existsSync()) {
          try {
            final entryJson = await entryFile.readAsString();
            final entry = BiliDownloadEntryInfo.fromJson(jsonDecode(entryJson))
              ..pageDirPath = pageDir.path
              ..entryDirPath = entryDir.path;
            if (entry.isCompleted) {
              result.add(entry);
            } else {
              waitDownloadQueue.add(entry..status = DownloadStatus.wait);
            }
          } catch (_) {}
        }
      }
    }

    return result;
  }

  void downloadVideo(
    Part page,
    VideoDetailData? videoDetail,
    ugc.EpisodeItem? videoArc,
    VideoQuality videoQuality,
  ) {
    final cid = page.cid!;
    if (downloadList.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    if (waitDownloadQueue.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    final pageData = PageInfo(
      cid: cid,
      page: page.page!,
      from: page.from,
      part: page.part,
      vid: page.vid,
      hasAlias: false,
      tid: 0,
      width: 0,
      height: 0,
      rotate: 0,
      downloadTitle: '视频已缓存完成',
      downloadSubtitle: videoDetail?.title ?? videoArc!.title,
    );
    final currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final entry = BiliDownloadEntryInfo(
      mediaType: 2,
      hasDashAudio: false,
      isCompleted: false,
      totalBytes: 0,
      downloadedBytes: 0,
      title: videoDetail?.title ?? videoArc!.title!,
      typeTag: videoQuality.code.toString(),
      cover: (videoDetail?.pic ?? videoArc!.cover!).http2https,
      preferedVideoQuality: videoQuality.code,
      qualityPithyDescription: videoQuality.desc,
      guessedTotalBytes: 0,
      totalTimeMilli: (page.duration ?? 0) * 1000,
      danmakuCount:
          videoDetail?.stat?.danmaku ?? videoArc?.arc?.stat?.danmaku ?? 0,
      timeUpdateStamp: currentTime,
      timeCreateStamp: currentTime,
      canPlayInAdvance: true,
      interruptTransformTempFile: false,
      avid: videoDetail?.aid ?? videoArc!.aid!,
      spid: 0,
      seasonId: null,
      ep: null,
      source: null,
      bvid: videoDetail?.bvid ?? videoArc!.bvid!,
      ownerId: videoDetail?.owner?.mid ?? videoArc?.arc?.author?.mid,
      ownerName: videoDetail?.owner?.name ?? videoArc?.arc?.author?.name,
      pageData: pageData,
    );
    _createDownload(entry);
  }

  void downloadBangumi(
    int index,
    PgcInfoModel pgcItem,
    pgc.EpisodeItem episode,
    VideoQuality quality,
  ) {
    final cid = episode.cid!;
    if (downloadList.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    if (waitDownloadQueue.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    final currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final source = SourceInfo(
      avId: episode.aid!,
      cid: cid,
    );
    final ep = EpInfo(
      avId: source.avId,
      page: index,
      danmaku: source.cid,
      cover: episode.cover!,
      episodeId: episode.id!,
      index: episode.title!,
      indexTitle: episode.longTitle ?? '',
      showTitle: episode.showTitle,
      from: episode.from ?? 'bangumi',
      seasonType: pgcItem.type ?? (episode.from == 'pugv' ? -1 : 0),
      width: 0,
      height: 0,
      rotate: 0,
      link: episode.link ?? '',
      bvid: episode.bvid ?? IdUtils.av2bv(source.avId),
      sortIndex: index,
    );
    final entry = BiliDownloadEntryInfo(
      mediaType: 2,
      hasDashAudio: false,
      isCompleted: false,
      totalBytes: 0,
      downloadedBytes: 0,
      title: pgcItem.seasonTitle ?? pgcItem.title ?? '',
      typeTag: quality.code.toString(),
      cover: episode.cover!,
      preferedVideoQuality: quality.code,
      qualityPithyDescription: quality.desc,
      guessedTotalBytes: 0,
      totalTimeMilli:
          (episode.duration ?? 0) *
          (episode.from == 'pugv' ? 1000 : 1), // pgc millisec,, pugv sec
      danmakuCount: pgcItem.stat?.danmaku ?? 0,
      timeUpdateStamp: currentTime,
      timeCreateStamp: currentTime,
      canPlayInAdvance: true,
      interruptTransformTempFile: false,
      spid: 0,
      seasonId: pgcItem.seasonId!.toString(),
      bvid: episode.bvid ?? IdUtils.av2bv(source.avId),
      avid: source.avId,
      ep: ep,
      source: source,
      ownerId: pgcItem.upInfo?.mid,
      ownerName: pgcItem.upInfo?.uname,
      pageData: null,
    );
    _createDownload(entry);
  }

  Future<void> _createDownload(BiliDownloadEntryInfo entry) async {
    final entryDir = await _getDownloadEntryDir(entry);
    final entryJsonFile = File(path.join(entryDir.path, _entryFile));
    await entryJsonFile.writeAsString(jsonEncode(entry.toJson()));
    entry
      ..pageDirPath = entryDir.parent.path
      ..entryDirPath = entryDir.path
      ..status = DownloadStatus.wait;
    waitDownloadQueue.add(entry);
    unawaited(startDownload(entry));
  }

  Future<Directory> _getDownloadEntryDir(BiliDownloadEntryInfo entry) async {
    late final String dirName;
    late final String pageDirName;
    if (entry.ep case final ep?) {
      dirName = 's_${entry.seasonId}';
      pageDirName = ep.episodeId.toString();
    } else if (entry.pageData case final page?) {
      dirName = entry.avid.toString();
      pageDirName = 'c_${page.cid}';
    }
    final pageDir = Directory(
      path.join(await _getDownloadPath(), dirName, pageDirName),
    );
    if (!pageDir.existsSync()) {
      await pageDir.create(recursive: true);
    }
    return pageDir;
  }

  static Future<String> _getDownloadPath() async {
    final dir = Directory(downloadPath);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// 启动/恢复一个下载：加入等待队列并按并行上限调度
  Future<void> startDownload(BiliDownloadEntryInfo entry) {
    // 用户显式触发：重置失败重试计数并取消待触发的重试
    _clearRetry(entry.cid);
    return _lock.synchronized(() {
      if (entry.isCompleted || _tasks.containsKey(entry.cid)) {
        return;
      }
      if (!waitDownloadQueue.contains(entry)) {
        waitDownloadQueue.add(entry);
      }
      // 用户显式点击：即使暂停/失败也强制开始
      _scheduleLocked(force: entry);
    });
  }

  /// 填充空闲的下载槽位（受 [maxConcurrentDownloads] 限制，实现并行下载）
  void _scheduleLocked({BiliDownloadEntryInfo? force}) {
    if (force != null && !_tasks.containsKey(force.cid)) {
      _tasks[force.cid] = _DownloadTask(force);
      activeList.add(force);
      unawaited(_runTask(force.cid));
    }
    while (_tasks.length < maxConcurrentDownloads) {
      final next = _nextPendingEntry();
      if (next == null) {
        break;
      }
      _tasks[next.cid] = _DownloadTask(next);
      activeList.add(next);
      unawaited(_runTask(next.cid));
    }
    waitDownloadQueue.refresh();
    activeList.refresh();
    _refreshDownloadNotification();
  }

  Future<void> _scheduleDownloads() {
    return _lock.synchronized(_scheduleLocked);
  }

  static bool _isFailureStatus(DownloadStatus status) =>
      status == DownloadStatus.failDanmaku ||
      status == DownloadStatus.failDownload ||
      status == DownloadStatus.failDownloadAudio ||
      status == DownloadStatus.failPlayUrl;

  void _clearRetry(int cid) {
    _retryTimers.remove(cid)?.cancel();
    _retryCounts.remove(cid);
  }

  /// 失败后自动重新激活（带次数上限，避免无限重试）
  void _scheduleRetry(BiliDownloadEntryInfo entry) {
    if (entry.isCompleted) return;
    final count = (_retryCounts[entry.cid] ?? 0) + 1;
    if (count > maxAutoRetries) {
      _retryCounts.remove(entry.cid);
      return;
    }
    _retryCounts[entry.cid] = count;
    _retryTimers[entry.cid]?.cancel();
    _retryTimers[entry.cid] = Timer(retryDelay, () {
      _retryTimers.remove(entry.cid);
      // 定时器触发前可能被暂停/删除/已恢复，重新校验
      if (entry.isCompleted ||
          entry.status == DownloadStatus.pause ||
          _tasks.containsKey(entry.cid) ||
          !waitDownloadQueue.contains(entry)) {
        return;
      }
      // 直接强制重新激活（不经过 startDownload，避免重置重试计数）
      unawaited(
        _lock.synchronized(() => _scheduleLocked(force: entry)),
      );
    });
  }

  /// 刷新实时活动通知（下载进度），带节流；无任何任务时关闭通知
  void _refreshDownloadNotification() {
    if (waitDownloadQueue.isEmpty && activeList.isEmpty) {
      unawaited(DownloadProgressChannel.stop());
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastNotifAt) < const Duration(milliseconds: 1000)) {
      return;
    }
    _lastNotifAt = now;
    final queueLen = waitDownloadQueue.length;
    if (activeList.isEmpty) {
      // 队列仍在但无活跃任务：暂停/等待状态
      unawaited(
        DownloadProgressChannel.update(
          queueLength: queueLen,
          title: '缓存已暂停',
          subText: '点击进入继续缓存',
          progressBytes: 0,
          totalBytes: 0,
          hasProgress: false,
        ),
      );
      return;
    }
    final first = activeList.first;
    final status = first.status;
    final done = first.downloadedBytes;
    final total = first.totalBytes;
    final String subText;
    if (status == DownloadStatus.downloading ||
        status == DownloadStatus.audioDownloading) {
      subText = total > 0
          ? '${(done / total * 100).toStringAsFixed(0)}% · '
                '${CacheManager.formatSize(done)}/${CacheManager.formatSize(total)}'
          : CacheManager.formatSize(done);
    } else {
      subText = status.message;
    }
    final title = activeList.length > 1
        ? '${first.showTitle}（等${activeList.length}个视频同时下载）'
        : first.showTitle;
    unawaited(
      DownloadProgressChannel.update(
        queueLength: queueLen,
        title: title,
        subText: subText,
        progressBytes: done,
        totalBytes: total,
        hasProgress: total > 0,
      ),
    );
  }

  BiliDownloadEntryInfo? _nextPendingEntry() {
    for (final e in waitDownloadQueue) {
      if (_tasks.containsKey(e.cid) || e.isCompleted) {
        continue;
      }
      // 仅自动开始新加入（wait）的任务；暂停/失败的任务等待用户手动重新开始
      if (e.status != DownloadStatus.wait) {
        continue;
      }
      return e;
    }
    return null;
  }

  /// 单个任务的完整下载流程（弹幕 → 播放地址 → 音视频流）
  Future<void> _runTask(int cid) async {
    final task = _tasks[cid];
    if (task == null) return;
    final entry = task.entry;
    try {
      if (!await downloadDanmaku(entry: entry)) {
        await _closeTask(cid);
        return;
      }
      // 下载期间可能被暂停/删除
      if (!_tasks.containsKey(cid)) return;

      _updateEntryStatus(entry, DownloadStatus.getPlayUrl);

      final mediaFileInfo = await DownloadHttp.getVideoUrl(
        entry: entry,
        ep: entry.ep,
        source: entry.source,
        pageData: entry.pageData,
      );
      if (!_tasks.containsKey(cid)) return;

      final videoDir = Directory(path.join(entry.entryDirPath, entry.typeTag));
      if (!videoDir.existsSync()) {
        await videoDir.create(recursive: true);
      }

      final mediaJsonFile = File(path.join(videoDir.path, _indexFile));
      await Future.wait([
        mediaJsonFile.writeAsString(jsonEncode(mediaFileInfo.toJson())),
        _downloadCover(entry: entry),
      ]);

      if (!_tasks.containsKey(cid)) return;

      switch (mediaFileInfo) {
        case Type1 mediaFileInfo:
          final first = mediaFileInfo.segmentList.first;
          task.videoManager = DownloadManager(
            url: first.url,
            path: path.join(videoDir.path, PathUtils.videoNameType1),
            onReceiveProgress: (p, t) => _onReceive(entry, p, t),
            onDone: ([Object? e]) => _onDone(entry, e),
          );
          break;
        case Type2 mediaFileInfo:
          task.videoManager = DownloadManager(
            url: mediaFileInfo.video.first.baseUrl,
            path: path.join(videoDir.path, PathUtils.videoNameType2),
            onReceiveProgress: (p, t) => _onReceive(entry, p, t),
            onDone: ([Object? e]) => _onDone(entry, e),
          );
          final audio = mediaFileInfo.audio;
          if (audio != null && audio.isNotEmpty) {
            task.audioManager = DownloadManager(
              url: audio.first.baseUrl,
              path: path.join(videoDir.path, PathUtils.audioNameType2),
              onReceiveProgress: null,
              onDone: ([Object? e]) => _onAudioDone(entry, e),
            );
          }
          late final first = mediaFileInfo.video.first;
          entry.pageData
            ?..width = first.width
            ..height = first.height;
          entry.ep
            ?..width = first.width
            ..height = first.height;
          _updateBiliDownloadEntryJson(entry);
          break;
        default:
          break;
      }
    } catch (e) {
      if (_tasks.containsKey(cid)) {
        _updateEntryStatus(entry, DownloadStatus.failPlayUrl);
        await _closeTask(cid);
      }
      if (kDebugMode) {
        debugPrint('get download url error: $e');
      }
    }
  }

  Future<bool> downloadDanmaku({
    required BiliDownloadEntryInfo entry,
    bool isUpdate = false,
  }) async {
    final cid = entry.pageData?.cid ?? entry.source?.cid;
    if (cid == null) {
      return false;
    }
    final danmakuFile = File(
      path.join(entry.entryDirPath, PathUtils.danmakuName),
    );
    if (isUpdate || !danmakuFile.existsSync()) {
      try {
        if (!isUpdate) {
          _updateEntryStatus(entry, DownloadStatus.getDanmaku);
        }
        final seg = (entry.totalTimeMilli / PlDanmakuController.segmentLength)
            .ceil();

        final res = await Future.wait([
          for (var i = 1; i <= seg; i++)
            DmGrpc.dmSegMobile(cid: cid, segmentIndex: i),
        ]);

        final danmaku = res.removeAt(0).data;
        for (final i in res) {
          if (i case Success(:final response)) {
            danmaku.elems.addAll(response.elems);
          }
        }
        res.clear();
        await danmakuFile.writeAsBytes(danmaku.writeToBuffer());

        return true;
      } catch (e) {
        if (!isUpdate) {
          _updateEntryStatus(entry, DownloadStatus.failDanmaku);
        }
        if (kDebugMode) SmartDialog.showToast(e.toString());
        return false;
      }
    }
    return true;
  }

  Future<bool> _downloadCover({
    required BiliDownloadEntryInfo entry,
  }) async {
    try {
      final filePath = path.join(entry.entryDirPath, PathUtils.coverName);
      if (File(filePath).existsSync()) {
        return true;
      }
      final file = (await CacheManager.manager.getFileFromCache(
        entry.cover,
      ))?.file;
      if (file != null) {
        await file.copy(filePath);
      } else {
        await Request.dio.download(entry.cover, filePath);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  void _updateEntryStatus(BiliDownloadEntryInfo entry, DownloadStatus status) {
    entry.status = status;
    activeList.refresh();
    waitDownloadQueue.refresh();
    _refreshDownloadNotification();
  }

  Future<void> _updateBiliDownloadEntryJson(BiliDownloadEntryInfo entry) {
    final entryJsonFile = File(path.join(entry.entryDirPath, _entryFile));
    return entryJsonFile.writeAsString(jsonEncode(entry.toJson()));
  }

  void _onReceive(BiliDownloadEntryInfo entry, int progress, int total) {
    if (progress == 0 && total != 0) {
      _updateBiliDownloadEntryJson(entry..totalBytes = total);
    }
    entry
      ..downloadedBytes = progress
      ..status = DownloadStatus.downloading;
    _updateEntryStatus(entry, DownloadStatus.downloading);
  }

  void _onDone(BiliDownloadEntryInfo entry, [Object? error]) {
    final task = _tasks[entry.cid];
    if (task == null) {
      return;
    }
    if (error != null) {
      // 暂停/失败：同时取消音频下载
      final status = task.videoManager?.status ?? DownloadStatus.pause;
      unawaited(task.audioManager?.cancel(isDelete: false));
      _updateEntryStatus(entry, status);
      unawaited(_closeTask(entry.cid));
      return;
    }
    if (task.audioManager case final audio?) {
      switch (audio.status) {
        case DownloadStatus.downloading:
          // 视频已下完，音频仍在下载
          entry.downloadedBytes = entry.totalBytes;
          _updateEntryStatus(entry, DownloadStatus.audioDownloading);
          unawaited(_updateBiliDownloadEntryJson(entry));
          return;
        case DownloadStatus.failDownload:
          _updateEntryStatus(entry, DownloadStatus.failDownloadAudio);
          unawaited(_closeTask(entry.cid));
          return;
        default:
          break;
      }
    }
    entry.downloadedBytes = entry.totalBytes;
    _updateEntryStatus(entry, DownloadStatus.completed);
    unawaited(_closeTask(entry.cid, completed: true));
  }

  void _onAudioDone(BiliDownloadEntryInfo entry, [Object? error]) {
    final task = _tasks[entry.cid];
    if (task == null) {
      return;
    }
    if (task.videoManager?.status != DownloadStatus.completed) {
      return;
    }
    if (error == null) {
      entry.downloadedBytes = entry.totalBytes;
      _updateEntryStatus(entry, DownloadStatus.completed);
      unawaited(_closeTask(entry.cid, completed: true));
    } else {
      final status = task.audioManager?.status ?? DownloadStatus.pause;
      _updateEntryStatus(
        entry,
        status == DownloadStatus.failDownload
            ? DownloadStatus.failDownloadAudio
            : status,
      );
      unawaited(_closeTask(entry.cid));
    }
  }

  /// 结束一个任务：completed=true 移入已缓存列表，否则保留在等待队列（暂停/失败可重试）
  Future<void> _closeTask(int cid, {bool completed = false}) {
    return _lock.synchronized(() async {
      final task = _tasks.remove(cid);
      if (task == null) {
        return;
      }
      activeList.remove(task.entry);
      final entry = task.entry;
      if (completed) {
        entry
          ..downloadedBytes = entry.totalBytes
          ..isCompleted = true;
        await _updateBiliDownloadEntryJson(entry);
        waitDownloadQueue.remove(entry);
        downloadList.insert(0, entry);
        flagNotifier.refresh();
        _clearRetry(cid);
      } else {
        await _updateBiliDownloadEntryJson(entry);
        // 下载失败时自动重新激活（暂停不算失败，不自动重试）
        if (_isFailureStatus(entry.status)) {
          _scheduleRetry(entry);
        }
      }
      _scheduleLocked();
    });
  }

  void nextDownload() {
    unawaited(_scheduleDownloads());
  }

  Future<void> deleteDownload({
    required BiliDownloadEntryInfo entry,
    bool removeList = false,
    bool removeQueue = false,
    bool refresh = true,
    bool downloadNext = true,
  }) async {
    if (removeList) {
      downloadList.remove(entry);
    }
    if (removeQueue) {
      waitDownloadQueue.remove(entry);
    }
    // 无论条目是否活跃，删除时都取消待触发的自动重试
    _clearRetry(entry.cid);
    if (isActive(entry.cid)) {
      await cancelDownload(
        isDelete: true,
        downloadNext: downloadNext,
        entry: entry,
      );
    }
    final downloadDir = Directory(entry.pageDirPath);
    if (downloadDir.existsSync()) {
      if (!await downloadDir.lengthGte(2)) {
        await downloadDir.tryDel(recursive: true);
      } else {
        final entryDir = Directory(entry.entryDirPath);
        if (entryDir.existsSync()) {
          await entryDir.tryDel(recursive: true);
        }
      }
    }
    if (refresh) {
      flagNotifier.refresh();
    }
  }

  Future<void> deletePage({
    required String pageDirPath,
    bool refresh = true,
  }) async {
    await Directory(pageDirPath).tryDel(recursive: true);
    downloadList.removeWhere((e) => e.pageDirPath == pageDirPath);
    if (refresh) {
      flagNotifier.refresh();
    }
  }

  /// 取消/暂停指定条目的下载任务
  Future<void> cancelDownload({
    required bool isDelete,
    bool downloadNext = true,
    required BiliDownloadEntryInfo entry,
  }) {
    return _lock.synchronized(() async {
      final task = _tasks.remove(entry.cid);
      if (task != null) {
        await task.videoManager?.cancel(isDelete: isDelete);
        await task.audioManager?.cancel(isDelete: isDelete);
        activeList.remove(entry);
        if (!isDelete) {
          entry.status = DownloadStatus.pause;
          await _updateBiliDownloadEntryJson(entry);
        } else {
          _clearRetry(entry.cid);
          waitDownloadQueue.remove(entry);
        }
      } else if (!isDelete && entry.status.isDownloading) {
        // 队列中尚未真正开始的任务：直接标记暂停
        entry.status = DownloadStatus.pause;
      }
      if (downloadNext) {
        _scheduleLocked();
      }
      waitDownloadQueue.refresh();
      activeList.refresh();
      _refreshDownloadNotification();
    });
  }
}

class _DownloadTask {
  final BiliDownloadEntryInfo entry;
  DownloadManager? videoManager;
  DownloadManager? audioManager;
  _DownloadTask(this.entry);
}

typedef SetNotifier = Set<VoidCallback>;

extension SetNotifierExt on SetNotifier {
  void refresh() {
    for (final i in this) {
      i();
    }
  }
}
