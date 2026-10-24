package com.example.pilinara

import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.view.WindowManager.LayoutParams
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private lateinit var methodChannel: MethodChannel
    private var videoSurfaceHost: VideoSurfaceHost? = null

    /**
     * 透明背景模式：让 Flutter 的 surface 支持逐像素透明且 Z 序置顶，
     * 这样播放页可以把视频 SurfaceView 放在 Flutter 之下，
     * 弹幕/控件等 Flutter UI 仍然绘制在视频之上（HDR 直通方案的基础）。
     */
    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "PiliNara")
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                else -> result.notImplemented()
            }
        }

        // 视频底层（SurfaceView）控制通道
        val surfaceChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.pilinara/video_surface")
        surfaceChannel.setMethodCallHandler { call, result ->
            val host = videoSurfaceHost
                ?: VideoSurfaceHost(this, surfaceChannel).also { videoSurfaceHost = it }
            fun arg(name: String): Int =
                (call.argument<Any>(name) as? Number)?.toInt() ?: 0

            when (call.method) {
                "create" -> {
                    host.create()
                    result.success(null)
                }
                "setRect" -> {
                    host.setRect(arg("x"), arg("y"), arg("width"), arg("height"))
                    result.success(null)
                }
                "remove" -> {
                    host.remove()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        videoSurfaceHost?.remove()
        videoSurfaceHost = null
        super.onDestroy()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 透明 Flutter surface 下，未被 Flutter 绘制的区域会露出窗口背景，
        // 统一给黑色，避免出现闪烁/花屏。
        window.setBackgroundDrawable(ColorDrawable(Color.BLACK))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AndroidHelper.ToDart.onUserLeaveHint?.run()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration?
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AndroidHelper.isPipMode = isInPictureInPictureMode
        methodChannel.invokeMethod("onPipChanged", isInPictureInPictureMode)
    }
}
