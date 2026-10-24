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

/// {@template native_video_controller}
///
/// NativeVideoController
/// ---------------------
///
/// The [PlatformVideoController] implementation based on native C/C++ used on:
/// * Windows
/// * GNU/Linux
/// * macOS
/// * iOS
///
/// {@endtemplate}
class NativeVideoController extends PlatformVideoController {
  /// Whether [NativeVideoController] is supported on the current platform or not.
  static bool get supported =>
      Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isIOS;

  /// Fixed width of the video output.
  int? width;

  /// Fixed height of the video output.
  int? height;

  /// Width of the video (from [VideoParams]).
  int? videoParamsWidth;

  /// Height of the video (from [VideoParams]).
  int? videoParamsHeight;

  /// [Lock] used to synchronize [onLoadHooks], [onUnloadHooks] & [subscription].
  final lock = Lock();

  /// [StreamSubscription] for listening to video [Rect].
  StreamSubscription<VideoParams>? videoParamsSubscription;

  /// {@macro native_video_controller}
  NativeVideoController._(super.player, super.configuration)
      : width = configuration.width,
        height = configuration.height {
    videoParamsSubscription = player.stream.videoParams.listen(
      (event) => lock.synchronized(() {
        final w = event.dw;
        final h = event.dh;
        if (w == null || w == 0 || h == null || h == 0) {
          return null;
        }

        final int width;
        final int height;
        if (event.rotate == 0 || event.rotate == 180) {
          width = w;
          height = h;
        } else {
          // width & height are swapped for 90 or 270 degrees rotation.
          width = h;
          height = w;
        }

        if (videoParamsWidth == width && videoParamsHeight == height) {
          return null;
        }

        videoParamsWidth = width;
        videoParamsHeight = height;

        return _channel.invokeMethod('VideoOutputManager.SetSize', {
          'handle': player.handle.toString(),
          'width': width.toString(),
          'height': height.toString(),
        });
      }),
    );
  }

  /// {@macro native_video_controller}
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
    final controller = NativeVideoController._(player, configuration);

    // Register [_dispose] for execution upon [Player.dispose].
    player.release.add(controller.dispose);

    // Store the [NativeVideoController] in the [_controllers].
    _controllers[handle] = controller;

    final values = {
      'vo': configuration.vo ?? 'libmpv',
      'hwdec': configuration.hwdec ?? 'auto',
      'vid': 'auto',
    };
    for (final entry in values.entries) {
      player.setProperty(entry.key, entry.value);
    }

    // Wait until first texture ID is received.
    // We are not waiting on the native-side itself because it will block the UI thread.
    final completer = Completer<void>();
    void listener() {
      final value = controller.id.value;
      if (value != null) {
        debugPrint('NativeVideoController: Texture ID: $value');
        completer.complete();
      }
    }

    controller.id.addListener(listener);

    await _channel.invokeMethod('VideoOutputManager.Create', {
      'handle': handle.toString(),
      'configuration': {
        'width': configuration.width.toString(),
        'height': configuration.height.toString(),
        'enableHardwareAcceleration': configuration.enableHardwareAcceleration,
      },
    });

    await completer.future;
    controller.id.removeListener(listener);

    // Return the [VideoController].
    return controller;
  }

  /// Sets the required size of the video output.
  /// This may yield substantial performance improvements if a small [width] & [height] is specified.
  ///
  /// Remember:
  /// * “Premature optimization is the root of all evil”
  /// * “With great power comes great responsibility”
  @override
  Future<void>? setSize({int? width, int? height}) {
    if (this.width == width && this.height == height) {
      // No need to resize if the requested size is same as the current size.
      return null;
    }
    final handle = player.handle;
    if (width != null && height != null) {
      this.width = width;
      this.height = height;
      return _channel.invokeMethod(
        'VideoOutputManager.SetSize',
        {
          'handle': handle.toString(),
          'width': width.toString(),
          'height': height.toString(),
        },
      );
    } else {
      this.width = null;
      this.height = null;
      return _channel.invokeMethod(
        'VideoOutputManager.SetSize',
        {
          'handle': handle.toString(),
          'width': videoParamsWidth?.toString() ?? 'null',
          'height': videoParamsHeight?.toString() ?? 'null',
        },
      );
    }
  }

  /// Disposes the instance. Releases allocated resources back to the system.
  @override
  Future<void> dispose() async {
    super.dispose();
    await videoParamsSubscription?.cancel();
    final handle = player.handle;
    _controllers.remove(handle);
    await _channel.invokeMethod('VideoOutputManager.Dispose', {
      'handle': handle.toString(),
    });
  }

  /// Currently created [NativeVideoController]s.
  /// This is used to notify about updated texture IDs & [Rect]s through [_channel].
  static final _controllers = HashMap<int, NativeVideoController>();

  /// [MethodChannel] for invoking platform specific native implementation.
  static final _channel =
      const MethodChannel('com.alexmercerind/media_kit_video')
        ..setMethodCallHandler((MethodCall call) {
          assert(call.method == 'VideoOutput.Resize');
          try {
            final Map args = call.arguments;
            debugPrint(call.method);
            debugPrint(args.toString());
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
              // Notify about the first frame being rendered.
              if (rect.width > 0 && rect.height > 0) {
                final completer = ctr.waitUntilFirstFrameRenderedCompleter;
                if (!completer.isCompleted) completer.complete();
              }
            }
          } catch (error, stackTrace) {
            Zone.current.handleUncaughtError(error, stackTrace);
          }
          return Future.value();
        });
}
