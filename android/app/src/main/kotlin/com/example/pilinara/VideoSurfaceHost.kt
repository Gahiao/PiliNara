package com.example.pilinara

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.PixelCopy
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import android.widget.FrameLayout
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.lang.reflect.Method

/**
 * 把一块 SurfaceView 放在 FlutterView **之下**，供 libmpv / MediaCodec 直接输出画面。
 *
 * 为什么不用 PlatformView：
 * Flutter 的 Texture 固定是 RGBA8888，HDR 元数据在这一步丢失；而 hybrid composition 的
 * PlatformView 会盖住 Flutter 绘制的弹幕/控制栏。这里改为把 SurfaceView 插到窗口内容视图的
 * 第 0 层（FlutterView 之下），Flutter 的 surface 在透明模式下仍然绘制在它上方，
 * 于是视频在底层、弹幕与控制栏正常叠加，并且真正走 SurfaceView 的 10bit / HDR 通路。
 *
 * 播放器通过 `com.pilinara/video_surface` 通道驱动本类：
 * - `create`：首次创建（或在页面/小窗之间转移所有权时复用）SurfaceView；
 * - `setRect`：把 SurfaceView 摆到 Flutter 上报的物理像素矩形；
 * - `setHdr`：保留的兼容方法（当前不再主动请求窗口 HDR 色彩模式，避免整屏高亮闪屏）；
 * - `remove`：延迟销毁（避免小窗 ↔ 页面切换时 Surface 反复重建导致黑闪）；
 * - `capture`：用 PixelCopy 截图（HDR 直通时 mpv 自身拿不到画面）。
 *
 * 注意：SurfaceView 是独立图层，View 的 transform / clip 对它基本无效，所以这里只做
 * 位置与尺寸（布局）同步，圆角、旋转等由 Flutter 侧规避。
 */
class VideoSurfaceHost(
    private val activity: Activity,
    private val channel: MethodChannel,
) {
    companion object {
        private const val TAG = "VideoSurfaceHost"

        /** 标记 HDR 视频自己的 SurfaceView，避免透明化时误伤。 */
        const val SURFACE_TAG = "pilinara_hdr_video_surface"

        /** 页面/小窗切换时延迟销毁，等待新 owner 接管，避免 Surface 反复创建。 */
        private const val TEARDOWN_DELAY_MS = 400L

        /** 延迟释放 android.view.Surface 的 global ref，避免 mpv 仍持有旧引用。 */
        private const val WID_RELEASE_DELAY_MS = 5_000L
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private var surfaceView: SurfaceView? = null
    private var ownerId = 0
    private var wid = 0L
    private var tenBit = false
    private var pendingTeardown: Runnable? = null

    private val newGlobalObjectRef: Method? = runCatching {
        Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper")
            .getDeclaredMethod("newGlobalObjectRef", Any::class.java)
            .apply { isAccessible = true }
    }.getOrNull()

    private val deleteGlobalObjectRef: Method? = runCatching {
        Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper")
            .getDeclaredMethod("deleteGlobalObjectRef", java.lang.Long.TYPE)
            .apply { isAccessible = true }
    }.getOrNull()

    /**
     * 创建（或复用）底层 SurfaceView。
     *
     * 复用是关键：页面 ↔ 小窗、全屏 ↔ 半屏切换时若销毁重建 Surface，`wid` 会变化、
     * mpv 需要重新初始化视频输出，肉眼看到的就是「黑闪一下」。只要格式不变就沿用
     * 同一个 SurfaceView，仅更新所有者与布局。
     */
    fun create(
        owner: Int,
        left: Int,
        top: Int,
        width: Int,
        height: Int,
        wantTenBit: Boolean,
    ) {
        cancelPendingTeardown()
        ownerId = owner
        val w = width.coerceAtLeast(1)
        val h = height.coerceAtLeast(1)

        if (surfaceView == null || tenBit != wantTenBit) {
            teardownNow()
            ownerId = owner
            val sv = buildSurfaceView(wantTenBit)
            tenBit = wantTenBit
            surfaceView = sv
            val content = contentView()
            if (content == null) {
                Log.e(TAG, "create: content view unavailable")
                surfaceView = null
                return
            }
            content.addView(
                sv,
                0,
                FrameLayout.LayoutParams(w, h).apply {
                    leftMargin = left
                    topMargin = top
                },
            )
        }

        applyLayout(left, top, w, h)

        // 复用的 Surface 不会再次触发 surfaceCreated，这里主动把已有 wid 交给新 owner。
        if (wid != 0L) {
            notifyDart("surfaceCreated", wid, w, h)
        }
    }

    /** 更新 SurfaceView 在窗口中的位置与大小（物理像素，相对 FlutterView 左上角）。 */
    fun setRect(owner: Int, left: Int, top: Int, width: Int, height: Int) {
        if (owner != ownerId) return
        applyLayout(left, top, width.coerceAtLeast(1), height.coerceAtLeast(1))
    }

    /**
     * 请求销毁。延迟 [TEARDOWN_DELAY_MS] 执行：页面切小窗（或反向）时新旧两个
     * Flutter 控件会在极短时间内先后 create/remove，立即销毁会让 Surface 重建、
     * mpv 重新初始化，表现为视频黑闪。
     */
    fun remove(owner: Int) {
        if (owner != ownerId) return
        cancelPendingTeardown()
        val runnable = Runnable {
            if (ownerId == owner) {
                teardownNow()
            }
        }
        pendingTeardown = runnable
        mainHandler.postDelayed(runnable, TEARDOWN_DELAY_MS)
    }

    /** Activity 销毁时立即释放。 */
    /** 供 Media3 DoVi 视频解码直接使用同一个原生 SurfaceView。 */
    fun surfaceView(): SurfaceView? = surfaceView

    fun release() {
        cancelPendingTeardown()
        teardownNow()
    }

    /**
     * 用 PixelCopy 抓取当前 SurfaceView 的画面。
     *
     * HDR 直通（`vo=mediacodec_embed`）时画面由 MediaCodec 直接写到 Surface，
     * mpv 自己拿不到帧，`Player.screenshot()` 会返回空；只能从原生侧抓。
     */
    fun capture(owner: Int, result: MethodChannel.Result) {
        val sv = surfaceView
        if (owner != ownerId || sv == null || sv.width <= 0 || sv.height <= 0) {
            result.success(null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            result.success(null)
            return
        }
        val bitmap = try {
            Bitmap.createBitmap(sv.width, sv.height, Bitmap.Config.ARGB_8888)
        } catch (t: Throwable) {
            Log.w(TAG, "capture: unable to allocate bitmap", t)
            result.success(null)
            return
        }
        val listener = PixelCopy.OnPixelCopyFinishedListener { copyResult ->
            if (copyResult == PixelCopy.SUCCESS) {
                Thread {
                    val bytes = runCatching {
                        ByteArrayOutputStream().use { output ->
                            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
                            output.toByteArray()
                        }
                    }.getOrNull()
                    mainHandler.post { result.success(bytes) }
                }.apply { isDaemon = true }.start()
            } else {
                Log.w(TAG, "capture: PixelCopy failed with $copyResult")
                mainHandler.post { result.success(null) }
            }
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                PixelCopy.request(sv, bitmap, listener, mainHandler)
            } else {
                PixelCopy.request(sv.holder.surface, bitmap, listener, mainHandler)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "capture: PixelCopy unavailable", t)
            result.success(null)
        }
    }

    /**
     * 采样 SurfaceView 当前画面，返回 0-255 的最大亮度分量。
     *
     * 用于区分「解码器没有出画」和「Flutter 层把画面盖住」：
     * 返回 0 说明 Surface 本身是黑的，与 Flutter 无关。
     */
    fun probe(owner: Int, result: MethodChannel.Result) {
        val sv = surfaceView
        if (owner != ownerId || sv == null || sv.width <= 1 || sv.height <= 1) {
            result.success(null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            result.success(null)
            return
        }
        val shown = sv.isShown
        val visibility = sv.visibility
        val alpha = sv.alpha.toDouble()
        val parent = sv.parent?.javaClass?.name ?: "-"
        val windowColorMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.window.colorMode
        } else {
            -1
        }
        val bitmap = try {
            Bitmap.createBitmap(sv.width, sv.height, Bitmap.Config.ARGB_8888)
        } catch (t: Throwable) {
            Log.w(TAG, "probe: unable to allocate bitmap", t)
            result.success(null)
            return
        }
        val listener = PixelCopy.OnPixelCopyFinishedListener { copyResult ->
            if (copyResult != PixelCopy.SUCCESS) {
                Log.w(TAG, "probe: PixelCopy failed with $copyResult")
                bitmap.recycle()
                mainHandler.post { result.success(null) }
            } else {
                Thread {
                    val data = runCatching {
                        var sum = 0L
                        var count = 0
                        var maxValue = 0
                        var bright = 0
                        val stepX = maxOf(1, bitmap.width / 32)
                        val stepY = maxOf(1, bitmap.height / 18)
                        var y = 0
                        while (y < bitmap.height) {
                            var x = 0
                            while (x < bitmap.width) {
                                val pixel = bitmap.getPixel(x, y)
                                val value = maxOf(
                                    Color.red(pixel),
                                    Color.green(pixel),
                                    Color.blue(pixel),
                                )
                                sum += value
                                count++
                                if (value > maxValue) maxValue = value
                                if (value > 8) bright++
                                x += stepX
                            }
                            y += stepY
                        }
                        val mean = if (count > 0) (sum / count).toInt() else 0
                        mapOf(
                            "mean" to mean,
                            "max" to maxValue,
                            "bright" to bright,
                            "shown" to shown,
                            "vis" to visibility,
                            "alpha" to alpha,
                            "parent" to parent,
                            "windowColorMode" to windowColorMode,
                        )
                    }.getOrNull()
                    bitmap.recycle()
                    mainHandler.post { result.success(data) }
                }.apply { isDaemon = true }.start()
            }
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                PixelCopy.request(sv, bitmap, listener, mainHandler)
            } else {
                PixelCopy.request(sv.holder.surface, bitmap, listener, mainHandler)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "probe: PixelCopy unavailable", t)
            bitmap.recycle()
            result.success(null)
        }
    }

    private fun buildSurfaceView(requestTenBit: Boolean): SurfaceView {
        val sv = SurfaceView(activity)
        sv.tag = SURFACE_TAG
        sv.setZOrderOnTop(false)
        // 视频层保持在窗口之后，由窗口 punch hole + Z 置顶的 FlutterSurfaceView
        // 的透明像素透出。media overlay 在部分 ROM 上会盖住 Flutter UI，已回退。
        sv.setZOrderMediaOverlay(false)
        // 视频在 Flutter 之下，不能吃掉 Flutter 的手势（点击/拖动交给上层）。
        sv.isFocusable = false
        sv.isFocusableInTouchMode = false
        sv.isClickable = false
        sv.isLongClickable = false
        sv.setOnTouchListener { _, _ -> false }

        // mediacodec_embed 的缓冲格式由 MediaCodec 决定，不能强设；
        // 其它渲染后端请求 10bit 缓冲，给 HDR 留出位深。
        if (requestTenBit && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            runCatching { sv.holder.setFormat(PixelFormat.RGBA_1010102) }
                .onFailure { Log.w(TAG, "unable to request RGBA_1010102", it) }
        }

        sv.holder.addCallback(
            object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    if (surfaceView !== sv) return
                    val ref = runCatching {
                        newGlobalObjectRef?.invoke(null, holder.surface) as? Long ?: 0L
                    }.getOrDefault(0L)
                    wid = ref
                    Log.i(TAG, "surfaceCreated wid=$ref")
                    notifyDart("surfaceCreated", ref, sv.width, sv.height)
                }

                override fun surfaceChanged(
                    holder: SurfaceHolder,
                    format: Int,
                    width: Int,
                    height: Int,
                ) {
                    if (surfaceView !== sv) return
                    // 布局变化只需要同步位置，mpv 的渲染尺寸由 Dart 侧按视频编码尺寸设置，
                    // 不随控件缩放/旋转反复改变（否则会反复重建视频输出）。
                    notifyDart("surfaceChanged", wid, width, height)
                }

                override fun surfaceDestroyed(holder: SurfaceHolder) {
                    if (surfaceView !== sv) return
                    Log.i(TAG, "surfaceDestroyed")
                    notifyDart("surfaceDestroyed", 0L, 0, 0)
                    releaseWid(wid)
                    wid = 0L
                }
            },
        )
        return sv
    }

    private fun applyLayout(left: Int, top: Int, width: Int, height: Int) {
        val sv = surfaceView ?: return
        val params = (sv.layoutParams as? FrameLayout.LayoutParams)
            ?: FrameLayout.LayoutParams(width, height)
        if (params.width == width &&
            params.height == height &&
            params.leftMargin == left &&
            params.topMargin == top
        ) {
            return
        }
        params.width = width
        params.height = height
        params.leftMargin = left
        params.topMargin = top
        sv.layoutParams = params
    }

    private fun teardownNow() {
        cancelPendingTeardown()
        val sv = surfaceView
        surfaceView = null
        ownerId = 0
        if (sv != null) {
            runCatching { (sv.parent as? ViewGroup)?.removeView(sv) }
        }
        releaseWid(wid)
        wid = 0L
        tenBit = false
    }

    private fun releaseWid(ref: Long) {
        if (ref == 0L) return
        mainHandler.postDelayed({
            runCatching { deleteGlobalObjectRef?.invoke(null, ref) }
        }, WID_RELEASE_DELAY_MS)
    }

    private fun cancelPendingTeardown() {
        pendingTeardown?.let { mainHandler.removeCallbacks(it) }
        pendingTeardown = null
    }

    private fun notifyDart(method: String, wid: Long, width: Int, height: Int) {
        try {
            channel.invokeMethod(
                method,
                mapOf(
                    "owner" to ownerId,
                    "wid" to wid,
                    "width" to width,
                    "height" to height,
                ),
            )
        } catch (t: Throwable) {
            Log.w(TAG, "notifyDart($method) failed", t)
        }
    }

    private fun contentView(): ViewGroup? =
        activity.findViewById<ViewGroup>(android.R.id.content)
            ?: (activity.window.decorView as? ViewGroup)
}
