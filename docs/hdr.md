# HDR / 杜比视界支持（Android 直通出画）

本分支（`ds-ai-hdr`）为播放器补上了 HDR / HDR Vivid / 杜比视界的片源获取、色彩处理，
并在 Android 上实现了**真正能点亮面板 HDR** 的出画路径。桌面端仍保持 media_kit 的
纹理渲染，只做色调映射。

## 一、两种出画路径

Flutter 的 `Texture` 固定是 **RGBA8888**，HDR 元数据在这一步必然丢失。因此：

| 片源 | 出画方式 | 说明 |
| --- | --- | --- |
| SDR | Flutter 纹理（media_kit 原路径） | 保留硬解、Anime4K、色调映射等全部 mpv 渲染能力 |
| HDR / 杜比视界 | **Flutter 之下的原生 SurfaceView** | 默认 `mediacodec_embed` 由解码器直接送显；也可选 `gpu-next` 走 Vulkan 交换链输出 |

关键点：

* SurfaceView 由原生 `VideoSurfaceHost` 插到窗口内容视图的**第 0 层**，位于 Flutter
  surface 之下；Flutter 的 surface 在透明模式下仍绘制在其上方。
* 视频区域只保留一块透明占位，**弹幕、字幕、控制栏、手势全部是 Flutter 绘制**，
  不会被原生 View 遮挡或吃掉点击（这是旧的 hybrid composition PlatformView 方案
  解决不了的问题）。
* 出画方式在播放器创建时确定。切换画质 / 换集导致 SDR ↔ HDR 变化时，
  `PlPlayerController._switchOutputIfNeeded()` 会重建播放器（其余情况复用）。

## 二、设置项

设置 → 播放设置 →「开启硬解」下方：

| 设置项 | 存储键 | 默认值 | 说明 |
| --- | --- | --- | --- |
| HDR 支持 | `enableHdr` | 开 | 总开关。关闭后 HDR 片源也走纹理（只做色调映射） |
| HDR 直通出画 | `hdrSurface` | **开** | HDR 片源改用 SurfaceView 直通送显；切换后重开视频生效 |
| HDR 渲染后端 | `hdrBackend` | **`mediacodec_embed`** | `mediacodec_embed`：解码器直通，最稳；`gpu-next`：libplacebo + Vulkan，实验性 HDR；`gpu-next-gl` / `gpu`：OpenGL 兼容路径 |
| HDR 解码方式 | `hdrHwdecMode` | `auto` | 仅影响纹理路径；直通出画 + `mediacodec_embed` 时固定 `mediacodec` |
| HDR 输出模式 | `hdrOutputMode` | `auto` | `passthrough` 会额外写 `target-colorspace-hint=yes`（对纹理路径基本无效） |
| HDR 色调映射 | `hdrToneMapping` | `auto` | `--tone-mapping`，纹理 / `gpu-next` / `gpu` 路径有效；`mediacodec_embed` 不生效 |
| HDR 目标峰值亮度 | `hdrTargetPeak` | `0`（自动） | `--target-peak`，纹理 / `gpu-next` / `gpu` 路径有效 |
| HDR 动态峰值检测 | `hdrComputePeak` | 开 | `--hdr-compute-peak`，纹理 / `gpu-next` / `gpu` 路径有效 |
| 杜比视界兼容模式 | `dolbyVisionFallback` | 开 | 仅 profile 5 回退 HDR10；profile 8/8.4 不回退 |
| HDR 状态诊断 | — | — | 查看当前出画路径、`wid`、`vo`、`hwdec-current`、片源色彩等 |

> `mediacodec_embed` 由 MediaCodec 直接解码到 Surface，mpv 拿不到帧，
> 因此色调映射 / 峰值亮度 / 抖动等参数在这条路径上**不会生效**，这是直通的代价，
> 也是它唯一能真正输出 HDR 的原因。关闭「HDR 直通出画」即可回到可调色调映射的纹理路径。

## 三、原生出画层怎么工作

`android/app/src/main/kotlin/com/example/pilinara/VideoSurfaceHost.kt`：

1. `create(owner, x, y, w, h, tenBit, hdr)`：创建（或**复用**）SurfaceView，
   一次性按最终矩形添加，不存在「先 1×1 再跳位」的黑闪；
2. `setRect`：页面滚动、全屏/半屏、旋转、小窗拖动时逐帧只更新布局；
3. `surfaceCreated`：把 `android.view.Surface` 的 global ref（`wid`）回传 Dart；
4. 窗口 HDR 模式只对真正有 HDR 输出能力的后端预切换（`mediacodec_embed` 与
   `gpu-next` Vulkan），并在播放器/首帧出现之前完成，避免首帧出声时整屏亮一下。
   `gpu-next-gl` / `gpu` 不切换窗口 HDR，否则 SDR 画面会被系统当成 HDR 显示而发灰。
   原生 `setHdr` 通道保留但已不再使用；
5. `remove`：延迟 400ms 销毁。页面 ↔ 小窗切换时新旧控件会短暂共存，
   立即销毁会导致 Surface 重建、mpv 重新初始化 → 黑闪；
6. `capture`：用 `PixelCopy` 抓当前画面，供 HDR 直通时截图。

Dart 侧 `lib/plugin/pl_player/utils/native_video_surface.dart`：

* 控件本身透明，尺寸与视频画面一致；
* 每帧结束后读取 `RenderBox` 在屏幕上的真实矩形（含 FittedBox 缩放与手势缩放），
  变化时才下发 `setRect`，不主动申请帧、不空转；
* 用自增的 `owner` 令牌交接页面/小窗两个控件，过期调用会被原生与控制器同时忽略；
* 只有拿到有效视频尺寸（`VideoController.rect`）后才 `create`，保证首帧尺寸正确。

`--android-surface-size` 使用 **SurfaceView 的实际布局尺寸**（与旧的 hybrid 出画路径
一致），不是视频编码尺寸。部分设备/解码器在 `android-surface-size` 与 SurfaceView
布局不一致时会直接黑屏（例如把 3840×2160 写到一个 1080×607 的 Surface 上）。
布局尺寸变化做了 200ms 防抖，小窗拖动/全屏动画期间不会逐帧重建视频输出。

### 页面/视频控件不能有不透明底色

原生视频在 Flutter surface 之下，Flutter 场景里任何不透明绘制都会盖住它。视频页：

* `SimpleScaffold` 的 Material 透明，视频 header 的黑底移除；
* 非视频区域（简介/评论/侧栏/小窗）显式加回主题表面色背景；
* `PLVideoPlayer` 的 `_videoWidget` 在 native 模式下透明；
* **最容易漏的一层**：`videoPlayer()` 的 `Stack` 里有一层铺满视频区的
  `const ColoredBox(color: Colors.black)`。它在视频控件之下、原生视频之上，
  HDR 直通时必须跳过（`if (plPlayerController?.useNativeSurface != true)`），
  否则会出现「挖孔正确、采样 mean=227、孔内仍然全黑」。
  这是最终定位到的直接原因。
* 播放页根节点用 `HdrHolePunch` 铺黑，只把视频矩形挖成透明；
* 预测性返回时用 `HdrVideoBlackout` 只压黑当前视频矩形，页面其余部分仍然可见，
  不再盖整屏黑幕。

### Flutter 必须用 surface 渲染模式（FlutterSurfaceView）

`FlutterActivity` 的默认实现是：

```java
getRenderMode() {
  return getBackgroundMode() == opaque ? RenderMode.surface : RenderMode.texture;
}
```

把 `getBackgroundMode()` 设为 `transparent` 后，默认会使用 **FlutterTextureView**。
TextureView 属于窗口内部的一层，窗口本身不透明，无法透出窗口之后的视频
SurfaceView（表现为采样有画面但屏幕全黑）。因此 `MainActivity` 必须同时覆盖：

```kotlin
override fun getBackgroundMode() = BackgroundMode.transparent
override fun getRenderMode() = RenderMode.surface
```

`surface` 模式下 delegate 会创建 `FlutterSurfaceView(context, transparent = true)`，
它自己会设置 `PixelFormat.TRANSPARENT(-2)` 并 `setZOrderOnTop(true)`；不要再强行
改成 `TRANSLUCENT(-3)`。HDR 状态诊断会显示 `backgroundMode` / `renderMode` 以及
视图树中每个 SurfaceView 的 `format` / `size`（`getFormat` 在 compileSdk 37 的
stub 中已移除，运行时用反射读取，读不到显示 `?`）。

### 整屏亮度跳变属系统 HDR 模式切换

真 HDR 需要显示面板切到 HDR 模式。部分设备只支持**全局** HDR 模式（而不是按层合成
HDR/SDR），进入 HDR 播放时整个屏幕（包括 SDR 的弹幕/控件/简介）会变亮一次。

应用会在 `setDataSource` 阶段、首帧之前通过 `setWindowHdr` 预切窗口色彩模式
（`window.setColorMode(COLOR_MODE_HDR)`），让这次跳变发生在加载/黑屏阶段而不是首帧
出声时；离开播放页时复位为 `COLOR_MODE_DEFAULT`。它只对 `mediacodec_embed` 与
`gpu-next` Vulkan 生效。即使不预切，部分设备也会根据 HDR Surface 的 dataspace 自动
切换，应用无法完全消除；不希望出现跳变时，关闭「HDR 直通出画」走 8bit 色调映射。

## 四、mpv 参数（HDR 路径）

### 4.1 mediacodec_embed（默认，推荐）

```text
vo=mediacodec_embed
hwdec=mediacodec            # 必须直通硬解
wid=<SurfaceView 的 Surface global ref>
android-surface-size=WxH    # SurfaceView 布局尺寸（不是视频编码尺寸）
vid=auto
target-colorspace-hint=yes
```

`tone-mapping` / `hdr-compute-peak` / `dither` 仍会写入，但这条路径下 mpv 拿不到帧，
参数不参与最终画面，HDR 完全由 MediaCodec 输出 buffer 的 dataspace 决定。

### 4.2 gpu-next + Vulkan（实验）

需要带 Vulkan 的 libmpv 构建（本仓库 fork：
`https://github.com/Gahiao/libmpv-android-video-build`，构建时打开 `MPV_VULKAN` /
`LIBPLACEBO_VULKAN`，并且 **libplacebo 必须带 SPIR-V 编译器 shaderc**）。
`ra_ctx_vulkan_android`（`gpu-context=androidvk`）是 fork 新增的 Android Vulkan 上下文。

PiliNara 不再手工替换 jar：`third_party/media_kit_libs_android_video` 的
`downloadLibmpv` 任务会在每次 Android 构建时从 fork 的 `libmpv-latest` release
下载各 ABI 的 `default-*.jar` 与 `SHA256SUMS`，校验后放进 `build/output`。
因此 fork 的 Build workflow 每跑一次，App 下次构建就会自动用上最新库；首次使用
必须先手动跑一次该 workflow，生成 `libmpv-latest`。

> **没有 shaderc 会直接黑屏**：libplacebo 的 Vulkan 后端要用 shaderc/glslang 编译
> GLSL。只开 `-Dvulkan=enabled` 而没有 `-Dshaderc=enabled` 时，mpv 日志会出现
> `Failed initializing any SPIR-V compiler! Maybe libplacebo was built without support
> for either libshaderc or glslang?`，随后 `Failed initializing vulkan device`，
> 表现为音频/进度正常但画面纯黑。fork 的 `dep_libplacebo=(shaderc)` 与
> `libplacebo.sh -Dshaderc=enabled` 已修复这一点。

```text
gpu-api=vulkan
gpu-context=androidvk
vo=gpu-next
gpu-dumb-mode=no
target-colorspace-hint=yes
target-colorspace-hint-mode=target
target-colorspace-hint-strict=no
target-prim=auto
target-trc=auto
hdr-compute-peak=yes
gamut-mapping-mode=auto
dither-depth=auto
video-output-levels=auto
wid=<SurfaceView 的 Surface global ref>
```

顺序很重要：**先 `vo=null` → 写 `gpu-api` / `gpu-context` → 给 `wid` →
`vo=gpu-next` → 再写一次 HDR 属性**。`gpu-context` 只在 VO 创建时读取一次；
`target-colorspace-hint` / `target-prim` / `target-trc` 是 VO 选项，`vo=null`
时写入会被忽略，必须在 VO 创建后再写一次（`reset: false`，避免把刚协商好的
HDR 交换链复位成 SDR）。

> **media_kit 会覆盖 `gpu-context`**：`AndroidVideoController.create` 在
> `Player.create` 之后无条件写入 `vo=null`、`gpu-context=android`、`opengl-es=yes`、
> `force-window=yes`（`third_party/media_kit_video/lib/src/video_controller/android_video_controller/real.dart`）。
> 如果只在创建播放器前写 Vulkan 参数，`gpu-context` 一定会被改回 `android`，gpu-next
> 永远走 OpenGL。因此 `PlPlayerController._initPlayer()` 在 `VideoController.create`
> 之后补写一次 HDR 属性，`_applyNativeSurface()` 在 `vo=gpu-next` 之前写初始化参数、
> 在 `vo=gpu-next` 之后（首帧前）再补写一次 HDR 目标属性。

`gpu-next` 的 `vo_gpu_next` 在 `target-colorspace-hint=yes` 且上下文没有报告目标
色彩空间（`ra_ctx_vulkan_android` 的 `target_csp` 返回空）时，会按 HDR10（PQ/BT.2020）
构造 hint，再通过 `VK_EXT_swapchain_colorspace` 协商交换链。

**自动回退**：播放开始 2.5 秒后读取 `vo-configured`；若仍为 `no`，说明当前
libmpv 的 Vulkan VO 初始化失败（最常见原因就是缺 shaderc），应用会设置
`_vulkanVoUnavailable` 并自动回退：HDR 片源改用 `mediacodec_embed` 直通，
保住面板 HDR 亮度；SDR / 杜比兼容路径改用 `gpu-next OpenGL`。回退时重新下
`vo/wid`；SDR / OpenGL 路径会关闭窗口 HDR 预切。状态诊断会显示「已自动回退
（原 gpu-next Vulkan）」以及「Vulkan 自动回退: 已触发」。设置页重新选择后端
会清除该标记，允许再次尝试 Vulkan。

### 4.3 gpu-next OpenGL / gpu（兼容）

`gpu-next-gl` 使用 `gpu-api=opengl` / `gpu-context=android` 并写 `fbo-format=rgba16hf`
（`fbo-format` 是 OpenGL 选项，Vulkan 路径不能写），同时显式写
`target-colorspace-hint=no`，让 libplacebo 正常 tone map 回 SDR。Android EGL 没有
HDR 交换链扩展，这条路径通常只输出 SDR，主要用于兼容排查。

## 五、片源获取

`VideoHttp.videoUrl` 的 `fnval` 保持 `4048`：

| 位 | 含义 |
| --- | --- |
| 16 | DASH |
| 64 | HDR（画质 125） |
| 128 | 4K |
| 256 | 杜比音频 |
| 512 | 杜比视界（画质 126） |
| 1024 | 8K |
| 2048 | AV1 |

> **不要加 4096**：曾把 `fnval` 改成 `8144` 想打开 HDR Vivid（129），但 4096 不是
> web playurl 支持的位，服务端会返回 `-404`，表现为所有视频都提示不存在。
> 因此 HDR Vivid 片源目前取不到；HDR（125）与杜比视界（126）不受影响。

## 六、平台能力与已知限制

1. **gpu-next Vulkan 仍是实验路径**。libmpv fork 增加了 `ra_ctx_vulkan_android`，
   gpu-next 可通过 `VK_EXT_swapchain_colorspace` 请求 HDR10 交换链；但 fork 的
   `video/out/vulkan/context_android.c` 只调用 `ANativeWindow_setBuffersGeometry`，
   没有调用 `ANativeWindow_setBuffersDataSpace`，部分 ROM 仍可能把 Vulkan 交换链
   当 SDR 合成（表现为画面正常但面板不切 HDR，或颜色发灰）。**确定能点亮 HDR 的
   仍是 `mediacodec_embed`**；Vulkan 路径因设备驱动差异或 libmpv 缺少 shaderc
   可能黑屏。应用已内置 `vo-configured` 检测：HDR 片源自动回退到
   `mediacodec_embed` 直通，SDR 路径回退 `gpu-next-gl`；也可以手动切后端。
   此外 fork 的构建矩阵里 `MPV_VULKAN` 与 `LIBPLACEBO_VULKAN` 必须同时打开；只开
   其中一个会出现 GL/mediacodec 输出全黑（fork 提交 `effde5e` 用于二分定位）。
2. **杜比视界 profile 5**：使用 IPTPQc2 色彩空间，`mediacodec_embed` 直通会把它
   当成 SDR（诊断里表现为 `bt.709 / bt.1886`、`sig-peak=0`）导致偏色。选择
   `gpu-next` / `gpu-next-gl` 时由 libplacebo 解析 DoVi RPU，保留 126 原片源，
   不再触发兼容模式回退，也不走 Media3；`mediacodec_embed` / `gpu` 下开启「杜比视界
   兼容模式」才会改用同分辨率 HDR10（125）。兼容模式只处理 profile 5；profile
   8/8.4 带 HDR10/HLG 基础层，始终保留 DoVi 直通。走 gpu-next 的 profile 5 会让
   窗口进入 HDR 模式（Vulkan 交换链按 HDR10 输出），这是正常行为。
3. **手势限制**：原生 SurfaceView 是独立图层，无法跟随 Flutter 的旋转与镜像。
   HDR 直通时禁用双指旋转、自动重置镜像；缩放/平移通过矩形同步仍然可用。
4. **PiP**：支持，但小窗圆角无法裁切原生图层（会看到直角视频）；
   关闭动画只作用于 Flutter 层。系统 PiP 与 App 内小窗均已做透明底色适配。
5. **截图**：HDR 直通时改用原生 `PixelCopy`，不再依赖 `Player.screenshot()`。
6. **透明 Flutter surface**：为让视频位于 Flutter 之下，Activity 使用
   `BackgroundMode.transparent`；窗口背景已固定为黑色（`NormalTheme` + `onCreate`），
   避免透白闪烁。

## 七、「面板亮度没有激发」怎么排查

设置 → 播放设置 →「HDR 状态诊断」：

1. `出画路径` 必须是 `SurfaceView(HDR)`；如果是 `Texture(8bit)`，说明当前画质不是
   HDR/杜比视界档位，或关闭了「HDR 直通出画」/「HDR 支持」/硬解；
2. `原生 Surface` 的 `wid` 不为 `-`；为 `-` 说明 SurfaceView 还没创建/挂载；
3. 按后端核对 `vo` / `gpu-api` / `gpu-context`：
   * `mediacodec_embed`：`vo=mediacodec_embed`，`hwdec-current=mediacodec`；
   * `gpu-next`：`vo=gpu-next`、`gpu-api=vulkan`、`gpu-context=androidvk`，
     `hwdec-current` 应为 `mediacodec-copy` / `auto-copy`（mpv 需要拿到帧）；
   * `gpu-next-gl`：`gpu-api=opengl`、`gpu-context=android`；
4. 如果 `gpu-context` 仍显示 `android`，说明 media_kit 的覆盖没有被补写覆盖掉——
   检查 `_initPlayer` 中 `VideoController.create` 之后的 `_applyHdrProperties` 调用；
5. `gpu-next` 还要确认 `target-colorspace-hint=yes`、`target-prim=bt.2020`、
   `target-trc=pq` 已经生效；这三项是 VO 选项，只在 `vo=gpu-next` 之后补写
   才会被 libplacebo 看到；
6. `视频色彩` 的 gamma 为 `pq` / `hlg` 才是真 HDR 片源；`bt.1886` 是 SDR；
7. 以上都正常但面板仍不亮：检查设备是否支持 HDR、系统显示设置是否开启 HDR，
   以及当前窗口是否被系统限制为 SDR。

### 7.1 亮度手势在 HDR 下没有反应

部分设备进入 HDR 输出后会把面板锁在峰值亮度，WindowManager.LayoutParams.screenBrightness
或系统亮度设置都压不住原生 HDR 图层。HDR 直通时亮度手势改为调整 Flutter 侧的黑色
遮罩（PlPlayerController.nativeBrightness），只向下压暗、不影响解码/色调映射：

* setBrightness 在 useNativeSurface 为 true 时不再调用系统/应用窗口亮度；
* HDR 直通从面板峰值亮度开始，首次滑动先把基准和值对齐到 1.0，避免
  _brightnessValue 初始值较低时第一次滑动把画面瞬间压黑；value=base 不遮、
  value=0 全黑；切换出/重新进入 HDR 时依据 nativeBrightness 的 -1 复位；
* 遮罩在 lib/pages/video/widgets/hdr_hole_punch.dart 的
  HdrNativeBrightnessOverlay，夹在挖孔黑底与页面内容之间，只压暗视频孔，
  控制栏和亮度指示仍然清晰；IgnorePointer 不拦截手势；
* SDR / 纹理路径仍走原来的系统或应用窗口亮度，不受影响。

## 八、代码位置

| 文件 | 作用 |
| --- | --- |
| `android/.../VideoSurfaceHost.kt` | 原生 SurfaceView 宿主：创建/复用、矩形、HDR 色彩模式、PixelCopy 截图 |
| `android/.../MainActivity.kt` | `com.pilinara/video_surface` 通道、透明 Flutter surface、黑色窗口背景 |
| `lib/plugin/pl_player/utils/native_video_surface.dart` | Flutter 侧透明占位 + 逐帧矩形同步 + owner 交接 |
| `lib/plugin/pl_player/utils/native_video_surface_channel.dart` | 通道封装（create / setRect / setHdr / remove / capture） |
| `lib/plugin/pl_player/controller.dart` | 出画方式决策、播放器重建、`wid`/`vo` 下发、HDR 属性、诊断、截图 |
| `lib/plugin/pl_player/models/hdr_config.dart` | HDR 模式/算法/解码方式/后端枚举与 mpv 属性 |
| `lib/pages/setting/models/video_settings.dart` | 设置项、对话框、状态诊断 |
| `lib/pages/video/controller.dart` | 播放前写入「当前片源是否 HDR」 |
| `lib/pages/video/widgets/hdr_hole_punch.dart` | 视频挖孔黑底、返回手势压黑、HDR 亮度遮罩 |
| `lib/common/widgets/pip_mini_video_content.dart` | 小窗视频内容（透明底色 + 原生占位） |
| `lib/services/pip_overlay_service.dart` | 小窗/系统 PiP 的透明底色适配 |
| `lib/utils/video_utils.dart` | 杜比视界兼容模式的选质回退 |
| `third_party/media_kit_video` | 仅保留 `androidExternalSurface`（不创建纹理，由应用提供 Surface）；注意它会覆盖 `gpu-context` |
| `third_party/libmpv-android-video-build` | libmpv / libplacebo 带 Vulkan 的构建 fork（`androidvk` 上下文、构建矩阵） |

## 九、自测建议

1. 找一部带「杜比视界」或「HDR」标签的视频，选对应画质播放；
2. 状态诊断确认 `出画路径=SurfaceView(HDR)`、`vo=mediacodec_embed`、
   `hwdec-current=mediacodec`、gamma 为 `pq`/`hlg`；
3. 观察打开视频时是否还有整屏闪烁；正常应只有视频区域短暂黑场后出画；
4. 全屏 ↔ 半屏、竖屏 ↔ 横屏、进入 App 内小窗 / 系统 PiP，确认视频位置正确、
   弹幕与控制栏正常、退出后亮度回落；
5. 截图（HDR 直通下走 PixelCopy）应能正常保存；
6. 切到 SDR 画质：应自动重建为纹理出画，Anime4K 等能力恢复；
7. 关闭「HDR 直通出画」后重开视频：回到纹理路径，色调映射参数应即时可调。

## 十、打开视频白屏 / 灰屏修复记录

打开视频时曾出现整屏灰色（约 `#b5b5b5`）或启动时白屏，两者来源不同：

### 10.1 整屏灰色 = Flutter release ErrorWidget

`lib/pages/video/view.dart` 为了实现预测性返回手势的黑色遮罩，曾把 `ModalRoute` 强转成
`Listenable`：

```dart
// 错误：ModalRoute 不是 Listenable
animation: (route as Listenable?) ?? kAlwaysDismissedAnimation,
```

`ModalRoute` 继承自 `TransitionRoute`，并没有实现 `Listenable`，这个 cast 在 build 时
抛出 `TypeError`。release 模式下 Flutter 用 `ErrorWidget` 覆盖整页，颜色就是
`0xF0C0C0C0` 叠在黑底上的灰色，看起来像「白屏/灰屏」。按返回键能立刻回到首页，
因为路由本身没有问题。

正确做法是使用 `NavigatorState.userGestureInProgressNotifier`（Flutter 自己的
`_ModalScopeState` 也用它跟踪 `popGestureInProgress`）：

```dart
final Listenable? gesture = route?.navigator?.userGestureInProgressNotifier;
...
animation: gesture ?? kAlwaysDismissedAnimation,
```

> 如果以后再次看到整屏灰色，先用 `flutter run` 看 build 异常；不要只按「白屏」去查
> 原生 Surface。

### 10.2 启动白屏 = LaunchTheme 的白色启动图

* `android/app/src/main/res/drawable/background.png` 是一个 **1×1 白色像素**，旧的
  `launch_background.xml`（含 `-v21` / `night` 变体）把它铺满全屏；
* `values-v31/styles.xml` 的 `android:windowSplashScreenBackground` 还是 `#ffffff`。

Android 12+ 在 Flutter 首帧之前显示 splash，于是先白一下。现在四个
`launch_background.xml` 都改成 `@android:color/black`，`values-v31` /
`values-night-v31` 的 splash 背景也统一为 `#000000`，与 `NormalTheme` 的黑色窗口背景一致。
