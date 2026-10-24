import 'dart:async';
import 'dart:math' show max, min;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/hdr_config.dart';
import 'package:PiliPlus/plugin/pl_player/utils/native_video_surface_channel.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart' show Obx;

/// 视频在 Flutter **之下**的原生出画层（HDR 直通）。
///
/// Flutter 侧只保留一块与视频同尺寸的透明占位，真正画面由原生 SurfaceView 输出：
/// * 点击、弹幕、控制栏仍由 Flutter 正常接收与绘制（不会被原生 View 遮挡）；
/// * SurfaceView 的位置/大小按本控件在屏幕上的真实矩形逐帧同步；
/// * 页面 ↔ 小窗切换时用 owner 令牌交接，避免 Surface 反复重建造成黑闪。
class NativeVideoSurface extends StatefulWidget {
  const NativeVideoSurface({
    super.key,
    required this.controller,
    this.aspectRatio,
  });

  final PlPlayerController controller;
  final double? aspectRatio;

  @override
  State<NativeVideoSurface> createState() => _NativeVideoSurfaceState();
}

class _NativeVideoSurfaceState extends State<NativeVideoSurface>
    with WidgetsBindingObserver {
  static int _nextOwner = 0;

  /// 通道只有一个 handler，由最近一次 create 成功的控件持有。
  static _NativeVideoSurfaceState? _handlerOwner;

  late final int _owner = ++_nextOwner;

  bool _created = false;
  bool _attached = false;
  int? _surfaceWid;
  (int, int, int, int)? _lastRect;
  bool _disposed = false;
  bool _frameScheduled = false;

  /// 无帧时的兜底同步（小窗拖动、系统 PiP 尺寸变化不一定触发 Flutter 帧）。
  Timer? _fallbackTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fallbackTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _sync(),
    );
    _scheduleSync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_created) return;
    final rect = _lastRect;
    if (rect == null) return;
    // 切后台/Activity 重建可能让原生侧的宿主与 Surface 丢失，
    // 回到前台时重新 create 一次（原生侧会复用已有 Surface，不会重建）。
    _ensureHandler();
    unawaited(
      NativeVideoSurfaceChannel.create(
        owner: _owner,
        x: rect.$1,
        y: rect.$2,
        width: rect.$3,
        height: rect.$4,
        tenBit: Pref.hdrBackend != HdrBackend.mediacodecEmbed.value,
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    if (identical(_handlerOwner, this)) {
      _handlerOwner = null;
      NativeVideoSurfaceChannel.channel.setMethodCallHandler(null);
    }
    if (_created) {
      unawaited(NativeVideoSurfaceChannel.remove(owner: _owner));
      _created = false;
    }
    // 令牌不匹配时（新控件已接管）控制器会忽略这次 detach。
    widget.controller.detachNativeSurface(_owner);
    super.dispose();
  }

  /// 每帧结束后同步一次矩形（不主动申请帧，因此不会空转耗电）。
  void _scheduleSync() {
    if (_disposed || _frameScheduled) return;
    _frameScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _frameScheduled = false;
      if (!mounted || _disposed) return;
      _sync();
      _scheduleSync();
    });
  }

  void _ensureHandler() {
    if (identical(_handlerOwner, this)) return;
    _handlerOwner = this;
    NativeVideoSurfaceChannel.channel.setMethodCallHandler(_onNativeCall);
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (_disposed || !mounted) return null;
    final args = call.arguments;
    if (args is! Map) return null;
    if ((args['owner'] as num?)?.toInt() != _owner) return null;
    switch (call.method) {
      case 'surfaceCreated':
        final wid = (args['wid'] as num?)?.toInt() ?? 0;
        if (wid == 0) return null;
        _surfaceWid = wid;
        _attachOrResize(
          (args['width'] as num?)?.toInt() ?? 0,
          (args['height'] as num?)?.toInt() ?? 0,
        );
        break;
      case 'surfaceDestroyed':
        _surfaceWid = null;
        _attached = false;
        widget.controller.detachNativeSurface(_owner);
        break;
      // 布局尺寸变化（全屏/旋转/小窗拖动）：同步给 mpv 的
      // `android-surface-size`，控制器内部做了防抖。
      case 'surfaceChanged':
        _attachOrResize(
          (args['width'] as num?)?.toInt() ?? 0,
          (args['height'] as num?)?.toInt() ?? 0,
        );
        break;
    }
    return null;
  }

  /// 挂载 wid（首次）或更新 SurfaceView 布局尺寸。
  void _attachOrResize(int nativeWidth, int nativeHeight) {
    final wid = _surfaceWid;
    if (wid == null || nativeWidth <= 1 || nativeHeight <= 1) return;
    if (!_attached) {
      widget.controller.attachNativeSurface(
        _owner,
        wid,
        nativeWidth,
        nativeHeight,
      );
      _attached = true;
    } else {
      widget.controller.resizeNativeSurface(
        _owner,
        nativeWidth,
        nativeHeight,
      );
    }
  }

  void _sync() {
    if (_disposed || !mounted) return;
    final controller = widget.controller;
    if (!controller.useNativeSurface) return;
    final videoController = controller.videoController;
    if (videoController == null) return;

    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || box.size.isEmpty) return;
    final bounds = _globalBounds(box);
    if (bounds == null) return;

    // 通知播放页根节点：只有这个矩形可以透出底层原生画面。
    widget.controller.nativeContentRect.value = bounds;

    final dpr = MediaQuery.devicePixelRatioOf(context);
    final left = (bounds.left * dpr).round();
    final top = (bounds.top * dpr).round();
    final width = (bounds.width * dpr).round();
    final height = (bounds.height * dpr).round();
    if (width <= 0 || height <= 0) return;

    final target = (left, top, width, height);
    if (!_created) {
      _created = true;
      _lastRect = target;
      _ensureHandler();
      unawaited(
        NativeVideoSurfaceChannel.create(
          owner: _owner,
          x: left,
          y: top,
          width: width,
          height: height,
          tenBit: Pref.hdrBackend != HdrBackend.mediacodecEmbed.value,
        ),
      );
      return;
    }
    if (_lastRect != target) {
      _lastRect = target;
      unawaited(
        NativeVideoSurfaceChannel.setRect(
          owner: _owner,
          x: left,
          y: top,
          width: width,
          height: height,
        ),
      );
    }
  }

  /// 本控件在屏幕上的轴对齐包围盒（含 FittedBox 缩放与 InteractiveViewer 变换）。
  ///
  /// 四个角都参与计算：只取左上/右下在旋转时得到的包围盒偏小；HDR 模式已禁用
  /// 旋转与镜像，因此这里与画面矩形一致。
  Rect? _globalBounds(RenderBox box) {
    final matrix = box.getTransformTo(null);
    final size = box.size;
    final points = [
      MatrixUtils.transformPoint(matrix, Offset.zero),
      MatrixUtils.transformPoint(matrix, Offset(size.width, 0)),
      MatrixUtils.transformPoint(matrix, Offset(size.width, size.height)),
      MatrixUtils.transformPoint(matrix, Offset(0, size.height)),
    ];
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;
    for (final point in points) {
      if (!point.dx.isFinite || !point.dy.isFinite) return null;
      left = min(left, point.dx);
      top = min(top, point.dy);
      right = max(right, point.dx);
      bottom = max(bottom, point.dy);
    }
    if (right <= left || bottom <= top) return null;
    return Rect.fromLTRB(left, top, right, bottom);
  }

  @override
  Widget build(BuildContext context) {
    _scheduleSync();
    final controller = widget.controller;
    return Obx(() {
      final videoController = controller.videoOutput.value;
      if (videoController == null || !controller.useNativeSurface) {
        return const SizedBox.shrink();
      }
      return ValueListenableBuilder<Rect?>(
        valueListenable: videoController.rect,
        builder: (context, rect, _) {
          final dpr = MediaQuery.devicePixelRatioOf(context);
          if (rect == null || rect.width <= 1 || rect.height <= 1) {
            // 视频参数还没到：先按 16:9 占位，让原生 SurfaceView 能尽早
            // 拿到 wid 并初始化视频输出（否则 mpv 可能永远不产生 video-params）。
            return const SizedBox(width: 16, height: 9);
          }
          final height = rect.height / dpr;
          final aspectRatio = widget.aspectRatio;
          final width = aspectRatio == null
              ? rect.width / dpr
              : height * aspectRatio;
          return SizedBox(width: width, height: height);
        },
      );
    });
  }
}
