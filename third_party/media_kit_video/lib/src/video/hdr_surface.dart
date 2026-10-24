import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Android `SurfaceView` host for HDR video output.
///
/// 为什么不用 `AndroidView`：
/// * `AndroidView` 可能走 virtual display（最终仍是纹理，8bit），
///   必须显式使用 hybrid composition（`initExpensiveAndroidView`）才能拿到
///   真正的 SurfaceView，供 libmpv / MediaCodec 直接输出；
/// * hybrid composition 的原生 View 默认会参与手势竞争，把 Flutter 侧的
///   点击（控制栏、进度条）吃掉。这里用 `transparent` 命中测试 + 空手势集合，
///   让点击全部交给 Flutter 的控件层。
class MpvHdrSurface extends StatelessWidget {
  const MpvHdrSurface({super.key, required this.handle, this.tenBit = true});

  /// libmpv 的 `mpv_handle*` 地址，原生侧用它把 `--wid` 回传给 Dart。
  final int handle;

  /// 是否向 SurfaceView 申请 10bit 缓冲（RGBA_1010102）。
  /// `vo=mediacodec_embed` 由解码器决定缓冲格式，不能再强设。
  final bool tenBit;

  static const String viewType = 'media_kit_video/hdr_surface';

  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(
      viewType: viewType,
      onCreatePlatformView: (params) {
        return PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: viewType,
          layoutDirection: Directionality.of(context),
          creationParams: {'handle': handle, 'tenBit': tenBit},
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
      },
      surfaceFactory: (context, controller) => PlatformViewSurface(
        controller: controller,
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        // 空集合 = 原生视图不参与手势竞争，点击交回 Flutter。
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      ),
    );
  }
}
