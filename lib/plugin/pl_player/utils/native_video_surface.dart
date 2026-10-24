import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:PiliPlus/plugin/pl_player/controller.dart';

/// 视频在 Flutter **之下**的原生出画层。
///
/// Flutter 的 surface 在 P1 已设为透明且 Z 序置顶，因此这里只需要：
/// 1. 请原生创建一块 SurfaceView（位于 FlutterView 下层）；
/// 2. 把本控件在屏幕上的真实矩形（物理像素）同步给原生；
/// 3. 把原生回报的 `wid` / 尺寸转交给播放器去驱动 mpv。
///
/// 本控件自身不绘制任何内容（透明），弹幕/控件由 Flutter 正常叠加。
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

class _NativeVideoSurfaceState extends State<NativeVideoSurface> {
  static const _channel = MethodChannel('com.pilinara/video_surface');

  bool _disposed = false;
  Timer? _rectTimer;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_onNativeCall);
    _channel.invokeMethod('create');
    // 布局/全屏/旋转变化不一定触发 rebuild，这里低频兜底同步矩形。
    _rectTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _syncRect(),
    );
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (_disposed) return null;
    final args = call.arguments;
    switch (call.method) {
      case 'surfaceCreated':
        widget.controller.attachNativeSurface(
          (args['wid'] as num).toInt(),
          (args['width'] as num).toInt(),
          (args['height'] as num).toInt(),
        );
        break;
      case 'surfaceChanged':
        widget.controller.resizeNativeSurface(
          (args['width'] as num).toInt(),
          (args['height'] as num).toInt(),
        );
        break;
      case 'surfaceDestroyed':
        widget.controller.detachNativeSurface();
        break;
    }
    return null;
  }

  void _syncRect() {
    if (_disposed || !mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final topLeft = box.localToGlobal(Offset.zero);
    final bottomRight = box.localToGlobal(box.size.bottomRight(Offset.zero));
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final left = (topLeft.dx * dpr).round();
    final top = (topLeft.dy * dpr).round();
    final width = ((bottomRight.dx - topLeft.dx) * dpr).round();
    final height = ((bottomRight.dy - topLeft.dy) * dpr).round();
    if (width <= 0 || height <= 0) return;
    _channel.invokeMethod('setRect', {
      'x': left,
      'y': top,
      'width': width,
      'height': height,
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _rectTimer?.cancel();
    _channel.setMethodCallHandler(null);
    _channel.invokeMethod('remove');
    widget.controller.detachNativeSurface();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncRect());
    final videoController = widget.controller.videoController;
    if (videoController == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: videoController.rect,
      builder: (context, _) {
        final rect = videoController.rect.value;
        if (rect == null || rect.width <= 0 || rect.height <= 0) {
          return const SizedBox.shrink();
        }
        final dpr = MediaQuery.devicePixelRatioOf(context);
        return SizedBox(
          width: widget.aspectRatio == null
              ? rect.width / dpr
              : rect.height / dpr * widget.aspectRatio!,
          height: rect.height / dpr,
        );
      },
    );
  }
}
