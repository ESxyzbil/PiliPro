import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/audio.dart';
import 'package:PiliPlus/models_new/video/video_tag/data.dart';
import 'package:PiliPlus/pages/audio/lyrics_api.dart';
import 'package:PiliPlus/pages/audio/lyrics_memory.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pb.dart'
    show
        DetailItem,
        PlayURLResp,
        PlaylistSource,
        PlayInfo,
        ThumbUpReq_ThumbType,
        ListOrder,
        DashItem,
        ResponseUrl;
import 'package:PiliPlus/http/user.dart' as user_http;
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/music.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/models/model_owner.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart'
    show FavMixin;
import 'package:PiliPlus/pages/dynamics_repost/view.dart';
import 'package:PiliPlus/pages/main_reply/view.dart';
import 'package:PiliPlus/pages/setting/models/play_settings.dart'
    show kMaxVolume;
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/services/live_update_channel.dart';
import 'package:PiliPlus/services/desktop_lyrics_service.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/triple_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/media_control_windows.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/connectivity_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/share_utils.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';

class AudioController extends GetxController
    with
        GetTickerProviderStateMixin,
        TripleMixin,
        FavMixin,
        BlockConfigMixin,
        BlockMixin {
  late Int64 id;
  late Int64 oid;
  late List<Int64> subId;
  late int itemType;
  Int64? extraId;
  late final PlaylistSource from;
  @override
  late final bool isUgc = itemType == 1;

  final audioItem = Rxn<DetailItem>();
  final audioTitle = ''.obs;
  final audioArtist = ''.obs;

  /// 当前音频对应视频的 bvid（普通视频进入时用于拉取相关推荐）
  String? bvid;

  /// 当前视频的 UP 主 mid（推荐切换时更新，供 UP 主页跳转）
  int currentOwnerMid = 0;

  /// 相关推荐视频（普通视频/无列表时，下一曲以首个响应）
  final RxList<HotVideoItemModel> relatedVideos = <HotVideoItemModel>[].obs;
  bool _relatedLoading = false;

  /// "下一首播放"队列（推荐视频卡片按钮加入，播放完当前后自动播放）
  final RxList<HotVideoItemModel> nextUpQueue = <HotVideoItemModel>[].obs;
  // 离线回退信息
  String? _fallbackTitle;
  String? _fallbackCover;
  String? _fallbackOwnerName;
  int? _fallbackOwnerMid;
  List<BiliDownloadEntryInfo>? offlineEntries;

  bool _hasInit = false;
  @override
  Player? player;
  late int cacheAudioQa;

  late bool isDragging = false;
  bool _endOfStreamTriggered = false;
  final Rx<Duration> position = Duration.zero.obs;
  final Rx<Duration> duration = Duration.zero.obs;

  late final AnimationController animController;

  List<StreamSubscription>? _subscriptions;

  int? index;
  List<DetailItem>? playlist;

  late double speed = 1.0;

  late final Rx<PlayRepeat> playMode = Pref.audioPlayMode.obs;

  @override
  late final isLogin = Accounts.main.isLogin;

  Duration? _start;
  VideoDetailController? _videoDetailController;

  String? _prev;
  String? _next;
  bool get reachStart => _prev == null;

  ListOrder order = ListOrder.ORDER_NORMAL;
  final RxBool showCoverInfo = true.obs;

  // 歌词相关
  final Rx<LyricsSource> selectedSource = LyricsSource.netease.obs;
  final lyricsResults = <LyricsSource, LyricsResult>{}.obs;
  final lyricsSearchResults = <LyricsSource, List<LyricsSearchItem>>{}.obs;
  final selectedSearchItems = <LyricsSource, LyricsSearchItem?>{}.obs;
  /// CC 字幕锁定状态（响应式）
  final RxBool ccLocked = false.obs;
  /// 全局默认 CC 字幕（响应式）
  final RxBool ccDefault = false.obs;
  /// 弹幕歌词锁定状态（响应式）
  final RxBool dmLocked = false.obs;
  /// 全局默认弹幕歌词（响应式）
  final RxBool dmDefault = false.obs;
  final RxInt currentLineIndex = 0.obs;
  final RxBool isLoadingLyrics = false.obs;
  final RxString lyricsError = ''.obs;

  /// 歌词搜索请求序号：切歌/重复搜索时丢弃旧请求结果，防止竞态覆盖
  int _lyricsSearchSeq = 0;

  double? _lastVolume;
  late final RxDouble desktopVolume = RxDouble(Pref.desktopVolume);

  late final MediaControlWindows _mediaControl = MediaControlWindows();

  /// 音频页是否正在播放（含后台），供视频页判断 SMTC 控制权：
  /// 音频页在播时，视频页不得抢占 SMTC 回调（否则系统媒体按钮失效）
  static bool isBackgroundPlaying = false;

  void _initMediaControl() {
    if (!PlatformUtils.isDesktop) return;
    // 如果被视频页先 enable 了（_enabled=true），用 updateCallbacks 覆盖
    if (_mediaControl.enabled) {
      _mediaControl.updateCallbacks(
        onPlay: () => onPlay(),
        onPause: () => onPause(),
        onNext: () => playNext(),
        onPrevious: () => playPrev(),
      );
    } else {
      _mediaControl.enable(
        onPlay: () => onPlay(),
        onPause: () => onPause(),
        onNext: () => playNext(),
        onPrevious: () => playPrev(),
      );
    }
    // 如果已经有歌曲信息，立即推送
    if (audioItem.value case DetailItem(:final arc, :final owner)) {
      _mediaControl.updateMetadata(title: arc.title, artist: owner.name);
    }
  }

  void toggleVolume() {
    if (_lastVolume == null) {
      _lastVolume = desktopVolume.value;
      setVolume(0, clearLastVolme: false);
    } else {
      setVolume(_lastVolume!);
    }
  }

  void setVolume(double volume, {bool clearLastVolme = true}) {
    if (clearLastVolme) {
      _lastVolume = null;
    }
    desktopVolume.value = volume;
    player?.setVolume(volume * 100);
  }

  void syncVolume([_]) {
    final volume = desktopVolume.value;
    PlPlayerController.instance
      ?..volume.value = volume
      ..videoPlayerController?.setVolume(volume * 100);
    GStorage.setting.put(SettingBoxKey.desktopVolume, volume.toPrecision(3));
  }

  @override
  void onInit() {
    super.onInit();
    DesktopLyricsService.show();
    final args = Get.arguments;
    oid = Int64(args['oid']);
    final id = args['id'];
    this.id = id != null ? Int64(id) : oid;
    subId = (args['subId'] as List<int>?)?.map(Int64.new).toList() ?? [oid];
    itemType = args['itemType'];
    from = args['from'];
    _start = args['start'];
    bvid = args['bvid'] as String?;
    final int? extraId = args['extraId'];
    if (extraId != null) {
      this.extraId = Int64(extraId);
    }
    if (args['heroTag'] case String heroTag) {
      try {
        _videoDetailController = Get.find<VideoDetailController>(tag: heroTag);
      } catch (_) {}
    }

    // 读取离线回退信息
    _fallbackTitle = args['title'] as String?;
    _fallbackCover = args['cover'] as String?;
    _fallbackOwnerName = args['ownerName'] as String?;
    _fallbackOwnerMid = args['ownerMid'] as int?;
    offlineEntries = (args["offlineEntries"] as List?)
        ?.map((e) => BiliDownloadEntryInfo.fromJson(e as Map<String, dynamic>))
        .toList();

    if (offlineEntries != null && offlineEntries!.isNotEmpty) {
      // 离线模式：不请求 API 播放列表，直接用本地缓存
      index = offlineEntries!.indexWhere((e) => e.avid == oid.toInt());
      if (index == -1) index = 0;
      final entry = offlineEntries![index!];
      audioTitle.value = entry.title;
      audioArtist.value = entry.ownerName ?? '';
      if (entry.cover.isNotEmpty) {
        _mediaControl.updateMetadata(
          title: entry.title,
          artist: entry.ownerName ?? '',
          thumbnail: entry.cover,
        );
      }
      searchLyrics('${entry.title} ${entry.ownerName ?? ''}');
      // 通知 audio_service 更新媒体通知（SMTC + 系统通知栏）
      if (videoPlayerServiceHandler != null) {
        videoPlayerServiceHandler!.onVideoDetailChange(
          entry,
          entry.cid,
          'audio_offline',
        );
      }
    } else {
      _queryPlayList(isInit: true);
    }
    loadRelated();

    final String? audioUrl = args['audioUrl'];
    final hasAudioUrl = audioUrl != null;
    if (hasAudioUrl) {
      _querySponsorBlock();
      _onOpenMedia(audioUrl, ua: BrowserUa.pc, referer: HttpString.baseUrl);
    }
    ConnectivityUtils.isWiFi.then((isWiFi) {
      cacheAudioQa = isWiFi ? Pref.defaultAudioQa : Pref.defaultAudioQaCellular;
      if (!hasAudioUrl) {
        _queryPlayUrl();
      }
    });
    if (videoPlayerServiceHandler case final handler?) {
      handler
        ..onPlay = onPlay
        ..onPause = onPause
        ..onSeek = onSeek
        ..onSkipToNext = () async {
          return playNext();
        }
        ..onSkipToPrevious = () async {
          return playPrev();
        };
    }

    animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );

    if (shutdownTimerService.isActive) {
      shutdownTimerService
        ..onPause = onPause
        ..isPlaying = isPlaying;
    }
  }

  bool isPlaying() {
    return player?.state.playing ?? false;
  }

  Future<void>? onPlay() {
    return player?.play();
  }

  Future<void>? onPause() {
    return player?.pause();
  }

  Future<void>? onSeek(Duration duration) {
    return player?.seek(duration);
  }

  void _updateCurrItem(DetailItem item) {
    audioItem.value = item;
    audioTitle.value = item.arc.title;
    audioArtist.value = item.owner.name;
    currentOwnerMid = item.owner.mid.toInt();
    hasLike.value = item.stat.hasLike_7;
    coinNum.value = item.stat.hasCoin_8 ? 2 : 0;
    hasFav.value = item.stat.hasFav;
    videoPlayerServiceHandler?.onVideoDetailChange(
      item,
      (subId.firstOrNull ?? oid).toInt(),
      hashCode.toString(),
    );
    // 更新 Windows SMTC 元数据（含封面）
    _mediaControl.updateMetadata(
      title: item.arc.title,
      artist: item.owner.name,
      thumbnail: item.arc.cover,
    );
    // 自动搜索歌词
    final title = '${item.arc.title} ${item.owner.name}';
    searchLyrics(title);
  }

  Future<void> _queryPlayList({
    bool isInit = false,
    bool isLoadPrev = false,
    bool isLoadNext = false,
  }) async {
    final res = await AudioGrpc.audioPlayList(
      id: id,
      oid: isInit ? oid : null,
      subId: isInit ? subId : null,
      itemType: isInit ? itemType : null,
      from: isInit ? from : null,
      next: isLoadPrev
          ? _prev
          : isLoadNext
          ? _next
          : null,
      extraId: extraId,
      order: order,
    );
    if (res case Success(:final response)) {
      if (isInit) {
        late final paginationReply = response.paginationReply;
        _prev = response.reachStart ? null : paginationReply.prev;
        _next = response.reachEnd ? null : paginationReply.next;
        final index = response.list.indexWhere((e) => e.item.oid == oid);
        if (index != -1) {
          this.index = index;
          _updateCurrItem(response.list[index]);
          playlist = response.list;
        }
      } else if (isLoadPrev) {
        _prev = response.reachStart ? null : response.paginationReply.prev;
        if (response.list.isNotEmpty) {
          index += response.list.length;
          playlist?.insertAll(0, response.list);
        }
      } else if (isLoadNext) {
        _next = response.reachEnd ? null : response.paginationReply.next;
        if (response.list.isNotEmpty) {
          playlist?.addAll(response.list);
        }
      }
      return;
    }
    if (isInit && _fallbackTitle != null) {
      // offline fallback: use passed metadata
      audioTitle.value = _fallbackTitle!;
      if (_fallbackOwnerName != null) {
        audioArtist.value = _fallbackOwnerName!;
      }
      if (_fallbackCover != null) {
        _mediaControl.updateMetadata(
          title: _fallbackTitle!,
          artist: _fallbackOwnerName ?? '',
          thumbnail: _fallbackCover!,
        );
      }
      if (_fallbackOwnerName != null) {
        final title = '${_fallbackTitle} ${_fallbackOwnerName}';
        searchLyrics(title);
      }
    } else {
      res.toast();
    }
  }

  @pragma('vm:notify-debugger-on-exception')
  void _querySponsorBlock() {
    if (isUgc && enableSponsorBlock) {
      try {
        final bvid = IdUtils.av2bv(oid.toInt());
        final cid = subId.first.toInt();
        querySponsorBlock(bvid: bvid, cid: cid);
      } catch (_) {}
    }
  }

  Future<bool> _queryPlayUrl() async {
    _querySponsorBlock();
    final res = await AudioGrpc.audioPlayUrl(
      itemType: itemType,
      oid: oid,
      subId: subId,
    );
    if (res case Success(:final response)) {
      _onPlay(response);
      return true;
    } else {
      res.toast();
      return false;
    }
  }

  void _onPlay(PlayURLResp data) {
    final PlayInfo? playInfo = data.playerInfo.values.firstOrNull;
    if (playInfo != null) {
      if (playInfo.hasPlayDash()) {
        final playDash = playInfo.playDash;
        final audios = playDash.audio;
        if (audios.isEmpty) {
          return;
        }
        position.value = Duration.zero;
        final audio = audios.findClosestTarget(
          (e) => e.id <= cacheAudioQa,
          (a, b) => a.id > b.id ? a : b,
        );
        _onOpenMedia(VideoUtils.getCdnUrl(audio.playUrls));
      } else if (playInfo.hasPlayUrl()) {
        final playUrl = playInfo.playUrl;
        final durls = playUrl.durl;
        if (durls.isEmpty) {
          return;
        }
        final durl = durls.first;
        position.value = Duration.zero;
        _onOpenMedia(VideoUtils.getCdnUrl(durl.playUrls));
      }
    }
  }

  Future<void> _onOpenMedia(
    String url, {
    String ua = Constants.userAgentApp,
    String? referer,
  }) async {
    await _initPlayerIfNeeded();
    player
      ?..setMediaHeader(
        userAgent: ua,
        // mpv cannot clear referer option
        headers: {'Referer': ?referer},
      )
      ..open(Media(url, start: _start));
    _start = null;
  }

  Future<void> _initPlayerIfNeeded() async {
    if (_hasInit) return;
    _hasInit = true;
    assert(player == null, _subscriptions = null);
    player = await Player.create(
      configuration: PlayerConfiguration(
        options: {
          'volume': PlatformUtils.isDesktop
              ? (desktopVolume.value * 100).toString()
              : Pref.playerVolume.toString(),
          'volume-max': kMaxVolume.toString(),
          // keep-open 保持默认 (yes)：避免 mpv 状态机重置导致通知控件异常
          // 播完检测由位置监听器处理
          ...Pref.initBuffer(),
        },
      ),
    );
    if (isClosed) {
      player!.dispose();
      player = null;
      return;
    }
    _initMediaControl();
    final stream = player!.stream;
    _subscriptions = [
      stream.position.listen((position) {
        if (isDragging) return;
        final prevPosition = this.position.value;
        if (position.inSeconds != prevPosition.inSeconds) {
          this.position.value = position;
          _videoDetailController?.playedTime = position;
          videoPlayerServiceHandler?.onPositionChange(position);
          updateLyricsLine();
        }
        // 播放结束检测（适配后台/息屏时 completed 事件延迟/不触发的情况）
        if (!_endOfStreamTriggered &&
            duration.value > const Duration(seconds: 2) &&
            position >= duration.value - const Duration(seconds: 1) &&
            position > Duration.zero &&
            prevPosition < position) {
          // prevPosition < position 确保位置在向前走（不是 seek 跳过来的）
          _endOfStreamTriggered = true;
          _handleCompletion();
        }
      }),
      stream.duration.listen(duration.call),
      stream.playing.listen((playing) {
        isBackgroundPlaying = playing;
        final PlayerStatus playerStatus;
        if (playing) {
          _endOfStreamTriggered = false;
          animController.forward();
          playerStatus = PlayerStatus.playing;
          // 息屏时保持 CPU 活跃以便检测播完
          WakelockPlus.enable();
          // 重新接管 SMTC 回调（防被视频页抢占导致系统媒体按钮失效）
          _initMediaControl();
        } else {
          animController.reverse();
          playerStatus = PlayerStatus.paused;
          WakelockPlus.disable();
        }
        _mediaControl.updatePlaybackStatus(playing);
        videoPlayerServiceHandler?.onStatusChange(playerStatus, false, false);
      }),
      stream.completed.listen((completed) {
        _videoDetailController?.playedTime = duration.value;
        videoPlayerServiceHandler?.onStatusChange(
          PlayerStatus.completed,
          false,
          false,
        );
        if (completed) {
          _handleCompletion();
        }
      }),
    ];
  }

  @override
  Future<void> actionLikeVideo() async {
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final newVal = !hasLike.value;
    final res = await AudioGrpc.audioThumbUp(
      oid: oid,
      subId: subId,
      itemType: itemType,
      type: newVal
          ? ThumbUpReq_ThumbType.LIKE
          : ThumbUpReq_ThumbType.CANCEL_LIKE,
    );
    if (res case Success(:final response)) {
      hasLike.value = newVal;
      try {
        audioItem.value!.stat
          ..hasLike_7 = newVal
          ..like += newVal ? 1 : -1;
        audioItem.refresh();
      } catch (_) {}
      SmartDialog.showToast(response.message);
    } else {
      res.toast();
    }
  }

  @override
  Future<void> actionTriple() async {
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    final res = await AudioGrpc.audioTripleLike(
      oid: oid,
      subId: subId,
      itemType: itemType,
    );
    if (res case Success(:final response)) {
      hasLike.value = true;
      if (response.coinOk && !hasCoin) {
        coinNum.value = 2;
        GlobalData().afterCoin(2);
        try {
          audioItem.value!.stat
            ..hasCoin_8 = true
            ..coin += 2;
          audioItem.refresh();
        } catch (_) {}
      }
      hasFav.value = true;
      if (!hasCoin) {
        SmartDialog.showToast('投币失败');
      } else {
        SmartDialog.showToast('三连成功');
      }
    } else {
      res.toast();
    }
  }

  @override
  int get copyright => audioItem.value?.arc.copyright ?? 1;

  @override
  Future<void> onPayCoin(int coin, bool coinWithLike) async {
    final res = await AudioGrpc.audioCoinAdd(
      oid: oid,
      subId: subId,
      itemType: itemType,
      num: coin,
      thumbUp: coinWithLike,
    );
    if (res.isSuccess) {
      final updateLike = !hasLike.value && coinWithLike;
      if (updateLike) {
        hasLike.value = true;
      }
      coinNum.value += coin;
      try {
        final stat = audioItem.value!.stat
          ..hasCoin_8 = true
          ..coin += coin;
        if (updateLike) {
          stat
            ..hasLike_7 = true
            ..like += 1;
        }
        audioItem.refresh();
      } catch (_) {}
      GlobalData().afterCoin(coin);
    } else {
      res.toast();
    }
  }

  @override
  void showFavBottomSheet(BuildContext context, {bool isLongPress = false}) {
    if (!isLogin) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    if (enableQuickFav) {
      if (!isLongPress) {
        actionFavVideo(isQuick: true);
      } else {
        PageUtils.showFavBottomSheet(context: context, ctr: this);
      }
    } else if (!isLongPress) {
      PageUtils.showFavBottomSheet(context: context, ctr: this);
    }
  }

  void showReply() {
    MainReplyPage.toMainReplyPage(
      oid: oid.toInt(),
      replyType: isUgc ? 1 : 14,
    );
  }

  void actionShareVideo(BuildContext context) {
    final audioUrl = isUgc
        ? '${HttpString.baseUrl}/video/${IdUtils.av2bv(oid.toInt())}'
        : '${HttpString.baseUrl}/audio/au$oid';
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        clipBehavior: Clip.hardEdge,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              title: const Text(
                '复制链接',
                style: TextStyle(fontSize: 14),
              ),
              onTap: () {
                Get.back();
                Utils.copyText(audioUrl);
              },
            ),
            ListTile(
              dense: true,
              title: const Text(
                '其它app打开',
                style: TextStyle(fontSize: 14),
              ),
              onTap: () {
                Get.back();
                PageUtils.launchURL(audioUrl);
              },
            ),
            if (PlatformUtils.isMobile)
              ListTile(
                dense: true,
                title: const Text(
                  '分享视频',
                  style: TextStyle(fontSize: 14),
                ),
                onTap: () {
                  Get.back();
                  if (audioItem.value case DetailItem(
                    :final arc,
                    :final owner,
                  )) {
                    ShareUtils.shareText(
                      '${arc.title} '
                      'UP主: ${owner.name}'
                      ' - $audioUrl',
                    );
                  }
                },
              ),
            ListTile(
              dense: true,
              title: const Text(
                '分享至动态',
                style: TextStyle(fontSize: 14),
              ),
              onTap: () {
                Get.back();
                if (audioItem.value case DetailItem(
                  :final arc,
                  :final owner,
                )) {
                  showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    builder: (context) => RepostPanel(
                      rid: oid.toInt(),
                      dynType: isUgc ? 8 : 256,
                      pic: arc.cover,
                      title: arc.title,
                      uname: owner.name,
                    ),
                  );
                }
              },
            ),
            if (isUgc)
              ListTile(
                dense: true,
                title: const Text(
                  '分享至消息',
                  style: TextStyle(fontSize: 14),
                ),
                onTap: () {
                  Get.back();
                  if (audioItem.value case DetailItem(
                    :final arc,
                    :final owner,
                  )) {
                    try {
                      PageUtils.pmShare(
                        context,
                        content: {
                          "id": oid.toString(),
                          "title": arc.title,
                          "headline": arc.title,
                          "source": 5,
                          "thumb": arc.cover,
                          "author": owner.name,
                          "author_id": owner.mid.toString(),
                        },
                      );
                    } catch (e) {
                      SmartDialog.showToast(e.toString());
                    }
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  void playOrPause() {
    if (player case final player?) {
      if ((duration.value - position.value).inMilliseconds < 50) {
        player.seek(Duration.zero).whenComplete(player.play);
      } else {
        player.playOrPause();
      }
    }
  }

  bool playPrev() {
    if (index != null && playlist != null && player != null) {
      final prev = index! - 1;
      if (prev >= 0) {
        playIndex(prev);
        return true;
      }
    }
    // 离线模式
    if (index != null && offlineEntries != null && player != null) {
      final prev = index! - 1;
      if (prev >= 0) {
        playOfflineIndex(prev);
        return true;
      }
    }
    // 推荐模式：回退到切换前的视频
    return playRelatedPrev();
  }

  /// 播放结束处理（由 completed 事件或 position 检测触发）
  void _handleCompletion() {
    _videoDetailController?.playedTime = duration.value;
    if (shutdownTimerService.isWaiting) {
      shutdownTimerService.handleWaiting();
    } else {
      switch (playMode.value) {
        case PlayRepeat.pause:
          break;
        case PlayRepeat.listOrder:
          if (!playNext(nextPart: true)) {
            playNext(); // 无下一分集时切到列表下一首
          }
          break;
        case PlayRepeat.singleCycle:
          onPlay();
          break;
        case PlayRepeat.listCycle:
          if (!playNext(nextPart: true)) {
            if (index != null && index != 0 && playlist != null) {
              playIndex(0);
            } else if (index != null && offlineEntries != null && offlineEntries!.isNotEmpty) {
              playOfflineIndex(0);
            } else {
              onPlay();
            }
          }
          break;
        case PlayRepeat.autoPlayRelated:
          break;
      }
    }
  }

  /// 拉取当前 bvid 的相关推荐（普通视频/无列表时，作为"下一曲"和推荐列表数据源）
  Future<void> loadRelated() async {
    final bv = bvid;
    if (bv == null || _relatedLoading) return;
    _relatedLoading = true;
    try {
      final res = await VideoHttp.relatedVideoList(bvid: bv);
      if (res case Success(:final response)) {
        if (response != null) {
          relatedVideos.assignAll(response);
        }
      }
    } catch (_) {}
    _relatedLoading = false;
  }

  /// 无列表（普通视频）时，下一曲 → 相关推荐首个
  bool playRelatedNext() {
    if (relatedVideos.isEmpty) {
      loadRelated();
      return false;
    }
    playRelatedAt(0);
    return true;
  }

  /// 播放推荐列表中的第 index 个视频（音频模式）
  Future<void> playRelatedAt(int index) async {
    if (index < 0 || index >= relatedVideos.length) return;
    await _playRelatedItem(relatedVideos[index]);
  }

  /// 播放推荐列表中的指定视频（音频模式）
  Future<void> _playRelatedItem(HotVideoItemModel item) async {
    final cid = item.cid;
    if (cid == null || item.bvid == null) return;
    _pushRelatedHistory();
    await _switchVideo(
      aid: item.aid ?? 0,
      cid: cid,
      bvid: item.bvid!,
      title: item.title,
      cover: item.cover ?? '',
      ownerName: item.owner.name ?? '',
      ownerFace: item.owner is Owner ? (item.owner as Owner).face ?? '' : '',
      ownerMid: item.owner.mid ?? 0,
      desc: item.desc ?? '',
      pubdate: item.pubdate ?? 0,
      view: item.stat.view ?? 0,
      duration: item.duration ?? 0,
      stat: () {
        final st = item.stat;
        return (
          like: st.like ?? 0,
          coin: st is HotStat ? (st.coin ?? 0).toInt() : 0,
          favourite: st is HotStat ? (st.favorite ?? 0) : 0,
          reply: st is HotStat ? (st.reply ?? 0) : 0,
          share: st is HotStat ? (st.share ?? 0) : 0,
        );
      }(),
    );
  }

  /// 推荐模式：上一曲 → 回退到切换前的视频
  bool playRelatedPrev() {
    if (_relatedHistory.isEmpty) return false;
    final entry = _relatedHistory.removeLast();
    _switchVideo(
      aid: entry.aid,
      cid: entry.cid,
      bvid: entry.bvid,
      title: entry.title,
      cover: entry.cover,
      ownerName: entry.ownerName,
      ownerFace: entry.ownerFace,
      desc: entry.desc,
      pubdate: entry.pubdate,
      view: entry.view,
    );
    return true;
  }

  /// 推荐切换历史（上一曲回退栈）
  final List<
      ({
        int aid,
        int cid,
        String bvid,
        String title,
        String cover,
        String ownerName,
        String ownerFace,
        String desc,
        int pubdate,
        int view,
      })> _relatedHistory = [];

  void _pushRelatedHistory() {
    final bv = bvid;
    if (bv == null) return;
    final cur = audioItem.value;
    _relatedHistory.add((
      aid: oid.toInt(),
      cid: subId.firstOrNull?.toInt() ?? 0,
      bvid: bv,
      title: cur?.arc.title ?? audioTitle.value,
      cover: cur?.arc.cover ?? '',
      ownerName: cur?.owner.name ?? audioArtist.value,
      ownerFace: cur?.owner.avatar ?? '',
      desc: cur?.arc.desc ?? '',
      pubdate: cur?.arc.publish.toInt() ?? 0,
      view: cur?.stat.view ?? 0,
    ));
  }

  /// 切换到指定视频（音频模式）：更新源、UI、SMTC、媒体通知、歌词、推荐
  Future<void> _switchVideo({
    required int aid,
    required int cid,
    required String bvid,
    required String title,
    required String cover,
    required String ownerName,
    required String ownerFace,
    String desc = '',
    int pubdate = 0,
    int view = 0,
    int duration = 0,
    int ownerMid = 0,
    ({
      int like,
      int coin,
      int favourite,
      int reply,
      int share,
    })? stat,
  }) async {
    oid = Int64(aid);
    subId = [Int64(cid)];
    this.bvid = bvid;
    currentOwnerMid = ownerMid;
    this.index = null;
    // 推荐模式：无播放列表（队列 = 相关推荐），避免播放列表弹窗异常
    playlist = null;
    // 更新 UI 信息（音频信息复用 DetailItem 可变字段）
    final cur = audioItem.value;
    if (cur != null) {
      try {
        cur.arc.title = title;
        cur.arc.cover = cover;
        cur.arc.desc = desc;
        cur.arc.displayedOid = aid.toString();
        cur.arc.publish = Int64(pubdate);
        cur.owner.name = ownerName;
        cur.owner.avatar = ownerFace;
        if (ownerMid > 0) {
          cur.owner.mid = Int64(ownerMid);
        }
        cur.stat.view = view;
        audioItem.refresh();
      } catch (_) {}
      // 更新点赞/投币/收藏/评论/转发等统计（推荐视频有完整 stat）
      if (stat case final s?) {
        try {
          cur.stat
            ..like = s.like
            ..coin = s.coin
            ..favourite = s.favourite
            ..reply = s.reply
            ..share = s.share;
          audioItem.refresh();
        } catch (_) {}
      }
    }
    // 推荐视频无登录态标记 → 点赞/收藏状态清零
    hasLike.value = false;
    coinNum.value = 0;
    hasFav.value = false;
    audioTitle.value = title;
    audioArtist.value = ownerName;
    _mediaControl.updateMetadata(
      title: title,
      artist: ownerName,
      thumbnail: cover,
    );
    // 媒体通知（audio_service → SMTC + 安卓通知栏）
    if (videoPlayerServiceHandler case final handler?) {
      try {
        handler.onVideoDetailChange(
          HotVideoItemModel.fromJson({
            'aid': aid,
            'cid': cid,
            'bvid': bvid,
            'title': title,
            'pic': cover,
            'owner': {'name': ownerName, 'face': ownerFace},
            'stat': {},
            'duration': duration,
          }),
          cid,
          'audio_related',
        );
      } catch (_) {}
      // 安卓通知兜底：直接更新 mediaItem（不依赖类型分支）
      try {
        handler.setMediaItem(
          MediaItem(
            id: '${cid}audio_related',
            title: title,
            artist: ownerName,
            duration: Duration(seconds: duration),
            artUri: Uri.tryParse(ImageUtils.safeThumbnailUrl(cover)),
          ),
        );
      } catch (_) {}
    }
    searchLyrics('$title $ownerName');
    // 换源播放
    _queryPlayUrl().then((res) {
      if (res) {
        _videoDetailController = null;
      }
    });
    // 预取新视频的相关推荐
    loadRelated();
  }

  /// 把推荐视频加入"下一首播放"队列
  void addToNextUp(HotVideoItemModel item) {
    if (item.cid == null || item.bvid == null) return;
    // 避免与当前播放或已在队列里的重复
    if (item.aid != null && item.aid == oid.toInt()) return;
    if (nextUpQueue.any((e) => e.aid == item.aid)) return;
    nextUpQueue.add(item);
    if (nextUpQueue.length == 1) {
      SmartDialog.showToast('已加入下一首播放');
    } else {
      SmartDialog.showToast('已加入下一首播放（队列 ${nextUpQueue.length} 首）');
    }
  }

  bool playNext({bool nextPart = false}) {
    if (nextPart) {
      if (audioItem.value case DetailItem(:final parts)) {
        if (parts.length > 1) {
          final subId = this.subId.firstOrNull;
          final nextIndex = parts.indexWhere((e) => e.subId == subId) + 1;
          if (nextIndex != 0 && nextIndex < parts.length) {
            final nextPart = parts[nextIndex];
            oid = nextPart.oid;
            this.subId = [nextPart.subId];
            // 分P 切换后同步 bvid（保持 aid/bvid 一致）
            bvid = IdUtils.av2bv(nextPart.oid.toInt());
            _queryPlayUrl().then((res) {
              if (res) {
                _videoDetailController = null;
              }
            });
            return true;
          }
        }
      }
    }
    // "下一首播放"队列优先
    if (nextUpQueue.isNotEmpty && player != null) {
      final item = nextUpQueue.removeAt(0);
      _playRelatedItem(item);
      return true;
    }
    if (index != null && playlist != null && player != null) {
      final next = index! + 1;
      if (next < playlist!.length) {
        if (next == playlist!.length - 1 && _next != null) {
          _queryPlayList(isLoadNext: true);
        }
        playIndex(next);
        return true;
      }
    }
    // 离线模式
    if (index != null && offlineEntries != null && player != null) {
      final next = index! + 1;
      if (next < offlineEntries!.length) {
        playOfflineIndex(next);
        return true;
      }
    }
    // 无列表（普通视频进入）：下一曲 → 相关推荐首个
    return playRelatedNext();
  }

  void playIndex(int index, {List<Int64>? subId}) {
    if (index == this.index && subId == null) return;
    this.index = index;
    final audioItem = playlist![index];
    final item = audioItem.item;
    oid = item.oid;
    this.subId =
        subId ??
        (item.subId.isNotEmpty ? item.subId : [audioItem.parts.first.subId]);
    itemType = item.itemType;
    // 切歌后同步 bvid（列表项可能无 bvid，用 oid 反推），
    // 否则标题点击跳转会 aid/bvid 不匹配 → 视频不存在(-404)
    bvid = IdUtils.av2bv(item.oid.toInt());
    _queryPlayUrl().then((res) {
      if (res) {
        _videoDetailController = null;
        _updateCurrItem(audioItem);
      }
    });
  }


  /// 离线播放：从本地缓存文件切歌
  Future<void> playOfflineIndex(int index) async {
    if (offlineEntries == null || index >= offlineEntries!.length) return;
    final entry = offlineEntries![index];
    this.index = index;

    // 更新当前状态
    oid = Int64(entry.avid);
    subId = [Int64(entry.cid)];
    // 离线条目无 bvid，用 oid 反推保证标题跳转参数一致
    bvid = IdUtils.av2bv(entry.avid);

    // 构造音频文件路径
    final fileDir = entry.typeTag != null && entry.typeTag!.isNotEmpty
        ? '${entry.entryDirPath}/${entry.typeTag}'
        : entry.entryDirPath;
    if (fileDir.isEmpty) {
      SmartDialog.showToast('缓存路径为空');
      return;
    }

    String? audioPath;
    if (entry.mediaType == 1) {
      audioPath = '$fileDir/${PathUtils.videoNameType1}';
    } else {
      audioPath = '$fileDir/${PathUtils.audioNameType2}';
    }

    final audioFile = File(audioPath);
    if (!audioFile.existsSync()) {
      // 尝试另一种格式
      audioPath = entry.mediaType == 1
          ? '$fileDir/${PathUtils.audioNameType2}'
          : '$fileDir/${PathUtils.videoNameType1}';
      if (!File(audioPath).existsSync()) {
        SmartDialog.showToast('本地音频文件不存在');
        return;
      }
    }

    // 更新 UI 信息
    audioTitle.value = entry.title;
    audioArtist.value = entry.ownerName ?? '';
    if (entry.cover.isNotEmpty) {
      _mediaControl.updateMetadata(
        title: entry.title,
        artist: entry.ownerName ?? '',
        thumbnail: entry.cover,
      );
    }

    // 切歌后重新搜索歌词
    final lyricTitle = '${entry.title} ${entry.ownerName ?? ''}';
    searchLyrics(lyricTitle);

    // 打开本地文件播放
    await _initPlayerIfNeeded();
    player?.open(Media(audioPath));

    // 通知 audio_service 更新媒体通知
    if (videoPlayerServiceHandler != null) {
      videoPlayerServiceHandler!.onVideoDetailChange(
        entry,
        entry.cid,
        'audio_offline',
      );
    }
  }
  void setSpeed(double speed) {
    if (player case final player?) {
      this.speed = speed;
      player.setRate(speed);
    }
  }

  @override
  (Object, int) get getFavRidType => (oid, isUgc ? 2 : 12);

  @override
  void updateFavCount(int count) {
    try {
      audioItem.value!.stat
        ..hasFav = count > 0
        ..favourite += count;
      audioItem.refresh();
    } catch (_) {}
  }

  Future<void> loadPrev(BuildContext context) async {
    if (_prev == null) return;
    final length = playlist!.length;
    await _queryPlayList(isLoadPrev: true);
    if (length != playlist!.length && context.mounted) {
      (context as Element).markNeedsBuild();
    }
  }

  Future<void> loadNext(BuildContext context) async {
    if (_next == null) return;
    final length = playlist!.length;
    await _queryPlayList(isLoadNext: true);
    if (length != playlist!.length && context.mounted) {
      (context as Element).markNeedsBuild();
    }
  }

  void onChangeOrder(ListOrder value) {
    if (order != value) {
      order = value;
      if (offlineEntries != null && offlineEntries!.isNotEmpty) {
        _sortOfflineEntries();
      } else {
        _queryPlayList(isInit: true);
      }
    }
  }

  void _sortOfflineEntries() {
    if (offlineEntries == null || offlineEntries!.isEmpty) return;
    final currentAvid = oid.toInt();
    switch (order) {
      case ListOrder.ORDER_REVERSE:
        offlineEntries = offlineEntries!.reversed.toList();
        break;
      case ListOrder.ORDER_RANDOM:
        // 随机排序时当前曲目保持在首位
        final currentIdx = offlineEntries!.indexWhere(
          (e) => e.avid == currentAvid,
        );
        final BiliDownloadEntryInfo? current =
            currentIdx != -1 ? offlineEntries![currentIdx] : null;
        if (current != null) {
          final rest = offlineEntries!
              .where((e) => e.avid != currentAvid)
              .toList();
          rest.shuffle();
          offlineEntries = [current, ...rest];
          index = 0;
        } else {
          offlineEntries = List.of(offlineEntries!);
          offlineEntries!.shuffle();
        }
        break;
      default: // ORDER_NORMAL, NO_ORDER — keep original order
        return;
    }
    if (offlineEntries == null) return;
    final newIndex = offlineEntries!.indexWhere((e) => e.avid == currentAvid);
    if (newIndex != -1) {
      index = newIndex;
    } else {
      index = 0;
    }
  }

  /// 歌词缓存键
  static const String _lyricsCacheKey = 'audio_lyrics_cache';

  /// 从缓存恢复歌词（在搜索结果加载前使用）
  void loadCachedLyrics() {
    final cached = GStorage.localCache.get(_lyricsCacheKey) as String?;
    if (cached == null || cached.isEmpty) return;
    try {
      final data = jsonDecode(cached) as Map;
      // 恢复搜索结果列表
      if (data['searchResults'] is Map) {
        for (final entry in (data['searchResults'] as Map).entries) {
          LyricsSource? source;
          for (final s in LyricsSource.values) {
            if (s.name == entry.key) { source = s; break; }
          }
          if (source == null) continue;
          final items = (entry.value as List).map((i) {
            return LyricsSearchItem(
              title: i['title'] as String? ?? '',
              artist: i['artist'] as String? ?? '',
              subtitle: i['subtitle'] as String? ?? '',
              neteaseSongId: i['neteaseSongId'] as int?,
              kugouFileHash: i['kugouFileHash'] as String?,
            );
          }).toList();
          lyricsSearchResults[source] = items;
        }
      }
      // 恢复歌词结果
      if (data['results'] is Map) {
        for (final entry in (data['results'] as Map).entries) {
          LyricsSource? source;
          for (final s in LyricsSource.values) {
            if (s.name == entry.key) { source = s; break; }
          }
          if (source == null) continue;
          final r = entry.value as Map;
          List<LyricsLine>? syncedLines;
          if (r['syncedLines'] is List) {
            syncedLines = (r['syncedLines'] as List).map((l) {
              return LyricsLine(
                Duration(milliseconds: l['time'] as int? ?? 0),
                l['text'] as String? ?? '',
              );
            }).toList();
          }
          lyricsResults[source] = LyricsResult(
            source: r['source'] as String? ?? '',
            syncedLines: syncedLines,
            plainText: r['plainText'] as String?,
            error: r['error'] as String?,
          );
        }
      }
      // 恢复选中的来源
      if (data['selectedSource'] is String) {
        LyricsSource? selected;
        for (final s in LyricsSource.values) {
          if (s.name == data['selectedSource']) { selected = s; break; }
        }
        if (selected != null) {
          selectedSource.value = selected;
        }
      }
    } catch (_) {
      // 缓存损坏忽略
    }
  }

  /// 保存歌词到缓存
  void _saveLyricsCache() {
    final data = {
      'selectedSource': selectedSource.value.name,
      'results': lyricsResults.map((k, v) {
        return MapEntry(k.name, {
          'source': v.source,
          'plainText': v.plainText,
          'syncedLines': v.syncedLines?.map((l) => {
            'time': l.time.inMilliseconds,
            'text': l.text,
          }).toList(),
          'error': v.error,
        });
      }),
      'searchResults': lyricsSearchResults.map((k, v) {
        return MapEntry(k.name, v.map((i) => {
          'title': i.title,
          'artist': i.artist,
          'subtitle': i.subtitle,
          'neteaseSongId': i.neteaseSongId,
          'kugouFileHash': i.kugouFileHash,
        }).toList());
      }),
    };
    GStorage.localCache.put(_lyricsCacheKey, jsonEncode(data));
  }

  /// 用视频标题搜索歌词
  /// 缓存的 view/detail Tags（供 _fetchBilibiliSongInfo 复用，避免重复请求）
  List<VideoTagItem>? _detailTags;

  /// 常见非歌名标签（用于从 B 站标签里过滤出歌曲名候选）
  static const Set<String> _tagSongBlacklist = {    '音乐', '翻唱', '原创', 'ACG', '电音', '纯音乐', 'VOCALOID', '中文', '日语',
    '英语', '每日推荐', '自制', 'MV', 'OP', 'ED', 'OST', 'BGM', '治愈', '伤感',
    '古风', '流行', '摇滚', '民谣', '说唱', '电子', '现场', '国语', '粤语', '日系',
    '动漫', '游戏', '搞笑', '日常', '生活', '学习', '科技', '数码', '美食', '影视',
    '音乐现场', '翻唱歌曲', '音乐推荐', '单曲循环', '好听', '新歌', '经典', '怀旧',
    'vocaloid', 'V家', '中文VOCALOID', '日文歌', '英文歌', '纯音乐推荐',
  };

  /// 获取 B 站视频标签，从中提取可能的歌曲名（过滤常见非歌名标签）。
  /// 数据源优先级：
  /// 1. /x/web-interface/view/detail 的 Tags —— 唯一带"发现《歌名》"音乐标签
  ///    + music_id（B 站官方歌曲标记）的接口
  /// 2. /x/web-interface/view/detail/tag（videoTags）
  /// 3. /x/tag/archive/tags（videoTagsV2，无需登录，更抗风控）
  Future<List<String>> _fetchBilibiliTags() async {
    final bvid = this.bvid;
    if (bvid == null || bvid.isEmpty) return [];
    List<VideoTagItem>? items;

    // ① 完整 view/detail Tags（"发现《歌名》" + music_id）
    try {
      final res0 = await user_http.UserHttp.videoDetailTags(bvid: bvid);
      if (res0 case Success(:final response) when response != null) {
        items = response;
      }
    } catch (_) {}
    // 缓存给 _fetchBilibiliSongInfo 复用（避免重复请求）
    _detailTags = items;

    // ② 主标签接口（/x/web-interface/view/detail/tag）
    if (items == null || items.isEmpty) {
      try {
        final cid = subId.firstOrNull?.toInt();
        final res = await user_http.UserHttp.videoTags(bvid: bvid, cid: cid);
        if (res case Success(:final response) when response != null) {
          items = response;
        }
      } catch (_) {}
    }
    // ③ 备用接口（/x/tag/archive/tags）
    if (items == null || items.isEmpty) {
      try {
        final res2 = await user_http.UserHttp.videoTagsV2(bvid: bvid);
        if (res2 case Success(:final response) when response != null) {
          items = response;
        }
      } catch (_) {}
    }
    if (items == null) return [];

    bool isValidTag(String t) {
      if (t.length < 2 || t.length > 30) return false;
      if (_tagSongBlacklist.contains(t)) return false;
      if (RegExp(r'[，。、；：！？,.;:!?【】\[\]()（）]').hasMatch(t)) {
        return false;
      }
      return true;
    }

    final result = <String>[];
    // ① musicId 非空 → B 站官方歌曲标签，最优先。
    //    典型格式"发现《歌名》" → 提取歌名（去掉"发现《》"包装）
    final songNamePattern = RegExp(r'发现《(.+)》');
    for (final e in items) {
      final hasMusicId = (e.musicId?.isNotEmpty ?? false) && e.musicId != '0';
      final name = e.tagName?.trim() ?? '';
      if (!hasMusicId || name.isEmpty) continue;
      final m = songNamePattern.firstMatch(name);
      final song = m?.group(1)?.trim();
      if (song != null && song.isNotEmpty && !result.contains(song)) {
        result.add(song);
      } else if (isValidTag(name) && !result.contains(name)) {
        result.add(name);
      }
    }
    // ② 其余普通标签（保持接口顺序）
    final normalTags = items
        .where((e) => !((e.musicId?.isNotEmpty ?? false) && e.musicId != '0'))
        .map((e) => e.tagName?.trim() ?? '')
        .where(isValidTag);
    for (final t in normalTags) {
      if (!result.contains(t)) result.add(t);
    }
    return result;
  }

  /// 从 B 站音乐标签（"发现《歌名》" + music_id）取 (歌名, 原唱歌手)。
  /// 复用 [_detailTags]（_fetchBilibiliTags 已缓存），歌手取 B 站音乐详情，
  /// 失败/无标签时返回 null（不阻塞搜索）。
  Future<(String, String)?> _fetchBilibiliSongInfo() async {
    final items = _detailTags;
    if (items == null || items.isEmpty) return null;
    final songNamePattern = RegExp(r'发现《(.+)》');
    for (final e in items) {
      final hasMusicId = (e.musicId?.isNotEmpty ?? false) && e.musicId != '0';
      final name = e.tagName?.trim() ?? '';
      if (!hasMusicId || name.isEmpty) continue;
      final m = songNamePattern.firstMatch(name);
      final song = m?.group(1)?.trim();
      if (song == null || song.isEmpty) continue;
      // 尝试拿原唱歌手（B 站音乐详情）；失败时歌手留空（不影响歌名搜索）
      String artist = '';
      try {
        final r = await MusicHttp.bgmDetail(e.musicId!);
        if (r case Success(:final response)) {
          artist = response.originArtist ?? '';
        }
      } catch (_) {}
      return (song, artist);
    }
    return null;
  }

  Future<void> searchLyrics(String title) async {
    if (title.isEmpty) return;
    final seq = ++_lyricsSearchSeq;
    isLoadingLyrics.value = true;
    lyricsError.value = '';
    lyricsResults.clear();
    lyricsSearchResults.clear();
    // 重置 CC 字幕状态（切歌时清掉上一首的）
    ccLocked.value = false;
    ccDefault.value = false;
    dmLocked.value = false;
    dmDefault.value = false;

    // 同时取 B站 CC 字幕（不参与搜索，基于 aid+cid）
    _fetchBilibiliCc(seq);

    // 同时识别弹幕歌词（顶置/底置/高级弹幕）
    _fetchDanmakuLyrics(seq);

    // 搜索所有平台（用于显示候选列表 + 取歌词）
    // 关键词优先级：
    //   标题（稳定兜底）
    //   B 站官方歌曲标记（"发现《歌名》" + music_id → 歌名/歌名+歌手，最精准）
    //   其余标签（musicId 优先 → 普通标签）
    final tags = await _fetchBilibiliTags();
    final songInfo = await _fetchBilibiliSongInfo();
    if (seq != _lyricsSearchSeq) return; // 已被更新的搜索取代，丢弃
    final keywords = <String>[title];
    if (songInfo case (final sname, final sartist)) {
      if (sname.isNotEmpty) {
        if (sartist.isNotEmpty) keywords.add('$sname $sartist');
        keywords.add(sname);
      }
    }
    for (final t in tags) {
      if (!keywords.contains(t)) keywords.add(t);
      if (keywords.length >= 5) break;
    }
    searchAllPlatformsMulti(keywords).then((searchResults) {
      if (seq != _lyricsSearchSeq) return; // 竞态：丢弃过期结果
      lyricsSearchResults.addAll(searchResults);

      // 检查是否有已记忆的匹配，尝试从搜索结果中匹配
      final remembered = LyricsMemory.getRemembered(
          audioTitle.value, audioArtist.value);
      if (remembered != null) {
        final (rememberedSource, rememberedItem) = remembered;

        // CC 字幕：不用搜索，[lyricsResults] 已在 [_fetchBilibiliCc] 中加载
        if (rememberedSource == LyricsSource.bilibili_cc) {
          isLoadingLyrics.value = false;
          _saveLyricsCache();
          return;
        }

        // 弹幕歌词：不用搜索，[lyricsResults] 已在 [_fetchDanmakuLyrics] 中加载
        // （否则会走 _searchAndUseRemembered → fetchLyricsForItem → "不支持此方式"）
        if (rememberedSource == LyricsSource.danmaku) {
          isLoadingLyrics.value = false;
          _saveLyricsCache();
          return;
        }

        final items = searchResults[rememberedSource];
        if (items != null) {
          // 在搜索结果中找标题+歌手匹配的完整项（含平台 ID）
          for (final item in items) {
            if (item.title == rememberedItem.title &&
                item.artist == rememberedItem.artist) {
              // 找到 → 使用完整搜索结果项（含 neteaseSongId/kugouFileHash）
              fetchLyricsForSourceItem(rememberedSource, item).then((_) {
                isLoadingLyrics.value = false;
                _saveLyricsCache();
              });
              return;
            }
          }
          // 搜索结果列表有该源但无精确匹配
          // 可能是搜索词太长/格式不同导致 API 返回不同结果
          // → 按已记忆的歌名+歌手单独搜
          _searchAndUseRemembered(
            rememberedSource, rememberedItem, title, searchResults);
          return;
        }
        // 该源无搜索结果 → 按已记忆的歌名+歌手单独搜
        _searchAndUseRemembered(
          rememberedSource, rememberedItem, title, searchResults);
        return;
      }

      // 无记忆 → 各平台选与视频标题/标签歌名最匹配的一首取歌词
      // 先计算各平台最佳匹配项与最高吻合度
      final bestBySource = <LyricsSource, LyricsSearchItem>{};
      var maxScore = 0.0;
      // 歌手候选：B 站音乐详情原唱歌手 + 视频 UP 主（用于同名歌打分加权）
      final artistNames = <String>[
        if (songInfo != null && songInfo.$2.isNotEmpty) songInfo.$2,
        if (audioArtist.value.isNotEmpty) audioArtist.value,
      ];
      for (final entry in searchResults.entries) {
        final items = entry.value;
        if (items.isEmpty) continue;
        final best = pickBestLyricsItem(
          items,
          audioTitle.value,
          tagNames: tags,
          artistNames: artistNames,
        );
        bestBySource[entry.key] = best;
        final score = titleSimilarityScore(
          best.title,
          audioTitle.value,
          tags,
          artistNames,
        );
        if (score > maxScore) maxScore = score;
      }
      // 吻合度过低（<0.3）：平台搜到的歌名与视频标题/标签都不像
      // → 直接以弹幕歌词为源（若弹幕成功会自动选中；否则退回平台最佳）
      const lowMatchThreshold = 0.3;
      final lowMatch = bestBySource.isNotEmpty && maxScore < lowMatchThreshold;
      if (lowMatch) {
        // 平台结果标为"匹配度过低"，弹幕成为默认歌词源
        for (final entry in bestBySource.entries) {
          lyricsResults[entry.key] = LyricsResult(
            source: entry.key.label,
            error: '歌名与标题匹配度过低（${maxScore.toStringAsFixed(2)}），已切弹幕歌词',
          );
        }
        for (final entry in searchResults.entries) {
          if (!bestBySource.containsKey(entry.key)) {
            lyricsResults[entry.key] = LyricsResult(
              source: entry.key.label,
              error: '未找到歌曲',
            );
          }
        }
        final dm = lyricsResults[LyricsSource.danmaku];
        if (dm != null && dm.isSuccess) {
          selectedSource.value = LyricsSource.danmaku;
        }
        isLoadingLyrics.value = false;
        _saveLyricsCache();
        return;
      }
      // 正常路径：各平台取最佳匹配项的歌词
      final fetches = <Future<void>>[];
      for (final entry in searchResults.entries) {
        final source = entry.key;
        final best = bestBySource[source];
        if (best != null) {
          fetches.add(
            fetchLyricsForItem(source, best).then((result) {
              lyricsResults[source] = result;
            }),
          );
        } else {
          lyricsResults[source] = LyricsResult(
            source: source.label,
            error: '未找到歌曲',
          );
        }
      }
      // 全部完成后更新 UI
      Future.wait(fetches).then((_) {
        isLoadingLyrics.value = false;
        _saveLyricsCache();
        final current = lyricsResults[selectedSource.value];
        if (current == null || !current.isSuccess) {
          for (final entry in lyricsResults.entries) {
            if (entry.value.isSuccess) {
              selectedSource.value = entry.key;
              break;
            }
          }
        }
      }).catchError((e) {
        isLoadingLyrics.value = false;
      });
    });
  }

  /// 识别弹幕歌词（顶置/底置/高级弹幕，基于 cid，不参与搜索）
  Future<void> _fetchDanmakuLyrics(int seq) async {
    final cid = subId.firstOrNull?.toInt();
    if (cid == null || cid <= 0) return;
    final result = await fetchLyricsFromDanmaku(cid);
    if (seq != _lyricsSearchSeq) return; // 竞态：丢弃过期结果
    lyricsResults[LyricsSource.danmaku] = result;
    if (result.isSuccess) {
      // 初始化锁定 & 全局默认状态
      dmLocked.value = LyricsMemory.isRememberedSource(
          audioTitle.value, audioArtist.value, LyricsSource.danmaku);
      dmDefault.value = LyricsMemory.defaultDanmaku;
      // 自动切换到弹幕歌词的条件（按优先级，同 CC 字幕）：
      // 1. 单曲锁定（remembered）
      // 2. 全局默认（defaultDanmaku）
      // 3. 已选中弹幕歌词
      // 4. 还没有任何歌词源成功
      if (dmLocked.value ||
          dmDefault.value ||
          selectedSource.value == LyricsSource.danmaku ||
          !lyricsResults.values.any((r) => r.isSuccess)) {
        selectedSource.value = LyricsSource.danmaku;
      }
    }
    update();
  }

  /// 切换弹幕歌词的记忆锁定
  void toggleDmLock() {
    final title = audioTitle.value;
    final artist = audioArtist.value;
    if (LyricsMemory.isRememberedSource(title, artist, LyricsSource.danmaku)) {
      LyricsMemory.forget(title, artist);
      dmLocked.value = false;
    } else {
      LyricsMemory.rememberSource(title, artist, LyricsSource.danmaku);
      dmLocked.value = true;
    }
  }

  /// 取 B站 CC 字幕（基于 aid + cid）
  Future<void> _fetchBilibiliCc(int seq) async {
    final cid = subId.firstOrNull?.toInt();
    final aid = oid.toInt();
    if (cid == null || cid <= 0) return;
    final result = await fetchBilibiliCc(aid, cid);
    if (seq != _lyricsSearchSeq) return; // 竞态：丢弃过期结果
    lyricsResults[LyricsSource.bilibili_cc] = result;
    if (result.isSuccess) {
      // 初始化锁定 & 全局默认状态
      ccLocked.value = LyricsMemory.isRememberedCc(
          audioTitle.value, audioArtist.value);
      ccDefault.value = LyricsMemory.defaultCc;
      // 自动切换到 CC 字幕的条件（按优先级）：
      // 1. 单曲锁定（rememberedCc）
      // 2. 全局默认（defaultCc）
      // 3. 已选中 CC 字幕
      // 4. 还没有任何歌词源成功
      if (ccLocked.value ||
          ccDefault.value ||
          selectedSource.value == LyricsSource.bilibili_cc ||
          !lyricsResults.values.any((r) => r.isSuccess)) {
        selectedSource.value = LyricsSource.bilibili_cc;
      }
    }
  }

  /// 从搜索结果列表中选择指定项并取歌词
  Future<void> fetchLyricsForSourceItem(LyricsSource source, LyricsSearchItem item) async {
    try {
      selectedSearchItems[source] = item;
      final result = await fetchLyricsForItem(source, item);
      lyricsResults[source] = result;
      selectedSource.value = source;
      _saveLyricsCache();
      updateLyricsLine();
      update(); // 强制通知 UI 刷新
    } catch (e) {
      lyricsResults[source] = LyricsResult(source: source.label, error: '加载失败');
      update();
    }
  }

  /// 根据播放进度更新当前歌词行
  void updateLyricsLine() {
    final result = lyricsResults[selectedSource.value];
    if (result != null && result.isSuccess) {
      final idx = result.getCurrentLineIndex(position.value);
      currentLineIndex.value = idx;
      // 推送歌词到通知栏（OPPO 流体云 / 动态岛）
      if (idx >= 0 && result.syncedLines != null && idx < result.syncedLines!.length) {
        final text = result.syncedLines![idx].text;
        final nextText = idx + 1 < result.syncedLines!.length
            ? result.syncedLines![idx + 1].text
            : null;
        videoPlayerServiceHandler?.updateLyrics(text, nextLyrics: nextText);
        _pushToLiveUpdate(text, nextText);
        DesktopLyricsService.setLyrics(
          currentLine: text,
          nextLine: nextText ?? '',
          progress: 0.0,
        );
      }
    }
  }

  /// 推送歌词到 ColorOS 流体云胶囊（独立于媒体通知）
  void _pushToLiveUpdate(String currentLyric, String? nextLyric) {
    final media = videoPlayerServiceHandler?.mediaItem.value;
    LiveUpdateChannel.updateMusic(
      songTitle: media?.title ?? '',
      currentLyric: currentLyric,
      nextLyric: nextLyric ?? '',
      progress: position.value.inMilliseconds ~/ 1000,
      maxProgress: (media?.duration?.inMilliseconds ?? 1) ~/ 1000,
      isPlaying: isPlaying(),
    );
  }

  /// 切换歌词来源
  void switchLyricsSource(LyricsSource source) {
    selectedSource.value = source;
    updateLyricsLine();
  }

  /// 切换 CC 字幕的记忆锁定
  void toggleCcLock() {
    final title = audioTitle.value;
    final artist = audioArtist.value;
    if (LyricsMemory.isRememberedCc(title, artist)) {
      LyricsMemory.forget(title, artist);
      ccLocked.value = false;
    } else {
      LyricsMemory.rememberCc(title, artist);
      ccLocked.value = true;
    }
  }

  @override
  BlockConfigMixin get blockConfig => this;

  @override
  int get currPosInMilliseconds => position.value.inMilliseconds;

  @override
  Future<void>? seekTo(Duration duration, {required bool isSeek}) =>
      onSeek(duration);

  @override
  int? get timeLength => duration.value.inMilliseconds;

  /// 记忆匹配在搜索结果中没找到 → 按歌名+歌手单独搜该平台
  void _searchAndUseRemembered(
    LyricsSource source,
    LyricsSearchItem rememberedItem,
    String originalTitle,
    Map<LyricsSource, List<LyricsSearchItem>> otherResults,
  ) {
    // 用已记忆的歌名+歌手作为关键词搜索
    final keyword = '${rememberedItem.title} ${rememberedItem.artist}';
    searchAllPlatforms(keyword).then((results) {
      final items = results[source] ?? [];
      for (final item in items) {
        if (item.title == rememberedItem.title &&
            item.artist == rememberedItem.artist) {
          // 找到了，用这个完整项取歌词
          fetchLyricsForSourceItem(source, item).then((_) {
            isLoadingLyrics.value = false;
            _saveLyricsCache();
          });
          return;
        }
      }
      // 真的找不到了 → 直接点取歌词试试（可能无 ID 会报错）
      fetchLyricsForItem(source, rememberedItem).then((result) {
        lyricsResults[source] = result;
        selectedSource.value = source;
        isLoadingLyrics.value = false;
        _saveLyricsCache();
      });
    });
    // 显示其他源的结果
    for (final entry in otherResults.entries) {
      if (entry.key != source) {
        lyricsSearchResults[entry.key] = entry.value;
      }
    }
  }

  @override
  bool get autoPlay => true;

  @override
  bool get preInitPlayer => true;

  @override
  void onClose() {
    isBackgroundPlaying = false;
    DesktopLyricsService.hide();
    WakelockPlus.disable();
    shutdownTimerService
      ..onPause = null
      ..isPlaying = null
      ..reset();
    videoPlayerServiceHandler
      ?..onPlay = null
      ..onPause = null
      ..onSeek = null
      ..onVideoDetailDispose(hashCode.toString());
    _subscriptions?.forEach((e) => e.cancel());
    _subscriptions?.clear();
    _subscriptions = null;
    _mediaControl.disable();
    player?.dispose();
    player = null;
    animController.dispose();
    super.onClose();
  }
}

extension on DashItem {
  Iterable<String> get playUrls sync* {
    yield baseUrl;
    yield* backupUrl;
  }
}

extension on ResponseUrl {
  Iterable<String> get playUrls sync* {
    yield url;
    yield* backupUrl;
  }
}
