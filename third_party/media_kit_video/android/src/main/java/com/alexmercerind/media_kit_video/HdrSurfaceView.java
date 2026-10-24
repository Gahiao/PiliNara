/**
 * This file is a part of PiliNara's media_kit_video fork.
 *
 * HdrSurfaceView
 * --------------
 * Android video output backed by a real SurfaceView instead of a
 * TextureRegistry.SurfaceTextureEntry. A SurfaceTexture is always composited
 * by Flutter as RGBA8888, which silently drops HDR metadata; a SurfaceView can
 * be backed by a 10-bit buffer (RGBA_1010102) and lets libmpv request an HDR
 * EGL surface via --target-colorspace-hint.
 *
 * The Java object reference of android.view.Surface is handed to libmpv as
 * --wid, exactly like the Texture implementation does, so no libmpv changes
 * are required.
 */
package com.alexmercerind.media_kit_video;

import android.content.Context;
import android.content.pm.ActivityInfo;
import android.graphics.PixelFormat;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;

import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.Locale;

import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.platform.PlatformView;

public class HdrSurfaceView implements PlatformView {
    private static final String TAG = "media_kit";

    private final long handle;
    private final MethodChannel channelReference;
    private final SurfaceView surfaceView;

    private final Method newGlobalObjectRef;
    private final Method deleteGlobalObjectRef;

    /**
     * Pointer address to the global object reference of android.view.Surface
     * i.e. (intptr_t)(*android.view.Surface), passed to libmpv as --wid.
     */
    private long wid = 0;

    /** 是否申请 10bit 缓冲。mediacodec_embed 由解码器决定格式，不能强设。 */
    private final boolean tenBit;

    /** 宿主 Activity，用于设置/恢复窗口的 HDR 色彩模式。 */
    private final android.app.Activity activity;

    HdrSurfaceView(Context context, long handle, boolean tenBit, MethodChannel channelReference) {
        this.handle = handle;
        this.tenBit = tenBit;
        this.channelReference = channelReference;
        this.activity =
            (context instanceof android.app.Activity) ? (android.app.Activity) context : null;

        Method newGlobalObjectRefRef = null;
        Method deleteGlobalObjectRefRef = null;
        try {
            // Part of package:media_kit_libs_android_video (same helper used by VideoOutput.java).
            final Class<?> helper = Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper");
            newGlobalObjectRefRef = helper.getDeclaredMethod("newGlobalObjectRef", Object.class);
            deleteGlobalObjectRefRef = helper.getDeclaredMethod("deleteGlobalObjectRef", long.class);
            newGlobalObjectRefRef.setAccessible(true);
            deleteGlobalObjectRefRef.setAccessible(true);
        } catch (Throwable e) {
            Log.e(TAG, "HdrSurfaceView: MediaKitAndroidHelper unavailable", e);
        }
        newGlobalObjectRef = newGlobalObjectRefRef;
        deleteGlobalObjectRef = deleteGlobalObjectRefRef;

        surfaceView = new SurfaceView(context);
        surfaceView.setZOrderOnTop(false);
        // 不要吃掉触摸事件：视频是 hybrid composition 的原生 View，
        // 一旦它消费了点击，Flutter 侧的手势层（进度条/控制栏）就收不到。
        surfaceView.setFocusable(false);
        surfaceView.setFocusableInTouchMode(false);
        surfaceView.setClickable(false);
        surfaceView.setLongClickable(false);
        surfaceView.setOnTouchListener((v, event) -> false);

        // Request a 10-bit buffer for the SurfaceView. The EGL configuration
        // requested by libmpv must match this format for HDR to survive.
        // mediacodec_embed 模式下缓冲由 MediaCodec 自己决定，不能强设格式。
        if (tenBit) {
            try {
                surfaceView.getHolder().setFormat(PixelFormat.RGBA_1010102);
            } catch (Throwable e) {
                Log.e(TAG, "HdrSurfaceView: unable to request RGBA_1010102", e);
            }
        }

        // Let the system know this window may render HDR content.
        setWindowColorMode(ActivityInfo.COLOR_MODE_HDR);

        surfaceView.getHolder().addCallback(
            new SurfaceHolder.Callback() {
                @Override
                public void surfaceCreated(SurfaceHolder holder) {
                    synchronized (HdrSurfaceView.this) {
                        try {
                            if (newGlobalObjectRef == null) {
                                return;
                            }
                            wid = (long) newGlobalObjectRef.invoke(null, holder.getSurface());
                            Log.i(
                                TAG,
                                String.format(
                                    Locale.ENGLISH,
                                    "HdrSurfaceView.surfaceCreated: handle=%d wid=%d",
                                    handle,
                                    wid
                                )
                            );
                            notifyDart(
                                "HdrSurface.SurfaceCreated",
                                wid,
                                surfaceView.getWidth(),
                                surfaceView.getHeight()
                            );
                        } catch (Throwable e) {
                            e.printStackTrace();
                        }
                    }
                }

                @Override
                public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
                    synchronized (HdrSurfaceView.this) {
                        Log.i(
                            TAG,
                            String.format(
                                Locale.ENGLISH,
                                "HdrSurfaceView.surfaceChanged: handle=%d %dx%d",
                                handle,
                                width,
                                height
                            )
                        );
                        notifyDart("HdrSurface.SurfaceChanged", wid, width, height);
                    }
                }

                @Override
                public void surfaceDestroyed(SurfaceHolder holder) {
                    synchronized (HdrSurfaceView.this) {
                        // 退出播放页/视图销毁时必须把窗口色彩模式复位，
                        // 否则面板会一直停留在 HDR 高亮状态。
                        setWindowColorMode(ActivityInfo.COLOR_MODE_DEFAULT);
                        notifyDart("HdrSurface.SurfaceDestroyed", wid, 0, 0);
                        final long ref = wid;
                        wid = 0;
                        if (ref != 0 && deleteGlobalObjectRef != null) {
                            // Delay the deletion to avoid libmpv referencing it
                            // (same approach as VideoOutput#dispose).
                            new Handler(Looper.getMainLooper()).postDelayed(
                                () -> {
                                    try {
                                        deleteGlobalObjectRef.invoke(null, ref);
                                    } catch (Throwable e) {
                                        e.printStackTrace();
                                    }
                                },
                                5000
                            );
                        }
                    }
                }
            }
        );
    }

    /** Sets the window colour mode, ignoring failures on older devices. */
    private void setWindowColorMode(int colorMode) {
        if (activity == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return;
        }
        try {
            activity.getWindow().setColorMode(colorMode);
        } catch (Throwable e) {
            e.printStackTrace();
        }
    }

    private void notifyDart(String method, long wid, int width, int height) {
        try {
            final HashMap<String, Object> data = new HashMap<>();
            data.put("handle", handle);
            data.put("wid", wid);
            data.put("width", width);
            data.put("height", height);
            channelReference.invokeMethod(method, data);
        } catch (Throwable e) {
            e.printStackTrace();
        }
    }

    @Override
    public View getView() {
        return surfaceView;
    }

    @Override
    public void dispose() {
        // 视图销毁时同样复位窗口色彩模式（某些情况下 dispose 先于
        // surfaceDestroyed 执行）。
        setWindowColorMode(ActivityInfo.COLOR_MODE_DEFAULT);
        synchronized (this) {
            final long ref = wid;
            wid = 0;
            if (ref != 0 && deleteGlobalObjectRef != null) {
                try {
                    deleteGlobalObjectRef.invoke(null, ref);
                } catch (Throwable e) {
                    e.printStackTrace();
                }
            }
        }
        try {
            surfaceView.getHolder().getSurface().release();
        } catch (Throwable e) {
            e.printStackTrace();
        }
    }
}
