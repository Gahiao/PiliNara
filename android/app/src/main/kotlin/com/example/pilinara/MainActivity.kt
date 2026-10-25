package com.example.pilinara

import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager.LayoutParams
import android.widget.ImageView
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private lateinit var methodChannel: MethodChannel
    private var videoSurfaceHost: VideoSurfaceHost? = null

    /**
     * 透明背景模式：让 Flutter 的 surface 支持逐像素透明且 Z 序置顶，
     * 这样播放页可以把 HDR 视频的 SurfaceView 放在 Flutter 之下，
     * 弹幕/控件等 Flutter UI 仍然绘制在视频之上。
     *
     * 只有 HDR 直通出画需要它；窗口背景已在 NormalTheme / onCreate 中固定为黑色，
     * 因此不会出现透白闪烁。
     */
    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent

    /**
     * 必须强制 surface 渲染模式。
     *
     * FlutterActivity 的默认实现是：backgroundMode != opaque 时返回
     * RenderMode.texture。TextureView 属于窗口内的一层，窗口本身不透明，
     * 会把位于窗口之后的 HDR 视频 SurfaceView 完全盖住（采样有画面但全黑）。
     * 只有 FlutterSurfaceView（RenderMode.surface）才能以 TRANSLUCENT + Z 置顶
     * 的方式叠在视频 SurfaceView 之上，露出挖孔区域。
     */
    override fun getRenderMode(): RenderMode = RenderMode.surface

    /**
     * SurfaceHolder.getFormat() 在 compileSdk 37 的 stub 里已被移除，
     * 运行时仍然存在，这里用反射读取用于诊断（读不到返回 null）。
     */
    private fun readSurfaceFormat(holder: SurfaceHolder): Int? {
        return runCatching {
            val method = holder.javaClass.getMethod("getFormat")
            (method.invoke(holder) as? Number)?.toInt()
        }.recoverCatching {
            val method = holder.javaClass.getMethod("getSurfaceFormat")
            (method.invoke(holder) as? Number)?.toInt()
        }.getOrNull()
    }

    /** 诊断：Flutter 层是否透明、背景模式与视图树。 */
    private fun describeSurface(): String {
        val builder = StringBuilder()
        builder.append("backgroundMode=").append(getBackgroundMode().name)
        builder.append("\nrenderMode=").append(getRenderMode().name)
        val decor = window.decorView as? ViewGroup ?: return builder.toString()
        fun walk(view: View, depth: Int) {
            builder.append('\n').append("  ".repeat(depth)).append(view.javaClass.name)
            if (view is TextureView) {
                builder.append(" [TextureView]")
            }
            if (view is ImageView) {
                builder.append(" [ImageView]")
            }
            if (view is SurfaceView) {
                builder
                    .append(" format=")
                    .append(readSurfaceFormat(view.holder) ?: "?")
                    .append(" size=")
                    .append(view.width)
                    .append('x')
                    .append(view.height)
                if (view.tag == VideoSurfaceHost.SURFACE_TAG) {
                    builder.append(" [video]")
                }
            }
            if (view is ViewGroup) {
                for (i in 0 until view.childCount) {
                    walk(view.getChildAt(i), depth + 1)
                }
            }
        }
        walk(decor, 0)
        return builder.toString()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        videoSurfaceHost?.release()
        videoSurfaceHost = null

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "PiliNara")
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                else -> result.notImplemented()
            }
        }

        // HDR 视频底层（SurfaceView）控制通道
        val surfaceChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.pilinara/video_surface",
        )
        val host = VideoSurfaceHost(this, surfaceChannel)
        videoSurfaceHost = host

        surfaceChannel.setMethodCallHandler { call, result ->
            fun intArg(name: String): Int =
                (call.argument<Any>(name) as? Number)?.toInt() ?: 0
            fun boolArg(name: String): Boolean =
                call.argument<Any>(name) as? Boolean ?: false

            when (call.method) {
                "create" -> {
                    host.create(
                        owner = intArg("owner"),
                        left = intArg("x"),
                        top = intArg("y"),
                        width = intArg("width"),
                        height = intArg("height"),
                        wantTenBit = boolArg("tenBit"),
                    )
                    result.success(null)
                }
                "setRect" -> {
                    host.setRect(
                        owner = intArg("owner"),
                        left = intArg("x"),
                        top = intArg("y"),
                        width = intArg("width"),
                        height = intArg("height"),
                    )
                    result.success(null)
                }
                "setHdr" -> {
                    // 保留方法名以兼容旧调用；当前实现不再主动切换窗口色彩模式，
                    // 避免整屏高亮闪屏。
                    result.success(null)
                }
                "remove" -> {
                    host.remove(owner = intArg("owner"))
                    result.success(null)
                }
                "capture" -> host.capture(
                    owner = intArg("owner"),
                    result = result,
                )
                "probe" -> host.probe(
                    owner = intArg("owner"),
                    result = result,
                )
                "surfaceInfo" -> result.success(describeSurface())
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        videoSurfaceHost?.release()
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
        // 统一给黑色，避免出现白色闪烁。
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
