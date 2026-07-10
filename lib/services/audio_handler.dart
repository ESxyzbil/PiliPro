import 'dart:io' show File, FileMode, Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pb.dart' show DetailItem;
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/live/live_room_info_h5/data.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/media_control_windows.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:audio_service/audio_service.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as path;

Future<VideoPlayerServiceHandler> initAudioService() {
  return AudioService.init(
    builder: VideoPlayerServiceHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.piliplus.audio',
      androidNotificationChannelName: 'Audio Service ${Constants.appName}',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      fastForwardInterval: Duration(seconds: 10),
      rewindInterval: Duration(seconds: 10),
      androidNotificationChannelDescription: 'Media notification channel',
      androidNotificationIcon: 'drawable/ic_notification_icon',
    ),
  );
}

class VideoPlayerServiceHandler extends BaseAudioHandler with SeekHandler {
  static final List<MediaItem> _item = [];
  bool enableBackgroundPlay = Pref.enableBackgroundPlay;

  Future<void>? Function()? onPlay;
  Future<void>? Function()? onPause;
  Future<void>? Function(Duration position)? onSeek;
  Future<bool>? Function()? onSkipToPrevious;
  Future<bool>? Function()? onSkipToNext;

  @override
  Future<void> play() {
    return onPlay?.call() ??
        PlPlayerController.playIfExists() ??
        Future.syncValue(null);
    // player.play();
  }

  @override
  Future<void> pause() {
    return onPause?.call() ?? PlPlayerController.pauseIfExists();
    // player.pause();
  }

  @override
  Future<void> seek(Duration position) {
    playbackState.add(
      playbackState.value.copyWith(
        updatePosition: position,
      ),
    );
    return (onSeek?.call(position) ??
        PlPlayerController.seekToIfExists(position, isSeek: false));
    // await player.seekTo(position);
  }

  @override
  Future<void> skipToNext() async {
    final success = await onSkipToNext?.call() ?? false;
    if (success && _item.isNotEmpty) {
      final currentIndex = _item.indexWhere((e) => e.id == mediaItem.value?.id);
      if (currentIndex != -1 && currentIndex + 1 < _item.length) {
        setMediaItem(_item[currentIndex + 1]);
      }
    }
  }

  @override
  Future<void> skipToPrevious() async {
    final success = await onSkipToPrevious?.call() ?? false;
    if (success && _item.isNotEmpty) {
      final currentIndex = _item.indexWhere((e) => e.id == mediaItem.value?.id);
      if (currentIndex > 0) {
        setMediaItem(_item[currentIndex - 1]);
      }
    }
  }

  void setMediaItem(MediaItem newMediaItem) {
    if (!enableBackgroundPlay) return;
    if (!mediaItem.isClosed) mediaItem.add(newMediaItem);
  }

  String? _originalTitle;
  String? _originalArtist;

  /// 更新通知栏歌词（酷狗风格）
  ///   setContentTitle:  当前歌词行（岛上显示这个）
  ///   setContentText:   歌曲名（原标题）
  ///   setSubText:       下一句歌词
  void updateLyrics(String? lyrics, {String? nextLyrics}) {
    if (!enableBackgroundPlay) return;
    final current = mediaItem.value;
    if (current == null) return;

    // 第一次调用时存下原标题/歌手
    _originalTitle ??= current.title;
    _originalArtist ??= current.artist;

    if (lyrics != null && lyrics.isNotEmpty) {
      // 歌词打在标题上（岛上显示），原歌名移到歌手位
      mediaItem.add(current.copyWith(
        title: lyrics,
        artist: _originalTitle ?? '',
        displayDescription: nextLyrics ?? '',
      ));
    } else {
      // 没有歌词时恢复原始信息
      mediaItem.add(current.copyWith(
        title: _originalTitle ?? '',
        artist: _originalArtist ?? '',
        displayDescription: '',
      ));
    }
  }

  void setPlaybackState(
    PlayerStatus status,
    bool isBuffering,
    bool isLive,
  ) {
    if (!enableBackgroundPlay ||
        _item.isEmpty ||
        !PlPlayerController.instanceExists()) {
      return;
    }

    final AudioProcessingState processingState;
    if (status.isCompleted) {
      processingState = AudioProcessingState.completed;
    } else if (isBuffering) {
      processingState = AudioProcessingState.buffering;
    } else {
      processingState = AudioProcessingState.ready;
    }

    final playing = status.isPlaying;
    playbackState.add(
      playbackState.value.copyWith(
        processingState: isBuffering
            ? AudioProcessingState.buffering
            : processingState,
        controls: [
          if (!isLive) ...[
            const MediaControl(
              androidIcon: 'drawable/ic_player_skip_previous',
              label: 'Previous',
              action: MediaAction.skipToPrevious,
            ),
            const MediaControl(
              androidIcon: 'drawable/ic_player_rewind_10s',
              label: 'Rewind',
              action: MediaAction.rewind,
            ),
          ],
          if (playing)
            const MediaControl(
              androidIcon: 'drawable/ic_player_pause',
              label: 'Pause',
              action: MediaAction.pause,
            )
          else
            const MediaControl(
              androidIcon: 'drawable/ic_player_play',
              label: 'Play',
              action: MediaAction.play,
            ),
          if (!isLive) ...[
            const MediaControl(
              androidIcon: 'drawable/ic_player_fast_forward_10s',
              label: 'Fast Forward',
              action: MediaAction.fastForward,
            ),
            const MediaControl(
              androidIcon: 'drawable/ic_player_skip_next',
              label: 'Next',
              action: MediaAction.skipToNext,
            ),
          ],
        ],
        playing: playing,
        systemActions: const {
          MediaAction.seek,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
        },
      ),
    );
    if (Platform.isAndroid &&
        (AndroidHelper.isPipMode ||
            PlPlayerController.instance?.isAutoEnterPip == true)) {
      AndroidHelper.updatePipActions(
        PlatformDispatcher.instance.engineId!,
        isLive,
        playing,
      );
    }
  }

  void onStatusChange(PlayerStatus status, bool isBuffering, isLive) {
    // SMTC 播放状态更新独立于 enableBackgroundPlay / _item
    if (Platform.isWindows) {
      MediaControlWindows().updatePlaybackStatus(status.isPlaying);
    }

    if (!enableBackgroundPlay) return;

    if (_item.isEmpty) return;
    setPlaybackState(status, isBuffering, isLive);
  }

  void onVideoDetailChange(
    dynamic data,
    int cid,
    String herotag, {
    String? artist,
    String? cover,
  }) {
    debugLog('onVideoDetailChange called: type=${data?.runtimeType} cid=$cid herotag=$herotag');
    // SMTC 更新独立于 enableBackgroundPlay / PlPlayerController — 先跑
    _updateSmtcFromData(data, cid, herotag, artist: artist, cover: cover);

    if (!enableBackgroundPlay) return;
    // if (kDebugMode) {
    //   debugPrint('当前调用栈为：');
    //   debugPrint(StackTrace.current);
    // }
    if (!PlPlayerController.instanceExists()) return;
    if (data == null) return;

    Uri getUri(String? cover) => Uri.parse(ImageUtils.safeThumbnailUrl(cover));

    late final id = '$cid$herotag';
    final MediaItem mediaItem;
    switch (data) {
      case VideoDetailData(:final pages):
        if (pages != null && pages.length > 1) {
          final current = pages.firstWhereOrNull((e) => e.cid == cid);
          mediaItem = MediaItem(
            id: id,
            title: current?.part ?? '',
            artist: data.owner?.name,
            duration: Duration(seconds: current?.duration ?? 0),
            artUri: getUri(data.pic),
          );
        } else {
          mediaItem = MediaItem(
            id: id,
            title: data.title ?? '',
            artist: data.owner?.name,
            duration: Duration(seconds: data.duration ?? 0),
            artUri: getUri(data.pic),
          );
        }
      case EpisodeItem():
        mediaItem = MediaItem(
          id: id,
          title: data.showTitle ?? data.longTitle ?? data.title ?? '',
          artist: artist,
          duration: data.from == 'pugv'
              ? Duration(seconds: data.duration ?? 0)
              : Duration(milliseconds: data.duration ?? 0),
          artUri: getUri(data.cover),
        );
      case RoomInfoH5Data():
        mediaItem = MediaItem(
          id: id,
          title: data.roomInfo?.title ?? '',
          artist: data.anchorInfo?.baseInfo?.uname,
          artUri: getUri(data.roomInfo?.cover),
          isLive: true,
        );
      case Part():
        mediaItem = MediaItem(
          id: id,
          title: data.part ?? '',
          artist: artist,
          duration: Duration(seconds: data.duration ?? 0),
          artUri: getUri(cover),
        );
      case DetailItem(:final arc):
        mediaItem = MediaItem(
          id: id,
          title: arc.title,
          artist: data.owner.name,
          duration: Duration(seconds: arc.duration.toInt()),
          artUri: getUri(arc.cover),
        );
      case BiliDownloadEntryInfo():
        final coverFile = File(
          path.join(data.entryDirPath, PathUtils.coverName),
        );
        final uri = coverFile.existsSync()
            ? coverFile.absolute.uri
            : getUri(data.cover);
        mediaItem = MediaItem(
          id: id,
          title: data.showTitle,
          artist: data.ownerName,
          duration: Duration(milliseconds: data.totalTimeMilli),
          artUri: uri,
        );
      default:
        return;
    }

    // if (kDebugMode) debugPrint("exist: ${PlPlayerController.instanceExists()}");
    if (!PlPlayerController.instanceExists()) return;
    _item.add(mediaItem);
    setMediaItem(mediaItem);
    // 重置原标题缓存，下次 updateLyrics 会重新捕获
    _originalTitle = null;
    _originalArtist = null;
  }

  /// Extract display info from [data] and push to Windows SMTC.
  /// Runs independently of [enableBackgroundPlay] and [PlPlayerController].
  void _updateSmtcFromData(
    dynamic data,
    int cid,
    String herotag, {
    String? artist,
    String? cover,
  }) {
    debugLog('_updateSmtcFromData entered: data=${data?.runtimeType} cid=$cid');
    if (!Platform.isWindows || data == null) {
      debugLog('_updateSmtcFromData: skip (isWindows=${Platform.isWindows} data=$data)');
      return;
    }
    try {
      String smtcTitle = '';
      String smtcArtist = artist ?? '';
      String smtcThumb = cover ?? '';
      switch (data) {
        case VideoDetailData(:final pages, :final title, :final owner, :final pic):
          if (pages != null && pages.length > 1) {
            final current = pages.firstWhereOrNull((e) => e.cid == cid);
            smtcTitle = current?.part ?? title ?? '';
          } else {
            smtcTitle = title ?? '';
          }
          smtcArtist = owner?.name ?? smtcArtist;
          smtcThumb = pic ?? smtcThumb;
        case EpisodeItem():
          smtcTitle = data.showTitle ?? data.longTitle ?? data.title ?? '';
          smtcArtist = artist ?? '';
          smtcThumb = data.cover ?? '';
        case RoomInfoH5Data():
          smtcTitle = data.roomInfo?.title ?? '';
          smtcArtist = data.anchorInfo?.baseInfo?.uname ?? '';
          smtcThumb = data.roomInfo?.cover ?? '';
        case Part():
          smtcTitle = data.part ?? '';
          smtcArtist = artist ?? '';
          smtcThumb = cover ?? '';
        case DetailItem(:final arc):
          smtcTitle = arc.title ?? '';
          smtcArtist = data.owner.name ?? '';
          smtcThumb = arc.cover ?? '';
        case BiliDownloadEntryInfo():
          smtcTitle = data.showTitle;
          smtcArtist = data.ownerName ?? '';
          smtcThumb = data.cover;
        default:
          debugLog('_updateSmtcFromData: unknown type ${data.runtimeType}');
          return;
      }
      debugLog('_updateSmtcFromData: title="$smtcTitle" artist="$smtcArtist" thumb.len=${smtcThumb.length} enabled=${MediaControlWindows().enabled}');
      if (smtcTitle.isEmpty && smtcArtist.isEmpty) {
        debugLog('_updateSmtcFromData: both empty, skip');
        return;
      }
      final smtc = MediaControlWindows();
      if (!smtc.enabled) {
        smtc.enable(
          onPlay: PlPlayerController.playIfExists,
          onPause: PlPlayerController.pauseIfExists,
        );
      } else if (data is VideoDetailData) {
        // 视频页覆盖 play/pause
        // 不碰 next/prev — 由视频页自身的 _setupSmtcNavigation() / didPopNext() 管理
        smtc.updateCallbacks(
          onPlay: PlPlayerController.playIfExists,
          onPause: PlPlayerController.pauseIfExists,
        );
      }
      smtc.updateMetadata(
        title: smtcTitle,
        artist: smtcArtist,
        thumbnail: smtcThumb,
      );
      debugLog('_updateSmtcFromData: updateMetadata called');
    } catch (e, s) {
      debugLog('_updateSmtcFromData ERROR: $e\n$s');
    }
  }

  /// Write debug message to a log file.
  static void debugLog(String msg) {
    if (!Platform.isWindows) return;
    try {
      final tmp = Platform.environment['TEMP'] ?? 'C:\\Windows\\Temp';
      final f = File('$tmp\\piliplus_smtc_debug.log');
      f.writeAsStringSync('[${DateTime.now()}] $msg\n', mode: FileMode.append);
    } catch (_) {
      // Last resort — write to app directory
      try {
        final f = File('C:\\Users\\34983\\Documents\\PiliPlus\\piliplus_debug.log');
        f.writeAsStringSync('[${DateTime.now()}] $msg\n', mode: FileMode.append);
      } catch (_) {}
    }
  }

  void _updateWindowsSmtc(MediaItem item) {
    if (!Platform.isWindows) return;
    try {
      final smtc = MediaControlWindows();
      if (!smtc.enabled) {
        // 首次 enable — 只设 play/pause，不覆盖 next/prev
        smtc.enable(
          onPlay: PlPlayerController.playIfExists,
          onPause: PlPlayerController.pauseIfExists,
        );
      }
      smtc.updateMetadata(
        title: item.title,
        artist: item.artist,
        thumbnail: item.artUri?.toString() ?? '',
      );
    } catch (_) {
      // SMTC 未初始化时静默忽略
    }
  }

  void onVideoDetailDispose(String herotag) {
    if (!enableBackgroundPlay) return;

    if (_item.isNotEmpty) {
      _item.removeWhere((item) => item.id.endsWith(herotag));
    }
    if (_item.isNotEmpty) {
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.idle,
          playing: false,
        ),
      );
      setMediaItem(_item.last);
      stop();
    }
    // 清除 Windows SMTC 数据（仅在没有其他 media item 时）
    if (_item.isEmpty && Platform.isWindows) {
      try {
        MediaControlWindows().clearMetadata();
      } catch (_) {}
    }
  }

  void clear() {
    if (!enableBackgroundPlay) return;
    mediaItem.add(null);
    _item.clear();
    /**
     * if (playbackState.processingState == AudioProcessingState.idle &&
            previousState?.processingState != AudioProcessingState.idle) {
          await AudioService._stop();
        }
     */
    if (playbackState.value.processingState == AudioProcessingState.idle) {
      playbackState.add(
        PlaybackState(
          processingState: AudioProcessingState.completed,
          playing: false,
        ),
      );
    }
    playbackState.add(
      PlaybackState(
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
  }

  void onPositionChange(Duration position) {
    if (!enableBackgroundPlay ||
        _item.isEmpty ||
        !PlPlayerController.instanceExists()) {
      return;
    }

    playbackState.add(
      playbackState.value.copyWith(
        updatePosition: position,
      ),
    );
  }
}
