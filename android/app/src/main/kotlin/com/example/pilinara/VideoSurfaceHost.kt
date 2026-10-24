package com.example.pilinara

import android.app.Activity
import android.content.pm.ActivityInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import android.widget.FrameLayout
import io.flutter.plugin.common.MethodChannel
import java.lang.reflect.Method

/**
 * 把一块 SurfaceView 放在 FlutterView 之下，供 libmpv / MediaCodec 直接出画。
 *
 * P1 已把 Flutter 的 surface 设为透明且 Z 序置顶，所以这里的 SurfaceView
 * 虽然层级更低，仍然能被 Flutter 的透明区域“透出”看到，而 Flutter 绘制的
 * 弹幕/控件会正常盖在视频之上。
 */
class VideoSurfaceHost(
    private val activity: Activity,
    private val channel: MethodChannel,
) {
    companion object {
        private const val TAG = "VideoSurfaceHost"
    }

    private var surfaceView: SurfaceView? = null
    private var wid: Long = 0L

    private val newGlobalObjectRef: Method? = runCatching {
        Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper")
            .getDeclaredMethod("newGlobalObjectRef", Any::class.java)
            .apply { isAccessible = true }
    }.getOrNull()

    private val deleteGlobalObjectRef: Method? = runCatching {
        Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper")
            .getDeclaredMethod("deleteGlobalObjectRef", Long::class.javaPrimitiveType)
            .apply { isAccessible = true }
    }.getOrNull()

    fun create() {
        remove()
        val sv = SurfaceView(activity)
        sv.setZOrderOnTop(false)
        sv.setZOrderMediaOverlay(false)
        sv.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                wid = runCatching {
                    newGlobalObjectRef?.invoke(null, holder.surface) as? Long ?: 0L
                }.getOrDefault(0L)
                Log.i(TAG, "surfaceCreated wid=$wid ${sv.width}x${sv.height}")
                channel.invokeMethod(
                    "surfaceCreated",
                    mapOf(
                        "wid" to wid,
                        "width" to sv.width,
                        "height" to sv.height,
                    ),
                )
            }

            override fun surfaceChanged(
                holder: SurfaceHolder,
                format: Int,
                width: Int,
                height: Int,
            ) {
                Log.i(TAG, "surfaceChanged ${width}x$height")
                channel.invokeMethod(
                    "surfaceChanged",
                    mapOf("width" to width, "height" to height),
                )
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                Log.i(TAG, "surfaceDestroyed")
                channel.invokeMethod("surfaceDestroyed", null)
                val ref = wid
                wid = 0L
                if (ref != 0L) {
                    Handler(Looper.getMainLooper()).postDelayed({
                        runCatching { deleteGlobalObjectRef?.invoke(null, ref) }
                    }, 5000)
                }
            }
        })

        val decor = activity.window.decorView as ViewGroup
        decor.addView(sv, 0, FrameLayout.LayoutParams(1, 1))
        surfaceView = sv
        setHdrColorMode(true)
    }

    fun setRect(x: Int, y: Int, width: Int, height: Int) {
        val sv = surfaceView ?: return
        val lp = (sv.layoutParams as? FrameLayout.LayoutParams)
            ?: FrameLayout.LayoutParams(width, height)
        lp.width = width.coerceAtLeast(1)
        lp.height = height.coerceAtLeast(1)
        lp.leftMargin = x
        lp.topMargin = y
        sv.layoutParams = lp
    }

    fun remove() {
        setHdrColorMode(false)
        val sv = surfaceView ?: return
        surfaceView = null
        runCatching { (sv.parent as? ViewGroup)?.removeView(sv) }
        val ref = wid
        wid = 0L
        if (ref != 0L) {
            runCatching { deleteGlobalObjectRef?.invoke(null, ref) }
        }
    }

    private fun setHdrColorMode(enabled: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            activity.window.setColorMode(
                if (enabled) {
                    ActivityInfo.COLOR_MODE_HDR
                } else {
                    ActivityInfo.COLOR_MODE_DEFAULT
                },
            )
        }
    }
}
