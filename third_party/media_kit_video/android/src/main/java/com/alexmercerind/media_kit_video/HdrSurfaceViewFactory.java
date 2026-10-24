/**
 * This file is a part of PiliNara's media_kit_video fork.
 */
package com.alexmercerind.media_kit_video;

import android.content.Context;

import java.util.Map;

import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMessageCodec;
import io.flutter.plugin.platform.PlatformView;
import io.flutter.plugin.platform.PlatformViewFactory;

public class HdrSurfaceViewFactory extends PlatformViewFactory {
    private final MethodChannel channelReference;

    HdrSurfaceViewFactory(MethodChannel channelReference) {
        super(StandardMessageCodec.INSTANCE);
        this.channelReference = channelReference;
    }

    @Override
    public PlatformView create(Context context, int viewId, Object args) {
        long handle = 0;
        try {
            if (args instanceof Map) {
                final Object value = ((Map<?, ?>) args).get("handle");
                if (value != null) {
                    handle = Long.parseLong(value.toString());
                }
            }
        } catch (Throwable e) {
            e.printStackTrace();
        }
        return new HdrSurfaceView(context, handle, channelReference);
    }
}
