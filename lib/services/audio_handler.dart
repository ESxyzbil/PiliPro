import 'dart:async';
import 'dart:io' show File, FileMode, Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pb.dart' show DetailItem;
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/live/live_room_info_h5/data.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/pages/audio/controller.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/triple_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/media_control_windows.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:audio_service/audio_service.dart';
import 'package:collection/collection.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
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

typedef _StatusConfig = (
  PlayerStatus status,
  bool isBuffering,
  bool isLive,
  double speed,
);

class VideoPlayerServiceHandler extends BaseAudioHandler with SeekHandler {
  static final List<MediaItem> _item = [];
  bool enableBackgroundPlay = Pref.enableBackgroundPlay;
  MediaFavController? _mediaFavCtr;

  Future<void>? Function()? onPlay;
  Future<void>? Function()? onPause;
  Future<void>? Function(Duration position)? onSeek;
  // 通知栏/锁屏「上一曲 / 下一曲」：由播放页或音频页注入切歌逻辑，
  // 返回 false 表示当前页没有可切的上/下一曲（见 skipToPrevious/Next）。
  // （保留作兜底：音频页已改为下面的"调用时解析"，不再绑死到实例上。）
  Future<bool>? Function()? onSkipToPrevious;
  Future<bool>? Function()? onSkipToNext;

  /// 当前应接管通知栏/锁屏控制权的音频页实例。
  ///
  /// ⚠️ 多音频标签并存（每个音频标签一个 AudioController）时通知栏只有一套
  /// 控制，必须在**调用时**解析出活的实例。以前的写法是在 AudioController
  /// onInit 里把 onPlay/onPause/onSeek/onSkipTo* 绑到那个实例上：
  /// ①绑死的实例被关掉后 `onClose` 把回调置 null → 通知栏按钮点下去无声无息；
  /// ②后打开的音频页会覆盖绑定 → 控制权落到"没在播"的实例上；
  /// ③关掉非播放中的音频标签还会把通知状态改成"已暂停"。
  /// 这三条合起来就是用户反馈的"audioservice 控制偶发失效"。
  ///
  /// 解析规则：只考虑**可用**实例（未销毁、播放器已创建），其中正在播放的
  /// 优先，其次最后注册的。不可用实例必须排除——刚打开的音频页在播放器
  /// 异步创建完成前 `player == null`，此时若被选中，通知栏按钮会"点了没反应"
  /// （用户反馈"打开音频页时有概率直接不能对应控制"）。
  AudioController? get _liveAudioCtr {
    final usable = <AudioController>[];
    for (final c in AudioController.liveInstances) {
      if (!c.isClosed && c.player != null) usable.add(c);
    }
    if (usable.isEmpty) return null;
    for (final c in usable) {
      if (c.isPlaying()) return c;
    }
    return usable.last;
  }

  /// 是否有音频页实例接管（供 onUpdateState 判断当前是否"音频态"）
  bool get _hasLiveAudio => AudioController.liveInstances.isNotEmpty;

  /// 上一次的控制权持有者（用于识别"持有者变了"并补发真实状态）
  Object? _lastOwner;

  /// 临时诊断（release 也进 logcat，tag=flutter）：前缀 [PL_AUD]，
  /// 用于定位"通知栏控制/显示对应不上"的具体环节。排查完删除。
  static String? _lastAudLog;
  void _aud(String msg) {
    if (msg == _lastAudLog) return;
    _lastAudLog = msg;
    // ignore: avoid_print
    print('[PL_AUD] $msg');
  }

  void _audAction(String action, AudioController? audio) {
    _aud(
      '$action -> ctr=${audio?.hashCode ?? "null"} playing=${audio?.isPlaying()} '
      'player=${audio?.player != null} n=${AudioController.liveInstances.length} '
      'item=${mediaItem.value?.id}',
    );
  }

  /// 让通知栏**显示的条目**跟随**控制权持有者**。
  ///
  /// 多音频标签并存时有两个"谁是当前"的判断，必须保持一致：
  /// - 媒体条目（通知上看到的歌名/封面）来自各实例自己在 onVideoDetailChange
  ///   里推上来的 mediaItem，规则是"最后一次推的赢"；
  /// - 控制权（按钮作用对象）是调用时按"正在播放优先"解析的。
  /// 两者不一致就会出现用户实测的现象：显示的是暂停中的 A，按下去动的却是
  /// 正在播放的 B。这里统一以控制权持有者为准，把它的条目重新设为当前条目。
  void syncActiveItem() {
    final ctr = _liveAudioCtr;
    // 控制权持有者发生变化 → 立刻重推它的**真实**状态。
    // 多实例可以同时播放（不做单实例限制），但通知栏只有一个图标：图标必须
    // 永远等于持有者的真实状态。非持有者的状态上报会被上面的过滤丢弃，若不
    // 在此补发，持有者切换后图标就会停在上一个实例的状态上（用户实测
    // "操作一复杂，播放/暂停状态就对不上"）。
    if (!identical(ctr, _lastOwner)) {
      _lastOwner = ctr;
      _aud('owner change -> ${ctr?.hashCode}');
      if (ctr != null) emitActiveState(ctr);
    }
    if (ctr == null || _item.isEmpty) {
      _aud('sync skip ctr=${ctr?.hashCode} items=${_item.length}');
      return;
    }
    final suffix = ctr.hashCode.toString();
    MediaItem? hit;
    for (final it in _item) {
      if (it.id.endsWith(suffix)) hit = it; // 取该实例最后一条（当前曲目）
    }
    if (hit != null && mediaItem.value?.id != hit.id) {
      _aud(
        'sync switch cur=${mediaItem.value?.id} -> ${hit.id} '
        'active=${ctr.hashCode} items=${_item.length}',
      );
      setMediaItem(hit);
      // 条目切过去的同时把播放状态也对齐（否则新条目可能沿用上一条的图标）
      emitActiveState(ctr);
    } else if (hit == null) {
      _aud(
        'sync miss active=${ctr.hashCode} items='
        '${_item.map((e) => e.id).join(",")}',
      );
    }
  }

  /// 操作后强制把控制权持有者的**真实**播放状态重推一次（跳过去重）。
  /// 复杂操作序列下（A 暂停 → B 播放 → 切回 A…）通知栏图标若只依赖"配置
  /// 变化"去重推送，容易与实际不符（用户实测"操作一复杂，播放/暂停状态就对不上"）。
  void emitActiveState(AudioController owner) {
    if (!identical(owner, _liveAudioCtr)) return;
    if (!enableBackgroundPlay || _item.isEmpty) return;
    final playing = owner.isPlaying();
    final pos = owner.player?.state.position ?? Duration.zero;
    _lastConfig = (playing ? .playing : .paused, false, false, owner.speed);
    _lastPos = pos;
    _updateState(
      .ready,
      playing,
      false,
      position: pos,
      speed: owner.speed,
    );
    _aud('emit playing=$playing ctr=${owner.hashCode}');
  }

  @override
  Future<void> play() async {
    final audio = _liveAudioCtr;
    _audAction('play', audio);
    if (audio != null) {
      // 播放器还没建好、或上次取流失败时，走"就绪后再播"（内部会补一次取流，
      // 让通知栏的播放键在弱网失败后能自行恢复）
      final r = audio.playUrlFailed.value ? null : audio.onPlay();
      if (r != null) {
        await r;
      } else {
        await audio.playWhenReady();
      }
      emitActiveState(audio);
      return;
    }
    await (onPlay?.call() ??
        PlPlayerController.playIfExists() ??
        Future.syncValue(null));
  }

  @override
  Future<void> pause() async {
    final audio = _liveAudioCtr;
    _audAction('pause', audio);
    if (audio != null) {
      await audio.onPause();
      emitActiveState(audio);
      return;
    }
    await (onPause?.call() ??
        PlPlayerController.pauseIfExists() ??
        Future.syncValue(null));
  }

  @override
  Future<void> seek(Duration position) {
    final audio = _liveAudioCtr;
    _audAction('seek', audio);
    if (audio != null) return audio.onSeek(position) ?? Future.syncValue(null);
    return onSeek?.call(position) ??
        PlPlayerController.seekToIfExists(position, isSeek: false) ??
        Future.syncValue(null);
  }

  @override
  Future<void> skipToNext() async {
    final audio = _liveAudioCtr;
    _audAction('skipNext', audio);
    if (audio != null) {
      // 音频页切歌后会自行推送新的 mediaItem（onVideoDetailChange），
      // 这里不要再改 _item / 媒体条目，避免多实例队列互相打架。
      audio.playNext();
      return;
    }    final success = await onSkipToNext?.call() ?? false;
    if (success && _item.isNotEmpty) {
      final currentIndex = _item.indexWhere((e) => e.id == mediaItem.value?.id);
      if (currentIndex != -1 && currentIndex + 1 < _item.length) {
        setMediaItem(_item[currentIndex + 1]);
      }
    }
  }

  @override
  Future<void> skipToPrevious() async {
    final audio = _liveAudioCtr;
    _audAction('skipPrev', audio);
    if (audio != null) {
      audio.playPrev();
      return;
    }
    final success = await onSkipToPrevious?.call() ?? false;
    if (success && _item.isNotEmpty) {
      final currentIndex = _item.indexWhere((e) => e.id == mediaItem.value?.id);
      if (currentIndex > 0) {
        setMediaItem(_item[currentIndex - 1]);
      }
    }
  }

  /// 媒体通知收藏按钮点击：弹出收藏夹选择（复用视频页收藏面板）
  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    if (name == 'fav') {
      _handleFav();
    }
    return super.customAction(name, extras);
  }

  void _handleFav() {
    if (!Accounts.main.isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final cur = mediaItem.value;
    final rid = cur?.extras?['rid'];
    final rtype = cur?.extras?['rtype'];
    if (rid == null || rtype is! int || Get.context == null) {
      SmartDialog.showToast('当前条目不支持收藏');
      return;
    }
    final ctr = _mediaFavCtr ??= MediaFavController(ridType: (rid, rtype));
    ctr.ridType = (rid, rtype);
    unawaited(ctr.queryVideoInFolder());
    PageUtils.showFavBottomSheet(context: Get.context!, ctr: ctr);
  }

  /// 根据条目类型计算收藏所需 rid/rtype（不支持收藏的类型返回 null）
  static Map<String, dynamic>? _favExtras(Object data) {
    switch (data) {
      case VideoDetailData():
        return data.aid == null ? null : {'rid': data.aid!, 'rtype': 2};
      case EpisodeItem():
        return data.id == null ? null : {'rid': data.id!, 'rtype': 24};
      case HotVideoItemModel():
        return data.aid == null ? null : {'rid': data.aid!, 'rtype': 2};
      case BiliDownloadEntryInfo():
        if (data.ep case final ep?) {
          return {'rid': ep.episodeId, 'rtype': 24};
        }
        return {'rid': data.avid, 'rtype': 2};
      default:
        return null;
    }
  }

  void setMediaItem(MediaItem newMediaItem) {
    if (!enableBackgroundPlay) return;
    // if (kDebugMode) {
    //   debugPrint("此时调用栈为：");
    //   debugPrint(newMediaItem);
    //   debugPrint(newMediaItem.title);
    //   debugPrint(StackTrace.current.toString());
    // }
    if (!mediaItem.isClosed) mediaItem.add(newMediaItem);
    // 诊断：通知栏封面（artUri）是否随自动连播变化——不改就一直显示上一首
    _aud(
      'setItem id=${newMediaItem.id} title=${newMediaItem.title} '
      'art=${newMediaItem.artUri}',
    );
    // ⚠️ 换歌后顺带推一次 playbackState：部分 ODM（ColorOS 流体云等）的媒体
    // 卡片只在**播放状态变化**时重绘大图，仅替换 metadata 时封面会停在上一首
    // （用户实测"自动连播不更新封面"）。这里发一次内容等价的状态更新，强制
    // 通知重建。
    final state = playbackState.value;
    playbackState.add(
      state.copyWith(updatePosition: state.updatePosition),
    );
    // 媒体项变化 → 重置歌词原标题缓存（下次 updateLyrics 重新捕获）
    _originalTitle = null;
    _originalArtist = null;
  }

  String? _originalTitle;
  String? _originalArtist;

  /// 更新通知栏歌词（酷狗风格）
  ///   setContentTitle:  当前歌词行（岛上显示这个）
  ///   setContentText:   歌曲名（原标题）
  ///   setSubText:       下一句歌词
  void updateLyrics(String? lyrics, {String? nextLyrics, Object? owner}) {
    if (!enableBackgroundPlay) return;
    // 多音频实例：歌词只允许"控制权持有者"写。否则暂停中的 A 会把正在播放
    // 的 B 的通知标题改成 A 的歌词（用户实测：通知显示的始终是第一个的信息）。
    if (owner != null &&
        AudioController.liveInstances.length > 1 &&
        !identical(owner, _liveAudioCtr)) {
      return;
    }
    final current = mediaItem.value;
    if (current == null) return;

    // 第一次调用时存下原标题/歌手
    _originalTitle ??= current.title;
    _originalArtist ??= current.artist;

    if (lyrics != null && lyrics.isNotEmpty) {
      // 歌词打在标题上（岛上显示），原歌名移到歌手位
      mediaItem.add(
        current.copyWith(
          title: lyrics,
          artist: _originalTitle ?? '',
          displayDescription: nextLyrics ?? '',
        ),
      );
    } else {
      // 没有歌词时恢复原始信息
      mediaItem.add(
        current.copyWith(
          title: _originalTitle ?? '',
          artist: _originalArtist ?? '',
          displayDescription: '',
        ),
      );
    }
  }

  Duration? _lastPos;
  _StatusConfig? _lastConfig;
  void onUpdateState(
    PlayerStatus status,
    bool isBuffering,
    bool isLive, {
    required Duration position,
    required double speed,
    String? debugLabel,
    Object? owner,
  }) {
    // Windows SMTC 播放/暂停状态：与后台播放开关无关，先于下面的短路。
    if (Platform.isWindows) {
      MediaControlWindows().updatePlaybackStatus(status.isPlaying);
    }

    if (!enableBackgroundPlay || _item.isEmpty) {
      return;
    }

    // 先让显示对齐控制权（任何实例的状态上报都会触发一次，用于收敛）
    syncActiveItem();

    // 多音频实例：只采纳"控制权持有者"的状态上报。否则后台没在播的实例
    // 也会把自己的 paused 推上来，把正在播放的通知栏改成暂停——用户实测
    // 表现为通知栏状态乱跳、按钮点了没反应。
    if (owner != null &&
        AudioController.liveInstances.length > 1 &&
        !identical(owner, _liveAudioCtr)) {
      _aud(
        'state DROP owner=${owner.hashCode} active=${_liveAudioCtr?.hashCode} '
        'n=${AudioController.liveInstances.length} status=${status.name}',
      );
      return;
    }
    _aud(
      'state owner=${owner?.hashCode} active=${_liveAudioCtr?.hashCode} '
      'n=${AudioController.liveInstances.length} status=${status.name} '
      'item=${mediaItem.value?.id}',
    );

    // 有音频实例接管时忽略视频页的暂停事件（音频在后台继续播）
    if (_hasLiveAudio && debugLabel == 'onVideoPaused') return;

    final newConfig = (status, isBuffering, isLive, speed);
    if (_lastConfig == newConfig) {
      if (_lastPos != null) {
        final pos = position.inSeconds;
        final lastPos = _lastPos!.inSeconds;
        _lastPos = position;
        if (pos == lastPos && pos != 0) return;
      }
    }
    _lastConfig = newConfig;

    final AudioProcessingState processingState;
    final bool playing;
    switch (status) {
      case .completed:
        playing = false;
        processingState = .completed;
      case .playing:
        playing = true;
        processingState = isBuffering ? .buffering : .ready;
      case .paused:
        playing = isBuffering;
        processingState = isBuffering ? .buffering : .ready;
    }
    _updateState(
      processingState,
      playing,
      isLive,
      position: position,
      speed: speed,
    );
  }

  void _updateState(
    AudioProcessingState state,
    bool playing,
    bool isLive, {
    required Duration position,
    required double speed,
  }) {
    playbackState.add(
      playbackState.value.copyWith(
        processingState: state,
        updatePosition: position,
        speed: speed,
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
              action: .rewind,
            ),
          ],
          if (playing)
            const MediaControl(
              androidIcon: 'drawable/ic_player_pause',
              label: 'Pause',
              action: .pause,
            )
          else
            const MediaControl(
              androidIcon: 'drawable/ic_player_play',
              label: 'Play',
              action: .play,
            ),
          if (!isLive) ...[
            const MediaControl(
              androidIcon: 'drawable/ic_player_fast_forward_10s',
              label: 'Fast Forward',
              action: .fastForward,
            ),
            const MediaControl(
              androidIcon: 'drawable/ic_player_skip_next',
              label: 'Next',
              action: MediaAction.skipToNext,
            ),
          ],
          // 收藏：仅当前条目可收藏（mediaItem 带 rid/rtype）时在通知上显示
          if (mediaItem.value?.extras case {
            'rid': Object(),
            'rtype': int(),
          }) ...[
            MediaControl.custom(
              androidIcon: 'drawable/ic_player_fav',
              label: '收藏',
              name: 'fav',
            ),
          ],
        ],
        playing: playing,
        systemActions: const {.seek},
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

  void onVideoDetailChange(
    dynamic data,
    int cid,
    String herotag, {
    String? artist,
    String? cover,
  }) {
    debugLog(
      'onVideoDetailChange called: type=${data?.runtimeType} cid=$cid herotag=$herotag',
    );
    // SMTC 更新独立于 enableBackgroundPlay / PlPlayerController — 先跑
    _updateSmtcFromData(data, cid, herotag, artist: artist, cover: cover);

    if (!enableBackgroundPlay) return;
    // if (kDebugMode) {
    //   debugPrint('当前调用栈为：');
    //   debugPrint(StackTrace.current);
    // }
    // 音频页（离线/在线）使用 media_kit Player，不是 PlPlayerController；
    // 音频页数据（DetailItem / HotVideoItemModel / BiliDownloadEntryInfo）不依赖
    // PlPlayerController 实例，直接更新媒体通知。
    if (data is! BiliDownloadEntryInfo &&
        data is! DetailItem &&
        data is! HotVideoItemModel &&
        !PlPlayerController.instanceExists()) {
      return;
    }
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
            extras: _favExtras(data),
          );
        } else {
          mediaItem = MediaItem(
            id: id,
            title: data.title ?? '',
            artist: data.owner?.name,
            duration: Duration(seconds: data.duration ?? 0),
            artUri: getUri(data.pic),
            extras: _favExtras(data),
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
          extras: _favExtras(data),
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
      case HotVideoItemModel():
        final dur = data.duration ?? 0;
        mediaItem = MediaItem(
          id: id,
          title: data.title,
          artist: data.owner.name ?? '',
          duration: Duration(seconds: dur > 0 ? dur : 0),
          artUri: getUri(data.cover),
          extras: _favExtras(data),
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
          extras: _favExtras(data),
        );
      default:
        return;
    }

    // if (kDebugMode) debugPrint("exist: ${PlPlayerController.instanceExists()}");
    if (data is! BiliDownloadEntryInfo &&
        data is! DetailItem &&
        data is! HotVideoItemModel &&
        !PlPlayerController.instanceExists()) {
      return;
    }
    _item.add(mediaItem);
    setMediaItem(mediaItem);
    _aud(
      'push id=${mediaItem.id} herotag=$herotag '
      'active=${_liveAudioCtr?.hashCode} n=${_item.length}',
    );
    // 非控制权持有者推条目时立刻纠回（否则暂停中的实例会把通知抢回去）
    syncActiveItem();
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
      debugLog(
        '_updateSmtcFromData: skip (isWindows=${Platform.isWindows} data=$data)',
      );
      return;
    }
    try {
      String smtcTitle = '';
      String smtcArtist = artist ?? '';
      String smtcThumb = cover ?? '';
      switch (data) {
        case VideoDetailData(
          :final pages,
          :final title,
          :final owner,
          :final pic,
        ):
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
        case HotVideoItemModel():
          smtcTitle = data.title;
          smtcArtist = data.owner.name ?? '';
          smtcThumb = data.cover ?? '';
        case BiliDownloadEntryInfo():
          smtcTitle = data.showTitle;
          smtcArtist = data.ownerName ?? '';
          smtcThumb = data.cover;
        default:
          debugLog('_updateSmtcFromData: unknown type ${data.runtimeType}');
          return;
      }
      debugLog(
        '_updateSmtcFromData: title="$smtcTitle" artist="$smtcArtist" thumb.len=${smtcThumb.length} enabled=${MediaControlWindows().enabled}',
      );
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
        // 视频页覆盖 play/pause（音频页后台播放时不抢占 — SMTC 控制权归音频页）
        // 不碰 next/prev — 由视频页自身的 _setupSmtcNavigation() / didPopNext() 管理
        if (!AudioController.isBackgroundPlaying) {
          smtc.updateCallbacks(
            onPlay: PlPlayerController.playIfExists,
            onPause: PlPlayerController.pauseIfExists,
          );
        }
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
        final f = File(
          'C:\\Users\\34983\\Documents\\PiliPlus\\piliplus_debug.log',
        );
        f.writeAsStringSync(
          '[${DateTime.now()}] $msg\n',
          mode: FileMode.append,
        );
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

    final bool currentRemoved =
        mediaItem.value?.id.endsWith(herotag) ?? false;
    if (_item.isNotEmpty) {
      _item.removeWhere((item) => item.id.endsWith(herotag));
    }
    final bool hasLiveAudio = AudioController.liveInstances.isNotEmpty;
    if (_item.isNotEmpty) {
      // 只有被移除的正是当前条目时才改写通知栏条目，否则会把正在播放的
      // 另一次播放换成别的 mediaItem。
      if (currentRemoved) setMediaItem(_item.last);
      // ⚠️ 还有其它音频实例活着时**不要**伪造"已暂停"：否则关掉一个非播放
      // 中的音频标签，就把正在播放的另一个标签在通知栏显示成暂停。
      if (!hasLiveAudio) {
        playbackState.add(
          playbackState.value.copyWith(
            processingState: .ready,
            playing: false,
          ),
        );
      }
    }
    // 清除 Windows SMTC 数据（仅在没有其他 media item 时）
    if (_item.isEmpty && Platform.isWindows) {
      try {
        MediaControlWindows().clearMetadata();
      } catch (_) {}
    }
    // 关闭的实例可能正是刚才显示的条目 → 让显示重新跟随控制权持有者
    syncActiveItem();
  }

  void clearIfNeeded() {
    if (!enableBackgroundPlay) return;
    if (_item.isEmpty) clear();
  }

  void clear() {
    if (!enableBackgroundPlay) return;
    mediaItem.add(null);
    _item.clear();
    _lastPos = null;
    _lastConfig = null;
    /**
     * if (playbackState.processingState == AudioProcessingState.idle &&
            previousState?.processingState != AudioProcessingState.idle) {
          await AudioService._stop();
        }
     */
    if (playbackState.value.processingState == .idle) {
      playbackState.add(PlaybackState(processingState: .completed));
    }
    playbackState.add(
      PlaybackState(
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
  }

  void onPositionChange(Duration position) {
    if (!enableBackgroundPlay || _item.isEmpty) {
      return;
    }

    // 每秒一次的位置上报是最稳的收敛点：让通知条目始终等于控制权持有者的
    // 当前曲目（切换播放实例/暂停/切歌后最多 1s 内对齐）
    syncActiveItem();

    playbackState.add(
      playbackState.value.copyWith(
        updatePosition: position,
      ),
    );
  }
}

/// 媒体通知收藏按钮使用的轻量收藏容器：
/// 复用 FavMixin/FavPanel（收藏夹选择面板），不依赖视频页 controller。
class MediaFavController extends GetxController
    with GetSingleTickerProviderStateMixin, TripleMixin, FavMixin {
  MediaFavController({required this.ridType});

  /// 当前条目的收藏参数 (rid, type)：UGC 视频=aid/2，PGC=epId/24
  (Object, int) ridType;

  @override
  bool get isLogin => Accounts.main.isLogin;

  @override
  int get copyright => 0;

  @override
  void onPayCoin(int coin, bool coinWithLike) {}

  @override
  Future<void> actionTriple() async {}

  @override
  void actionLikeVideo() {}

  @override
  (Object, int) get getFavRidType => ridType;

  @override
  void updateFavCount(int count) {}
}
