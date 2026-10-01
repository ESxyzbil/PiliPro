import 'dart:async' show Completer, StreamSubscription, Timer;
import 'dart:convert' show ascii;
import 'dart:io' show Directory, File, Platform;
import 'dart:math' show max, min;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/audio_normalization.dart';
import 'package:PiliPlus/models/common/super_resolution_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/user/danmaku_rule.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/video/video_shot/data.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_model.dart';
import 'package:PiliPlus/pages/setting/models/play_settings.dart'
    show kMaxVolume;
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/double_tap_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/duration.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/video_fit_type.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/services/asr/asr_audio_bridge.dart';
import 'package:PiliPlus/services/asr/asr_model_manager.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/ocr_frame_bridge.dart';
import 'package:PiliPlus/services/ocr/ocr_model_manager.dart';
import 'package:PiliPlus/services/ocr/ocr_service.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/asset_utils.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/box_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:archive/archive.dart' show getCrc32;
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback, DeviceOrientation;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

typedef PlayCallback = Future<void>? Function();

class PlPlayerController with BlockConfigMixin {
  Player? _videoPlayerController;
  VideoController? _videoController;

  // 添加一个私有静态变量来保存实例
  static PlPlayerController? _instance;

  // 流事件  监听播放状态变化
  // StreamSubscription? _playerEventSubs;

  /// [playerStatus] has a [status] observable
  final playerStatus = PlPlayerStatus(PlayerStatus.playing);

  ///
  final Rx<DataStatus> dataStatus = Rx(DataStatus.none);

  // bool controlsEnabled = false;

  /// 响应数据
  /// 带有Seconds的变量只在秒数更新时更新，以避免频繁触发重绘
  // 播放位置
  Duration position = Duration.zero;
  final RxInt positionSeconds = 0.obs;

  /// 进度条位置
  Duration sliderPosition = Duration.zero;
  final RxInt sliderPositionSeconds = 0.obs;
  // 展示使用
  final Rx<Duration> sliderTempPosition = Rx(Duration.zero);

  /// 视频时长
  final Rx<Duration> duration = Rx(Duration.zero);

  /// 视频缓冲
  final Rx<Duration> buffered = Rx(Duration.zero);
  final RxInt bufferedSeconds = 0.obs;

  int _playerCount = 0;

  late double lastPlaybackSpeed = 1.0;
  final RxDouble _playbackSpeed = Pref.playSpeedDefault.obs;
  late final RxDouble _longPressSpeed = Pref.longPressSpeedDefault.obs;

  /// 音量控制条
  final RxDouble volume = RxDouble(
    PlatformUtils.isDesktop ? Pref.desktopVolume : 1.0,
  );
  final setSystemBrightness = Pref.setSystemBrightness;

  /// 亮度控制条
  final RxDouble brightness = (-1.0).obs;

  /// 是否展示控制条
  final RxBool showControls = false.obs;

  /// 亮度控制条展示/隐藏
  final RxBool showBrightnessStatus = false.obs;

  /// 是否长按倍速
  final RxBool longPressStatus = false.obs;

  /// 屏幕锁 为true时，关闭控制栏
  final RxBool controlsLock = false.obs;

  /// 全屏状态
  final RxBool isFullScreen = false.obs;
  // 默认投稿视频格式
  bool isLive = false;

  bool _isVertical = false;

  /// 视频比例
  final Rx<VideoFitType> videoFit = Rx(VideoFitType.contain);

  /// 后台播放
  late final RxBool continuePlayInBackground =
      Pref.continuePlayInBackground.obs;

  ///
  final RxBool isSliderMoving = false.obs;

  bool _autoPlay = false;

  // 记录历史记录
  int? _aid;
  String? _bvid;
  int? cid;
  int? _epid;
  int? _seasonId;
  int? _pgcType;
  VideoType _videoType = VideoType.ugc;
  int _heartDuration = 0;
  int? width;
  int? height;

  late final tryLook = !Accounts.get(AccountType.video).isLogin && Pref.p1080;

  late DataSource dataSource;

  Timer? _timer;
  StreamSubscription<Duration>? _subForSeek;

  Box setting = GStorage.setting;

  // final Durations durations;

  String get bvid => _bvid!;

  /// 视频播放速度
  double get playbackSpeed => _playbackSpeed.value;

  // 长按倍速
  double get longPressSpeed => _longPressSpeed.value;

  /// [videoPlayerController] instance of Player
  Player? get videoPlayerController => _videoPlayerController;

  /// [videoController] instance of Player
  VideoController? get videoController => _videoController;

  bool isMuted = false;

  /// 听视频
  late final RxBool onlyPlayAudio = false.obs;

  /// 镜像
  late final RxBool flipX = false.obs;

  late final RxBool flipY = false.obs;

  final RxBool isBuffering = true.obs;

  /// 全屏方向
  bool get isVertical => _isVertical;

  /// 弹幕开关
  late final RxBool _enableShowDanmaku = Pref.enableShowDanmaku.obs;
  late final RxBool _enableShowLiveDanmaku = Pref.enableShowLiveDanmaku.obs;
  RxBool get enableShowDanmaku =>
      isLive ? _enableShowLiveDanmaku : _enableShowDanmaku;

  late final bool autoPiP = Pref.autoPiP;
  bool get isPipMode =>
      (Platform.isAndroid && AndroidHelper.isPipMode) ||
      (PlatformUtils.isDesktop && isDesktopPip);
  late bool isDesktopPip = false;
  late Rect _lastWindowBounds;

  late final showWindowTitleBar = Pref.showWindowTitleBar;
  late final RxBool isAlwaysOnTop = false.obs;
  Future<void> setAlwaysOnTop(bool value) {
    isAlwaysOnTop.value = value;
    return windowManager.setAlwaysOnTop(value);
  }

  Future<void> exitDesktopPip() {
    isDesktopPip = false;
    return Future.wait([
      if (showWindowTitleBar)
        windowManager.setTitleBarStyle(TitleBarStyle.normal),
      windowManager.setMinimumSize(const Size(400, 700)),
      windowManager.setBounds(_lastWindowBounds),
      setAlwaysOnTop(false),
      windowManager.setAspectRatio(0),
    ]);
  }

  Future<void> enterDesktopPip() async {
    if (isFullScreen.value) return;

    isDesktopPip = true;

    _lastWindowBounds = await windowManager.getBounds();

    if (showWindowTitleBar) {
      windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    }

    final Size size;
    final state = videoPlayerController!.state;
    int width = state.width;
    int height = state.height;
    if (width == 0) {
      width = this.width ?? 16;
    }
    if (height == 0) {
      height = this.height ?? 9;
    }
    if (height > width) {
      size = Size(280.0, 280.0 * height / width);
    } else {
      size = Size(280.0 * width / height, 280.0);
    }

    await windowManager.setMinimumSize(size);
    setAlwaysOnTop(true);
    windowManager
      ..setSize(size)
      ..setAspectRatio(width / height);
  }

  void toggleDesktopPip() {
    if (isDesktopPip) {
      exitDesktopPip();
    } else {
      enterDesktopPip();
    }
  }

  late bool _isAutoEnterPip = false;
  bool get isAutoEnterPip => _isAutoEnterPip;

  static bool get _isCurrVideoPage {
    final routing = Get.routing;
    if (routing.route is! GetPageRoute) {
      return false;
    }
    return _isVideoPage(routing.current);
  }

  static bool _isVideoPage(String routeName) {
    return routeName == '/videoV' || routeName == '/liveRoom';
  }

  void enterPip({bool autoEnter = false}) {
    if (videoPlayerController != null) {
      final state = videoPlayerController!.state;
      PageUtils.enterPip(
        autoEnter: autoEnter,
        width: state.width == 0 ? width : state.width,
        height: state.height == 0 ? height : state.height,
        isLive: isLive,
        isPlaying: playerStatus.isPlaying,
      );
    }
  }

  void _disableAutoEnterPip() {
    if (_isAutoEnterPip) {
      PiliAndroidHelper.disableAutoEnterPip();
    }
  }

  // 弹幕相关配置
  late final enableTapDm = PlatformUtils.isMobile && Pref.enableTapDm;
  late RuleFilter filters = Pref.danmakuFilterRule;
  // 关联弹幕控制器
  DanmakuController<DanmakuExtra>? danmakuController;
  bool showDanmaku = true;
  Set<int> dmState = <int>{};
  late final mergeDanmaku = Pref.mergeDanmaku;
  late final String midHash = getCrc32(
    ascii.encode(Accounts.main.mid.toString()),
    0,
  ).toRadixString(16);
  late final RxDouble danmakuOpacity = Pref.danmakuOpacity.obs;

  late List<double> speedList = Pref.speedList;
  late bool enableAutoLongPressSpeed = Pref.enableAutoLongPressSpeed;
  late final showControlDuration = Pref.enableLongShowControl
      ? const Duration(seconds: 30)
      : const Duration(seconds: 3);
  // 字幕
  late double subtitleFontScale = Pref.subtitleFontScale;
  late double subtitleFontScaleFS = Pref.subtitleFontScaleFS;
  late int subtitlePaddingH = Pref.subtitlePaddingH;
  late int subtitlePaddingB = Pref.subtitlePaddingB;
  late double subtitleBgOpacity = Pref.subtitleBgOpacity;
  final bool showVipDanmaku = Pref.showVipDanmaku; // loop unswitching
  late double subtitleStrokeWidth = Pref.subtitleStrokeWidth;
  late int subtitleFontWeight = Pref.subtitleFontWeight;

  // settings
  late final showFSActionItem = Pref.showFSActionItem;
  late final enableShrinkVideoSize = Pref.enableShrinkVideoSize;
  late final darkVideoPage = Pref.darkVideoPage;
  late final enableSlideVolumeBrightness = Pref.enableSlideVolumeBrightness;
  late final enableSlideFS = Pref.enableSlideFS;
  late final enableDragSubtitle = Pref.enableDragSubtitle;
  late final fastForBackwardDuration = Duration(
    seconds: Pref.fastForBackwardDuration,
  );

  late final horizontalSeasonPanel = Pref.horizontalSeasonPanel;
  late final preInitPlayer = Pref.preInitPlayer;
  late final showRelatedVideo = Pref.showRelatedVideo;
  late final showVideoReply = Pref.showVideoReply;
  late final showBangumiReply = Pref.showBangumiReply;
  late final reverseFromFirst = Pref.reverseFromFirst;
  late final horizontalPreview = Pref.horizontalPreview;
  late final showDmChart = Pref.showDmChart;
  late final showViewPoints = Pref.showViewPoints;
  late final showFsScreenshotBtn = Pref.showFsScreenshotBtn;
  late final showFsLockBtn = Pref.showFsLockBtn;
  late final keyboardControl = Pref.keyboardControl;
  late final uiScale = Pref.uiScale;

  late final bool autoEnterFullScreen = Pref.autoEnterFullScreen;
  late final bool autoExitFullscreen = Pref.autoExitFullscreen;
  late final bool autoPlayEnable = Pref.autoPlayEnable;
  late final bool enableVerticalExpand = Pref.enableVerticalExpand;
  late final bool pipNoDanmaku = Pref.pipNoDanmaku;

  late final bool tempPlayerConf = Pref.tempPlayerConf;

  late int? cacheVideoQa = PlatformUtils.isMobile ? null : Pref.defaultVideoQa;
  late int cacheAudioQa = Pref.defaultAudioQa;
  bool enableHeart = true;
  late final String? hwdec = Pref.enableHA ? Pref.hardwareDecoding : null;

  late final progressType = Pref.btmProgressBehavior;
  late final enableQuickDouble = Pref.enableQuickDouble;
  late final fullScreenGestureReverse = Pref.fullScreenGestureReverse;

  late final isRelative = Pref.useRelativeSlide;
  late final offset = isRelative
      ? Pref.sliderDuration / 100
      : Pref.sliderDuration * 1000;

  num get sliderScale =>
      isRelative ? duration.value.inMilliseconds * offset : offset;

  // 播放顺序相关
  late PlayRepeat playRepeat = Pref.playRepeat;

  TextStyle get subTitleStyle => TextStyle(
    height: 1.5,
    fontSize:
        16 * (isFullScreen.value ? subtitleFontScaleFS : subtitleFontScale),
    letterSpacing: 0.1,
    wordSpacing: 0.1,
    color: Colors.white,
    fontWeight: FontWeight.values[subtitleFontWeight],
    backgroundColor: subtitleBgOpacity == 0
        ? null
        : Colors.black.withValues(alpha: subtitleBgOpacity),
  );

  late final Rx<SubtitleViewConfiguration> subtitleConfig = getSubConfig.obs;

  SubtitleViewConfiguration get getSubConfig {
    final subTitleStyle = this.subTitleStyle;
    return SubtitleViewConfiguration(
      style: subTitleStyle,
      strokeStyle: subtitleBgOpacity == 0
          ? subTitleStyle.copyWith(
              color: null,
              background: null,
              backgroundColor: null,
              foreground: Paint()
                ..color = Colors.black
                ..style = PaintingStyle.stroke
                ..strokeWidth = subtitleStrokeWidth,
            )
          : null,
      padding: EdgeInsets.only(
        left: subtitlePaddingH.toDouble(),
        right: subtitlePaddingH.toDouble(),
        bottom: subtitlePaddingB.toDouble(),
      ),
      textScaleFactor: 1,
    );
  }

  void updateSubtitleStyle() {
    subtitleConfig.value = getSubConfig;
  }

  void onUpdatePadding(EdgeInsets padding) {
    subtitlePaddingB = padding.bottom.round().clamp(0, 200);
    putSubtitleSettings();
  }

  void updateSliderPositionSecond() {
    int newSecond = sliderPosition.inSeconds;
    if (sliderPositionSeconds.value != newSecond) {
      sliderPositionSeconds.value = newSecond;
    }
  }

  void updatePositionSecond() {
    int newSecond = position.inSeconds;
    if (positionSeconds.value != newSecond) {
      positionSeconds.value = newSecond;
    }
    // 整段字幕按播放进度驱动浮层更新
    if (asrFullReady) {
      asrFullCursor.value = position.inMilliseconds;
    }
  }

  void updateBufferedSecond() {
    int newSecond = buffered.value.inSeconds;
    if (bufferedSeconds.value != newSecond) {
      bufferedSeconds.value = newSecond;
    }
  }

  static PlPlayerController? get instance => _instance;

  static bool instanceExists() {
    return _instance != null;
  }

  static void setPlayCallBack(PlayCallback? playCallBack) {
    _playCallBack = playCallBack;
  }

  static PlayCallback? _playCallBack;

  static Future<void>? playIfExists() {
    // await _instance?.play(repeat: repeat, hideControls: hideControls);
    final result = _playCallBack?.call();
    return result;
  }

  // try to get PlayerStatus
  static PlayerStatus? getPlayerStatusIfExists() {
    return _instance?.playerStatus.value;
  }

  static Future<void> pauseIfExists({
    bool notify = true,
    bool isInterrupt = false,
  }) async {
    if (_instance?.playerStatus.isPlaying ?? false) {
      await _instance?.pause(notify: notify, isInterrupt: isInterrupt);
    }
  }

  static Future<void> seekToIfExists(
    Duration position, {
    bool isSeek = true,
  }) async {
    await _instance?.seekTo(position, isSeek: isSeek);
  }

  static double? getVolumeIfExists() {
    return _instance?.volume.value;
  }

  static Future<void>? setVolumeIfExists(
    double volumeNew, {
    bool showIndicator = true,
  }) {
    return _instance?.setVolume(volumeNew, showIndicator: showIndicator);
  }

  Box video = GStorage.video;

  bool visible = true;

  DeviceOrientation? _orientation;
  late final checkIsAutoRotate = Platform.isAndroid && mode != .gravity;
  StreamSubscription<OrientationParams>? _orientationListener;

  void _stopOrientationListener() {
    _orientationListener?.cancel();
    _orientationListener = null;
  }

  void _onOrientationChanged(OrientationParams param) {
    _orientation = param.orientation;
    if (Platform.isIOS && !visible) return;
    final orientation = param.orientation;
    final isFullScreen = this.isFullScreen.value;
    if (checkIsAutoRotate &&
        param.isAutoRotate != true &&
        (!isFullScreen ||
            _isVertical ||
            orientation == .portraitUp ||
            orientation == .portraitDown)) {
      return;
    }
    switch (orientation) {
      case .portraitUp:
        if (!_isVertical && controlsLock.value) return;
        if (!horizontalScreen && !_isVertical && isFullScreen) {
          if (!isManualFS) {
            triggerFullScreen(status: false, orientation: orientation);
          }
        } else {
          portraitUpMode();
        }
      case .portraitDown:
        if (!horizontalScreen) return;
        if (!_isVertical && controlsLock.value) return;
        portraitDownMode();
      case .landscapeLeft:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeLeftMode();
        }
      case .landscapeRight:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeRightMode();
        }
    }
  }

  // 添加一个私有构造函数
  PlPlayerController._() {
    if (PlatformUtils.isMobile) {
      _orientationListener = NativeDeviceOrientationPlatform.instance
          .onOrientationChanged(
            checkIsAutoRotate: checkIsAutoRotate,
            angleDegrees: Platform.isAndroid ? Pref.angleDegrees : null,
          )
          .listen(_onOrientationChanged);
    }

    if (!Accounts.heartbeat.isLogin || Pref.historyPause) {
      enableHeart = false;
    }

    if (Platform.isAndroid && autoPiP) {
      if (DeviceUtils.sdkInt < 31) {
        AndroidHelper$ToDart.onUserLeaveHint = Runnable.implement(
          $Runnable(run: _onUserLeaveHint),
        );
      } else {
        _isAutoEnterPip = true;
      }
    }
  }

  void _onUserLeaveHint() {
    if (playerStatus.isPlaying && _isCurrVideoPage) {
      enterPip();
    }
  }

  // 获取实例 传参
  static PlPlayerController getInstance({bool isLive = false}) {
    // 如果实例尚未创建，则创建一个新实例
    return (_instance ??= PlPlayerController._())
      ..isLive = isLive
      .._playerCount += 1;
  }

  bool _processing = false;
  bool get processing => _processing;

  // offline
  bool get isFileSource => dataSource is FileSource;

  late final _audioNormalization = Pref.audioNormalization;
  late final enableAudioNormalization =
      Platform.isAndroid && _audioNormalization != '0';
  late final String _audioNormalizationParam =
      AudioNormalization.getParamFromConfig(_audioNormalization);

  // 初始化资源
  Future<void> setDataSource(
    DataSource dataSource, {
    bool isLive = false,
    bool autoplay = true,
    // 初始化播放位置
    Duration? seekTo,
    // 初始化播放速度
    double speed = 1.0,
    int? width,
    int? height,
    Duration? duration,
    // 方向
    bool? isVertical,
    // 记录历史记录
    int? aid,
    String? bvid,
    int? cid,
    int? epid,
    int? seasonId,
    int? pgcType,
    VideoType? videoType,
    VoidCallback? onInit,
    Volume? volume,
    bool autoFullScreenFlag = false,
  }) async {
    try {
      _processing = true;
      this.isLive = isLive;
      _videoType = videoType ?? VideoType.ugc;
      this.width = width;
      this.height = height;
      this.dataSource = dataSource;
      _autoPlay = autoplay;
      // 初始化视频倍速
      // _playbackSpeed.value = speed;
      // 初始化数据加载状态
      dataStatus.value = DataStatus.loading;
      // 初始化全屏方向
      _isVertical = isVertical ?? false;
      _aid = aid;
      _bvid = bvid;
      this.cid = cid;
      _epid = epid;
      _seasonId = seasonId;
      _pgcType = pgcType;

      if (showSeekPreview) {
        _clearPreview();
      }
      cancelLongPressTimer();
      if (_videoPlayerController != null &&
          _videoPlayerController!.state.playing) {
        await pause(notify: false);
      }

      if (_playerCount == 0) {
        return;
      }
      // 配置Player 音轨、字幕等等
      await _createVideoController(dataSource, seekTo, volume);

      if (_playerCount == 0) {
        _removeListeners();
        _videoPlayerController?.dispose();
        _videoPlayerController = null;
        _videoController = null;
        return;
      }

      // 获取视频时长 00:00
      this.duration.value = duration ?? _videoPlayerController!.state.duration;
      position = buffered.value = sliderPosition = seekTo ?? Duration.zero;
      updatePositionSecond();
      updateSliderPositionSecond();
      updateBufferedSecond();
      // 数据加载完成
      dataStatus.value = DataStatus.loaded;

      if (autoFullScreenFlag && autoEnterFullScreen) {
        triggerFullScreen(status: true);
      }

      await _initializePlayer();
      onInit?.call();
    } catch (err, stackTrace) {
      dataStatus.value = DataStatus.error;
      if (kDebugMode) {
        debugPrint(stackTrace.toString());
        debugPrint('plPlayer err:  $err');
      }
    } finally {
      _processing = false;
    }
  }

  String? shadersDirPath;
  Future<String> get copyShadersToExternalDirectory async {
    if (shadersDirPath != null) {
      return shadersDirPath!;
    }

    return shadersDirPath = await AssetUtils.getOrCopy(
      'assets/shaders',
      Assets.mpvAnime4KShaders.followedBy(Assets.mpvAnime4KShadersLite),
      path.join(appSupportDirPath, 'anime_shaders'),
    );
  }

  late final isAnim = _pgcType == 1 || _pgcType == 4;
  late final Rx<SuperResolutionType> superResolutionType =
      (isAnim ? Pref.superResolutionType : SuperResolutionType.disable).obs;
  Future<void> setShader([SuperResolutionType? type, NativePlayer? pp]) async {
    if (type == null) {
      type = superResolutionType.value;
    } else {
      superResolutionType.value = type;
      if (isAnim && !tempPlayerConf) {
        setting.put(SettingBoxKey.superResolutionType, type.index);
      }
    }
    pp ??= _videoPlayerController!;
    switch (type) {
      case SuperResolutionType.disable:
        return pp.command(const ['change-list', 'glsl-shaders', 'clr', '']);
      case SuperResolutionType.efficiency:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShadersLite,
          ),
        ]);
      case SuperResolutionType.quality:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShaders,
          ),
        ]);
    }
  }

  static final loudnormRegExp = RegExp('loudnorm=([^,]+)');

  Future<Player> _initPlayer() async {
    assert(_videoPlayerController == null);
    final opt = {
      'video-sync': Pref.videoSync,
      if (Platform.isAndroid) 'ao': Pref.audioOutput,
      'volume':
          (PlatformUtils.isMobile ? Pref.playerVolume : volume.value * 100)
              .toString(),
      'volume-max': kMaxVolume.toString(),
    };
    final autosync = Pref.autosync;
    if (autosync != '0') {
      opt['autosync'] = autosync;
    }

    final player = await Player.create(
      configuration: PlayerConfiguration(
        logLevel: kDebugMode ? .warn : .error,
        options: opt,
      ),
    );

    assert(_videoController == null);

    _videoController = await VideoController.create(
      player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: hwdec != null,
        androidAttachSurfaceAfterVideoParameters: false,
        hwdec: hwdec,
      ),
    );

    player.setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl);

    _startListeners(player);

    return player;
  }

  Map<String, String>? _buffer;
  Map<String, String> get buffer =>
      _buffer ??= Pref.initBuffer(_playbackSpeed.value);
  Map<String, String>? _liveBuffer;
  Map<String, String> get liveBuffer => _liveBuffer ??= Pref.initLiveBuffer();

  // 配置播放器
  Future<void> _createVideoController(
    DataSource dataSource,
    Duration? seekTo,
    Volume? volume,
  ) async {
    isBuffering.value = false;
    buffered.value = Duration.zero;
    _heartDuration = 0;
    position = Duration.zero;
    // 初始化时清空弹幕，防止上次重叠
    danmakuController?.clear();

    var player = _videoPlayerController;

    if (player == null) {
      player = await _initPlayer();
      if (_playerCount == 0) {
        _removeListeners();
        player.dispose();
        player = null;
        _videoController = null;
        return;
      }
      _videoPlayerController = player;
      if (isAnim && superResolutionType.value != .disable) {
        await setShader();
      }
    }

    final Map<String, String> extras = {};

    if (dataSource is FileSource) {
      extras['cache'] = 'no';
    } else {
      if (isLive) {
        extras.addAll(liveBuffer);
      } else {
        extras.addAll(buffer);
      }
    }

    String video = dataSource.videoSource;
    if (dataSource.audioSource case final audio? when (audio.isNotEmpty)) {
      if (onlyPlayAudio.value) {
        video = audio;
      } else {
        extras['audio-files'] =
            '"${Platform.isWindows ? audio.replaceAll(';', r'\;') : audio.replaceAll(':', r'\:')}"';
      }
      if (enableAudioNormalization) {
        final String audioNormalization;
        if (volume != null && volume.isNotEmpty) {
          audioNormalization = _audioNormalizationParam.replaceFirstMapped(
            loudnormRegExp,
            (i) =>
                'loudnorm=${volume.format(
                  Map.fromEntries(
                    i.group(1)!.split(':').map((item) {
                      final parts = item.split('=');
                      return MapEntry(parts[0].toLowerCase(), num.parse(parts[1]));
                    }),
                  ),
                )}',
          );
        } else {
          audioNormalization = _audioNormalizationParam.replaceFirst(
            loudnormRegExp,
            AudioNormalization.getParamFromConfig(Pref.fallbackNormalization),
          );
        }
        if (audioNormalization.isNotEmpty) {
          extras['lavfi-complex'] = '"[aid1] $audioNormalization [ao]"';
        }
      }
    }

    await player.open(
      Media(
        video,
        start: seekTo,
        extras: extras.isEmpty ? null : extras,
      ),
      play: false,
    );
  }

  Future<void>? refreshPlayer() {
    if (dataSource is FileSource) {
      return null;
    }
    if (_videoPlayerController case final ctr? when (ctr.current.isNotEmpty)) {
      return ctr.open(ctr.current.last.copyWith(start: position), play: true);
    }
    return null;
  }

  // 开始播放
  Future<void> _initializePlayer() async {
    if (_instance == null) return;
    // 设置倍速
    if (isLive) {
      await setPlaybackSpeed(1.0);
    } else {
      if (_videoPlayerController?.state.rate != _playbackSpeed.value) {
        await setPlaybackSpeed(_playbackSpeed.value);
      }
    }
    _initVideoFit();
    // if (_looping) {
    //   await setLooping(_looping);
    // }

    // 跳转播放
    // if (seekTo != Duration.zero) {
    //   await this.seekTo(seekTo);
    // }

    // 自动播放
    if (_autoPlay) {
      playIfExists();
      // await play(duration: duration);
    }
  }

  List<StreamSubscription>? _subscriptions;
  final Set<ValueChanged<Duration>> _positionListeners = {};
  final Set<ValueChanged<PlayerStatus>> _statusListeners = {};

  /// 播放事件监听
  void _startListeners(NativePlayer player) {
    assert(_subscriptions == null);
    final stream = player.stream;
    _subscriptions = [
      stream.playing.listen((event) {
        WakelockPlus.toggle(enable: event);
        if (event) {
          if (_isAutoEnterPip) {
            if (_isCurrVideoPage) {
              enterPip(autoEnter: true);
            } else {
              _disableAutoEnterPip();
            }
          }
          playerStatus.value = PlayerStatus.playing;
        } else {
          _disableAutoEnterPip();
          playerStatus.value = PlayerStatus.paused;
        }
        videoPlayerServiceHandler?.onStatusChange(
          playerStatus.value,
          isBuffering.value,
          isLive,
        );

        /// 触发回调事件
        for (final element in _statusListeners) {
          element(event ? PlayerStatus.playing : PlayerStatus.paused);
        }
        if (videoPlayerController!.state.position.inSeconds != 0) {
          makeHeartBeat(positionSeconds.value, type: HeartBeatType.status);
        }
      }),
      stream.completed.listen((event) {
        if (event) {
          playerStatus.value = PlayerStatus.completed;

          /// 触发回调事件
          for (final element in _statusListeners) {
            element(PlayerStatus.completed);
          }
        } else {
          // playerStatus.value = PlayerStatus.playing;
        }
        makeHeartBeat(positionSeconds.value, type: HeartBeatType.completed);
      }),
      stream.position.listen((event) {
        position = event;
        updatePositionSecond();
        if (!isSliderMoving.value) {
          sliderPosition = event;
          updateSliderPositionSecond();
        }

        /// 触发回调事件
        for (final element in _positionListeners) {
          element(event);
        }
        makeHeartBeat(event.inSeconds);
      }),
      stream.duration.listen((Duration event) {
        duration.value = event;
      }),
      stream.buffer.listen((Duration event) {
        buffered.value = event;
        updateBufferedSecond();
      }),
      stream.buffering.listen((bool event) {
        isBuffering.value = event;
        videoPlayerServiceHandler?.onStatusChange(
          playerStatus.value,
          event,
          isLive,
        );
      }),
      if (kDebugMode)
        stream.log.listen(((PlayerLog log) {
          if (log.level == 'error' || log.level == 'fatal') {
            Utils.reportError('${log.level}: ${log.prefix}: ${log.text}', null);
          } else {
            debugPrint(log.toString());
          }
        })),
      stream.error.listen((String event) {
        if (dataSource is FileSource &&
            event.startsWith("Failed to open file")) {
          return;
        }
        if (isLive) {
          if (event.startsWith('tcp: ffurl_read returned ') ||
              event.startsWith("Failed to open https://") ||
              event.startsWith("Can not open external file https://")) {
            Future.delayed(const Duration(milliseconds: 3000), refreshPlayer);
          }
          return;
        }
        if (event.startsWith("Failed to open https://") ||
            event.startsWith("Can not open external file https://") ||
            //tcp: ffurl_read returned 0xdfb9b0bb
            //tcp: ffurl_read returned 0xffffff99
            event.startsWith('tcp: ffurl_read returned ')) {
          EasyThrottle.throttle(
            'controllerStream.error.listen',
            const Duration(milliseconds: 10000),
            () {
              Future.delayed(const Duration(milliseconds: 3000), () {
                // if (kDebugMode) {
                //   debugPrint("isBuffering.value: ${isBuffering.value}");
                // }
                // if (kDebugMode) {
                //   debugPrint("_buffered.value: ${_buffered.value}");
                // }
                if (isBuffering.value && buffered.value == Duration.zero) {
                  SmartDialog.showToast(
                    '视频链接打开失败，重试中',
                    displayTime: const Duration(milliseconds: 500),
                  );
                  refreshPlayer();
                }
              });
            },
          );
        } else if (event.startsWith('Could not open codec')) {
          SmartDialog.showToast('无法加载解码器, $event，可能会切换至软解');
        } else if (!onlyPlayAudio.value) {
          if (event.startsWith("error running") ||
              event.startsWith("Failed to open .") ||
              event.startsWith("Cannot open") ||
              event.startsWith("Can not open")) {
            return;
          }
          Utils.reportError(event);
          // SmartDialog.showToast('视频加载错误, $event');
        }
      }),
      // controllerStream.volume.listen((event) {
      //   if (!mute.value && _volumeBeforeMute != event) {
      //     _volumeBeforeMute = event / 100;
      //   }
      // }),
      // 媒体通知监听
      if (videoPlayerServiceHandler != null)
        positionSeconds.listen((int event) {
          videoPlayerServiceHandler!.onPositionChange(Duration(seconds: event));
        }),
    ];
  }

  /// 移除事件监听
  void _removeListeners() {
    _subscriptions?.forEach((e) => e.cancel());
    _subscriptions?.clear();
    _subscriptions = null;
  }

  void _cancelSubForSeek() {
    if (_subForSeek != null) {
      _subForSeek!.cancel();
      _subForSeek = null;
    }
  }

  /// 跳转至指定位置
  Future<void> seekTo(Duration position, {bool isSeek = true}) async {
    // if (position >= duration.value) {
    //   position = duration.value - const Duration(milliseconds: 100);
    // }
    if (_playerCount == 0) {
      return;
    }
    if (position < Duration.zero) {
      position = Duration.zero;
    }
    this.position = position;
    updatePositionSecond();
    _heartDuration = position.inSeconds;
    // ASR 开启时 seek 需重对齐音频流
    if (asrSubtitleEnabled.value) {
      _restartAsrIfNeeded();
    }

    Future<void> seek() async {
      if (isSeek) {
        /// 拖动进度条调节时，不等待第一帧，防止抖动
        await _videoPlayerController?.stream.buffer.first;
      }
      danmakuController?.clear();
      try {
        await _videoPlayerController?.seek(position);
      } catch (e) {
        if (kDebugMode) debugPrint('seek failed: $e');
      }
    }

    if (duration.value != Duration.zero) {
      seek();
    } else {
      // if (kDebugMode) debugPrint('seek duration else');
      _subForSeek?.cancel();
      _subForSeek = duration.listen((_) {
        seek();
        _cancelSubForSeek();
      });
    }
  }

  /// 设置倍速
  Future<void> setPlaybackSpeed(double speed) async {
    lastPlaybackSpeed = playbackSpeed;

    if (speed == _videoPlayerController?.state.rate) {
      return;
    }

    await _videoPlayerController?.setRate(speed);
    _playbackSpeed.value = speed;
    if (danmakuController != null) {
      try {
        DanmakuOption currentOption = danmakuController!.option;
        double defaultDuration = currentOption.duration * lastPlaybackSpeed;
        double defaultStaticDuration =
            currentOption.staticDuration * lastPlaybackSpeed;
        DanmakuOption updatedOption = currentOption.copyWith(
          duration: defaultDuration / speed,
          staticDuration: defaultStaticDuration / speed,
        );
        danmakuController!.updateOption(updatedOption);
      } catch (_) {}
    }
  }

  // 还原默认速度
  double playSpeedDefault = Pref.playSpeedDefault;
  Future<void> setDefaultSpeed() async {
    await _videoPlayerController?.setRate(playSpeedDefault);
    _playbackSpeed.value = playSpeedDefault;
  }

  /// 播放视频
  Future<void> play({bool repeat = false, bool hideControls = true}) async {
    if (_playerCount == 0) return;
    // 播放时自动隐藏控制条
    controls = !hideControls;
    // repeat为true，将从头播放
    if (repeat) {
      // await seekTo(Duration.zero);
      await seekTo(Duration.zero, isSeek: false);
    }

    await _videoPlayerController?.play();

    audioSessionHandler?.setActive(true);

    playerStatus.value = PlayerStatus.playing;
    // ASR 开启时恢复播放需重启音频流（暂停时已停）
    if (asrSubtitleEnabled.value) {
      _restartAsrIfNeeded();
    }
    // screenManager.setOverlays(false);
  }

  /// 暂停播放
  Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
    await _videoPlayerController?.pause();
    playerStatus.value = PlayerStatus.paused;
    // 暂停时停掉 ASR 音频解码，避免超前于画面
    if (asrSubtitleEnabled.value) {
      _asrBridge.stop();
    }

    // 主动暂停时让出音频焦点
    if (!isInterrupt) {
      audioSessionHandler?.setActive(false);
    }
  }

  bool tripling = false;

  /// 隐藏控制条
  void hideTaskControls() {
    _timer?.cancel();
    _timer = Timer(showControlDuration, () {
      if (!isSliderMoving.value && !tripling) {
        controls = false;
      }
      _timer = null;
    });
  }

  /// 调整播放时间
  void onChangedSlider(int v) {
    sliderPosition = Duration(seconds: v);
    updateSliderPositionSecond();
  }

  void onChangedSliderStart([Duration? value]) {
    if (value != null) {
      sliderTempPosition.value = value;
    }
    isSliderMoving.value = true;
  }

  bool? cancelSeek;
  bool? hasToast;

  void onUpdatedSliderProgress(Duration value) {
    sliderTempPosition.value = value;
    sliderPosition = value;
    updateSliderPositionSecond();
  }

  void onChangedSliderEnd() {
    if (cancelSeek != true) {
      feedBack();
    }
    cancelSeek = null;
    hasToast = null;
    isSliderMoving.value = false;
    hideTaskControls();
  }

  final RxBool volumeIndicator = false.obs;
  Timer? volumeTimer;
  bool volumeInterceptEventStream = false;

  final double maxVolume = PlatformUtils.isDesktop ? Pref.maxVolume : 1.0;
  Future<void> setVolume(double volume, {bool showIndicator = true}) async {
    if (this.volume.value != volume) {
      this.volume.value = volume;
      try {
        if (PlatformUtils.isDesktop) {
          await _videoPlayerController!.setVolume(volume * 100);
        } else {
          FlutterVolumeController.updateShowSystemUI(false);
          await FlutterVolumeController.setVolume(volume);
        }
      } catch (err) {
        if (kDebugMode) debugPrint(err.toString());
      }
    }
    if (showIndicator) {
      volumeIndicator.value = true;
    }
    volumeInterceptEventStream = true;
    volumeTimer?.cancel();
    volumeTimer = Timer(const Duration(milliseconds: 200), () {
      volumeIndicator.value = false;
      volumeInterceptEventStream = false;
      if (PlatformUtils.isDesktop) {
        setting.put(SettingBoxKey.desktopVolume, volume.toPrecision(3));
      }
    });
  }

  /// Toggle Change the videofit accordingly
  void toggleVideoFit(VideoFitType value) {
    _prefFit = videoFit.value = value;
    video.put(VideoBoxKey.cacheVideoFit, value.index);
  }

  /// 读取fit
  var _prefFit = VideoFitType.values[Pref.cacheVideoFit];
  void _initVideoFit() {
    if (_prefFit == .fill && _isVertical) {
      videoFit.value = .contain;
    } else {
      videoFit.value = _prefFit;
    }
  }

  /// 设置后台播放
  void setBackgroundPlay(bool val) {
    videoPlayerServiceHandler?.enableBackgroundPlay = val;
    if (!tempPlayerConf) {
      setting.put(SettingBoxKey.enableBackgroundPlay, val);
    }
  }

  set controls(bool visible) {
    showControls.value = visible;
    _timer?.cancel();
    if (visible) {
      hideTaskControls();
    }
  }

  Timer? longPressTimer;
  void cancelLongPressTimer() {
    longPressTimer?.cancel();
    longPressTimer = null;
  }

  /// 设置长按倍速状态 live模式下禁用
  Future<void> setLongPressStatus(bool val) async {
    if (isLive) {
      return;
    }
    if (controlsLock.value) {
      return;
    }
    if (longPressStatus.value == val) {
      return;
    }
    if (val) {
      if (playerStatus.isPlaying) {
        longPressStatus.value = val;
        HapticFeedback.lightImpact();
        await setPlaybackSpeed(
          enableAutoLongPressSpeed ? playbackSpeed * 2 : longPressSpeed,
        );
      }
    } else {
      // if (kDebugMode) debugPrint('$playbackSpeed');
      longPressStatus.value = val;
      await setPlaybackSpeed(lastPlaybackSpeed);
    }
  }

  bool get _isCompleted =>
      videoPlayerController!.state.completed ||
      (duration.value - position).inMilliseconds <= 50;

  // 双击播放、暂停
  Future<void> onDoubleTapCenter() async {
    if (!isLive && _isCompleted) {
      await videoPlayerController!.seek(Duration.zero);
      videoPlayerController!.play();
    } else {
      videoPlayerController!.playOrPause();
    }
  }

  final RxBool mountSeekBackwardButton = false.obs;
  final RxBool mountSeekForwardButton = false.obs;

  void onDoubleTapSeekBackward() {
    mountSeekBackwardButton.value = true;
  }

  void onDoubleTapSeekForward() {
    mountSeekForwardButton.value = true;
  }

  void onForward(Duration duration) {
    onForwardBackward(position + duration);
  }

  void onBackward(Duration duration) {
    onForwardBackward(position - duration);
  }

  void onForwardBackward(Duration duration) {
    seekTo(
      duration.clamp(Duration.zero, videoPlayerController!.state.duration),
      isSeek: false,
    ).whenComplete(play);
  }

  void doubleTapFuc(DoubleTapType type) {
    if (!enableQuickDouble) {
      onDoubleTapCenter();
      return;
    }
    switch (type) {
      case DoubleTapType.left:
        // 双击左边区域 👈
        onDoubleTapSeekBackward();
        break;
      case DoubleTapType.center:
        onDoubleTapCenter();
        break;
      case DoubleTapType.right:
        // 双击右边区域 👈
        onDoubleTapSeekForward();
        break;
    }
  }

  /// 关闭控制栏
  void onLockControl(bool val) {
    feedBack();
    controlsLock.value = val;
    if (!val && showControls.value) {
      showControls.refresh();
    }
    controls = !val;
  }

  void _setFullScreen(bool val) {
    isFullScreen.value = val;
    updateSubtitleStyle();
  }

  double screenRatio = 0.0;
  bool isManualFS = true;
  late final FullScreenMode mode = Pref.fullScreenMode;
  /// 是否使用横屏布局（新的横屏适配设置：关/自动（宽高比阈值）/开）。
  /// 用 getter 而非 late final：自动模式需随屏幕尺寸动态判定。
  bool get horizontalScreen => Pref.useHorizontalLayout;
  late final removeSafeArea = Pref.removeSafeArea;

  Future<void>? changeOrientation({
    required bool isVertical,
    DeviceOrientation? orientation,
  }) {
    if (orientation == null && (mode == .none || mode == .gravity)) {
      return null;
    }
    if (orientation == null &&
        (mode == .vertical ||
            (mode == .auto && isVertical) ||
            (mode == .ratio && (isVertical || screenRatio < kScreenRatio)))) {
      return portraitUpMode();
    } else {
      // https://github.com/flutter/flutter/issues/73651
      // https://github.com/flutter/flutter/issues/183708
      if (Platform.isAndroid) {
        if ((orientation ?? _orientation) == .landscapeRight) {
          return landscapeRightMode();
        } else {
          return landscapeLeftMode();
        }
      } else {
        if (orientation == .landscapeLeft) {
          return landscapeLeftMode();
        } else {
          return landscapeRightMode();
        }
      }
    }
  }

  // 全屏
  bool _fsProcessing = false;
  Future<void> triggerFullScreen({
    bool status = true,
    bool inAppFullScreen = false,
    DeviceOrientation? orientation,
    bool isManualFS = true,
  }) async {
    if (isDesktopPip) return;
    if (isFullScreen.value == status) return;

    if (_fsProcessing) return;
    _fsProcessing = true;
    this.isManualFS = isManualFS;
    try {
      if (status) {
        if (PlatformUtils.isMobile) {
          hideSystemBar();
          await changeOrientation(
            isVertical: isVertical,
            orientation: orientation,
          );
        } else {
          await enterDesktopFullScreen(inAppFullScreen: inAppFullScreen);
        }
      } else {
        if (PlatformUtils.isMobile) {
          if (!removeSafeArea) {
            showSystemBar();
          }
          if (orientation == null && mode == .none) {
            return;
          }
          await resetScreenRotation();
        } else {
          await exitDesktopFullScreen();
        }
      }
    } finally {
      _setFullScreen(status);
      _fsProcessing = false;
    }
  }

  void addPositionListener(ValueChanged<Duration> listener) {
    if (_playerCount == 0) return;
    _positionListeners.add(listener);
  }

  void removePositionListener(ValueChanged<Duration> listener) =>
      _positionListeners.remove(listener);

  void addStatusLister(ValueChanged<PlayerStatus> listener) {
    if (_playerCount == 0) return;
    _statusListeners.add(listener);
  }

  void removeStatusLister(ValueChanged<PlayerStatus> listener) =>
      _statusListeners.remove(listener);

  // 记录播放记录
  Future<void>? makeHeartBeat(
    int progress, {
    HeartBeatType type = .playing,
    bool isManual = false,
    dynamic aid,
    dynamic bvid,
    dynamic cid,
    dynamic epid,
    dynamic seasonId,
    dynamic pgcType,
    VideoType? videoType,
  }) {
    if (isLive ||
        !enableHeart ||
        progress == 0 ||
        (playerStatus.isPaused && !isManual)) {
      return null;
    }

    Future<void> send() {
      return VideoHttp.heartBeat(
        aid: aid ?? _aid,
        bvid: bvid ?? _bvid,
        cid: cid ?? this.cid,
        progress: progress,
        epid: epid ?? _epid,
        seasonId: seasonId ?? _seasonId,
        subType: pgcType ?? _pgcType,
        videoType: videoType ?? _videoType,
      );
    }

    switch (type) {
      case .playing:
        if (progress - _heartDuration >= 5) {
          _heartDuration = progress;
          return send();
        }
      case .status:
        if (progress - _heartDuration >= 2) {
          _heartDuration = progress;
          return send();
        }
      case .completed:
        if (playerStatus.isCompleted &&
            (duration.value - position).inMilliseconds <= 1000) {
          progress = -1;
        }
        return send();
    }
    return null;
  }

  void setPlayRepeat(PlayRepeat type) {
    playRepeat = type;
    if (!tempPlayerConf) video.put(VideoBoxKey.playRepeat, type.index);
  }

  void putSubtitleSettings() {
    setting.putAllNE({
      SettingBoxKey.subtitleFontScale: subtitleFontScale,
      SettingBoxKey.subtitleFontScaleFS: subtitleFontScaleFS,
      SettingBoxKey.subtitlePaddingH: subtitlePaddingH,
      SettingBoxKey.subtitlePaddingB: subtitlePaddingB,
      SettingBoxKey.subtitleBgOpacity: subtitleBgOpacity,
      SettingBoxKey.subtitleStrokeWidth: subtitleStrokeWidth,
      SettingBoxKey.subtitleFontWeight: subtitleFontWeight,
    });
  }

  bool _isCloseAll = false;
  bool get isCloseAll => _isCloseAll;

  Future<void>? resetScreenRotation() {
    if (horizontalScreen) {
      return fullMode();
    } else {
      return portraitUpMode();
    }
  }

  void onCloseAll() {
    _isCloseAll = true;
    dispose();
    Get.until((route) => route.isFirst);
  }

  void dispose() {
    // 每次减1，最后销毁
    resetScreenRotation();
    cancelLongPressTimer();
    _cancelSubForSeek();
    if (!_isCloseAll && _playerCount > 1) {
      _playerCount -= 1;
      _heartDuration = 0;
      return;
    }

    _playerCount = 0;
    if (removeSafeArea) {
      showSystemBar();
    }
    danmakuController = null;
    _stopOrientationListener();
    _disableAutoEnterPip();
    setPlayCallBack(null);
    dmState.clear();
    if (showSeekPreview) {
      _clearPreview();
    }
    if (Platform.isAndroid) {
      AndroidHelper$ToDart.onUserLeaveHint?.release();
      AndroidHelper$ToDart.onUserLeaveHint = null;
    }
    _timer?.cancel();
    // _position.close();
    // _playerEventSubs?.cancel();
    // _sliderPosition.close();
    // _sliderTempPosition.close();
    // _isSliderMoving.close();
    // _duration.close();
    // _buffered.close();
    // _showControls.close();
    // _controlsLock.close();

    // playerStatus.close();
    // dataStatus.close();

    if (PlatformUtils.isDesktop && isAlwaysOnTop.value) {
      windowManager.setAlwaysOnTop(false);
    }

    _removeListeners();
    _positionListeners.clear();
    _statusListeners.clear();
    if (playerStatus.isPlaying) {
      WakelockPlus.disable();
    }
    if (kDebugMode) {
      debugPrint('dispose player');
    }
    _stopAsr();
    _videoPlayerController?.dispose();
    _videoPlayerController = null;
    _videoController = null;
    _instance = null;
    videoPlayerServiceHandler?.clear();
  }

  /// ═══ OCR 字幕（视频页：单实例实时识别画面生成字幕）═══
  /// 预识别（第二实例取未来帧）在本设备不可行：无渲染器 screenshot 恒 null，
  /// 有渲染器必灰屏。故回到主播放器实时截图 + 后台 isolate 编码。
  final RxBool ocrSubtitleEnabled = false.obs;
  final RxString ocrSubtitleText = ''.obs;

  /// 已生成的 OCR 字幕段（开始/结束/文本），时间基于播放进度
  final List<({Duration start, Duration end, String text})> ocrSegments = [];

  /// 切换 OCR 字幕（整段识别：一次解码视频逐帧识别，生成时间轴字幕）
  Future<void> toggleOcrSubtitle() async {
    if (ocrSubtitleEnabled.value) {
      ocrSubtitleEnabled.value = false;
      ocrSubtitleText.value = '';
      ocrFullReady = false;
      ocrFullSegments.clear();
      _ocrFrameBridge.dispose();
      return;
    }
    if (isLive) {
      SmartDialog.showToast('直播暂不支持 OCR 字幕');
      return;
    }
    final videoUrl = dataSource.videoSource;
    if (videoUrl.isEmpty) {
      SmartDialog.showToast('当前视频无视频源，OCR 整段不可用');
      return;
    }
    if (!Get.isRegistered<OcrService>()) {
      Get.put(OcrService(), permanent: true);
    }
    if (!Get.isRegistered<OcrModelManager>()) {
      Get.put(OcrModelManager(), permanent: true);
    }
    if (!await OcrService.instance.isSupported()) {
      SmartDialog.showToast('OCR 仅支持 arm64 设备');
      return;
    }
    if (!await OcrModelManager.instance.isDownloaded()) {
      SmartDialog.showToast('请先到 设置 → 其他 → OCR 歌词模型 下载模型');
      return;
    }
    ocrSubtitleEnabled.value = true;
    _runFullOcrRecognition(videoUrl);
  }

  /// ═══ OCR 整段识别（一次解码视频逐帧 OCR，生成时间轴字幕）═══
  bool ocrFullReady = false;
  final List<({Duration start, Duration end, String text})> ocrFullSegments = [];
  bool _ocrFullRunning = false;
  final OcrFrameBridge _ocrFrameBridge = OcrFrameBridge();

  /// 工作台进度显示（OCR/ASR）
  final RxString ocrFullProgress = ''.obs;
  final RxString asrFullProgress = ''.obs;

  /// 工作台识别日志（shell 风格逐行滚动）
  final RxList<String> workbenchLogs = <String>[].obs;

  void wlog(String msg) {
    final t = DateTime.now();
    final ts = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
    workbenchLogs.add('[$ts] $msg');
    if (workbenchLogs.length > 500) {
      workbenchLogs.removeRange(0, workbenchLogs.length - 500);
    }
  }

  /// 公开：触发 OCR 整段识别（工作台页面调用）
  Future<void> runFullOcr() async {
    if (_ocrFullRunning) return;
    final url = dataSource.videoSource;
    if (url.isEmpty) {
      SmartDialog.showToast('当前视频无视频源，OCR 整段不可用');
      return;
    }
    if (!Get.isRegistered<OcrService>()) {
      Get.put(OcrService(), permanent: true);
    }
    if (!Get.isRegistered<OcrModelManager>()) {
      Get.put(OcrModelManager(), permanent: true);
    }
    if (!await OcrService.instance.isSupported()) {
      SmartDialog.showToast('OCR 仅支持 arm64 设备');
      return;
    }
    if (!await OcrModelManager.instance.isDownloaded()) {
      SmartDialog.showToast('请先到 设置 → 其他 → OCR 歌词模型 下载模型');
      return;
    }
    ocrSubtitleEnabled.value = true;
    await _runFullOcrRecognition(url);
  }

  /// 公开：触发 ASR 整段识别（工作台页面调用，独立于开关状态）
  Future<void> runFullAsr() async {
    if (_asrFullRunning) return;
    if (isLive) {
      SmartDialog.showToast('直播暂不支持 ASR 字幕');
      return;
    }
    final audioUrl = dataSource.audioSource;
    if (audioUrl == null || audioUrl.isEmpty) {
      SmartDialog.showToast('当前视频无独立音轨，ASR 不可用');
      return;
    }
    if (!Get.isRegistered<AsrService>()) {
      Get.put(AsrService(), permanent: true);
    }
    if (!Get.isRegistered<AsrModelManager>()) {
      Get.put(AsrModelManager(), permanent: true);
    }
    // 选择已下载的模型：离线(SenseVoice/Whisper)优先，否则流式
    await AsrModelManager.instance.refreshStatus();
    String? langCode;
    for (final l in AsrModelManager.languages) {
      if (AsrModelManager.instance.downloadedLangs.contains(l.code)) {
        if (langCode == null) langCode = l.code;
        if (l.isOffline) langCode = l.code;
      }
    }
    if (langCode == null) {
      SmartDialog.showToast('请先到 设置 → 其他 → ASR 语言包 下载模型');
      return;
    }
    final lang = AsrModelManager.instance.langOf(langCode)!;
    final modelDir = await AsrModelManager.instance.langDir(langCode);
    if (AsrService.instance.isLoaded && _asrModelDir != modelDir) {
      AsrService.instance.dispose();
    }
    _asrModelDir = modelDir;
    _asrModelLang = lang;
    final err = await AsrService.instance.init(lang, modelDir);
    if (err != null) {
      SmartDialog.showToast(err);
      return;
    }
    asrSubtitleEnabled.value = true;
    if (lang.isOffline) {
      await _runFullRecognition(audioUrl, lang, modelDir);
    } else {
      _startAsrPipeline(audioUrl);
    }
  }

  /// 公开：生成 SRT 字幕内容（按时间排序）
  String buildSrtContent(List<({Duration start, Duration end, String text})> segs) {
    final sorted = [...segs]..sort((a, b) => a.start.compareTo(b.start));
    final buf = StringBuffer();
    var i = 1;
    for (final s in sorted) {
      buf.writeln(i);
      buf.writeln(
        '${_fmtSrt(s.start)} --> ${_fmtSrt(s.end)}',
      );
      buf.writeln(s.text);
      buf.writeln();
      i++;
    }
    return buf.toString();
  }

  String _fmtSrt(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    final ms = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$h:$m:$s,$ms';
  }

  Future<void> _runFullOcrRecognition(String audioUrl) async {
    if (_ocrFullRunning) return;
    _ocrFullRunning = true;
    ocrFullReady = false;
    ocrFullSegments.clear();
    ocrSubtitleText.value = '正在提取视频帧…';
    ocrFullProgress.value = '正在提取视频帧…';
    wlog('OCR 整段识别开始');
    wlog('  视频源: ${audioUrl.length > 90 ? audioUrl.substring(0, 90) + '…' : audioUrl}');
    wlog('  取帧间隔: 1000ms, OCR: fast_paddle(560px)');
    final tmp = await getTemporaryDirectory();
    final frameDir =
        '${tmp.path}/ocr_frames_${DateTime.now().millisecondsSinceEpoch}';
    try {
      final completer = Completer<String>();
      _ocrFrameBridge.onDone = (dir, count) {
        if (!completer.isCompleted) completer.complete('$dir|$count');
      };
      _ocrFrameBridge.onFailed = (e) {
        if (!completer.isCompleted) completer.completeError(Exception(e));
      };
      _asrLog('[OCRFull] start frame extraction');
      _ocrFrameBridge.start(url: audioUrl, outDir: frameDir, sampleEveryMs: 1000);
      final res = await completer.future.timeout(const Duration(minutes: 5));
      final parts = res.split('|');
      final count = int.parse(parts[1]);
      _asrLog('[OCRFull] frames extracted: $count');
      wlog('  视频帧提取完成: $count 帧');
      if (count == 0) {
        ocrSubtitleText.value = '';
        ocrFullProgress.value = '';
        wlog('  错误: 未提取到视频帧');
        SmartDialog.showToast('未提取到视频帧');
        return;
      }
      ocrSubtitleText.value = '正在识别画面文字（$count 帧）…';
      ocrFullProgress.value = '正在识别画面文字（$count 帧）…';
      final dir = parts[0];
      var lastText = '';
      var segStart = Duration.zero;
      var emptyCount = 0;
      var textCount = 0;
      for (var i = 0; i < count; i++) {
        final f = File('$dir/f${i.toString().padLeft(5, '0')}.jpg');
        if (!await f.exists()) {
          if (i < 3) wlog('  帧 $i 文件不存在: $f');
          continue;
        }
        final rawText = (await OcrService.instance.recognize(f.path))?.trim() ?? '';
        final text = _filterOcrWatermark(rawText);
        if (text.isEmpty) {
          emptyCount++;
        } else {
          textCount++;
          if (textCount <= 3 || i % 30 == 0) {
            wlog('  帧 ${i * 1000 ~/ 1000}s: $text');
          }
        }
        final t = Duration(milliseconds: i * 1000);
        if (text.isNotEmpty && !_sameOcrText(lastText, text)) {
          if (lastText.isNotEmpty) {
            ocrFullSegments.add((start: segStart, end: t, text: lastText));
          }
          lastText = text;
          segStart = t;
        }
        if (i % 20 == 19) {
          ocrFullProgress.value = '正在识别画面文字 ${i + 1}/$count…';
        }
      }
      if (lastText.isNotEmpty) {
        ocrFullSegments.add((
          start: segStart,
          end: Duration(milliseconds: count * 1000),
          text: lastText,
        ));
      }
      ocrFullReady = true;
      ocrSubtitleText.value = '';
      ocrFullProgress.value = '识别完成：${ocrFullSegments.length} 段';
      wlog('  识别完成: ${ocrFullSegments.length} 段 (有文字帧 $textCount, 空帧 $emptyCount)');
      for (var i = 0; i < ocrFullSegments.length && i < 10; i++) {
        wlog('  段$i [${_fmtSrt(ocrFullSegments[i].start)} - ${_fmtSrt(ocrFullSegments[i].end)}] ${ocrFullSegments[i].text}');
      }
      _asrLog('[OCRFull] done: ${ocrFullSegments.length} segments');
      if (ocrFullSegments.isEmpty) {
        SmartDialog.showToast('未识别到画面文字');
      }
      try {
        Directory(dir).deleteSync(recursive: true);
      } catch (_) {}
    } catch (e) {
      _asrLog('[OCRFull] error: $e');
      ocrSubtitleText.value = '';
      ocrFullProgress.value = 'OCR 失败：$e';
      wlog('  OCR 失败: $e');
      SmartDialog.showToast('整段 OCR 失败: $e');
    } finally {
      _ocrFullRunning = false;
    }
  }

  /// 当前 OCR 整段时间轴段
  ({Duration start, Duration end, String text})? get _currentOcrSegment {
    if (!ocrFullReady || ocrFullSegments.isEmpty) return null;
    final posMs = position.inMilliseconds;
    for (final seg in ocrFullSegments) {
      if (posMs >= seg.start.inMilliseconds &&
          posMs < seg.end.inMilliseconds) {
        return seg;
      }
    }
    return null;
  }

  bool _sameOcrText(String a, String b) {
    final na = a.replaceAll(RegExp(r'\s'), '');
    final nb = b.replaceAll(RegExp(r'\s'), '');
    if (na.isEmpty || nb.isEmpty) return na == nb; // 空串仅相等才相同（防 contains('')恒true）
    return na == nb || na.contains(nb) || nb.contains(na);
  }

  /// ═══ B 站 UP 主水印过滤 ═══
  /// fast_paddle_ocr 只返回文本不带坐标，无法按区域排除，
  /// 故用「形态特征（即时） + 长稳静态（兜底）」两层启发式过滤水印行。
  /// 一行连续跨 N 个不同文本结果仍存在 → 判定为静态水印/台标。
  static const int _watermarkStableThreshold = 6;
  final Map<String, int> _watermarkStableCount = {};
  Set<String> _lastOcrLines = const {};

  /// 过滤 OCR 结果中的水印行，返回过滤后的文本。
  /// 长稳计数只在「文本发生变化」的帧更新：
  /// 字幕行至多跨 1-2 次变化即消失，静态水印则逐次累加直至被剔除。
  String _filterOcrWatermark(String text) {
    if (text.isEmpty) return '';
    final lines = text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (lines.isEmpty) return '';
    final cur = lines.toSet();
    if (!_sameLineSet(cur, _lastOcrLines)) {
      _watermarkStableCount.removeWhere((k, v) => !cur.contains(k));
      for (final l in cur) {
        _watermarkStableCount[l] = (_watermarkStableCount[l] ?? 0) + 1;
      }
      _lastOcrLines = cur;
    }
    return cur
        .where((l) =>
            !_isWatermarkLine(l) &&
            (_watermarkStableCount[l] ?? 0) < _watermarkStableThreshold)
        .join('\n');
  }

  bool _sameLineSet(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  /// 形态特征判定：B 站播放器水印（bilibili logo + 数字 ID）、
  /// UP 主头像水印（@昵称）、防伪码、UID 行、台标
  bool _isWatermarkLine(String line) {
    // B 站水印主体：bilibili logo 文字（可带数字 ID，如 "bilibili 12345678"）。
    // 仅当整行较短时判定为水印，避免误伤含 bilibili 的长句字幕。
    final lower = line.toLowerCase();
    if (lower.contains('bilibili') || line.contains('哔哩哔哩')) {
      return line.length <= 16;
    }
    if (line == 'b站') return true;
    // UP 主头像水印：头像 + @昵称
    if (line.contains('@')) return true;
    // 防伪码随机码：字母+数字混合，2-8 位（如 aB3x）
    if (RegExp(r'^[A-Za-z0-9]{2,8}$').hasMatch(line) &&
        RegExp(r'[A-Za-z]').hasMatch(line) &&
        RegExp(r'[0-9]').hasMatch(line)) {
      return true;
    }
    // UID 行：UID:123456 / uid：123456
    if (RegExp(r'^UID[:：]?\s*\d+$', caseSensitive: false).hasMatch(line)) {
      return true;
    }
    // 纯数字 5-10 位（B 站用户 ID）
    if (RegExp(r'^\d{5,10}$').hasMatch(line)) return true;
    return false;
  }

  /// ═══ ASR 语音字幕（流式识别：MediaCodec 音轨 PCM → sherpa-onnx）═══
  /// ASR 为主、OCR 辅助：融合文本优先显示语音识别结果，
  /// ASR 静默（无人声/纯画面文字）时回落到 OCR 画面文字。
  /// 日志桥：release 下 Dart print 不输出到 logcat，经 asr_audio 通道转发 Kotlin Log.i
  void _asrLog(String msg) {
    try {
      _asrBridge.log(msg);
    } catch (_) {}
  }

  final RxBool asrSubtitleEnabled = false.obs;
  final RxString asrSubtitleText = ''.obs;
  final List<({Duration start, Duration end, String text})> asrSegments = [];
  bool _asrLooping = false;
  bool _asrDecoding = false;
  int _emptyDecodeCount = 0;
  String? _asrModelDir;
  AsrLanguageInfo? _asrModelLang;
  int _pcmBlockCount = 0;
  int _asrTextCount = 0;
  final AsrAudioBridge _asrBridge = AsrAudioBridge();

  /// 融合字幕文本（ASR 整段 > OCR 整段 > 实时 ASR > 实时 OCR）
  String get fusedSubtitleText {
    if (asrFullReady) {
      // 读取 asrFullCursor 建立 Rx 依赖，驱动浮层按播放进度刷新
      asrFullCursor.value;
      final seg = _currentAsrSegment;
      if (seg != null) return seg.text;
      return '';
    }
    if (ocrFullReady) {
      asrFullCursor.value;
      final seg = _currentOcrSegment;
      if (seg != null) return seg.text;
      return '';
    }
    final asr = asrSubtitleText.value.trim();
    if (asr.isNotEmpty) return asr;
    return ocrSubtitleText.value;
  }

  bool get subtitleEnabled =>
      ocrSubtitleEnabled.value || asrSubtitleEnabled.value;

  Future<void> toggleAsrSubtitle() async {
    if (asrSubtitleEnabled.value) {
      _stopAsr();
      return;
    }
    if (isLive) {
      SmartDialog.showToast('直播暂不支持 ASR 字幕');
      return;
    }
    final audioUrl = dataSource.audioSource;
    _asrLog('[ASR] toggle: audioSource=${audioUrl == null ? "null" : (audioUrl.isEmpty ? "empty" : "len=${audioUrl.length}")}');
    if (audioUrl == null || audioUrl.isEmpty) {
      SmartDialog.showToast('当前视频无独立音轨，ASR 不可用');
      return;
    }
    if (!Get.isRegistered<AsrService>()) {
      Get.put(AsrService(), permanent: true);
    }
    if (!Get.isRegistered<AsrModelManager>()) {
      Get.put(AsrModelManager(), permanent: true);
    }
    // 选择已下载的模型：离线(SenseVoice/Whisper)优先（歌曲场景），否则流式
    await AsrModelManager.instance.refreshStatus();
    String? langCode;
    for (final l in AsrModelManager.languages) {
      if (AsrModelManager.instance.downloadedLangs.contains(l.code)) {
        if (langCode == null) langCode = l.code;
        if (l.isOffline) langCode = l.code;
      }
    }
    _asrLog('[ASR] toggle: langCode=$langCode downloaded=${AsrModelManager.instance.downloadedLangs.toSet()}');
    if (langCode == null) {
      SmartDialog.showToast('请先到 设置 → 其他 → ASR 语言包 下载模型');
      return;
    }
    final modelDir = await AsrModelManager.instance.langDir(langCode);
    final lang = AsrModelManager.instance.langOf(langCode);
    // 模型切换时释放旧模型
    if (AsrService.instance.isLoaded && _asrModelDir != modelDir) {
      AsrService.instance.dispose();
    }
    _asrModelDir = modelDir;
    _asrModelLang = lang;
    final err = await AsrService.instance.init(lang!, modelDir);
    _asrLog('[ASR] toggle: init err=$err modelDir=$modelDir type=${lang.type}');
    if (err != null) {
      SmartDialog.showToast(err);
      return;
    }
    asrSubtitleEnabled.value = true;
    if (lang.isOffline) {
      // 离线模型：整段识别生成时间轴字幕（播放同步显示）
      _runFullRecognition(audioUrl, lang, modelDir);
    } else {
      _startAsrPipeline(audioUrl);
    }
  }

  /// ═══ 整段识别（离线模型：生成时间轴字幕，播放同步）═══
  bool asrFullReady = false;
  final RxInt asrFullCursor = 0.obs; // 当前播放毫秒，驱动浮层更新
  bool _asrFullRunning = false;

  Future<void> _runFullRecognition(
    String audioUrl,
    AsrLanguageInfo lang,
    String modelDir,
  ) async {
    if (_asrFullRunning) return;
    _asrFullRunning = true;
    asrFullReady = false;
    asrSegments.clear();
    asrSubtitleText.value = '正在识别整段音频…';
    asrFullProgress.value = '正在解码整段音频…';
    wlog('ASR 整段识别开始');
    wlog('  模型: ${lang.label} (${lang.type})');
    wlog('  模型目录: $modelDir');
    wlog('  段长: 12000ms, 重叠: 2000ms');
    final tmp = await getTemporaryDirectory();
    final rawPath =
        '${tmp.path}/asr_full_${DateTime.now().millisecondsSinceEpoch}.raw';
    try {
      final completer = Completer<String>();
      _asrBridge.onAllDone = (p) {
        if (!completer.isCompleted) completer.complete(p);
      };
      _asrBridge.onAllFailed = (e) {
        if (!completer.isCompleted) completer.completeError(Exception(e));
      };
      _asrLog('[ASR] full: decodeAll start');
      _asrBridge.decodeAll(url: audioUrl, outPath: rawPath);
      final path = await completer.future.timeout(const Duration(minutes: 5));
      _asrLog('[ASR] full: decoded $path');
      wlog('  音轨解码完成');
      asrSubtitleText.value = '解码完成，正在识别…';
      asrFullProgress.value = '正在识别语音（SenseVoice/Whisper）…';
      final segs = await recognizeFullAudio(
        lang: lang,
        modelDir: modelDir,
        rawPath: path,
        segmentMs: 12000,
        overlapMs: 2000,
      );
      asrSegments.addAll(segs);
      asrFullReady = true;
      asrSubtitleText.value = '';
      asrFullProgress.value = '识别完成：${segs.length} 段';
      wlog('  识别完成: ${segs.length} 段');
      for (var i = 0; i < segs.length && i < 10; i++) {
        wlog('  段$i [${_fmtSrt(segs[i].start)} - ${_fmtSrt(segs[i].end)}] ${segs[i].text}');
      }
      _asrLog('[ASR] full done: ${segs.length} segments');
      for (var i = 0; i < segs.length && i < 12; i++) {
        _asrLog('[ASR] seg$i: ${segs[i].start.inMilliseconds}ms-${segs[i].end.inMilliseconds}ms ${segs[i].text}');
      }
      if (segs.isEmpty) {
        SmartDialog.showToast('未识别到内容');
      }
    } catch (e) {
      _asrLog('[ASR] full error: $e');
      asrSubtitleText.value = '';
      asrFullProgress.value = 'ASR 失败：$e';
      wlog('  ASR 失败: $e');
      SmartDialog.showToast('整段识别失败: $e');
    } finally {
      _asrFullRunning = false;
      try {
        final f = File(rawPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// 当前时间轴字幕段（整段识别完成后按播放进度取）
  ({Duration start, Duration end, String text})? get _currentAsrSegment {
    if (!asrFullReady || asrSegments.isEmpty) return null;
    final posMs = position.inMilliseconds;
    for (final seg in asrSegments) {
      if (posMs >= seg.start.inMilliseconds &&
          posMs < seg.end.inMilliseconds) {
        return seg;
      }
    }
    return null;
  }

  /// Whisper 分段识别缓冲（约 6 秒 @16k）
  static const int _whisperSegmentSamples = 16000 * 6;
  Float32List _whisperBuffer = Float32List(0);
  bool _whisperRecognizing = false;

  void _startAsrPipeline(String audioUrl) {
    AsrService.instance.reset();
    asrSubtitleText.value = '';
    _pcmBlockCount = 0;
    _asrTextCount = 0;
    _whisperBuffer = Float32List(0);
    _asrLog('[ASR] pipeline start, type=${_asrModelLang?.type}, audioUrl head=${audioUrl.length > 80 ? audioUrl.substring(0, 80) : audioUrl}');
    _asrBridge.onPcm = (pcm) {
      if (!asrSubtitleEnabled.value) return;
      if (_pcmBlockCount < 3) {
        final head = pcm.length >= 5 ? pcm.sublist(0, 5) : pcm;
        _asrLog('[ASR] pcm block ${_pcmBlockCount + 1}: ${pcm.length} samples head=$head');
      }
      _pcmBlockCount++;
      if (_asrModelLang?.isOffline == true) {
        // Whisper/SenseVoice：缓冲到 6 秒后分段识别（识别期间继续缓冲）
        final buf = Float32List(_whisperBuffer.length + pcm.length)
          ..setAll(0, _whisperBuffer)
          ..setAll(_whisperBuffer.length, pcm);
        _whisperBuffer = buf;
        if (_whisperBuffer.length >= _whisperSegmentSamples &&
            !_whisperRecognizing) {
          final seg = _whisperBuffer;
          _whisperBuffer = Float32List(0);
          _whisperRecognizing = true;
          _recognizeWhisperSegment(seg);
        }
      } else {
        AsrService.instance.acceptWaveform(pcm);
      }
    };
    _asrBridge.onEnded = () {
      // 音轨解码自然结束（播放到末尾）
    };
    _asrBridge.start(
      url: audioUrl,
      startMs: position.inMilliseconds,
      note: 'modelDir=$_asrModelDir',
    );
    if (_asrModelLang?.isOffline != true) {
      _asrLoop();
    }
  }

  /// Whisper 离线分段识别（主 isolate，识别期间 UI 可能短暂卡顿）
  Future<void> _recognizeWhisperSegment(Float32List seg) async {
    try {
      final sw = Stopwatch()..start();
      final text =
          (await AsrService.instance.recognizeSegment(seg))?.trim() ?? '';
      sw.stop();
      _asrLog('[ASR] whisper seg=${seg.length ~/ 16000}s '
          'decode=${sw.elapsed.inMilliseconds}ms text=$text');
      if (text.isNotEmpty) {
        asrSubtitleText.value = text;
        _asrTextCount++;
      }
    } catch (e) {
      _asrLog('[ASR] whisper error: $e');
    } finally {
      _whisperRecognizing = false;
    }
  }

  Future<void> _asrLoop() async {
    if (_asrLooping) return;
    _asrLooping = true;
    var lastText = '';
    var segStart = position;
    try {
      while (asrSubtitleEnabled.value) {
        await Future.delayed(const Duration(milliseconds: 120));
        if (!asrSubtitleEnabled.value || _asrDecoding) continue;
        _asrDecoding = true;
        try {
          final text = AsrService.instance.decodeAndGetText().trim();
          if (_asrTextCount < 3 && text.isNotEmpty) {
            _asrLog('[ASR] text#${_asrTextCount + 1}: $text');
          }
          if (text.isNotEmpty) {
            _asrTextCount++;
            _emptyDecodeCount = 0;
          } else {
            _emptyDecodeCount++;
            // 心跳：确认 decode 循环存活（每 ~12s 一次）
            if (_emptyDecodeCount == 100) {
              _asrLog('[ASR] decode alive, still empty (pcm=$_pcmBlockCount)');
              _emptyDecodeCount = 0;
            }
          }
          // 句末（静音检测）：定稿当前句入字幕段，开启新句
          if (AsrService.instance.isEndpoint) {
            final finalText = AsrService.instance.finalizeSegment().trim();
            if (finalText.isNotEmpty && !_sameOcrText(lastText, finalText)) {
              _addAsrSegment(segStart, position, finalText);
            }
            lastText = '';
            segStart = position;
          } else if (text.isNotEmpty) {
            lastText = text;
          }
          asrSubtitleText.value = text;
        } catch (e) {
          _asrLog('[ASR] decode error: $e');
        } finally {
          _asrDecoding = false;
        }
      }
    } finally {
      _asrLooping = false;
    }
  }

  void _addAsrSegment(Duration start, Duration end, String text) {
    if (end <= start || text.isEmpty) return;
    asrSegments.add((start: start, end: end, text: text));
  }

  void _stopAsr() {
    asrSubtitleEnabled.value = false;
    asrSubtitleText.value = '';
    asrFullReady = false;
    asrSegments.clear();
    _whisperBuffer = Float32List(0);
    _asrBridge.dispose();
    // AsrService 可能从未注册（从未开启过 ASR），dispose 时需保护
    if (Get.isRegistered<AsrService>()) {
      AsrService.instance.reset();
    }
  }

  /// seek/暂停恢复/倍速等需要重对齐时重启 ASR 音频流
  Future<void> _restartAsrIfNeeded() async {
    if (!asrSubtitleEnabled.value) return;
    final audioUrl = dataSource.audioSource;
    if (audioUrl == null || audioUrl.isEmpty) return;
    AsrService.instance.reset();
    asrSubtitleText.value = '';
    _asrBridge.start(
      url: audioUrl,
      startMs: position.inMilliseconds,
      note: 'modelDir=$_asrModelDir',
    );
  }

  static void updatePlayCount() {
    if (_instance?._playerCount == 1) {
      _instance?.dispose();
    } else {
      _instance?._playerCount -= 1;
    }
  }

  void setContinuePlayInBackground() {
    continuePlayInBackground.value = !continuePlayInBackground.value;
    if (!tempPlayerConf) {
      setting.put(
        SettingBoxKey.continuePlayInBackground,
        continuePlayInBackground.value,
      );
    }
  }

  void setOnlyPlayAudio() {
    onlyPlayAudio.value = !onlyPlayAudio.value;
    videoPlayerController?.setVideoTrack(
      onlyPlayAudio.value ? VideoTrack.no() : VideoTrack.auto(),
    );
  }

  late final Map<String, ui.Image?> previewCache = {};
  LoadingState<VideoShotData>? videoShot;
  late final RxBool showPreview = false.obs;
  late final showSeekPreview = Pref.showSeekPreview;
  late final previewIndex = RxnInt();

  void updatePreviewIndex(int seconds) {
    if (videoShot == null) {
      videoShot = LoadingState.loading();
      getVideoShot();
      return;
    }
    if (videoShot case Success(:final response)) {
      showPreview.value = true;
      previewIndex.value = max(
        0,
        (response.index.where((item) => item <= seconds).length - 2),
      );
    }
  }

  void _clearPreview() {
    showPreview.value = false;
    previewIndex.value = null;
    videoShot = null;
    for (final i in previewCache.values) {
      i?.dispose();
    }
    previewCache.clear();
  }

  Future<void> getVideoShot() async {
    videoShot = await VideoHttp.videoshot(bvid: bvid, cid: cid!);
  }

  Future<void> takeScreenshot() async {
    SmartDialog.showToast('截图中');
    final time = DurationUtils.formatDuration(
      position.inMilliseconds / 1000,
    ).replaceAll(':', '-');
    final image = await videoPlayerController?.screenshot();
    if (image != null) {
      SmartDialog.showToast('点击弹窗保存截图');
      showDialog(
        context: Get.context!,
        builder: (context) => GestureDetector(
          onTap: () async {
            final bytes = await image.toByteData(format: .png);
            if (bytes != null) {
              ImageUtils.saveByteImg(
                bytes: bytes.buffer.asUint8List(),
                fileName: 'screenshot_${cid}_$time',
              );
            }
            Get.back();
          },
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: min(MediaQuery.widthOf(context) / 3, 350),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      width: 5,
                      color: ColorScheme.of(context).surface,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: RawImage(image: image),
                  ),
                ),
              ),
            ),
          ),
        ),
      ).whenComplete(image.dispose);
    } else {
      SmartDialog.showToast('截图失败');
    }
  }

  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (didPop) {
      if (playerStatus.isPlaying) {
        pause();
      }

      setPlayCallBack(null);

      if (Platform.isAndroid && _playerCount <= 1) {
        _disableAutoEnterPip();
        if (!setSystemBrightness) {
          ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
        }
      }

      return;
    }

    if (controlsLock.value) {
      onLockControl(false);
      return;
    }
    if (isDesktopPip) {
      exitDesktopPip();
      return;
    }
    if (isFullScreen.value) {
      triggerFullScreen(status: false);
      return;
    }
    Get.back();
  }
}
