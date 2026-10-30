import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 与原生 `VideoSurfaceHost`（Kotlin）通信的通道封装。
///
/// HDR 直通出画时视频由 Flutter **之下**的原生 `SurfaceView` 输出：
/// * Flutter 只负责在该位置保留一块透明占位、把屏幕矩形同步给原生；
/// * 原生把 `android.view.Surface` 的 global ref（`wid`）回传给 mpv；
/// * 弹幕/控件仍然由 Flutter 正常绘制在视频之上。
///
/// 之所以不放进 media_kit 的 PlatformView：hybrid composition 的原生 View
/// 位于 Flutter 渲染层之上，会盖住弹幕与控制栏。
abstract final class NativeVideoSurfaceChannel {
  static const MethodChannel channel = MethodChannel(
    'com.pilinara/video_surface',
  );

  /// 创建（或复用）原生 SurfaceView，并把它摆到物理像素矩形。
  ///
  /// [owner] 是本次占用的令牌：页面 ↔ 小窗切换时新旧控件会短暂共存，
  /// 原生侧用它过滤过期调用。`x/y/width/height` 为相对 FlutterView 的物理像素。
  static Future<void> create({
    required int owner,
    required int x,
    required int y,
    required int width,
    required int height,
    required bool tenBit,
  }) => channel.invokeMethod<void>('create', {
    'owner': owner,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'tenBit': tenBit,
  });

  /// 只更新位置/大小（布局变化、缩放、旋转、小窗动画）。
  static Future<void> setRect({
    required int owner,
    required int x,
    required int y,
    required int width,
    required int height,
  }) => channel.invokeMethod<void>('setRect', {
    'owner': owner,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  });

  /// 请求/退出窗口 HDR 色彩模式（仅真 HDR 播放时开启）。
  static Future<void> setHdr({required int owner, required bool hdr}) =>
      channel.invokeMethod<void>('setHdr', {'owner': owner, 'hdr': hdr});

  /// 释放所有权。原生侧会延迟销毁，等待新 owner 接管。
  static Future<void> remove({required int owner}) =>
      channel.invokeMethod<void>('remove', {'owner': owner});

  /// 从原生 SurfaceView 抓取当前画面（PNG）。
  ///
  /// `vo=mediacodec_embed` 时画面不经过 mpv，`Player.screenshot()` 拿不到帧。
  static Future<Uint8List?> capture({required int owner}) =>
      channel.invokeMethod<Uint8List>('capture', {'owner': owner});

  /// 采样 SurfaceView 画面，返回 `{mean, max, bright}`：
  /// * `mean`：采样点平均亮度（0-255）；
  /// * `max`：最大亮度；
  /// * `bright`：亮度 > 8 的采样点数量。
  ///
  /// `mean` 为 0（或极小）表示 Surface 本身是黑的（解码器没出画），
  /// 与 Flutter 是否遮盖无关。
  static Future<Map?> probe({required int owner}) =>
      channel.invokeMethod<Map>('probe', {'owner': owner});

  /// 诊断：Flutter 层背景模式、SurfaceView format 与视图树。
  static Future<String?> surfaceInfo() =>
      channel.invokeMethod<String>('surfaceInfo');

  /// 进入 HDR 播放前预切窗口色彩模式，使面板切换发生在加载/黑屏阶段。
  static Future<void> setWindowHdr({required bool enabled}) =>
      channel.invokeMethod<void>('setWindowHdr', {'enabled': enabled});

  /// Media3 DoVi 视频：把视频流交给原生 ExoPlayer 解码到同一个 SurfaceView。
  static Future<bool> doviPrepare({
    required String url,
    required String? audioUrl,
    required String referer,
    required String userAgent,
  }) async =>
      await channel.invokeMethod<bool>('doviPrepare', {
        'url': url,
        'audioUrl': audioUrl,
        'referer': referer,
        'userAgent': userAgent,
      }) ??
      false;

  static Future<void> doviPlay() =>
      channel.invokeMethod<void>('doviPlay');

  static Future<void> doviPause() =>
      channel.invokeMethod<void>('doviPause');

  static Future<void> doviSeek({required int positionMs}) =>
      channel.invokeMethod<void>('doviSeek', {'positionMs': positionMs});

  static Future<void> doviSetRate({required double rate}) =>
      channel.invokeMethod<void>('doviSetRate', {'rate': rate});

  static Future<void> doviSetVolume({required double volume}) =>
      channel.invokeMethod<void>('doviSetVolume', {'volume': volume});

  static Future<int> doviPosition() async =>
      await channel.invokeMethod<int>('doviPosition') ?? 0;

  static Future<void> doviRelease() =>
      channel.invokeMethod<void>('doviRelease');
}
