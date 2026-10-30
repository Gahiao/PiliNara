import 'dart:async' show Completer, StreamSubscription, Timer, unawaited;
import 'dart:convert' show ascii, utf8;
import 'dart:io' show Platform;
import 'dart:math' show max, min;
import 'dart:ui' as ui;

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/audio_normalization.dart';
import 'package:PiliPlus/models/common/dm_chart_source.dart';
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
import 'package:PiliPlus/plugin/pl_player/models/hdr_config.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/speed_lock_hint.dart';
import 'package:PiliPlus/plugin/pl_player/models/video_fit_type.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/plugin/pl_player/utils/native_video_surface_channel.dart';
import 'package:PiliPlus/services/live_pip_overlay_service.dart';
import 'package:PiliPlus/services/pip_overlay_service.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/asset_utils.dart';
import 'package:PiliPlus/utils/desktop/window_controller.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/box_ext.dart';
import 'package:PiliPlus/utils/extension/native_geometry_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/ios/pip_helper.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:archive/archive.dart' show getCrc32;
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/foundation.dart'
    show ValueNotifier, clampDouble, kDebugMode;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart'
    show DeviceOrientation, HapticFeedback, KeyDownEvent;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:nativeapi/nativeapi.dart' as nativeapi show Size, Rectangle;
import 'package:path/path.dart' as path;
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';
import 'package:PiliPlus/plugin/pl_player/models/auto_audio_only_state.dart';

typedef PlayCallback = Future<void>? Function();
typedef PlayerInitCallback = Future<void> Function();
typedef PlayOwner = ({String tag, Type? type});

class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
  Player? _videoPlayerController;
  VideoController? _videoController;

  static PlPlayerController? _instance;

  final Rx<PlayerStatus> _playerStatus = Rx(.paused);
  PlayerStatus get playerStatus => _playerStatus.value;
  set playerStatus(PlayerStatus value) => _playerStatus.value = value;

  final Rx<DataStatus> dataStatus = Rx(.none);

  Duration? seekToPos;
  bool hasToasted = false;
  final RxBool isSeeking = false.obs;

  final RxInt position = RxInt(0);
  final RxInt seekPosition = RxInt(0);
  int get progress => isSeeking.value ? seekPosition.value : position.value;

  int get positionInMilliseconds => _useMedia3Dovi
      ? position.value * 1000
      : videoPlayerController?.state.position.inMilliseconds ?? 0;

  final RxInt buffered = RxInt(0);

  final RxInt duration = RxInt(0);

  int durationInMilliseconds = 0;

  void updateDuration(Duration value) {
    duration.value = value.inSeconds;
    durationInMilliseconds = value.inMilliseconds;
  }

  int _playerCount = 0;

  late double lastPlaybackSpeed = 1.0;
  final RxDouble _playbackSpeed = Pref.playSpeedDefault.obs;
  late final RxDouble _longPressSpeed = Pref.longPressSpeedDefault.obs;

  final RxDouble volume = RxDouble(
    PlatformUtils.isDesktop ? Pref.desktopVolume : 1.0,
  );
  final setSystemBrightness = Pref.setSystemBrightness;

  /// 系统音量（仅在应用内音量模式下用于追踪当前系统音量）
  final RxDouble systemVolume = RxDouble(1.0);

  /// duck 相关状态
  bool _isDucked = false;
  double _preDuckVolume = 1.0;
  final RxDouble brightness = (-1.0).obs;

  final RxBool showControls = false.obs;

  final RxBool showBrightnessStatus = false.obs;

  final RxBool longPressStatus = false.obs;

  /// 长按倍速锁定（仅当次播放生效，不持久化）
  bool speedLocked = false;

  /// 长按倍速锁定提示（六态，驱动播放器顶部 toast）
  final Rx<SpeedLockHint> speedLockHint = SpeedLockHint.none.obs;

  /// 长按中滑动越线后的预备态：松手才提交锁定/解锁
  bool _speedLockArmed = false;
  Timer? _speedLockHintTimer;

  final RxBool controlsLock = false.obs;

  final RxBool isFullScreen = false.obs;
  void Function(bool isFullScreen)? onFullScreenChanged;
  // 系统原生 PiP 状态
  final RxBool isNativePip = false.obs;
  bool isLive = false;

  VoidCallback? onPortraitSlideUp;
  VoidCallback? onPortraitSlideDown;
  bool Function()? onPortraitSlideEnabled;

  bool get enablePortraitSlideVideo =>
      Pref.portraitSlideVideo &&
          onPortraitSlideUp != null &&
          onPortraitSlideEnabled?.call() == true &&
          isFullScreen.value &&
          !isLive;

  bool _isVertical = false;

  final Rx<VideoFitType> videoFit = Rx(.contain);

  late final RxBool continuePlayInBackground =
      Pref.continuePlayInBackground.obs;

  bool _autoPlay = false;

  // 记录历史记录
  int? _aid;
  String? _bvid;
  int? cid;
  int? roomId;
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
  StreamSubscription? _subForSeek;

  Box setting = GStorage.setting;

  // final Durations durations;

  String get bvid => _bvid!;

  bool isCurrentVideoSource({
    required String bvid,
    required int cid,
  }) =>
      dataStatus.value == DataStatus.loaded &&
      _bvid == bvid &&
      this.cid == cid;

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

  /// 后台自动只听音频状态机
  AutoAudioOnlyState _autoAudioState = AutoAudioOnlyState.idle;
  Timer? _autoAudioOnlyTimer;
  bool _audioReopened = false;
  AppLifecycleState? _lastAppLifecycleState;
  bool _autoAudioRestoreInProgress = false;
  int _autoAudioRestoreGeneration = 0;
  Timer? _autoAudioRestoreTimer;
  StreamSubscription? _autoAudioRestoreSubscription;
  Completer<bool>? _autoAudioRestoreCompleter;
  final RxBool suppressBufferingIndicator = false.obs;

  /// 自动恢复需要重初始化的回调（视频→playerInit，直播→queryLiveUrl）
  PlayerInitCallback? onNeedsPlayerInit;

  /// 镜像
  late final RxBool flipX = false.obs;

  late final RxBool flipY = false.obs;

  final RxBool isBuffering = true.obs;

  /// 全屏方向
  // ignore: unnecessary_getters_setters
  bool get isVertical => _isVertical;

  set isVertical(bool value) {
    _isVertical = value;
  }

  /// 弹幕开关
  late final RxBool enableShowDanmaku = Pref.enableShowDanmaku.obs;
  late final RxBool enableShowLiveDanmaku = Pref.enableShowLiveDanmaku.obs;
  RxBool get enableShowDanmakuAdaptive =>
      isLive ? enableShowLiveDanmaku : enableShowDanmaku;

  late final bool autoPiP = Pref.autoPiP;
  bool get isPipMode =>
      isNativePip.value ||
      (Platform.isAndroid && AndroidHelper.isPipMode) ||
      (PlatformUtils.isDesktop && isDesktopPip);
  late bool isDesktopPip = false;
  late nativeapi.Rectangle _lastWindowBounds;
  static nativeapi.Rectangle? _lastPipBounds;

  nativeapi.Rectangle _adjustPipBounds(
    nativeapi.Rectangle lastRect,
    nativeapi.Size size,
    double aspectRatio,
  ) {
    final lastSize = lastRect.size;
    final lastOrientation = lastSize.orientation;
    final orientation = size.orientation;

    if (lastOrientation != orientation) {
      final double width, height;
      switch (orientation) {
        case .portrait:
          if (lastSize.width > size.height) {
            height = min(lastSize.width, _lastWindowBounds.size.height);
            width = height * aspectRatio;
          } else {
            height = size.height;
            width = size.width;
          }
        case .landscape:
          if (lastSize.height > size.width) {
            width = lastSize.height;
            height = width / aspectRatio;
          } else {
            height = size.height;
            width = size.width;
          }
      }

      return _lastPipBounds = nativeapi.Rectangle(
        x: lastRect.x,
        y: lastRect.y,
        width: width,
        height: height,
      );
    }
    return _lastPipBounds = nativeapi.Rectangle(
      x: lastRect.x,
      y: lastRect.y,
      width: lastSize.width,
      height: lastSize.width / aspectRatio,
    );
  }

  bool updatePipBounds(Window window) {
    if (isDesktopPip) {
      _lastPipBounds = window.bounds;
      return true;
    }
    return false;
  }

  late final showWindowTitleBar = Pref.showWindowTitleBar;
  late final RxBool isAlwaysOnTop = false.obs;
  void setAlwaysOnTop(bool value, {Window? window}) {
    window ??= WindowController.instance.window;
    if (window == null) return;

    isAlwaysOnTop.value = value;
    window.isAlwaysOnTop = value;
  }

  void exitDesktopPip() {
    final window = WindowController.instance.window;
    if (window == null) return;

    isDesktopPip = false;
    if (showWindowTitleBar) window.titleBarStyle = .normal;
    window
      ..minimumSize = DeviceUtils.desktopMinSize
      ..bounds = _lastWindowBounds
      ..aspectRatio = 0;
    setAlwaysOnTop(false, window: window);
  }

  void enterDesktopPip() {
    final window = WindowController.instance.window;
    if (window == null) return;

    if (isFullScreen.value) return;

    isDesktopPip = true;

    _lastWindowBounds = window.bounds;

    if (showWindowTitleBar) window.titleBarStyle = .hidden;

    const shortSide = 280.0;
    const minShortSide = 160.0;
    final nativeapi.Size size;
    final nativeapi.Size minimumSize;
    final state = videoPlayerController!.state;
    int width = state.width;
    int height = state.height;
    if (width == 0) width = this.width ?? 16;
    if (height == 0) height = this.height ?? 9;
    final aspectRatio = width / height;
    if (height > width) {
      size = nativeapi.Size(width: shortSide, height: shortSide / aspectRatio);
      minimumSize = nativeapi.Size(
        width: minShortSide,
        height: minShortSide / aspectRatio,
      );
    } else {
      size = nativeapi.Size(width: shortSide * aspectRatio, height: shortSide);
      minimumSize = nativeapi.Size(
        width: minShortSide * aspectRatio,
        height: minShortSide,
      );
    }

    window.minimumSize = minimumSize;
    setAlwaysOnTop(true, window: window);
    if (_lastPipBounds != null) {
      window.bounds = _adjustPipBounds(_lastPipBounds!, size, aspectRatio);
    } else {
      window.contentSize = size;
    }
    window.aspectRatio = aspectRatio;
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

  bool get _isInInAppPip {
    return PipOverlayService.isInPipMode || LivePipOverlayService.isInPipMode;
  }

  void enterPip({bool autoEnter = false}) {
    if (videoPlayerController case NativePlayer(:final state)) {
      if (Platform.isIOS) {
        if (videoController?.id.value case final textureId?) {
          IOSPipHelper.enter(
            textureId,
            width: state.width == 0 ? width : state.width,
            height: state.height == 0 ? height : state.height,
            autoEnter: autoEnter,
            state: _iosPipState(state),
          );
        }
        return;
      }
      PageUtils.enterPip(
        autoEnter: autoEnter,
        width: state.width == 0 ? width : state.width,
        height: state.height == 0 ? height : state.height,
        isLive: isLive,
        isPlaying: playerStatus.isPlaying,
      );
    }
  }

  // void _disableAutoEnterPipIfNeeded() {
  //   // 对齐上游逻辑，如果是从视频页返回到非视频页，则切断 Auto-Enter PiP
  //   if (!_isPreviousVideoPage) {
  //     _disableAutoEnterPip();
  //   }
  // }

  void disableAutoEnterPip() => _disableAutoEnterPip();

  void _disableAutoEnterPip() {
    if (_isAutoEnterPip) {
      if (Platform.isIOS) {
        IOSPipHelper.disableAutoEnter();
      } else {
        PiliAndroidHelper.disableAutoEnterPip();
      }
    }
  }

  Map<String, Object> _iosPipState(PlayerState state, [Duration? position]) {
    return {
      'isPlaying': playerStatus.isPlaying,
      'isBuffering': isBuffering.value,
      'isLive': isLive,
      'position': (position ?? state.position).inMilliseconds,
      'duration': durationInMilliseconds,
      'speed': state.rate,
    };
  }

  void _updateIOSPip([Duration? position]) {
    if (Platform.isIOS && IOSPipHelper.needsUpdate) {
      if (_videoPlayerController case final player?) {
        IOSPipHelper.update(_iosPipState(player.state, position));
      }
    }
  }

  // 弹幕相关配置
  late final enableTapDm = PlatformUtils.isMobile && Pref.enableTapDm;
  late RuleFilter filters = Pref.danmakuFilterRule;
  // 关联弹幕控制器
  DanmakuController<DanmakuExtra>? danmakuController;

  /// 弹幕遮挡区（弹幕层坐标系）。PLVideoPlayer 的几何驱动写入，PlDanmaku 消费；
  /// 两端都以此对象为交接点，画布重建（切 P）时 PlDanmaku 从这里补读。
  final ValueNotifier<Path?> danmakuMaskPath = ValueNotifier(null);
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
  // 副字幕(位置边距与主字幕共用)
  late double subtitleSecondaryFontScale = Pref.subtitleSecondaryFontScale;
  late double subtitleSecondaryFontScaleFS = Pref.subtitleSecondaryFontScaleFS;
  late double subtitleSecondaryBgOpacity = Pref.subtitleSecondaryBgOpacity;
  late double subtitleSecondaryStrokeWidth = Pref.subtitleSecondaryStrokeWidth;
  late int subtitleSecondaryFontWeight = Pref.subtitleSecondaryFontWeight;
  late double subtitleSecondarySpacing = Pref.subtitleSecondarySpacing;

  // settings
  late final showFSActionItem = Pref.showFSActionItem;
  late final enableShrinkVideoSize = Pref.enableShrinkVideoSize;
  late final enablePinchRotate = Pref.enablePinchRotate;
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
  DmChartSource get dmChartSource => Pref.dmChartSource;
  bool get showDmChart => dmChartSource.isEnabled;
  late final showViewPoints = Pref.showViewPoints;
  late final showFsScreenshotBtn = Pref.showFsScreenshotBtn;
  late final showFsLockBtn = Pref.showFsLockBtn;
  late final showFsLockBtnRight = Pref.showFsLockBtnRight;
  late final lockFsRotation = Pref.lockFsRotation;
  late final keyboardControl = Pref.keyboardControl;
  late final uiScale = Pref.uiScale;

  late final bool autoEnterFullScreen = Pref.autoEnterFullScreen;
  late final bool autoExitFullscreen = Pref.autoExitFullscreen;
  late final bool autoPlayEnable = Pref.autoPlayEnable;
  late final bool enableVerticalExpand = Pref.enableVerticalExpand;
  late final bool pipNoDanmaku = Pref.pipNoDanmaku;

  late final bool tempPlayerConf = Pref.tempPlayerConf;

  static const int videoPictureParameterMin = -100;
  static const int videoPictureParameterMax = 100;
  static const int audioDelayMin = -1000;
  static const int audioDelayMax = 1000;
  static const int audioDelayStep = 10;
  static const Duration _videoPictureSaveDelay = Duration(milliseconds: 300);

  late final RxInt videoBrightness =
      (tempPlayerConf ? 0 : Pref.videoBrightness).obs;
  late final RxInt videoContrast =
      (tempPlayerConf ? 0 : Pref.videoContrast).obs;
  late final RxInt videoSaturation =
      (tempPlayerConf ? 0 : Pref.videoSaturation).obs;
  late final RxInt videoGamma = (tempPlayerConf ? 0 : Pref.videoGamma).obs;
  late final RxInt videoHue = (tempPlayerConf ? 0 : Pref.videoHue).obs;
  late final RxInt audioDelayMs =
      (tempPlayerConf ? 0 : Pref.audioDelayMs).obs;
  Timer? _videoPictureSaveTimer;

  late int? cacheVideoQa = PlatformUtils.isMobile ? null : Pref.defaultVideoQa;
  late int cacheAudioQa = Pref.defaultAudioQa;
  bool enableHeart = true;

  /// 当前片源是否为 HDR / 杜比视界流，由播放页在 setDataSource 前写入。
  bool isHdrSource = false;

  /// 当前片源是否为杜比视界（画质 126）。杜比视界不要预切 HDR 窗口模式，
  /// 否则会覆盖掉系统/面板的杜比视界处理，导致颜色异常。
  bool isDolbyVisionSource = false;

  /// 当前片源是否为 HDR Vivid；同样不预切 HDR 窗口模式。
  bool isHdrVividSource = false;

  /// 当前选中视频流的 codecs 字符串（用于诊断 DoVi profile 5/8）。
  String? sourceCodecs;

  /// 当前片源是否为杜比视界 profile 5（dvh1.05/dvhe.05）。
  bool get isDolbyVisionProfile5 =>
      isDolbyVisionSource && (sourceCodecs?.contains('.05.') ?? false);

  /// 当前窗口是否已被预切到 HDR 色彩模式。
  bool _windowHdrRequested = false;

  /// 是否走 Media3/ExoPlayer 解码 profile 5 的真 DoVi 实验路径。
  bool _useMedia3Dovi = false;

  /// 当前 DoVi 视频流的 URL（视频轨，音频仍由 mpv 播放）。
  String? _doviVideoUrl;
  String? _doviAudioUrl;

  Timer? _doviSyncTimer;
  Timer? _doviPrepareTimer;
  bool _doviPrepared = false;
  bool _doviPlaying = false;
  bool _doviDisposed = false;

  /// 是否应该走「视频在 Flutter 之下」的 SurfaceView 出画。
  ///
  /// 只有真正的 HDR 片源才需要它：Flutter 纹理固定 8bit，会丢掉 HDR 元数据；
  /// 而 SDR 片源继续走纹理，保留硬解、Anime4K 等全部 mpv 渲染能力。
  /// 出画方式在播放器创建时确定，片源切换（切换画质/换集）时由
  /// [_switchOutputIfNeeded] 重建播放器。
  bool get _wantNativeSurface =>
      Platform.isAndroid &&
      Pref.enableHdr &&
      Pref.hdrSurface &&
      isHdrSource &&
      // mediacodec_embed 必须硬解；用户关掉硬解时退回纹理，避免黑屏。
      (HdrBackend.fromValue(Pref.hdrBackend) != HdrBackend.mediacodecEmbed ||
          Pref.enableHA);

  /// 原生 SurfaceView 出画开关。Rx 以便播放页在出画方式变化时立即重建视频控件。
  final RxBool nativeSurfaceMode = false.obs;

  /// 当前视频控制器（响应式）。播放器因出画方式变化而重建时，界面据此换源。
  final Rxn<VideoController> videoOutput = Rxn<VideoController>();

  bool get useNativeSurface => nativeSurfaceMode.value;

  /// 由 [HdrHwdecMode] 与片源类型决定最终使用的 `--hwdec`。
  ///
  /// 直通解码（如 Android 的 `mediacodec`）不会把画面交回 mpv，色调映射、
  /// 峰值亮度等 HDR 参数会全部无效；因此「自动」模式下 HDR 片源改用拷贝解码，
  /// SDR 片源仍沿用「硬解模式」的设置。
  ///
  /// `mediacodec_embed` 是例外：它必须由 MediaCodec 直接解码到 Surface，
  /// 所以只要走这条 HDR 出画路径，就强制使用 `mediacodec`。
  String? _resolveHwdec() {
    final backend = HdrBackend.fromValue(Pref.hdrBackend);
    if (_wantNativeSurface && backend == HdrBackend.mediacodecEmbed) {
      return 'mediacodec';
    }
    if (!Pref.enableHA) return null;
    final config = HdrConfig.fromPref();
    if (!config.enabled) return Pref.hardwareDecoding;
    return switch (config.hwdecMode) {
      HdrHwdecMode.auto =>
        isHdrSource ? config.copyHwdec : Pref.hardwareDecoding,
      HdrHwdecMode.follow => Pref.hardwareDecoding,
      HdrHwdecMode.copy => config.copyHwdec,
      HdrHwdecMode.direct => config.directHwdec,
    };
  }

  late final progressType = Pref.btmProgressBehavior;
  late final enableQuickDouble = Pref.enableQuickDouble;
  late final fullScreenGestureReverse = Pref.fullScreenGestureReverse;

  late final isRelative = Pref.useRelativeSlide;
  late final offset = isRelative
      ? Pref.sliderDuration / 100
      : Pref.sliderDuration * 1000;

  num get sliderScale => isRelative ? durationInMilliseconds * offset : offset;

  // 播放顺序相关
  late PlayRepeat playRepeat = Pref.playRepeat;

  TextStyle _buildSubtitleStyle({
    required double fontScale,
    required double fontScaleFS,
    required int fontWeight,
    required double bgOpacity,
  }) => TextStyle(
    height: 1.5,
    fontSize: 16 * (isFullScreen.value ? fontScaleFS : fontScale),
    letterSpacing: 0.1,
    wordSpacing: 0.1,
    color: Colors.white,
    fontWeight: FontWeight.values[fontWeight],
    backgroundColor: bgOpacity == 0
        ? null
        : Colors.black.withValues(alpha: bgOpacity),
  );

  TextStyle get subTitleStyle => _buildSubtitleStyle(
    fontScale: subtitleFontScale,
    fontScaleFS: subtitleFontScaleFS,
    fontWeight: subtitleFontWeight,
    bgOpacity: subtitleBgOpacity,
  );

  TextStyle get subTitleSecondaryStyle => _buildSubtitleStyle(
    fontScale: subtitleSecondaryFontScale,
    fontScaleFS: subtitleSecondaryFontScaleFS,
    fontWeight: subtitleSecondaryFontWeight,
    bgOpacity: subtitleSecondaryBgOpacity,
  );

  late final Rx<SubtitleViewConfiguration> subtitleConfig = getSubConfig.obs;
  String? _activeVideoContextKey;

  SubtitleViewConfiguration get getSubConfig {
    final subTitleStyle = this.subTitleStyle;
    final secondaryStyle = subTitleSecondaryStyle;

    // 无背景时用描边保证可读性,主副字幕各自独立
    TextStyle? strokeOf(TextStyle base, double bgOpacity, double strokeWidth) =>
        bgOpacity == 0
        ? base.copyWith(
            color: null,
            background: null,
            backgroundColor: null,
            foreground: Paint()
              ..color = Colors.black
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth,
          )
        : null;

    return SubtitleViewConfiguration(
      style: subTitleStyle,
      strokeStyle: strokeOf(
        subTitleStyle,
        subtitleBgOpacity,
        subtitleStrokeWidth,
      ),
      secondaryStyle: secondaryStyle,
      secondaryStrokeStyle: strokeOf(
        secondaryStyle,
        subtitleSecondaryBgOpacity,
        subtitleSecondaryStrokeWidth,
      ),
      spacing: subtitleSecondarySpacing,
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

  static PlPlayerController? get instance => _instance;

  static bool instanceExists() {
    return _instance != null;
  }

  static void setPlayCallBack(
    PlayCallback? playCallBack, {
    PlayOwner? playOwner,
  }) {
    _playCallBack = playCallBack;
    _playOwner = playOwner;
  }

  static PlayOwner? _playOwner;
  static PlayOwner? get playOwner => _playOwner;
  static PlayCallback? _playCallBack;

  static Future<void>? playIfExists() {
    if (_instance != null && !(_instance!.playerStatus.isPlaying)) {
      return _instance!.play();
    }
    return _playCallBack?.call();
  }

  // try to get PlayerStatus
  static PlayerStatus? getPlayerStatusIfExists() {
    return _instance?.playerStatus;
  }

  static Future<void>? pauseIfExists({
    bool notify = true,
    bool isInterrupt = false,
  }) {
    if (_instance?.playerStatus.isPlaying ?? false) {
      return _instance?.pause(notify: notify, isInterrupt: isInterrupt);
    }
    return null;
  }

  static Future<void>? seekToIfExists(
    Duration position, {
    bool isSeek = true,
  }) {
    return _instance?.seekTo(position, isSeek: isSeek);
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
        if (controlsLock.value && (lockFsRotation || _isVertical)) return;
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeLeftMode();
        }
      case .landscapeRight:
        if (controlsLock.value && (lockFsRotation || _isVertical)) return;
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

    if (Platform.isAndroid) {
      // onPipChanged 回调是本 fork 的系统 PiP 状态同步通道（上游没有），
      // 与下方的 autoPiP 注册共用同一个 MethodChannel handler
      Utils.channel.setMethodCallHandler((call) async {
        if (call.method == 'onPipChanged') {
          final bool isInPip = call.arguments as bool;
          isNativePip.value = isInPip;
          PipOverlayService.isNativePip = isInPip;
          LivePipOverlayService.isNativePip = isInPip;
          handleAutoAudioOnlyPipChanged(isInPip);
        }
      });

      if (autoPiP) {
        if (DeviceUtils.sdkInt < 31) {
          final func = Runnable.implement($Runnable(run: _onUserLeaveHint));
          AndroidHelper$ToDart.onUserLeaveHint = func;
          func.release();
        } else {
          _isAutoEnterPip = true;
        }
      }
    } else if (Platform.isIOS && autoPiP && IOSPipHelper.isAvailable) {
      _isAutoEnterPip = true;
    }
  }

  void _onUserLeaveHint() {
    if (_isInInAppPip) {
      enterPip();
      return;
    }
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

  static PlPlayerController ensureInstance({bool isLive = false}) {
    return (_instance ??= PlPlayerController._())..isLive = isLive;
  }

  static bool _isAnimPgcType(int? pgcType) => pgcType == 1 || pgcType == 4;

  void resetTempSettings({int? nextPgcType}) {
    if (!tempPlayerConf) {
      return;
    }

    if (kDebugMode) {
      debugPrint(
        '[PlPlayer] resetTempSettings (currentContext: $_activeVideoContextKey, nextPgcType: $nextPgcType)',
      );
    }

    enableShowDanmaku.value = Pref.enableShowDanmaku;
    enableShowLiveDanmaku.value = Pref.enableShowLiveDanmaku;
    videoPlayerServiceHandler?.enableBackgroundPlay = Pref.enableBackgroundPlay;
    continuePlayInBackground.value = Pref.continuePlayInBackground;
    playRepeat = Pref.playRepeat;
    cacheVideoQa = PlatformUtils.isMobile ? null : Pref.defaultVideoQa;
    cacheAudioQa = Pref.defaultAudioQa;
    if (_playbackSpeed.value != playSpeedDefault) {
      unawaited(setPlaybackSpeed(playSpeedDefault));
    }

    final defaultSuperResolutionType = _isAnimPgcType(nextPgcType)
        ? Pref.superResolutionType
        : SuperResolutionType.disable;
    superResolutionType.value = defaultSuperResolutionType;
    if (_videoPlayerController != null) {
      unawaited(
        setShader(defaultSuperResolutionType, _videoPlayerController!),
      );
    }

    resetAllVideoPictureParameters(persist: false);
  }

  int _normalizeVideoPictureParameter(num value) =>
      value.round().clamp(
        videoPictureParameterMin,
        videoPictureParameterMax,
      ).toInt();

  RxInt? _videoPictureParameterState(String property) => switch (property) {
    'brightness' => videoBrightness,
    'contrast' => videoContrast,
    'saturation' => videoSaturation,
    'gamma' => videoGamma,
    'hue' => videoHue,
    _ => null,
  };

  void setVideoPictureParameter(String property, num value) {
    final state = _videoPictureParameterState(property);
    if (state == null) return;

    final normalized = _normalizeVideoPictureParameter(value);
    state.value = normalized;
    _applyVideoPictureProperty(property, normalized);
    _scheduleVideoPictureSettingsSave();
  }

  void resetVideoPictureParameter(String property) {
    setVideoPictureParameter(property, 0);
  }

  void setAudioDelay(int value) {
    audioDelayMs.value = value.clamp(audioDelayMin, audioDelayMax).toInt();
    _applyAudioDelay();
    _scheduleVideoPictureSettingsSave();
  }

  void resetAudioDelay() => setAudioDelay(0);

  void _applyAudioDelay() {
    final player = _videoPlayerController;
    if (player == null || onlyPlayAudio.value) return;
    try {
      player.setProperty('audio-delay', (audioDelayMs.value / 1000).toString());
    } catch (_) {}
  }

  void resetAllVideoPictureParameters({bool persist = true}) {
    videoBrightness.value = 0;
    videoContrast.value = 0;
    videoSaturation.value = 0;
    videoGamma.value = 0;
    videoHue.value = 0;
    audioDelayMs.value = 0;
    applyVideoPictureParameters();
    if (persist) {
      _scheduleVideoPictureSettingsSave();
    }
  }

  void _applyVideoPictureProperty(String property, int value) {
    final player = _videoPlayerController;
    if (player == null || onlyPlayAudio.value) return;
    try {
      player.setProperty(property, value.toString());
    } catch (_) {}
  }

  void applyVideoPictureParameters([Player? target]) {
    final player = target ?? _videoPlayerController;
    if (player == null || onlyPlayAudio.value) return;
    try {
      player
        ..setProperty('brightness', videoBrightness.value.toString())
        ..setProperty('contrast', videoContrast.value.toString())
        ..setProperty('saturation', videoSaturation.value.toString())
        ..setProperty('gamma', videoGamma.value.toString())
        ..setProperty('hue', videoHue.value.toString())
        ..setProperty('audio-delay', (audioDelayMs.value / 1000).toString());
    } catch (_) {}
  }

  /// 上一次播放的 HDR 状态快照。
  ///
  /// 设置页无法在播放时打开（会先销毁播放页），所以播放过程中定时把状态
  /// 存下来，播放结束后仍可在「HDR 状态诊断」里回看。
  static String _lastHdrSnapshot = '';
  Timer? _hdrSnapshotTimer;

  /// 当前（或上一次）播放器与 HDR 相关的运行时状态。
  ///
  /// 关键看几处：
  /// * `出画路径`：`SurfaceView` 才可能真正输出 HDR；
  /// * `vo`：必须是 `gpu-next`，`target-colorspace-hint` 才会生效；
  /// * `hwdec-current`：`mediacodec` 表示直通，画面不经过 mpv；
  /// * `视频色彩`：gamma 为 `pq` / `hlg` 才是 HDR 片源，`bt.1886` 是 SDR。
  /// 设置页读取用：优先由当前播放器实时生成，播放器已销毁时回退到上次快照。
  ///
  /// 设置页会在打开时销毁播放页，所以不能依赖 [PlPlayerController.instance]。
  static String get lastHdrInfo => _lastHdrSnapshot.isEmpty
      ? '播放器尚未初始化。\n请先播放一个视频（播放中无法打开设置页），\n播放几秒后再回到这里查看上次播放的快照。'
      : '（上次播放的快照）\n$_lastHdrSnapshot';

  String _nativeRectLabel(ui.Rect? rect) {
    if (rect == null) return '-';
    return '${rect.left.toStringAsFixed(0)},${rect.top.toStringAsFixed(0)} '
        '${rect.width.toStringAsFixed(0)}x${rect.height.toStringAsFixed(0)}';
  }

  String _sizeLabel(ui.Size? size) {
    if (size == null) return '-';
    return '${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}';
  }

  String get hdrDebugInfo {
    final player = _videoPlayerController;
    if (player == null) return lastHdrInfo;

    String read(String property) {
      try {
        final value = player.getProperty(property);
        return value.isEmpty ? '-' : value;
      } catch (_) {
        return '-';
      }
    }

    final native = nativeSurfaceMode.value;
    return [
      '出画路径: ${native ? 'SurfaceView(HDR)' : 'Texture(8bit)'}',
      if (_useMedia3Dovi) '真 DoVi 解码: Media3 / ExoPlayer（视频），mpv 音频',
      if (native)
        '原生 Surface: wid=${_nativeWid ?? '-'}，'
            'SurfaceView 尺寸=${_nativeSurfaceSize == null ? '-' : '${_nativeSurfaceSize!.$1}x${_nativeSurfaceSize!.$2}'}',
      if (_lastProbeMean != null)
        '直通画面采样: mean=$_lastProbeMean / max=$_lastProbeMax / '
            'bright=$_lastProbeBright（mean≈0 表示 Surface 全黑）',
      if (_lastProbeShown != null)
        '直通 SurfaceView: shown=$_lastProbeShown / vis=$_lastProbeVisibility / '
            'alpha=$_lastProbeAlpha / parent=$_lastProbeParent / '
            'windowColorMode=$_lastProbeWindowColorMode',
      if (native) '直通画面矩形: ${_nativeRectLabel(nativeContentRect.value)}',
      if (native)
        '直通挖孔矩形: ${_nativeRectLabel(nativeHoleRect.value)} / '
            '页面尺寸: ${_sizeLabel(nativePageSize.value)}',
      'vo: ${read('vo')}',
      'vo-configured: ${read('vo-configured')}',
      'hwdec-current: ${read('hwdec-current')}',
      '视频色彩: ${read('video-params/primaries')} / ${read('video-params/gamma')}',
      '像素格式: ${read('video-params/pixelformat')}',
      '色彩矩阵: ${read('video-params/colormatrix')}',
      // sig-peak 是相对 SDR 白点（100nits）的倍数，不是 nits。
      '片源 sig-peak: ${read('video-params/sig-peak')}（×100nits）',
      'tone-mapping: ${read('tone-mapping')}',
      'hdr-compute-peak: ${read('hdr-compute-peak')}',
      'target-peak: ${read('target-peak')}',
      'target-colorspace-hint: ${read('target-colorspace-hint')}',
      'dither: ${read('dither')}',
      'HDR 开关: ${Pref.enableHdr ? '开' : '关'}，'
          '直通出画: ${Pref.hdrSurface ? '开' : '关'}，'
          '后端: ${Pref.hdrBackend}',
      '片源判定: ${isHdrSource ? (isDolbyVisionSource ? 'HDR / 杜比视界' : (isHdrVividSource ? 'HDR Vivid' : 'HDR')) : 'SDR'}',
      if (sourceCodecs != null) '片源 codecs: $sourceCodecs',
    ].join('\n');
  }

  /// 播放期间每 5 秒刷新一次 [hdrDebugInfo] 快照，供下播后查看。
  void _startHdrSnapshot() {
    _hdrSnapshotTimer?.cancel();
    _hdrSnapshotTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_videoPlayerController == null) return;
      final info = hdrDebugInfo;
      _lastHdrSnapshot = info;
      debugPrint('[HDR] snapshot\n$info');
    });
  }

  /// 设置页修改 HDR / 杜比视界选项后调用，使参数立即作用于当前播放器。
  void applyHdrOptions() {
    final player = _videoPlayerController;
    if (player == null) return;
    _applyHdrProperties(player, hdrSurface: nativeSurfaceMode.value);
  }

  // ---------------------------------------------------------------------------
  // 原生 SurfaceView（HDR 直通出画）
  // ---------------------------------------------------------------------------

  /// 当前原生 Surface 的所有者令牌（页面/小窗切换时用于过滤过期调用）。
  int? _nativeOwner;

  /// 原生 Surface 的 global ref，作为 mpv 的 `--wid`。
  int? _nativeWid;

  /// SurfaceView 在窗口中的实际像素尺寸。
  ///
  /// `--android-surface-size` 必须与 SurfaceView 的布局尺寸一致（与旧的
  /// hybrid 出画路径一致）；视频编码尺寸（如 3840x2160）由解码器自己决定，
  /// 拿它去设置 Surface 会让部分设备黑屏。
  (int, int)? _nativeSurfaceSize;

  int? _appliedWid;
  String? _appliedVo;
  (int, int)? _appliedSurfaceSize;

  /// 布局尺寸变化的防抖更新（小窗拖动/页面动画期间尺寸逐帧变化）。
  Timer? _nativeResizeTimer;

  /// 延迟解除绑定：页面 ↔ 小窗切换时新旧控件会短暂共存。
  Timer? _nativeDetachTimer;

  /// HDR 直通画面自检（播放几秒后采样一次，区分解码器黑屏和 Flutter 遮盖）。
  Timer? _nativeProbeTimer;

  /// 最近一次 SurfaceView 画面采样结果（平均亮度；0 表示全黑）。
  int? _lastProbeMean;
  int? _lastProbeMax;
  int? _lastProbeBright;
  bool? _lastProbeShown;
  int? _lastProbeVisibility;
  double? _lastProbeAlpha;
  String? _lastProbeParent;
  int? _lastProbeWindowColorMode;

  /// 原生视频当前在屏幕上的矩形（逻辑像素，全局坐标）。
  ///
  /// 播放页根节点用它挖出唯一的透明区域；其余区域由根节点显式铺黑，
  /// 不再依赖整页透明或窗口背景。
  final ValueNotifier<ui.Rect?> nativeContentRect = ValueNotifier<ui.Rect?>(
    null,
  );

  /// 页面根节点实际挖出的透明矩形（页面本地坐标），仅用于诊断。
  final ValueNotifier<ui.Rect?> nativeHoleRect = ValueNotifier<ui.Rect?>(null);

  /// 页面根节点尺寸，仅用于诊断挖孔是否落在页面内。
  final ValueNotifier<ui.Size?> nativePageSize = ValueNotifier<ui.Size?>(null);

  /// 原生 Surface 就绪信号：自动播放前等待它，避免「先出声音、黑屏几秒」。
  Completer<void>? _nativeSurfaceReady;

  bool get nativeSurfaceAttached => _nativeWid != null;

  int? get nativeSurfaceOwner => _nativeOwner;

  void _setVideoController(VideoController? value) {
    if (identical(_videoController, value)) return;
    _videoController = value;
    videoOutput.value = value;
  }

  bool _isStaleNativeOwner(int owner) {
    final current = _nativeOwner;
    return current != null && owner < current;
  }

  /// 原生 SurfaceView 就绪后，把 `wid` / SurfaceView 尺寸交给 mpv。
  void attachNativeSurface(int owner, int wid, int width, int height) {
    if (wid == 0 || _isStaleNativeOwner(owner)) return;
    _nativeDetachTimer?.cancel();
    _nativeDetachTimer = null;
    _nativeOwner = owner;
    _nativeWid = wid;
    if (width > 1 && height > 1) {
      _nativeSurfaceSize = (width, height);
    }
    // 播放器还没创建完时先记下来，_initPlayer 会在 VideoController 初始化
    // 完成后补一次，避免刚设置的 vo 被 media_kit 的初始化覆盖成 null。
    if (_videoPlayerController != null) {
      if (_useMedia3Dovi) {
        _scheduleDoviPrepare();
      } else {
        _applyNativeSurface();
      }
      _completeNativeSurfaceReady();
      if (_videoPlayerController!.state.playing) {
        _scheduleNativeProbe();
      }
    }
  }

  /// 播放开始后采样 SurfaceView 画面。
  ///
  /// 仅用于诊断：PixelCopy 读取的是原生 Surface 自身的内容，不受 Flutter
  /// 是否遮盖影响。数据会写入 HDR 状态快照，不再自动回退出画方式——
  /// 早期自动回退会在杜比/暗场首帧误判，把正常播放切回纹理。
  void _scheduleNativeProbe() {
    if (!nativeSurfaceMode.value || !isHdrSource) return;
    _nativeProbeTimer?.cancel();
    _nativeProbeTimer = Timer(const Duration(milliseconds: 2500), () {
      _nativeProbeTimer = null;
      _probeNativeSurface();
    });
  }

  Future<void> _probeNativeSurface() async {
    final owner = _nativeOwner;
    if (owner == null || !nativeSurfaceMode.value) return;
    final data = await NativeVideoSurfaceChannel.probe(owner: owner);
    final mean = (data?['mean'] as num?)?.toInt();
    final max = (data?['max'] as num?)?.toInt();
    final bright = (data?['bright'] as num?)?.toInt();
    final shown = data?['shown'] as bool?;
    final visibility = (data?['vis'] as num?)?.toInt();
    final alpha = (data?['alpha'] as num?)?.toDouble();
    final parent = data?['parent'] as String?;
    final windowColorMode = (data?['windowColorMode'] as num?)?.toInt();
    debugPrint(
      '[HDR] probe mean=$mean max=$max bright=$bright '
      'shown=$shown vis=$visibility alpha=$alpha parent=$parent '
      'windowColorMode=$windowColorMode',
    );
    _lastProbeMean = mean;
    _lastProbeMax = max;
    _lastProbeBright = bright;
    _lastProbeShown = shown;
    _lastProbeVisibility = visibility;
    _lastProbeAlpha = alpha;
    _lastProbeParent = parent;
    _lastProbeWindowColorMode = windowColorMode;
  }

  /// 按当前片源预切/复位窗口 HDR 模式。
  ///
  /// 在 setDataSource 开始、播放器与首帧出现之前切换，让面板的 HDR 模式
  /// 切换发生在加载/黑屏阶段，而不是首帧出声时整屏亮一下。
  void _updateWindowHdrMode() {
    // 只有 mediacodec_embed 真正由系统/解码器直通 HDR；gpu/gpu-next 在本
    // libmpv 构建上实际输出 SDR，不应把窗口预切成 HDR。
    // 杜比视界/HDR Vivid 也不预切，让系统按片源元数据切到正确显示模式。
    final backend = HdrBackend.fromValue(Pref.hdrBackend);
    final wanted =
        _wantNativeSurface &&
        backend == HdrBackend.mediacodecEmbed &&
        !isDolbyVisionSource &&
        !isHdrVividSource;
    if (wanted == _windowHdrRequested) return;
    _windowHdrRequested = wanted;
    unawaited(NativeVideoSurfaceChannel.setWindowHdr(enabled: wanted));
  }

  /// 播放页销毁时复位窗口 HDR 模式，避免设置页/首页停留在 HDR 窗口模式。
  void _resetWindowHdr() {
    if (!_windowHdrRequested) return;
    _windowHdrRequested = false;
    unawaited(NativeVideoSurfaceChannel.setWindowHdr(enabled: false));
  }

  void _releaseDoviPlayer() {
    _doviPrepareTimer?.cancel();
    _doviPrepareTimer = null;
    _doviSyncTimer?.cancel();
    _doviSyncTimer = null;
    _doviPrepared = false;
    _doviPlaying = false;
    // 只允许当前活跃的控制器释放原生 DoVi 播放器；旧页面/旧控制器的
    // dispose 不能把新页面刚准备好的 Media3 播放器释放掉（会直接黑屏）。
    if (_useMedia3Dovi && identical(this, _instance)) {
      unawaited(NativeVideoSurfaceChannel.doviRelease());
    }
  }

  void _scheduleDoviPrepare() {
    if (!_useMedia3Dovi || _doviDisposed) return;
    _doviPrepared = false;
    _doviPrepareTimer?.cancel();
    _doviPrepareTimer = Timer(const Duration(milliseconds: 300), () {
      _doviPrepareTimer = null;
      unawaited(_prepareDoviPlayer());
    });
  }

  Future<void> _prepareDoviPlayer() async {
    if (!_useMedia3Dovi || _doviDisposed || _doviPrepared) return;
    final url = _doviVideoUrl;
    if (url == null || url.isEmpty) return;
    final ok = await NativeVideoSurfaceChannel.doviPrepare(
      url: url,
      audioUrl: _doviAudioUrl,
      referer: HttpString.baseUrl,
      userAgent: BrowserUa.pc,
    );
    if (_doviDisposed || !_useMedia3Dovi) return;
    if (!ok) {
      _doviPrepareTimer?.cancel();
      _doviPrepareTimer = Timer(const Duration(milliseconds: 500), () {
        _doviPrepareTimer = null;
        unawaited(_prepareDoviPlayer());
      });
      return;
    }
    _doviPrepared = true;
    _startDoviSync();
  }

  void _startDoviSync() {
    _doviSyncTimer?.cancel();
    _doviSyncTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(_syncDovi());
    });
  }

  Future<void> _syncDovi() async {
    if (!_useMedia3Dovi || _doviDisposed || !_doviPrepared) return;
    final player = _videoPlayerController;
    if (player == null) return;
    final playing = player.state.playing;
    // mpv 只保留时间轴，进度以 Media3 为准，否则保存/恢复会停在 0 或旧值。
    final media3Pos = await NativeVideoSurfaceChannel.doviPosition();
    if (media3Pos > 0) {
      final sec = (media3Pos / 1000).round();
      if (sec != position.value) {
        position.value = sec;
        // stream.position 在 Media3 路径被忽略，这里补上 B 站历史心跳。
        // isManual 跳过 dataStatus/暂停检查：Media3 首帧就绪时 mpv 侧可能
        // 还没进入 playing，否则历史会被漏掉。
        makeHeartBeat(sec, isManual: true);
      }
    }
    if (playing != _doviPlaying) {
      _doviPlaying = playing;
      if (playing) {
        unawaited(NativeVideoSurfaceChannel.doviPlay());
      } else {
        unawaited(NativeVideoSurfaceChannel.doviPause());
      }
    }
    // Media3 自己播音频+视频，用 ExoPlayer 原生时钟；不再根据 mpv 位置
    // seek/调速，否则会周期性卡顿、定格。
  }

  /// 更新 SurfaceView 的布局尺寸。
  ///
  /// 防抖 200ms：小窗拖动/全屏动画期间尺寸逐帧变化，逐帧改
  /// `--android-surface-size` 会让视频输出反复重建（黑闪）。
  void resizeNativeSurface(int owner, int width, int height) {
    if (owner != _nativeOwner) return;
    if (width <= 1 || height <= 1) return;
    final size = (width, height);
    if (_nativeSurfaceSize == size) return;
    _nativeSurfaceSize = size;
    if (_videoPlayerController == null || _nativeWid == null) return;
    _nativeResizeTimer?.cancel();
    _nativeResizeTimer = Timer(const Duration(milliseconds: 200), () {
      _nativeResizeTimer = null;
      if (_nativeWid == null) return;
      final player = _videoPlayerController;
      final size = _nativeSurfaceSize;
      if (player == null || size == null) return;
      if (_appliedSurfaceSize == size) return;
      try {
        player.setProperty('android-surface-size', '${size.$1}x${size.$2}');
        _appliedSurfaceSize = size;
      } catch (_) {}
    });
  }

  /// 原生 Surface 被销毁（切后台、窗口重建等）时解除绑定。
  ///
  /// 延迟 400ms 执行：页面切小窗时新控件通常会紧接着 create 并接管，
  /// 立即把 `vo` 置空会让画面黑一下。
  void detachNativeSurface(int owner) {
    if (owner != _nativeOwner) return;
    _nativeDetachTimer?.cancel();
    final ownerPlayer = _videoPlayerController;
    _nativeDetachTimer = Timer(const Duration(milliseconds: 400), () {
      _nativeDetachTimer = null;
      if (_nativeOwner != owner) return;
      // 期间播放器被换掉（切视频/切画质）时不要再动新播放器。
      if (!identical(_videoPlayerController, ownerPlayer)) return;
      _nativeResizeTimer?.cancel();
      _nativeResizeTimer = null;
      _nativeOwner = null;
      _nativeWid = null;
      _appliedWid = null;
      _appliedVo = null;
      _appliedSurfaceSize = null;
      final player = ownerPlayer;
      if (player == null) return;
      try {
        player.setProperty('vo', 'null');
        player.setProperty('wid', '0');
      } catch (_) {}
    });
  }

  void _applyNativeSurface({Player? target}) {
    // 当前片源不是原生出画，或走 Media3 DoVi 时，都不能给 mpv 下发 vo/wid。
    if (!nativeSurfaceMode.value || _useMedia3Dovi) return;
    final player = target ?? _videoPlayerController;
    final wid = _nativeWid;
    final size = _nativeSurfaceSize;
    if (player == null || wid == null || size == null) return;
    if (size.$1 <= 1 || size.$2 <= 1) return;
    final vo = Pref.hdrBackend;
    final needVo = _appliedWid != wid || _appliedVo != vo;
    try {
      if (_appliedSurfaceSize != size) {
        player.setProperty('android-surface-size', '${size.$1}x${size.$2}');
        _appliedSurfaceSize = size;
      }
      if (needVo) {
        // 顺序很重要：先复位 vo，再给 wid，最后设置 vo。
        player.setProperty('vo', 'null');
        player.setProperty('wid', '$wid');
        player.setProperty('vid', 'auto');
        player.setProperty('vo', vo);
        _appliedWid = wid;
        _appliedVo = vo;
        _applyHdrProperties(player, hdrSurface: true);
      }
      debugPrint([
        '[HDR] nativeSurface vo=$vo',
        'wid=$wid',
        'surface=${size.$1}x${size.$2}',
      ].join(' '));
    } catch (_) {}
  }

  void _resetNativeSurfaceState() {
    _nativeDetachTimer?.cancel();
    _nativeDetachTimer = null;
    _nativeResizeTimer?.cancel();
    _nativeResizeTimer = null;
    _nativeProbeTimer?.cancel();
    _nativeProbeTimer = null;
    _nativeOwner = null;
    _nativeWid = null;
    _nativeSurfaceSize = null;
    _appliedWid = null;
    _appliedVo = null;
    _appliedSurfaceSize = null;
    nativeContentRect.value = null;
    _nativeSurfaceReady = null;
  }

  void _completeNativeSurfaceReady() {
    final completer = _nativeSurfaceReady;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  /// 写入 mpv 的 HDR 色彩处理参数。
  ///
  /// 只改色彩处理相关的运行期属性，不在这里决定 `--vo`：
  /// * 纹理出画时 `--vo` 由 media_kit 的 Android 控制器负责；
  /// * SurfaceView 出画时由 [_applyNativeSurface] 在 `wid` 就绪后设置。
  void _applyHdrProperties(Player player, {bool hdrSurface = false}) {
    try {
      // 先复位再写入，确保关闭 HDR 后不会残留上一次的参数
      for (final entry in HdrConfig.resetProperties.entries) {
        player.setProperty(entry.key, entry.value);
      }
      final properties = Map<String, String>.from(
        HdrConfig.fromPref().mpvProperties,
      );
      if (hdrSurface) {
        final backend = HdrBackend.fromValue(Pref.hdrBackend);
        // 只有 mediacodec_embed 由系统/解码器直通 HDR；gpu/gpu-next 的
        // libmpv 构建没有 Android HDR EGL/dataspace，请求 HDR 输出会黑屏或
        // 颜色异常。对这两个后端关闭 target-colorspace-hint，让 mpv 正常
        // 做 HDR→SDR 色调映射后输出到 Surface。
        properties['target-colorspace-hint'] =
            backend == HdrBackend.mediacodecEmbed ? 'yes' : 'no';
      }
      debugPrint('[HDR] properties: $properties');
      for (final entry in properties.entries) {
        player.setProperty(entry.key, entry.value);
      }
    } catch (_) {
      // 个别平台的 libmpv 构建不支持其中某些属性，忽略即可
    }
  }

  void _scheduleVideoPictureSettingsSave() {
    if (tempPlayerConf) return;
    _videoPictureSaveTimer?.cancel();
    _videoPictureSaveTimer = Timer(
      _videoPictureSaveDelay,
      persistVideoPictureSettings,
    );
  }

  void persistVideoPictureSettings() {
    _videoPictureSaveTimer?.cancel();
    _videoPictureSaveTimer = null;
    if (tempPlayerConf) return;
    setting.putAllNE({
      SettingBoxKey.videoBrightness: videoBrightness.value,
      SettingBoxKey.videoContrast: videoContrast.value,
      SettingBoxKey.videoSaturation: videoSaturation.value,
      SettingBoxKey.videoGamma: videoGamma.value,
      SettingBoxKey.videoHue: videoHue.value,
      SettingBoxKey.audioDelayMs: audioDelayMs.value,
    });
  }

  bool _processing = false;
  bool get processing => _processing;

  // offline
  bool get isFileSource => dataSource is FileSource;

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
    int? roomId,
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
      // 新片源前先释放旧的 Media3 DoVi 播放器。
      _releaseDoviPlayer();
      _useMedia3Dovi = isDolbyVisionProfile5 && Pref.media3Dovi;
      _doviVideoUrl = _useMedia3Dovi && dataSource is NetworkSource
          ? dataSource.videoSource
          : null;
      _doviAudioUrl = _useMedia3Dovi && dataSource is NetworkSource
          ? dataSource.audioSource
          : null;
      _doviDisposed = false;
      // 在创建播放器/首帧之前预切窗口 HDR 模式。
      _updateWindowHdrMode();
      // 换视频/换P：解除倍速锁定并恢复锁定前速度。
      // 必须先于临时配置重置执行，否则 lastPlaybackSpeed 会被先行覆盖
      await releaseSpeedLock();
      final nextVideoContextKey = PipOverlayService.buildVideoContextKey(
        videoType: videoType ?? VideoType.ugc,
        bvid: bvid,
        cid: cid,
        epId: epid,
        seasonId: seasonId,
      );
      final shouldResetTempSettings =
          tempPlayerConf &&
          _activeVideoContextKey != null &&
          nextVideoContextKey != null &&
          nextVideoContextKey != _activeVideoContextKey;
      if (shouldResetTempSettings) {
        resetTempSettings(nextPgcType: pgcType);
      }
      _activeVideoContextKey = nextVideoContextKey;

      // 换视频上下文时取消自动只听定时器，状态保持
      _cancelAutoAudioOnlyTimer();
      _interruptAutoAudioRestore();
      if (_autoAudioState == AutoAudioOnlyState.autoAudioOnly) {
        _audioReopened = true;
      }
      this.isLive = isLive;
      _videoType = videoType ?? VideoType.ugc;
      this.width = width;
      this.height = height;
      this.dataSource = dataSource;
      _autoPlay = autoplay;
      // 初始化数据加载状态
      dataStatus.value = DataStatus.loading;
      // 初始化全屏方向
      _isVertical = isVertical ?? false;
      _aid = aid;
      _bvid = bvid;
      this.cid = cid;
      this.roomId = roomId;
      _epid = epid;
      _seasonId = seasonId;
      _pgcType = pgcType;

      if (showSeekPreview) {
        _clearPreview();
      }
      hideDesktopProgressPreview();
      cancelLongPressTimer();
      if (_videoPlayerController != null &&
          _videoPlayerController!.state.playing) {
        await pause(notify: false);
      }

      if (_playerCount == 0) {
        if (kDebugMode) {
          debugPrint(
            '[PlPlayer] setDataSource aborted: _playerCount == 0 before init',
          );
        }
        return;
      }
      // 片源切换（切换画质 / 换集）可能改变出画方式：SDR 走纹理、HDR 走
      // SurfaceView。出画方式在播放器创建时固定，因此这里按需重建播放器。
      await _switchOutputIfNeeded();
      // 配置Player 音轨、字幕等等
      await _createVideoController(dataSource, seekTo, volume);

      if (_playerCount == 0) {
        if (kDebugMode) {
          debugPrint(
            '[PlPlayer] setDataSource aborted: _playerCount == 0 after createVideoController',
          );
        }
        _removeListeners();
        _setVideoController(null);
        _videoPlayerController?.dispose();
        _videoPlayerController = null;
        return;
      }

      updateDuration(duration ?? _videoPlayerController!.state.duration);
      position.value = buffered.value = seekTo?.inSeconds ?? 0;

      dataStatus.value = .loaded;
      if (_canUseSeekPreview) {
        unawaited(ensureVideoShot());
      }

      if (autoFullScreenFlag && autoEnterFullScreen) {
        triggerFullScreen(status: true);
      }

      // HDR 直通的原生 SurfaceView 需要播放页先挂载并完成布局，才能把 wid
      // 交给 mpv；否则 _initializePlayer 会白等超时。其它路径保持原有顺序。
      if (nativeSurfaceMode.value) {
        onInit?.call();
        await _initializePlayer();
      } else {
        await _initializePlayer();
        onInit?.call();
      }
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

  Future<Player> _initPlayer() async {
    assert(_videoPlayerController == null);
    if (PlatformUtils.isMobile && Pref.enableAppVolume) {
      // 移动平台应用内音量模式：初始化系统音量
      systemVolume.value = (await FlutterVolumeController.getVolume()) ?? 1.0;
      // 从持久化存储读取应用内音量
      volume.value = Pref.appVolume;
    }
    final opt = {
      'video-sync': Pref.videoSync,
      if (Platform.isAndroid) 'ao': Pref.audioOutput,
      'volume':
          (PlatformUtils.isMobile
                  ? (Pref.enableAppVolume
                        ? volume.value * 100
                        : Pref.playerVolume)
                  : volume.value * 100)
              .toString(),
      'volume-max': kMaxVolume.toString(),
    };
    final autosync = Pref.autosync;
    if (autosync != '0') {
      opt['autosync'] = autosync;
    }

    // HDR 片源在 Android 上改用「Flutter 之下的 SurfaceView」出画：
    // Flutter 纹理固定 RGBA8888，会把 10bit / HDR 元数据丢掉；SurfaceView 才能
    // 让 MediaCodec / libmpv 直接送显并点亮面板 HDR。SDR 片源继续走纹理，
    // 保留硬解、Anime4K 等 mpv 渲染能力。
    nativeSurfaceMode.value = _wantNativeSurface;
    _resetNativeSurfaceState();
    _nativeSurfaceReady = nativeSurfaceMode.value ? Completer<void>() : null;
    debugPrint(
      '[HDR] init: enable=${Pref.enableHdr} direct=${Pref.hdrSurface} '
      'hdrSource=$isHdrSource surface=${nativeSurfaceMode.value} '
      'vo=${nativeSurfaceMode.value ? Pref.hdrBackend : '-'} hwdec=${_resolveHwdec()}',
    );

    final hwdec = _resolveHwdec();
    final player = await Player.create(
      configuration: PlayerConfiguration(
        logLevel: kDebugMode ? .warn : .error,
        options: opt,
      ),
    );

    // Media3 DoVi：mpv 只负责音频，视频交给原生 ExoPlayer；必须在此之前
    // 关闭 mpv 的视频轨，避免两个解码器抢同一个 Surface。
    if (_useMedia3Dovi) {
      player.setProperty('vid', 'no');
      player.setProperty('aid', 'no');
    }

    // 渲染后端出错（例如 EGL 10bit 配置创建失败）会在这里出现，便于排查黑屏
    player.stream.error.listen((event) {
      debugPrint('[HDR][mpv-error] $event');
    });

    // HDR / 杜比视界：必须在视频输出初始化前写入，vo 创建时才会读取这些参数
    _applyHdrProperties(player, hdrSurface: nativeSurfaceMode.value);

    assert(_videoController == null);

    final videoController = await VideoController.create(
      player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: hwdec != null,
        androidAttachSurfaceAfterVideoParameters: false,
        hwdec: hwdec,
        // 视频画面由应用层的原生 SurfaceView 提供，media_kit 不创建纹理。
        // Media3 DoVi 路径下 mpv 只播放音频，不需要 external surface。
        androidExternalSurface: nativeSurfaceMode.value && !_useMedia3Dovi,
        // HDR 片源的渲染后端可在设置里切换（mediacodec_embed / gpu-next / gpu），
        // 不同设备驱动对 10bit EGL 的支持差异很大。
        vo: nativeSurfaceMode.value && !_useMedia3Dovi
            ? HdrBackend.fromValue(Pref.hdrBackend).value
            : null,
      ),
    );
    _setVideoController(videoController);

    if (Platform.isAndroid) {
      // Avoid sizing the surface using mpv's idle window between media loads.
      player.setProperty('force-window', 'no');
    }

    // 原生 SurfaceView 可能早于播放器就绪，这里补一次挂载。
    // media_kit 初始化会把 vo 复位成 null，所以必须强制重新下发。
    // 只有当前片源确实走原生出画时才挂载；切到 SDR/纹理时不能把旧 Surface
    // 的 vo/wid 应用到新播放器，否则新播放器会输出到旧原生层，Flutter 纹理
    // 停在最后一帧（切换视频时表现为画面定格）。
    if (nativeSurfaceMode.value && _nativeWid != null) {
      if (_useMedia3Dovi) {
        _scheduleDoviPrepare();
      } else {
        _appliedWid = null;
        _appliedVo = null;
        _appliedSurfaceSize = null;
        _applyNativeSurface(target: player);
      }
      _completeNativeSurfaceReady();
    }

    player.setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl);

    _startListeners(player);

    return player;
  }

  /// 片源切换时按需重建播放器，使出画方式与新的片源类型一致。
  ///
  /// 出画方式（纹理 / SurfaceView）在创建 `VideoController` 时固定：
  /// * 纹理路径无法输出 HDR，SurfaceView 路径才能让系统点亮面板 HDR；
  /// * SurfaceView 路径使用 `vo=mediacodec_embed`，会绕过 mpv 渲染，
  ///   不适合给 SDR 片源使用（会失去 Anime4K 等能力）。
  ///
  /// 因此只在 SDR ↔ HDR 切换时重建，普通换集、换 P 不受影响。
  Future<void> _switchOutputIfNeeded() async {
    final wantNative = _wantNativeSurface || _useMedia3Dovi;
    final player = _videoPlayerController;
    if (player == null) {
      nativeSurfaceMode.value = wantNative;
      return;
    }
    if (nativeSurfaceMode.value == wantNative) return;

    debugPrint('[HDR] output switch: native=$wantNative');
    _removeListeners();
    _hdrSnapshotTimer?.cancel();
    _resetNativeSurfaceState();
    _setVideoController(null);
    _videoPlayerController = null;
    nativeSurfaceMode.value = wantNative;
    // 先让 Flutter 把视频控件切到新的出画方式（纹理 ↔ 原生占位），
    // 再销毁旧播放器；否则旧 VideoController 被 dispose 后仍会被 Widget 使用一帧。
    await SchedulerBinding.instance.endOfFrame;
    try {
      await player.dispose();
    } catch (_) {}
  }

  late final buffer = Pref.initBuffer(_playbackSpeed.value);
  late final liveBuffer = Pref.initLiveBuffer();

  // 配置播放器
  Future<void> _createVideoController(
    DataSource dataSource,
    Duration? seekTo,
    Volume? volume,
  ) async {
    isBuffering.value = false;
    _heartDuration = 0;
    // 记录本次 open 的目标位置：mpv 在 seek 生效前会先报 position=0，
    // 若直接写回 position.value，进度条会被打回 0。
    seekToPos = seekTo;
    position.value = seekTo?.inSeconds ?? 0;
    buffered.value = 0;
    danmakuController?.clear();

    var player = _videoPlayerController;

    if (player == null) {
      player = await _initPlayer();
      if (_playerCount == 0) {
        _removeListeners();
        _setVideoController(null);
        player.dispose();
        player = null;
        return;
      }
      _videoPlayerController = player;
      if (isAnim && superResolutionType.value != .disable) {
        await setShader();
      }
    }

    final Map<String, String> extras = {
      if (dataSource is FileSource)
        'cache': 'no'
      else if (isLive)
        ...liveBuffer
      else
        ...buffer,
    };

    String video = dataSource.videoSource;
    if (dataSource.audioSource case final audio? when (audio.isNotEmpty)) {
      if (onlyPlayAudio.value) {
        video = audio;
      } else {
        // dely_open need provide length
        video =
            ('edl://'
            '!no_chapters;'
            // '!delay_open,media_type=video;'
            '%${isFileSource ? utf8.encode(video).length : video.length}%$video;'
            '!new_stream;!no_chapters;'
            // '!delay_open,media_type=audio;'
            '%${isFileSource ? utf8.encode(audio).length : audio.length}%$audio');
      }
      audioFilterExtras(volume, map: extras);
    }

    assert(!isLive || seekTo == null);
    // 按当前片源重新落一次 --hwdec：切换画质/换集时播放器可能复用，
    // 旧的直通解码会让 HDR 色调映射静默失效。file-local-options 只作用于
    // 接下来加载的这一个文件，不会污染后续播放。
    if (_resolveHwdec() case final hwdec?) {
      player.setProperty('file-local-options/hwdec', hwdec);
    }
    SmartDialog.showToast('DBG seek start=${seekTo?.inMilliseconds}');
    await player.open(
      Media(
        video,
        start: seekTo,
        extras: extras.isEmpty ? null : extras,
      ),
      play: false,
    );
    applyVideoPictureParameters(player);
    debugPrint(
      '[HDR] open: hdrSource=$isHdrSource surface=${nativeSurfaceMode.value} '
      'hwdec=${_resolveHwdec()} platform=${Platform.isAndroid ? 'android' : 'desktop'}',
    );
    _startHdrSnapshot();
  }

  Future<void>? refreshPlayer() {
    if (dataSource is FileSource) {
      return null;
    }
    if (_videoPlayerController case final ctr? when (ctr.current.isNotEmpty)) {
      var media = ctr.current.last;
      if (!isLive) media = media.copyWith(start: ctr.state.position);
      return ctr.open(media, play: true);
    }
    return null;
  }

  // 开始播放
  Future<void> _initializePlayer() async {
    if (_instance == null) return;
    // 设置倍速
    if (_videoPlayerController != null) {
      final speed = isLive ? 1.0 : playbackSpeed;
      if (_videoPlayerController!.state.rate != speed) {
        await setPlaybackSpeed(speed);
      }
    }
    _initVideoFit();

    // 自动播放
    if (!_autoPlay) return;
    if (nativeSurfaceMode.value &&
        !nativeSurfaceAttached &&
        _nativeSurfaceReady != null) {
      // HDR 直通：等原生 Surface 就绪再开始播放，避免「先出声音、黑屏几秒」。
      // 超时后照常播放：Surface 晚到时 mpv 会自动补上画面。
      unawaited(
        _nativeSurfaceReady!.future
            .timeout(const Duration(milliseconds: 600), onTimeout: () {})
            .then((_) {
              if (_instance != null && _autoPlay) {
                playIfExists();
              }
            }),
      );
      return;
    }
    playIfExists();
  }

  List<StreamSubscription>? _subscriptions;
  final Set<ValueChanged<Duration>> _positionListeners = {};
  final Set<ValueChanged<PlayerStatus>> _statusListeners = {};

  Timer? _wakeLockTimer;

  void _startWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = Timer(
      const Duration(milliseconds: 500),
      _stopWakeLock,
    );
  }

  void _stopWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = null;
  }

  void _stopWakeLock() {
    WakelockPlus.disable();
    _updatePlaybackState(debugLabel: 'onVideoPaused');
  }

  void _updatePlaybackState({Duration? position, String? debugLabel}) {
    videoPlayerServiceHandler?.onUpdateState(
      playerStatus,
      isBuffering.value,
      isLive,
      position: position ?? _videoPlayerController!.state.position,
      speed: playbackSpeed,
      debugLabel: debugLabel,
    );
    _updateIOSPip(position);
  }

  /// 播放事件监听
  void _startListeners(NativePlayer player) {
    assert(_subscriptions == null);
    final stream = player.stream;
    _subscriptions = [
      /// playing
      stream.playing.listen((bool playing) {
        if (playing) {
          playerStatus = .playing;
          _stopWakeLockTimer();
          _updatePlaybackState();
          WakelockPlus.enable();
          _scheduleNativeProbe();

          if (_isAutoEnterPip &&
              _autoAudioState != AutoAudioOnlyState.autoAudioOnly) {
            if (_isCurrVideoPage || _isInInAppPip) {
              enterPip(autoEnter: true);
            } else {
              _disableAutoEnterPip();
            }
          }
        } else {
          playerStatus = .paused;
          _startWakeLockTimer();
          _disableAutoEnterPip();
          _updateIOSPip();
        }

        for (final element in _statusListeners) {
          element(playing ? .playing : .paused);
        }

        final seconds = videoPlayerController!.state.position.inSeconds;
        if (seconds != 0) {
          makeHeartBeat(seconds, type: .status);
        }
      }),

      ///completed
      stream.completed.listen((bool completed) {
        if (completed) {
          playerStatus = .completed;
          _startWakeLockTimer();

          for (final element in _statusListeners) {
            element(.completed);
          }

          makeHeartBeat(-1, type: .completed);
        }
      }),

      /// position
      stream.position.listen((Duration position) {
        // Media3 只留时间轴时 mpv 的 position 不可信，进度由 _syncDovi 更新。
        if (_useMedia3Dovi) return;
        final posInSeconds = position.inSeconds;

        // open(start: seekTo) 生效前 mpv 会先报 0，忽略它，避免进度条归零。
        if (seekToPos != null) {
          if (posInSeconds == 0) return;
          seekToPos = null;
        }

        if (posInSeconds != this.position.value) {
          if (posInSeconds == 0 && playerStatus.isPlaying) {
            _updatePlaybackState(position: position);
          }

          this.position.value = posInSeconds;

          makeHeartBeat(posInSeconds);
        }

        for (final element in _positionListeners) {
          element(position);
        }
      }),
      stream.duration.listen((Duration duration) {
        updateDuration(duration);
        _updateIOSPip();
      }),
      stream.buffer.listen((Duration buffer) {
        buffered.value = buffer.inSeconds;
      }),
      stream.buffering.listen((bool buffering) {
        // Media3 出画时 mpv 只保留时间轴（vid/aid 都关掉），它的 buffering
        // 状态不可信，会出现多余的加载图标；交给 Media3 自己管理。
        if (_useMedia3Dovi) {
          isBuffering.value = false;
          return;
        }
        isBuffering.value = buffering;
        if (!playerStatus.isCompleted) {
          _stopWakeLockTimer();
          _updatePlaybackState();
        }
      }),
      if (kDebugMode)
        stream.log.listen(((PlayerLog log) {
          if (log.level == 'error' || log.level == 'fatal') {
            Utils.reportError(
              '${log.level}: ${log.prefix}: ${log.text}\n${player.state.playlist}',
              null,
            );
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
            Timer(const Duration(milliseconds: 3000), refreshPlayer);
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
            () => Timer(const Duration(milliseconds: 3000), () {
              // if (kDebugMode) {
              //   debugPrint("isBuffering.value: ${isBuffering.value}");
              // }
              // if (kDebugMode) {
              //   debugPrint("_buffered.value: ${_buffered.value}");
              // }
              if (isBuffering.value && buffered.value == 0) {
                final customHost = VideoUtils.customCDNUrl;
                SmartDialog.showToast(
                  customHost == null
                      ? '视频链接打开失败，重试中'
                      : '视频链接打开失败，重试中\n当前自定义CDN节点：$customHost，持续失败可尝试更换或清除',
                  displayTime: customHost == null
                      ? const Duration(milliseconds: 500)
                      : const Duration(milliseconds: 3000),
                );
                refreshPlayer();
              }
            }),
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
          if (!kDebugMode) {
            Utils.reportError('$event\n${player.state.playlist}');
          }
          // SmartDialog.showToast('视频加载错误, $event');
        }
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

  Future<void> seek(Duration position, {bool isSeek = false}) async {
    if (isSeek && !_useMedia3Dovi) {
      /// 拖动进度条调节时，不等待第一帧，防止抖动
      await _videoPlayerController?.stream.buffer.first;
    }
    danmakuController?.clear();
    try {
      if (_useMedia3Dovi) {
        this.position.value = position.inSeconds;
        unawaited(NativeVideoSurfaceChannel.doviSeek(
          positionMs: position.inMilliseconds + Pref.doviAudioOffset,
        ));
      } else {
        await _videoPlayerController?.seek(position);
      }
      _updateIOSPip(position);
    } catch (e) {
      if (kDebugMode) debugPrint('seek failed: $e');
    }
  }

  /// 跳转至指定位置
  Future<void> seekTo(Duration position, {bool isSeek = true}) async {
    if (_playerCount == 0) {
      return;
    }
    if (position < Duration.zero) {
      position = Duration.zero;
    }
    _heartDuration = position.inSeconds;

    if (duration.value != 0) {
      seek(position, isSeek: isSeek);
    } else {
      // if (kDebugMode) debugPrint('seek duration else');
      _subForSeek?.cancel();
      _subForSeek = duration.listen((_) {
        seek(position, isSeek: isSeek);
        _cancelSubForSeek();
      });
    }
  }

  /// 设置倍速
  Future<void> setPlaybackSpeed(double speed) async {
    lastPlaybackSpeed = playbackSpeed;

    if (speed == _videoPlayerController?.state.rate) return;

    await _videoPlayerController?.setRate(speed);
    if (_useMedia3Dovi) {
      unawaited(NativeVideoSurfaceChannel.doviSetRate(rate: speed));
    }
    if (!isLive) _playbackSpeed.value = speed;
    _updatePlaybackState();
    if (danmakuController != null) {
      try {
        danmakuController?.updateOption(
          danmakuController!.option.copyWith(
            duration: DanmakuOptions.danmakuDuration / speed,
            staticDuration: DanmakuOptions.danmakuStaticDuration / speed,
          ),
        );
      } catch (_) {}
    }
  }

  // 还原默认速度
  double playSpeedDefault = Pref.playSpeedDefault;
  Future<void> setDefaultSpeed() async {
    await _videoPlayerController?.setRate(playSpeedDefault);
    _playbackSpeed.value = playSpeedDefault;
  }

  bool _showControlsOnNextPlay = false;

  void markManualEpisodeChange() {
    if (Pref.showControlsOnManualEpisodeChange) {
      _showControlsOnNextPlay = true;
    }
  }

  bool _consumeShowControlsOnNextPlay() {
    final showControls = _showControlsOnNextPlay;
    _showControlsOnNextPlay = false;
    return showControls;
  }

  /// 底层播放：申请音频焦点 + 启动播放，不含 UI 副作用
  Future<void> _rawPlay() async {
    await _videoPlayerController?.play();
    if (_useMedia3Dovi) {
      unawaited(NativeVideoSurfaceChannel.doviPlay());
    }
    audioSessionHandler?.setActive(true);
    playerStatus = PlayerStatus.playing;
  }

  /// 播放视频
  Future<void> play({bool repeat = false, bool hideControls = true}) async {
    if (_playerCount == 0) return;
    // 播放时自动隐藏控制条
    final showControlsOnNextPlay = _consumeShowControlsOnNextPlay();
    controls = !hideControls || showControlsOnNextPlay;
    // repeat为true，将从头播放
    if (repeat) {
      await seekTo(Duration.zero, isSeek: false);
    }

    await _rawPlay();
  }

  /// 暂停播放
  Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
    await _videoPlayerController?.pause();
    if (_useMedia3Dovi) {
      unawaited(NativeVideoSurfaceChannel.doviPause());
    }
    playerStatus = .paused;

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
      if (!isSeeking.value && !tripling) {
        controls = false;
      }
      _timer = null;
    });
  }

  void onSeekStart(int seekFrom) {
    seekPosition.value = seekFrom;
    isSeeking.value = true;
  }

  void onSeekEnd() {
    if (showSeekPreview) {
      showPreview.value = false;
    }
    hasToasted = false;
    isSeeking.value = false;
    if (PlatformUtils.isDesktop) {
      requireDesktopProgressHoverReenter = _desktopProgressPointerInside;
      hideDesktopProgressPreview();
    }
    hideTaskControls();
  }

  final RxBool volumeIndicator = false.obs;
  Timer? volumeTimer;
  bool volumeInterceptEventStream = false;

  double get maxVolume => PlatformUtils.isDesktop
      ? Pref.maxVolume
      : (Pref.enableAppVolume && Pref.enableVolumeBoost ? 2.0 : 1.0);

  // 音量增强二次确认：是否已解锁突破 100%（松手后重置）
  bool volumeBoostUnlocked = false;

  // 手势滑动时的音量上限：未解锁时最大 1.0，解锁后最大 2.0
  double get gestureVolumeMax {
    if (Pref.enableAppVolume && Pref.enableVolumeBoost) {
      return volumeBoostUnlocked ? 2.0 : 1.0;
    }
    return maxVolume;
  }

  // 松手时重置解锁状态
  void onVolumeGestureEnd() {
    if (Pref.enableAppVolume && Pref.enableVolumeBoost) {
      volumeBoostUnlocked = false;
    }
  }

  Future<void> setVolume(double volume, {bool showIndicator = true}) async {
    if (this.volume.value != volume) {
      this.volume.value = volume;
      try {
        if (PlatformUtils.isDesktop) {
          await _videoPlayerController!.setVolume(volume * 100);
        } else {
          // 移动平台：根据设置选择音量控制方式
          if (Pref.enableAppVolume) {
            // 应用内音量模式：使用 media_kit 控制应用内音量
            _videoPlayerController?.setVolume(volume * 100);
            if (_useMedia3Dovi) {
              unawaited(NativeVideoSurfaceChannel.doviSetVolume(volume: volume));
            }
          } else {
            // 默认模式：控制系统音量
            FlutterVolumeController.updateShowSystemUI(false);
            await FlutterVolumeController.setVolume(volume);
          }
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
      } else if (Pref.enableAppVolume) {
        // 移动平台应用内音量模式：保存音量到持久化存储
        // duck 期间不保存，避免保存临时的减半音量
        if (!_isDucked) {
          Pref.appVolume = volume;
        }
      }
    });
  }

  /// 处理应用内音量设置变更
  Future<void> onAppVolumeSettingChanged() async {
    if (!PlatformUtils.isMobile) return;

    // 如果播放器未初始化，直接返回（设置已保存，下次播放器初始化时生效）
    if (_videoPlayerController == null) return;

    if (Pref.enableAppVolume) {
      // 切换到应用内音量模式
      // 获取当前系统音量
      final currentSystemVolume =
          (await FlutterVolumeController.getVolume()) ?? 1.0;
      systemVolume.value = currentSystemVolume;

      final appVolume = (Pref.playerVolume / 100)
          .clamp(0.0, maxVolume)
          .toDouble();
      volume.value = appVolume;
      Pref.appVolume = appVolume;
      volumeBoostUnlocked = false;

      // 关闭上游固定增益，避免和应用内音量叠加
      _videoPlayerController?.setVolume(appVolume * 100);

      // 显示提示
      SmartDialog.showToast('已切换到应用内音量模式');
    } else {
      // 切换到同步系统音量模式
      // 恢复上游播放器音量设置，并按增益折算系统音量
      final currentSystemVolume =
          (await FlutterVolumeController.getVolume()) ?? 1.0;
      final playerGain = max(Pref.playerVolume / 100, 0.01);
      final newSystemVolume = (currentSystemVolume * volume.value / playerGain)
          .clamp(0.0, 1.0)
          .toDouble();

      await FlutterVolumeController.updateShowSystemUI(false);
      await FlutterVolumeController.setVolume(newSystemVolume);
      await _videoPlayerController?.setVolume(Pref.playerVolume);
      volumeBoostUnlocked = false;

      // 更新状态
      systemVolume.value = newSystemVolume;
      volume.value = newSystemVolume;

      SmartDialog.showToast('已切换到同步系统音量模式');
    }
  }

  /// duck 事件处理（由 audio_session.dart 调用）
  Future<void> handleDuck(bool begin) async {
    if (!PlatformUtils.isMobile) return;

    if (Pref.enableAppVolume) {
      // 应用内音量模式：使用临时音量，不影响持久化值
      if (begin) {
        _isDucked = true;
        _preDuckVolume = volume.value;
        volume.value = volume.value * 0.5;
        _videoPlayerController?.setVolume(volume.value * 100);
      } else {
        _isDucked = false;
        volume.value = _preDuckVolume;
        _videoPlayerController?.setVolume(volume.value * 100);
      }
    }
    // 同步模式：使用原有逻辑，直接调用 setVolume 即可
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
    if (!visible && PlatformUtils.isDesktop) {
      hideDesktopProgressPreview();
    }
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
  Future<void> setLongPressStatus(bool val, {bool isCancel = false}) async {
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
        _speedLockArmed = false;
        _cancelSpeedLockHintTimer();
        longPressStatus.value = val;
        HapticFeedback.lightImpact();
        if (speedLocked) {
          // 锁定态：速度已固化为锁定值，不得再调速——setPlaybackSpeed 会
          // 覆盖 lastPlaybackSpeed（锁定前速度），动态倍速下还会二次翻倍
          speedLockHint.value = SpeedLockHint.swipeDownToUnlock;
        } else {
          await setPlaybackSpeed(
            enableAutoLongPressSpeed ? playbackSpeed * 2 : longPressSpeed,
          );
          if (longPressStatus.value) {
            speedLockHint.value = SpeedLockHint.swipeUpToLock;
          }
        }
      }
    } else {
      // 预备态在松手时提交；系统打断（cancel）一律不提交
      final bool commit = _speedLockArmed && !isCancel;
      _speedLockArmed = false;
      longPressStatus.value = val;
      if (speedLocked) {
        if (commit) {
          speedLocked = false;
          HapticFeedback.mediumImpact();
          await setPlaybackSpeed(lastPlaybackSpeed);
          _showTransientSpeedLockHint(SpeedLockHint.unlockedConfirm);
        } else {
          speedLockHint.value = SpeedLockHint.none;
        }
      } else {
        if (commit) {
          speedLocked = true;
          HapticFeedback.mediumImpact();
          _showTransientSpeedLockHint(SpeedLockHint.lockedConfirm);
        } else {
          speedLockHint.value = SpeedLockHint.none;
          await setPlaybackSpeed(lastPlaybackSpeed);
        }
      }
    }
  }

  // 长按倍速锁定：预备阈值 = 播放器实高 × 比例，clamp 到人体工学区间。
  // 比例由实测锚点反推（横屏半屏 48/231≈0.21、横屏全屏 96/411≈0.23），
  // 下限保小窗/小播放器手感，上限≈2.7cm 为拇指第一指节舒适推程封顶
  static const double _speedLockThresholdRatio = 0.22;
  static const double _speedLockThresholdMin = 48;
  static const double _speedLockThresholdMax = 112;
  static const double _speedLockHysteresis = 10;

  /// 长按中手指移动，dy 为相对长按起点的纵向偏移（上滑为负），
  /// [playerHeight] 为播放器组件实高（决定阈值）。
  /// 越线进入预备态、滑回取消预备，均可反复，提交只发生在松手
  void onLongPressMove(double dy, double playerHeight) {
    if (!longPressStatus.value) {
      return;
    }
    final double threshold = clampDouble(
      playerHeight * _speedLockThresholdRatio,
      _speedLockThresholdMin,
      _speedLockThresholdMax,
    );
    if (speedLocked) {
      // 下滑预备退出
      if (!_speedLockArmed && dy >= threshold) {
        _speedLockArmed = true;
        HapticFeedback.lightImpact();
        speedLockHint.value = SpeedLockHint.releaseToUnlock;
      } else if (_speedLockArmed && dy <= threshold - _speedLockHysteresis) {
        _speedLockArmed = false;
        HapticFeedback.lightImpact();
        speedLockHint.value = SpeedLockHint.swipeDownToUnlock;
      }
    } else {
      // 上滑预备锁定
      if (!_speedLockArmed && dy <= -threshold) {
        _speedLockArmed = true;
        HapticFeedback.lightImpact();
        speedLockHint.value = SpeedLockHint.releaseToLock;
      } else if (_speedLockArmed && dy >= -(threshold - _speedLockHysteresis)) {
        _speedLockArmed = false;
        HapticFeedback.lightImpact();
        speedLockHint.value = SpeedLockHint.swipeUpToLock;
      }
    }
  }

  /// 手动调速（倍速菜单/快捷键）：锁定态下先解除锁定再应用所选速度
  Future<void> setManualPlaybackSpeed(double speed) async {
    if (speedLocked) {
      await releaseSpeedLock(restoreSpeed: false);
    }
    await setPlaybackSpeed(speed);
  }

  /// 解除倍速锁定；[restoreSpeed] 为 true 时恢复锁定前速度
  Future<void> releaseSpeedLock({bool restoreSpeed = true}) async {
    if (!speedLocked) {
      return;
    }
    speedLocked = false;
    _speedLockArmed = false;
    _cancelSpeedLockHintTimer();
    speedLockHint.value = SpeedLockHint.none;
    if (restoreSpeed) {
      await setPlaybackSpeed(lastPlaybackSpeed);
    }
  }

  void _showTransientSpeedLockHint(SpeedLockHint hint) {
    speedLockHint.value = hint;
    _speedLockHintTimer?.cancel();
    _speedLockHintTimer = Timer(const Duration(seconds: 2), () {
      if (speedLockHint.value == hint) {
        speedLockHint.value = SpeedLockHint.none;
      }
    });
  }

  void _cancelSpeedLockHintTimer() {
    _speedLockHintTimer?.cancel();
    _speedLockHintTimer = null;
  }

  bool get isCompleted =>
      videoPlayerController!.state.completed ||
      durationInMilliseconds - positionInMilliseconds <= 50;

  // 双击播放、暂停
  Future<void> onDoubleTapCenter() async {
    if (!isLive && isCompleted) {
      await videoPlayerController!.seek(Duration.zero);
      await _rawPlay();
    } else if (videoPlayerController!.state.playing) {
      await pause();
    } else {
      await _rawPlay();
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
    onForwardBackward(videoPlayerController!.state.position + duration);
  }

  void onBackward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position - duration);
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
    if (val) {
      hideDesktopProgressPreview();
    }
    if (!val && showControls.value) {
      showControls.refresh();
    }
    controls = !val;
  }

  void _setFullScreen(bool val) {
    isFullScreen.value = val;
    updateSubtitleStyle();
    onFullScreenChanged?.call(val);
  }

  double screenRatio = 0.0;
  bool isManualFS = true;
  late final FullScreenMode mode = Pref.fullScreenMode;
  late final horizontalScreen = Pref.horizontalScreen;
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
          enterDesktopFullScreen(inAppFullScreen: inAppFullScreen);
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
          exitDesktopFullScreen();
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
    if (!isManual && dataStatus.value != DataStatus.loaded) {
      return null;
    }
    if (isLive ||
        !enableHeart ||
        progress == 0 ||
        (playerStatus.isPaused && !isManual)) {
      SmartDialog.showToast(
        'DBG hb skip progress=$progress enable=$enableHeart paused=${playerStatus.isPaused} data=${dataStatus.value}',
      );
      return null;
    }
    SmartDialog.showToast('DBG hb send progress=$progress type=$type');

    Future<void> send() async {
      try {
        await VideoHttp.heartBeat(
          aid: aid ?? _aid,
          bvid: bvid ?? _bvid,
          cid: cid ?? this.cid,
          progress: progress,
          epid: epid ?? _epid,
          seasonId: seasonId ?? _seasonId,
          subType: pgcType ?? _pgcType,
          videoType: videoType ?? _videoType,
        );
        SmartDialog.showToast('DBG hb ok progress=$progress type=$type');
      } catch (e) {
        SmartDialog.showToast('DBG hb fail progress=$progress err=$e');
      }
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
            (durationInMilliseconds - positionInMilliseconds) <= 1000) {
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
      SettingBoxKey.subtitleSecondaryFontScale: subtitleSecondaryFontScale,
      SettingBoxKey.subtitleSecondaryFontScaleFS: subtitleSecondaryFontScaleFS,
      SettingBoxKey.subtitleSecondaryBgOpacity: subtitleSecondaryBgOpacity,
      SettingBoxKey.subtitleSecondaryStrokeWidth: subtitleSecondaryStrokeWidth,
      SettingBoxKey.subtitleSecondaryFontWeight: subtitleSecondaryFontWeight,
      SettingBoxKey.subtitleSecondarySpacing: subtitleSecondarySpacing,
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
    if (PlatformUtils.isDesktop) exitDesktopFullScreen();
    dispose();
    Get.until((route) => route.isFirst);
  }

  // ──────────────────────────────────────────────
  // 后台自动只听音频 — 状态机
  // ──────────────────────────────────────────────

  /// 手动听视频/仅播放音频标记，由三点菜单或直播按钮调用
  void markManualOnlyPlayAudio(bool enabled) {
    _interruptAutoAudioRestore();
    if (enabled) {
      _cancelAutoAudioOnlyTimer();
      _autoAudioState = AutoAudioOnlyState.manualAudioOnly;
    } else {
      if (_autoAudioState == AutoAudioOnlyState.manualAudioOnly ||
          _autoAudioState == AutoAudioOnlyState.autoAudioOnly) {
        _autoAudioState = AutoAudioOnlyState.idle;
      }
    }
  }

  /// 设置项变更时调用
  void onAutoAudioOnlySettingChanged() {
    if (!Pref.autoAudioOnlyInBackground || !continuePlayInBackground.value) {
      if (_autoAudioState == AutoAudioOnlyState.arm ||
          _autoAudioState == AutoAudioOnlyState.pipHold) {
        _cancelAutoAudioOnlyTimer();
        _autoAudioState = AutoAudioOnlyState.idle;
      } else if (_autoAudioState == AutoAudioOnlyState.autoAudioOnly) {
        _cancelAutoAudioOnlyTimer();
        unawaited(restoreFromAutoAudioOnly());
      }
    }
  }

  void _cancelAutoAudioOnlyTimer() {
    _autoAudioOnlyTimer?.cancel();
    _autoAudioOnlyTimer = null;
  }

  /// 自动只听准入检查
  bool _canEnterAutoAudioOnly() {
    if (!PlatformUtils.isMobile) return false;
    if (!Pref.autoAudioOnlyInBackground) return false;
    if (!continuePlayInBackground.value) return false;
    if (_videoPlayerController == null) return false;
    if (!playerStatus.isPlaying) return false;
    if (isPipMode) return false;
    if (_autoAudioState == AutoAudioOnlyState.manualAudioOnly) return false;
    if (_autoAudioState == AutoAudioOnlyState.autoAudioOnly) return false;
    if (Get.currentRoute == '/audio') return false;
    // 点播有独立音轨才可切；直播没有音轨限制
    if (!isLive && !_hasIndependentAudioTrack) return false;
    return true;
  }

  bool get _hasIndependentAudioTrack {
    if (dataSource is FileSource) {
      return !(dataSource as FileSource).isMp4;
    }
    return dataSource.audioSource?.isNotEmpty == true;
  }

  /// 后台 10 秒到点，切到只听
  Future<void> applyAutoAudioOnly() async {
    if (!_canEnterAutoAudioOnly()) {
      _autoAudioState = AutoAudioOnlyState.idle;
      return;
    }

    onlyPlayAudio.value = true;

    if (isLive) {
      // 直播：重拉 only_audio=1
      _autoAudioState = AutoAudioOnlyState.autoAudioOnly;
      await onNeedsPlayerInit?.call();
    } else {
      // 点播：vid=no
      try {
        _videoPlayerController?.setProperty(
          'file-local-options/vid',
          'no',
        );
      } catch (_) {
        onlyPlayAudio.value = false;
        _autoAudioState = AutoAudioOnlyState.idle;
        return;
      }
      _audioReopened = false;
      _autoAudioState = AutoAudioOnlyState.autoAudioOnly;
    }
  }

  /// 回到前台，恢复画面
  Future<void> restoreFromAutoAudioOnly() async {
    if (_autoAudioState != AutoAudioOnlyState.autoAudioOnly) return;
    if (_autoAudioRestoreInProgress) return;

    _cancelAutoAudioOnlyTimer();
    _autoAudioRestoreInProgress = true;
    final restoreGeneration = ++_autoAudioRestoreGeneration;
    suppressBufferingIndicator.value = !isLive && !_audioReopened;

    try {
      // 直播，以及自动只听期间已经重开过纯音频 Media 的点播，
      // 都没有可供 vid=auto 复用的视频输入，直接走页面级恢复。
      if (isLive || _audioReopened) {
        await _fullRestore();
        return;
      }

      final player = _videoPlayerController;
      if (player == null || player.current.isEmpty) {
        await _fullRestore();
        return;
      }

      onlyPlayAudio.value = false;

      // 第一层：在当前 EDL Media 上重新选择视频轨，不重开 Media。
      try {
        player.setProperty('file-local-options/vid', 'auto');
      } catch (_) {
        await _fullRestore();
        return;
      }
      applyVideoPictureParameters();

      final restoredByTrackSwitch = await _waitForVideoOutput(
        restoreGeneration,
        checkCurrentState: false,
      );
      if (!_isAutoAudioRestoreCurrent(restoreGeneration)) {
        return;
      }

      if (restoredByTrackSwitch) {
        _completeAutoAudioRestore();
        return;
      }

      if (!_canUseAutoAudioRestoreFallback(player)) {
        _completeAutoAudioRestore();
        return;
      }

      // 第二层：当前 EDL 仍可复用时，只重开这一个 Media。
      if (await _reopenCurrentMedia(restoreGeneration)) {
        _completeAutoAudioRestore();
        return;
      }

      if (_isAutoAudioRestoreCurrent(restoreGeneration) &&
          _canUseAutoAudioRestoreFallback(player)) {
        // 第三层：当前 Media 也无法恢复时，交给页面重新初始化资源。
        await _fullRestore();
      } else if (_isAutoAudioRestoreCurrent(restoreGeneration)) {
        _completeAutoAudioRestore();
      }
    } finally {
      if (restoreGeneration == _autoAudioRestoreGeneration) {
        _autoAudioRestoreInProgress = false;
        suppressBufferingIndicator.value = false;
      }
    }
  }

  /// 等待当前 Media 恢复真实视频输出。
  Future<bool> _waitForVideoOutput(
    int restoreGeneration, {
    bool checkCurrentState = true,
  }) {
    final player = _videoPlayerController;
    if (player == null) return Future.value(false);
    if (checkCurrentState && _hasVideoOutput(player)) {
      return Future.value(true);
    }

    final completer = _autoAudioRestoreCompleter = Completer<bool>();
    final subscription = player.stream.videoParams.listen((_) {
      if (!_isAutoAudioRestoreCurrent(restoreGeneration)) {
        _finishAutoAudioRestoreWait(false);
      } else if (_hasVideoOutput(player)) {
        _finishAutoAudioRestoreWait(true);
      }
    });
    _autoAudioRestoreSubscription = subscription;
    _autoAudioRestoreTimer = Timer(
      const Duration(seconds: 4),
      () => _finishAutoAudioRestoreWait(false),
    );
    return completer.future;
  }

  bool _hasVideoOutput(Player player) {
    final state = player.state;
    if (state.track.video.id == 'no') return false;
    final params = state.videoParams;
    final width = params.dw ?? params.w ?? 0;
    final height = params.dh ?? params.h ?? 0;
    return width > 0 && height > 0;
  }

  bool _canUseAutoAudioRestoreFallback(Player player) =>
      playerStatus.isPlaying || player.state.buffering;

  bool _isAutoAudioRestoreCurrent(int restoreGeneration) =>
      restoreGeneration == _autoAudioRestoreGeneration &&
      _autoAudioState == AutoAudioOnlyState.autoAudioOnly &&
      _lastAppLifecycleState != AppLifecycleState.hidden &&
      _lastAppLifecycleState != AppLifecycleState.paused &&
      _lastAppLifecycleState != AppLifecycleState.detached &&
      !isPipMode;

  void _completeAutoAudioRestore() {
    _autoAudioState = AutoAudioOnlyState.idle;
    _audioReopened = false;
  }

  void _finishAutoAudioRestoreWait(bool result) {
    final completer = _autoAudioRestoreCompleter;
    if (completer == null || completer.isCompleted) return;
    _autoAudioRestoreTimer?.cancel();
    _autoAudioRestoreTimer = null;
    unawaited(_autoAudioRestoreSubscription?.cancel());
    _autoAudioRestoreSubscription = null;
    _autoAudioRestoreCompleter = null;
    completer.complete(result);
  }

  void _interruptAutoAudioRestore() {
    if (!_autoAudioRestoreInProgress &&
        _autoAudioRestoreCompleter == null) {
      return;
    }
    _autoAudioRestoreGeneration++;
    _autoAudioRestoreInProgress = false;
    suppressBufferingIndicator.value = false;
    _finishAutoAudioRestoreWait(false);
  }

  /// 第二层：重开当前 Media，避免立即进入页面级 playerInit 的加载状态。
  Future<bool> _reopenCurrentMedia(int restoreGeneration) async {
    final player = _videoPlayerController;
    if (player == null || player.current.isEmpty) return false;
    if (!_isAutoAudioRestoreCurrent(restoreGeneration)) return false;

    try {
      final shouldResumePlayback = player.state.playing;
      await player.open(
        player.current.last.copyWith(start: player.state.position),
        play: shouldResumePlayback,
      );
      applyVideoPictureParameters(player);
    } catch (_) {
      return false;
    }

    if (!_isAutoAudioRestoreCurrent(restoreGeneration)) return false;
    return _waitForVideoOutput(restoreGeneration);
  }

  /// 第三层：点播 playerInit，直播 queryLiveUrl。
  Future<void> _fullRestore() async {
    suppressBufferingIndicator.value = false;
    onlyPlayAudio.value = false;
    _completeAutoAudioRestore();
    await onNeedsPlayerInit?.call();
  }

  /// 生命周期变化 — 由 view 转发
  void handleAutoAudioOnlyLifecycle(AppLifecycleState state) {
    _lastAppLifecycleState = state;

    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _cancelAutoAudioOnlyTimer();
        if (_autoAudioRestoreInProgress) {
          _interruptAutoAudioRestore();
        }
        // 已在只听/手动听视频时，保持状态不退出
        if (_autoAudioState == AutoAudioOnlyState.autoAudioOnly ||
            _autoAudioState == AutoAudioOnlyState.manualAudioOnly) {
          break;
        }
        if (isPipMode) {
          _autoAudioState = AutoAudioOnlyState.pipHold;
        } else if (_canEnterAutoAudioOnly()) {
          _autoAudioOnlyTimer = Timer(
            const Duration(seconds: 10),
            applyAutoAudioOnly,
          );
          _autoAudioState = AutoAudioOnlyState.arm;
        }
        break;
      case AppLifecycleState.resumed:
        _cancelAutoAudioOnlyTimer();
        if (_autoAudioState == AutoAudioOnlyState.autoAudioOnly) {
          if (!_autoAudioRestoreInProgress) {
            unawaited(restoreFromAutoAudioOnly());
          }
        } else if (_autoAudioState == AutoAudioOnlyState.arm ||
            _autoAudioState == AutoAudioOnlyState.pipHold) {
          _autoAudioState = AutoAudioOnlyState.idle;
        }
        // manualAudioOnly / pipHold / arm / idle：保持状态不重置
        break;
      case AppLifecycleState.inactive:
        // 过渡状态，忽略
        break;
      case AppLifecycleState.detached:
        _cancelAutoAudioOnlyTimer();
        _interruptAutoAudioRestore();
        break;
    }
  }

  /// 系统 PiP 变化时由 onPipChanged 调用
  void handleAutoAudioOnlyPipChanged(bool isInPip) {
    if (isInPip) {
      _cancelAutoAudioOnlyTimer();
      if (_autoAudioRestoreInProgress) {
        _interruptAutoAudioRestore();
      }
      if (_autoAudioState == AutoAudioOnlyState.arm) {
        _autoAudioState = AutoAudioOnlyState.pipHold;
      }
    } else {
      // PiP 关闭
      _cancelAutoAudioOnlyTimer();
      if (_lastAppLifecycleState == AppLifecycleState.resumed) {
        if (_autoAudioState == AutoAudioOnlyState.autoAudioOnly) {
          unawaited(restoreFromAutoAudioOnly());
        } else if (_autoAudioState == AutoAudioOnlyState.arm ||
            _autoAudioState == AutoAudioOnlyState.pipHold) {
          _autoAudioState = AutoAudioOnlyState.idle;
        }
        // manualAudioOnly 保持不动
      } else {
        // 仍在后台：仅当不在只听/手动听时重新 arm
        if (_autoAudioState == AutoAudioOnlyState.autoAudioOnly ||
            _autoAudioState == AutoAudioOnlyState.manualAudioOnly) {
          return;
        }
        _autoAudioState = AutoAudioOnlyState.arm;
        _autoAudioOnlyTimer = Timer(
          const Duration(seconds: 10),
          applyAutoAudioOnly,
        );
      }
    }
  }

  void dispose() {
    // 离开播放页时复位窗口 HDR 模式，避免设置页/首页留在 HDR 窗口模式。
    _resetWindowHdr();
    _doviDisposed = true;
    _releaseDoviPlayer();
    _hdrSnapshotTimer?.cancel();
    // 注意：不要在这里抓快照。销毁过程中 surfaceDestroyed 会把 vo 置回 null，
    // 抓到的会是「拆机态」。播放中每 5 秒的快照已经足够还原真实状态。
    _cancelAutoAudioOnlyTimer();
    _interruptAutoAudioRestore();
    _autoAudioState = AutoAudioOnlyState.idle;
    _audioReopened = false;
    _lastAppLifecycleState = null;
    // 每次减1，最后销毁
    resetScreenRotation();
    cancelLongPressTimer();
    _cancelSpeedLockHintTimer();
    speedLocked = false;
    _speedLockArmed = false;
    speedLockHint.value = SpeedLockHint.none;
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
    danmakuMaskPath.value = null;
    _stopOrientationListener();
    _disableAutoEnterPip();
    setPlayCallBack(null);
    dmState.clear();
    hideDesktopProgressPreview();
    if (showSeekPreview) {
      _clearPreview();
    }
    if (Platform.isAndroid) {
      AndroidHelper$ToDart.onUserLeaveHint = null;
    } else if (Platform.isIOS) {
      IOSPipHelper.dispose();
    }
    _timer?.cancel();
    persistVideoPictureSettings();
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
      WindowController.instance.window?.isAlwaysOnTop = false;
    }

    _removeListeners();
    _positionListeners.clear();
    _statusListeners.clear();
    _stopWakeLockTimer();
    WakelockPlus.disable();
    if (kDebugMode) {
      debugPrint('dispose player');
    }
    nativeSurfaceMode.value = false;
    _resetNativeSurfaceState();
    _setVideoController(null);
    _videoPlayerController?.dispose();
    _videoPlayerController = null;
    _activeVideoContextKey = null;
    danmakuMaskPath.dispose();
    _instance = null;
    videoPlayerServiceHandler?.clear();
  }

  static void updatePlayCount() {
    if (_instance?._playerCount == 1) {
      _instance?.dispose();
    } else {
      _instance?._playerCount -= 1;
    }
  }

  void setContinuePlayInBackground() {
    continuePlayInBackground.toggle();
    if (!tempPlayerConf) {
      setting.put(
        SettingBoxKey.continuePlayInBackground,
        continuePlayInBackground.value,
      );
    }
    // 关掉后台播放时，停止自动只听状态机
    if (!continuePlayInBackground.value) {
      onAutoAudioOnlySettingChanged();
    }
  }

  late final Map<String, ui.Image?> previewCache = {};
  LoadingState<VideoShotData>? videoShot;
  late final RxBool showPreview = false.obs;
  late final showSeekPreview = Pref.showSeekPreview;
  late final previewIndex = RxnInt();
  final RxBool showDesktopProgressFeedback = false.obs;
  final Rx<double?> desktopProgressHoverValue = Rx<double?>(null);
  final Rx<double?> desktopProgressPreviewValue = Rx<double?>(null);
  final RxInt progressPreviewSeconds = 0.obs;
  final RxInt desktopProgressPreviewLayoutVersion = 0.obs;
  bool _desktopProgressPointerInside = false;
  bool requireDesktopProgressHoverReenter = false;

  bool get _canUseSeekPreview =>
      !isFileSource && showSeekPreview && cid != null;

  void refreshDesktopProgressPreviewLayout() {
    desktopProgressPreviewLayoutVersion.value++;
  }

  double _progressValueFromDuration(Duration value) {
    if (durationInMilliseconds <= 0) {
      return 0.0;
    }
    return (value.inMilliseconds / durationInMilliseconds).clamp(0.0, 1.0);
  }

  void _setDesktopProgressPreviewState(Duration value) {
    final progressValue = _progressValueFromDuration(value);
    progressPreviewSeconds.value = value.inSeconds;
    desktopProgressHoverValue.value = progressValue;
    desktopProgressPreviewValue.value = progressValue;
  }

  void updateDesktopProgressPreviewFromDrag(Duration value) {
    if (!PlatformUtils.isDesktop) {
      return;
    }
    _setDesktopProgressPreviewState(value);
    showDesktopProgressFeedback.value = true;
    if (!isFileSource && showSeekPreview) {
      updatePreviewIndex(value.inSeconds);
    }
  }

  void onDesktopProgressDragStart(Duration value) {
    _desktopProgressPointerInside = true;
    requireDesktopProgressHoverReenter = false;
    updateDesktopProgressPreviewFromDrag(value);
  }

  void onDesktopProgressHoverStart(Duration value) {
    _desktopProgressPointerInside = true;
    if (controlsLock.value || isSeeking.value) {
      return;
    }
    if (requireDesktopProgressHoverReenter) {
      return;
    }
    _setDesktopProgressPreviewState(value);
    showDesktopProgressFeedback.value = true;
    if (!isFileSource && showSeekPreview) {
      updatePreviewIndex(value.inSeconds);
    }
  }

  void onDesktopProgressHoverUpdate(Duration value) {
    _desktopProgressPointerInside = true;
    if (controlsLock.value || isSeeking.value) {
      return;
    }
    if (requireDesktopProgressHoverReenter) {
      return;
    }
    _setDesktopProgressPreviewState(value);
    showDesktopProgressFeedback.value = true;
    if (!isFileSource && showSeekPreview) {
      updatePreviewIndex(value.inSeconds);
    }
  }

  void onDesktopProgressHoverEnd() {
    _desktopProgressPointerInside = false;
    requireDesktopProgressHoverReenter = false;
    if (!isSeeking.value) {
      hideDesktopProgressPreview();
    }
  }

  void hideDesktopProgressPreview() {
    showDesktopProgressFeedback.value = false;
    desktopProgressHoverValue.value = null;
    desktopProgressPreviewValue.value = null;
    if (showSeekPreview) {
      showPreview.value = false;
    }
  }

  void _setPreviewIndexFromShot(int seconds) {
    final shot = videoShot;
    if (shot case Success(:final response)) {
      previewIndex.value = max(
        0,
        (response.index.where((item) => item <= seconds).length - 2),
      );
    }
  }

  Future<void> ensureVideoShot() async {
    if (!_canUseSeekPreview) {
      return;
    }
    if (videoShot is Loading) {
      return;
    }
    if (videoShot case Success()) {
      return;
    }

    final requestBvid = bvid;
    final requestCid = cid!;
    videoShot = LoadingState.loading();
    final response = await VideoHttp.videoshot(
      bvid: requestBvid,
      cid: requestCid,
    );
    if (requestBvid != _bvid || requestCid != cid) {
      return;
    }

    videoShot = response;
    if (!showPreview.value) {
      return;
    }
    if (response case Success()) {
      _setPreviewIndexFromShot(progressPreviewSeconds.value);
    } else {
      showPreview.value = false;
      previewIndex.value = null;
    }
  }

  void updatePreviewIndex(int seconds) {
    if (!_canUseSeekPreview) {
      return;
    }
    showPreview.value = true;
    if (videoShot == null) {
      previewIndex.value = null;
      unawaited(ensureVideoShot());
      return;
    }
    if (videoShot is Loading) {
      previewIndex.value = null;
      return;
    }
    if (videoShot case Success()) {
      _setPreviewIndexFromShot(seconds);
    } else {
      showPreview.value = false;
      previewIndex.value = null;
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

  /// 上游的 getVideoShot 与之并存的 ensureVideoShot（本 fork）：
  /// ensureVideoShot 会做 _canUseSeekPreview 守卫 + 迟到响应丢弃，
  /// 保留本 fork 版本，删除上游的简单版避免命名冲突。
  int _screenshotState = 0;

  /// 抓取当前画面：HDR 直通时 mpv 拿不到帧，改由原生 SurfaceView 截图。
  Future<ui.Image?> _grabScreenshotImage() async {
    final nativeOwner = _nativeOwner;
    if (!nativeSurfaceMode.value || nativeOwner == null) {
      return videoPlayerController?.screenshot();
    }
    final bytes = await NativeVideoSurfaceChannel.capture(owner: nativeOwner);
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  Future<void> takeScreenshot() async {
    if (_screenshotState > 0) return;
    _screenshotState = 1;
    SmartDialog.showToast('截图中');
    final image = await _grabScreenshotImage();
    if (image != null) {
      SmartDialog.showToast('点击弹窗或按 Enter 保存截图');
      await showDialog(
        context: Get.context!,
        requestFocus: true,
        builder: (context) {
          Future<void> save() async {
            if (_screenshotState > 1) return;
            _screenshotState = 2;
            final bytes = await image.toByteData(format: .png);
            if (bytes != null) {
              final time = DurationUtils.formatDuration(
                positionInMilliseconds / 1000,
              ).replaceAll(':', '-');
              ImageUtils.saveByteImg(
                bytes: bytes.buffer.asUint8List(),
                fileName: 'screenshot_${cid}_$time',
              );
            } else {
              SmartDialog.showToast('保存失败');
            }
            Get.back();
          }

          return Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent) {
                final key = event.logicalKey;
                if (key == .keyS || key == .enter || key == .numpadEnter) {
                  save();
                  return .handled;
                }
              }
              return .ignored;
            },
            child: GestureDetector(
              onTap: save,
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
          );
        },
      );
      image.dispose();
    } else {
      SmartDialog.showToast('截图失败');
    }
    _screenshotState = 0;
  }

  void onPopInvokedWithResult(
    bool didPop,
    Object? result, {
    bool pauseOnPop = true,
  }) {
    if (didPop) {
      if (pauseOnPop && playerStatus.isPlaying) {
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
