/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

import 'package:media_kit/media_kit.dart';

import 'package:media_kit_video/src/video_controller/platform_video_controller.dart';

/// {@template android_video_controller}
///
/// AndroidVideoController
/// ----------------------
///
/// The [PlatformVideoController] implementation based on native JNI & C/C++ used on Android.
///
/// {@endtemplate}
class AndroidVideoController extends PlatformVideoController {
  /// Whether [AndroidVideoController] is supported on the current platform or not.
  static bool get supported => Platform.isAndroid;

  /// Whether this controller renders into a native Android `SurfaceView`.
  @override
  bool get usesAndroidSurfaceView => configuration.androidSurfaceView;

  /// Pointer address to the global object reference of `android.view.Surface` i.e. `(intptr_t)(*android.view.Surface)`.
  final ValueNotifier<int?> wid = ValueNotifier<int?>(null);

  /// [Lock] used to synchronize [onLoadHooks], [onUnloadHooks] & [subscription].
  final lock = Lock();

  void setProperties(Map<String, String> properties) {
    for (final entry in properties.entries) {
      player.setProperty(entry.key, entry.value);
    }
  }

  /// Listener for updating the --wid property.
  Future<void> widListener() {
    return lock.synchronized(() async {
      if (configuration.androidSurfaceView) {
        // SurfaceView path: `--wid` / `--android-surface-size` are applied by
        // [_applySurfaceView] using the real surface size reported by native.
        return;
      }
      final width = rect.value?.width.toInt() ?? 1;
      final height = rect.value?.height.toInt() ?? 1;
      final androidSurfaceSizeValue = '${width}x$height';
      final widValue = wid.value?.toString() ?? '0';
      // When --wid is 0, vo=null is required to avoid SIGSEGV.
      final voValue = widValue == '0' ? 'null' : configuration.vo ?? 'gpu';
      final vidValue = widValue == '0' ? 'no' : 'auto';
      // It is important to re-initialize --vo after --android-surface-size.
      player.setProperty('vo', 'null');
      setProperties(
        {
          // ORDER IS IMPORTANT.
          'android-surface-size': androidSurfaceSizeValue,
          'wid': widValue,
          'vo': voValue,
          // It is important to re-initialize --vid in-case of --vo=mediacodec_embed.
          // Not doing so causes error "Could not open codec." & video never gets rendered.
          if (configuration.vo == 'mediacodec_embed') 'vid': vidValue,
        },
      );
      // Instead of seeking to the start (Duration.zero), seek to the current playback position
      // without jumping the user to the start of the media.
      final currentPosition = player.state.position;
      await player.seek(currentPosition);
    });
  }

  /// Applies the native `SurfaceView`'s surface to libmpv.
  ///
  /// `--android-surface-size` must be the real surface size (reported by
  /// `SurfaceHolder.Callback`), not the video size, because libmpv renders
  /// directly into this surface.
  Future<void> _applySurfaceView(int? wid, int width, int height) {
    return lock.synchronized(() async {
      if (wid == null || wid == 0 || width <= 0 || height <= 0) {
        return;
      }
      // It is important to re-initialize --vo after --android-surface-size.
      player.setProperty('vo', 'null');
      final vo = configuration.vo ?? 'gpu';
      setProperties({
        // ORDER IS IMPORTANT.
        'android-surface-size': '${width}x$height',
        'wid': wid.toString(),
        'vo': vo,
        // mediacodec_embed 由解码器直接输出到 Surface，需要重新启用 --vid。
        if (vo == 'mediacodec_embed') 'vid': 'auto',
      });
      // Seek to the current position so the new vo starts rendering without
      // jumping back to the beginning of the media.
      await player.seek(player.state.position);
    });
  }

  Future<void> _detachSurfaceView() {
    return lock.synchronized(() async {
      player.setProperty('vo', 'null');
      setProperties({'wid': '0'});
    });
  }

  /// [StreamSubscription] for listening to video [Rect].
  StreamSubscription<VideoParams>? videoParamsSubscription;

  /// {@macro android_video_controller}
  AndroidVideoController._(super.player, super.configuration) {
    wid.addListener(widListener);
    videoParamsSubscription = player.stream.videoParams.listen(
      (event) => lock.synchronized(() async {
        final int width;
        final int height;
        if (event.rotate == 0 || event.rotate == 180) {
          width = event.dw ?? 0;
          height = event.dh ?? 0;
        } else {
          // width & height are swapped for 90 or 270 degrees rotation.
          width = event.dh ?? 0;
          height = event.dw ?? 0;
        }

        final isZero = width == 0 || height == 0;
        final isSame = width == rect.value?.width.toInt() &&
            height == rect.value?.height.toInt();
        if (isZero || isSame) return;

        if (!configuration.androidSurfaceView) {
          await _channel.invokeMethod('VideoOutputManager.SetSurfaceSize', {
            'handle': player.handle.toString(),
            'width': width.toString(),
            'height': height.toString(),
          });
        }

        rect.value = Rect.fromLTRB(
          0.0,
          0.0,
          width.toDouble(),
          height.toDouble(),
        );

        if (!waitUntilFirstFrameRenderedCompleter.isCompleted) {
          waitUntilFirstFrameRenderedCompleter.complete();
        }
      }),
    );
  }

  /// {@macro android_video_controller}
  static Future<PlatformVideoController> create(
    Player player,
    VideoControllerConfiguration configuration,
  ) async {
    // Retrieve the native handle of the [Player].
    final handle = player.handle;
    // Return the existing [VideoController] if it's already created.
    if (_controllers.containsKey(handle)) {
      return _controllers[handle]!;
    }

    // Creation:
    final controller = AndroidVideoController._(player, configuration);

    // Register [_dispose] for execution upon [Player.dispose].
    player.release.add(controller.dispose);

    // Store the [VideoController] in the [_controllers].
    _controllers[handle] = controller;

    if (!configuration.androidSurfaceView) {
      await _channel.invokeMethod('VideoOutputManager.Create', {
        'handle': handle.toString(),
      });
    }

    controller.setProperties({
      // It is necessary to set vo=null here to avoid SIGSEGV, --wid must be assigned before vo=gpu is set.
      'vo': 'null',
      'hwdec': configuration.hwdec ??
          (configuration.enableHardwareAcceleration ? 'auto-safe' : 'no'),
      'vid': 'auto',
      'opengl-es': 'yes',
      'force-window': 'yes',
      'gpu-context': 'android',
      'sub-use-margins': 'no',
      'sub-font-provider': 'none',
      'sub-scale-with-window': 'yes',
      'hwdec-codecs': 'h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1',
    });

    // Return the [PlatformVideoController].
    return controller;
  }

  /// Sets the required size of the video output.
  /// This may yield substantial performance improvements if a small [width] & [height] is specified.
  ///
  /// Remember:
  /// * “Premature optimization is the root of all evil”
  /// * “With great power comes great responsibility”
  @override
  Future<void> setSize({int? width, int? height}) {
    throw UnsupportedError(
      '[AndroidVideoController.setSize] is not available on Android',
    );
  }

  /// Disposes the instance. Releases allocated resources back to the system.
  @override
  Future<void> dispose() async {
    super.dispose();
    wid.removeListener(widListener);
    wid.dispose();
    await videoParamsSubscription?.cancel();
    final handle = player.handle;
    _controllers.remove(handle);
    if (!configuration.androidSurfaceView) {
      await _channel.invokeMethod('VideoOutputManager.Dispose', {
        'handle': handle.toString(),
      });
    }
  }

  /// Currently created [AndroidVideoController]s.
  static final _controllers = HashMap<int, AndroidVideoController>();

  /// [MethodChannel] for invoking platform specific native implementation.
  static final _channel =
      const MethodChannel('com.alexmercerind/media_kit_video')
        ..setMethodCallHandler((MethodCall call) {
          try {
            final Map args = call.arguments;
            debugPrint(call.method);
            debugPrint(args.toString());
            switch (call.method) {
              case 'VideoOutput.Resize':
                {
                  // Notify about updated texture ID & [Rect].
                  final ctr = _controllers[args['handle'] as int];
                  if (ctr != null) {
                    final Map rectArgs = args['rect'];
                    final Rect rect = Rect.fromLTWH(
                      (rectArgs['left'] as num).toDouble(),
                      (rectArgs['top'] as num).toDouble(),
                      (rectArgs['width'] as num).toDouble(),
                      (rectArgs['height'] as num).toDouble(),
                    );
                    ctr.rect.value = rect;
                    ctr.id.value = args['id'] as int;
                    ctr.wid.value = args['wid'] as int;
                  }
                  break;
                }
              case 'HdrSurface.SurfaceCreated':
              case 'HdrSurface.SurfaceChanged':
                {
                  final ctr = _controllers[args['handle'] as int];
                  ctr?._applySurfaceView(
                    (args['wid'] as num?)?.toInt(),
                    (args['width'] as num?)?.toInt() ?? 0,
                    (args['height'] as num?)?.toInt() ?? 0,
                  );
                  break;
                }
              case 'HdrSurface.SurfaceDestroyed':
                {
                  final ctr = _controllers[args['handle'] as int];
                  ctr?._detachSurfaceView();
                  break;
                }
            }
          } catch (error, stackTrace) {
            Zone.current.handleUncaughtError(error, stackTrace);
          }
          return Future.value();
        });
}
