# HDR / 杜比视界支持（Android 直通出画）

本分支（`ds-ai-hdr`）为播放器补上了 HDR / HDR Vivid / 杜比视界的片源获取、色彩处理，
并在 Android 上实现了**真正能点亮面板 HDR** 的出画路径。桌面端仍保持 media_kit 的
纹理渲染，只做色调映射。

## 一、两种出画路径

Flutter 的 `Texture` 固定是 **RGBA8888**，HDR 元数据在这一步必然丢失。因此：

| 片源 | 出画方式 | 说明 |
| --- | --- | --- |
| SDR | Flutter 纹理（media_kit 原路径） | 保留硬解、Anime4K、色调映射等全部 mpv 渲染能力 |
| HDR / 杜比视界 | **Flutter 之下的原生 SurfaceView** | MediaCodec 直接送显，系统按 HDR 色彩空间输出，真正激发面板 HDR |

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
| HDR 渲染后端 | `hdrBackend` | **`mediacodec_embed`** | 唯一确定能点亮 HDR 的后端；`gpu-next` / `gpu` 为实验项 |
| HDR 解码方式 | `hdrHwdecMode` | `auto` | 仅影响纹理路径；直通出画 + `mediacodec_embed` 时固定 `mediacodec` |
| HDR 输出模式 | `hdrOutputMode` | `auto` | `passthrough` 会额外写 `target-colorspace-hint=yes`（对纹理路径基本无效） |
| HDR 色调映射 | `hdrToneMapping` | `auto` | `--tone-mapping`，仅纹理/`gpu` 后端有效 |
| HDR 目标峰值亮度 | `hdrTargetPeak` | `0`（自动） | `--target-peak`，仅纹理/`gpu` 后端有效 |
| HDR 动态峰值检测 | `hdrComputePeak` | 开 | `--hdr-compute-peak`，仅纹理/`gpu` 后端有效 |
| 杜比视界兼容模式 | `dolbyVisionFallback` | 关 | 存在同分辨率 HDR10 片源时把 DoVi 档位回退到 125 |
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
4. 不再主动调用 `window.setColorMode(COLOR_MODE_HDR)`：该调用会让整块屏幕切换到
   HDR 显示模式，部分设备表现为「突然高亮一下」，且画面未就绪时会一直停在亮屏黑画面。
   HDR 由 MediaCodec 输出 buffer 的 dataspace 交给系统处理（原生 `setHdr` 通道保留但不再使用）；
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

### 页面背景必须透明

Flutter 的页面背景、视频 header 的黑色底、以及 `MiniScaffold`/简介面板等任何不透明
绘制都会盖住底层的 SurfaceView（它位于整个 Flutter surface 之下）。因此视频页：

* `SimpleScaffold` 的 Material 改为透明，视频 header 的黑底移除；
* 非视频区域（简介/评论/侧栏/小窗）显式加回主题表面色背景；
* 全屏/横屏/竖屏/近似方形布局都已覆盖。

这是「HDR 已出画但画面全黑」的直接原因：原生视频在 Flutter 之下，之前被页面黑底/
Material 背景盖住了。

### Flutter surface 必须是 TRANSLUCENT

仅把页面画成透明还不够：承载 Flutter 的 `FlutterSurfaceView` 的 buffer format 必须是
`PixelFormat.TRANSLUCENT`，否则整个 Flutter 表面不透明，挖孔也不会透出底层。

`MainActivity` 在 `onCreate` / `onPostResume` 遍历视图树，发现 Flutter 的 SurfaceView
不是 TRANSLUCENT 时强制设置并置顶。`HDR 状态诊断` 底部会显示：

* `flutterSurfaceFormatBeforeFix=`：修复前的 format（`1`=RGBA_8888，不透明；
  `-3`=TRANSLUCENT）；
* 视图树中每个 SurfaceView 的 `format` 与 `size`。

### 整屏亮度跳变属系统 HDR 模式切换

真 HDR 需要显示面板切到 HDR 模式。部分设备只支持**全局** HDR 模式（而不是按层合成
HDR/SDR），进入 HDR 播放时整个屏幕（包括 SDR 的弹幕/控件/简介）会变亮一次。
应用层已经不再调用 `window.setColorMode`，这个切换是系统根据 HDR Surface 的 dataspace
自动完成的，应用无法消除。不希望出现切换时，关闭「HDR 直通出画」走 8bit 色调映射。

## 四、mpv 参数（HDR 路径）

```text
vo=mediacodec_embed
hwdec=mediacodec            # mediacodec_embed 必须直通硬解
wid=<SurfaceView 的 Surface global ref>
android-surface-size=WxH    # SurfaceView 布局尺寸（不是视频编码尺寸）
vid=auto
```

`target-colorspace-hint`、`tone-mapping` 等仍会写入，但在 `mediacodec_embed` 下不参与
最终画面，只对 `gpu-next` / `gpu` 实验后端有意义。

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

1. **libmpv 构建没有 Android HDR 输出能力**（缺 `ANativeWindow_setBuffersDataSpace`
   / 10bit EGL 色彩空间扩展），所以 `gpu-next` + `target-colorspace-hint` 实际不会
   点亮 HDR；只有 `mediacodec_embed` 直通可行。
2. **杜比视界 profile 5**：使用 IPTPQc2 色彩空间，交给 MediaCodec/系统直通处理；
   若设备解码器不支持，会黑屏/偏色，可开启「杜比视界兼容模式」回退 HDR10。
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
3. `vo` 应为 `mediacodec_embed`，`hwdec-current` 应为 `mediacodec`；
4. `视频色彩` 的 gamma 为 `pq` / `hlg` 才是真 HDR 片源；`bt.1886` 是 SDR；
5. 以上都正常但面板仍不亮：检查设备是否支持 HDR、系统显示设置是否开启 HDR，
   以及当前窗口是否被系统限制为 SDR。

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
| `lib/common/widgets/pip_mini_video_content.dart` | 小窗视频内容（透明底色 + 原生占位） |
| `lib/services/pip_overlay_service.dart` | 小窗/系统 PiP 的透明底色适配 |
| `lib/utils/video_utils.dart` | 杜比视界兼容模式的选质回退 |
| `third_party/media_kit_video` | 仅保留 `androidExternalSurface`（不创建纹理，由应用提供 Surface） |

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
