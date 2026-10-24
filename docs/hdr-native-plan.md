# Android 真 HDR 改造方案（方案 A：保留 libmpv，只换"上屏"）

> ⚠️ 本文是早期方案记录，最终实现已改为「视频在 Flutter 之下 + 应用自有 SurfaceView」，
> 且移除了 hybrid composition 的 PlatformView 路径。请以 [hdr.md](hdr.md) /
> [hdr-native-redo.md](hdr-native-redo.md) 为准。

> 范围：仅 Android；目标是在不破坏现有 mpv 能力（Anime4K/超分、loudnorm、音画同步、
> 字幕样式、截图）的前提下，让 HDR / 杜比视界片源把 10bit 画面送到支持 HDR 的
> SurfaceView，从而真正激发面板 HDR。

## 一、现状（已核对源码）

| 层 | 位置 | 现状 |
| --- | --- | --- |
| Dart 控制器 | `media_kit_video/lib/src/video_controller/android_video_controller/real.dart` | 创建时设 `vo=null`、`gpu-context=android`、`opengl-es=yes`；加载时 `setOption('wid', _wid)` + `setOption('vo','gpu')` |
| Android 出画 | `media_kit_video/android/.../VideoOutput.java` | `createSurfaceTexture()` → `new Surface(surfaceTexture)` → `wid = newGlobalObjectRef(surface)` |
| 关联 | `MediaKitVideoPlugin.java` | `VideoOutputManager` + `com.alexmercerind/media_kit_video` MethodChannel |

结论：`SurfaceTexture` 最终被 Flutter 当作 RGBA8 纹理采样，HDR 元数据在这里丢失。
`wid` 本身是 `android.view.Surface` 的 global ref，**换成 SurfaceView 的 `Surface` 后
mpv 侧完全不用改**——这是本方案成立的关键。

## 二、总体设计

新增一条**并行的出画路径**，由 `VideoControllerConfiguration` 上的开关控制：

- `androidSurfaceView = false`（默认）：保持现有 Texture 路径，零回归风险；
- `androidSurfaceView = true`：走 `SurfaceView` + PlatformView，供 HDR 播放使用。

Dart 侧仍然暴露 `VideoController` / `Video` 这两个 API，**App 代码（`PLVideoPlayer`、
`view.dart`）不需要改**，改造全部收敛在 media_kit_video fork 内部。

## 三、改动清单（fork 内）

### 1. 新增 `VideoOutputSurfaceView.java`

```java
// 伪代码骨架
public class VideoOutputSurfaceView implements PlatformView {
    private final SurfaceView view;      // getView() 返回它
    private long wid = 0;

    VideoOutputSurfaceView(Context ctx, long handle, MethodChannel channel) {
        view = new SurfaceView(ctx);
        view.getHolder().addCallback(new SurfaceHolder.Callback() {
            public void surfaceCreated(SurfaceHolder h) {
                h.setFormat(PixelFormat.RGBA_1010102);   // 10bit buffer
                wid = (long) newGlobalObjectRef.invoke(null, h.getSurface());
                // 回传 wid 给 Dart
            }
            public void surfaceChanged(SurfaceHolder h, int fmt, int w, int hgt) {
                player.setOption("android-surface-size", w + "x" + hgt);
            }
            public void surfaceDestroyed(SurfaceHolder h) { /* 清理 wid */ }
        });
    }
    @Override public View getView() { return view; }
    @Override public void dispose() { /* release surface / deleteGlobalObjectRef */ }
}
```

要点：

- `newGlobalObjectRef` / `deleteGlobalObjectRef` 通过反射调用
  `com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper`（与现有 `VideoOutput`
  完全一致），**不需要自己写 JNI**；
- Surface 生命周期变化时必须删旧 `wid` 再建新的，避免 mpv 持有悬空 jobject；
- `surfaceDestroyed` 时把 `vo` 置回 `null`，否则重新进前台会黑屏。

### 2. `MediaKitVideoPlugin.java`

- 在 `onAttachedToEngine` 里
  `flutterPluginBinding.getPlatformViewRegistry().registerViewFactory("media_kit_video/hdr_surface", factory)`；
- 增加 `VideoOutputManager.CreateHdrSurface` / `DisposeHdrSurface` 两个 method；
- 把 `wid` 通过 channel 回传给 Dart（Surface 创建是异步的，Dart 需等待）。

### 3. `android_video_controller/real.dart`

- `VideoControllerConfiguration` 增加 `bool androidSurfaceView = false`；
- `create()`：该模式下不再 `VideoOutputManager.Create`（不建纹理），
  改为 `CreateHdrSurface`，拿 `viewId` 与 `wid`；
- `onLoadHooks`：`setOption('wid', wid)` + `setOption('vo','gpu')`（顺序不能反）；
- `videoParams` 监听：SurfaceView 模式下用 `SurfaceHolder.setFixedSize(w,h)` 代替
  `SetSurfaceTextureSize`，并继续更新 `android-surface-size`。

### 4. `lib/src/video/video.dart` / `simple_video_texture.dart`

- `videoController` 为 SurfaceView 模式时，`build` 返回
  `PlatformViewLink(viewType: 'media_kit_video/hdr_surface', ...)` 或 `AndroidView`，
  外层继续用 `SizedBox` + `AspectRatio` 撑满；
- 其余（Texture）路径不变。

## 四、mpv 参数（HDR 路径）

```text
vo=gpu
gpu-context=android
opengl-es=yes
wid=<SurfaceView 的 Surface global ref>
target-colorspace-hint=yes
android-surface-size=WxH
hwdec=mediacodec-copy        # 或 mediacodec，两者都能出 HDR；copy 才能叠加色调映射
```

加上现有 HDR 设置里的 `--tone-mapping` / `--target-peak` / `--hdr-compute-peak`。
注意：**直通与色调映射是二选一**——`target-colorspace-hint=yes` 时交给显示端，
此时 `--tone-mapping` 不再决定最终亮度。

## 五、10bit EGL 的关键点

`target-colorspace-hint=yes` 能否真正生效，取决于两件事：

1. **libmpv 构建**是否带 Android 的 HDR 色彩空间支持
   （`EGL_EXT_gl_colorspace_bt2020_pq` / 10bit EGL config）。
   二进制来自 `My-Responsitories/libmpv-android-video-build`，**在你们自己手里**，
   必要时加编译选项重出包；
2. SurfaceView 的 `Surface` 要允许 10bit：`SurfaceHolder.setFormat(RGBA_1010102)`
   （或由 EGL config 决定 buffer 格式）。

若第一步不满足，mpv 会静默回落到 8bit，表现为"打开开关但面板不亮"。
**验证方法**：播放 HDR 片源时看 `HDR 状态诊断` 里 `vo` 与片源 gamma；
再加一行 `log-message` 级别的 mpv 日志（`--msg-level=vo=gpu=v`）确认 EGL config 位深。

## 六、风险清单

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| hybrid composition（PlatformView）性能 | 4K 下掉帧 | 先只在 HDR 片源启用；必要时改 `SurfaceView` + `setZOrderMediaOverlay` |
| PiP / 小窗 | PlatformView 进 PiP 可能黑屏 | HDR 模式下降级为截图或禁用 PiP |
| 截图（`screenshot-raw`） | 可能拿到黑图 | 验证；不行则在 HDR 模式改用系统截图 |
| 旋转 / 尺寸变化 | 画面拉伸或黑边 | `surfaceChanged` 里重设 fixedSize + `android-surface-size` |
| 多实例（PiP + 主播放器） | Surface 冲突 | 每个 `handle` 独立 SurfaceView |
| 杜比 profile 5 | 色彩错误 | 需要 `gpu-next`（libplacebo）；`gpu` 下只能走 HDR10 基础层 |

## 七、分阶段落地（每阶段都可独立编译验证）

- **P0**：把 media_kit_video 源码 vendor 进仓库，`dependency_overrides` 指向本地路径，
  不改任何代码 → 确认能构建、能播放（验证 fork 链路）。
- **P1**：加入 SurfaceView 出画路径（**先不开 HDR**），验证出画、旋转、切 P、PiP、
  截图，以及 SDR 下的功耗/帧率。
- **P2**：打开 `target-colorspace-hint` + 10bit，验证面板 HDR 激发；不满足则回到
  libmpv 构建层排查 EGL config。
- **P3**：接上设置开关（HDR 片源才走 SurfaceView）、回退逻辑、文档。

## 八、前提

P0 需要把 `media_kit_video` 完整源码（约 90 个文件）复制进仓库。
当前会话的 shell 被系统 PowerShell 执行策略阻断，无法执行复制与编译，
因此需要先解除该限制（详见下方说明）。
