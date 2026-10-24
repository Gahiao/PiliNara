# HDR 原生渲染重做（Android）——已落地

> 状态：**已全部实现**。最终结构见 [hdr.md](hdr.md)：
> 视频由 Flutter **之下**的原生 SurfaceView 输出（`VideoSurfaceHost`），
> Flutter 只保留透明占位并同步矩形；仅在真正的 HDR 片源上启用，
> SDR 片源继续走纹理以保留 mpv 渲染能力。

## 一、为什么必须重做

前几轮的结论：

1. **Flutter 纹理是 8bit**：`Texture` / virtual display / `SurfaceProducer` 最终都是 RGBA8888，
   HDR 元数据在这一步丢失，无法显示 HDR。
2. **hybrid composition 的 SurfaceView 在 Flutter 之上**：能 HDR，但弹幕、控制栏、进度条
   都被原生 View 盖住，出现遮挡、残留、点击失效。
3. **当前 libmpv 构建没有 HDR 输出能力**：`.so` 里没有
   `ANativeWindow_setBuffersDataSpace`、没有 `EGL_*_gl_colorspace` 扩展，
   `target-colorspace-hint` 是空操作。
4. **唯一能触发面板 HDR 的是 `vo=mediacodec_embed`**：解码器直接输出到 Surface，
   HDR 由系统处理（代价是不经过 mpv 渲染，色调映射等参数无效）。

结论：必须把「视频画面」和「Flutter UI」的层级反过来——视频在**下**，Flutter 在**上**。

## 二、新架构：视频在 Flutter 之下

关键发现（已对 `flutter.jar` 用 `javap` 确认）：

- `FlutterActivity.getBackgroundMode()` 是 `protected`，可覆写；
- `BackgroundMode.transparent` 会让 Flutter 用 `FlutterSurfaceView(context, true)`，
  该构造会开启逐像素透明并 `setZOrderOnTop(true)`。

于是：

```
┌─────────────────────────────┐
│ Flutter surface（半透明，置顶）│  弹幕 / 控制栏 / 字幕 / 手势
├─────────────────────────────┤
│ SurfaceView（视频，HDR 层）    │  mpv vo=mediacodec_embed
├─────────────────────────────┤
│ Window 背景（黑）             │
└─────────────────────────────┘
```

- 播放页把视频区域绘制为**透明**，透出下方的 SurfaceView；
- SurfaceView 由原生层创建，按 Flutter 上报的物理像素矩形定位；
- 点击由 Flutter 窗口接收，不再有遮挡问题；
- HDR 层独立于 Flutter 合成，系统按该 layer 的 dataspace 决定面板亮度。

## 三、分阶段

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| **P1** | `MainActivity` 覆写 `getBackgroundMode()` 为 `transparent`，窗口背景设为黑色 | ✅ 已实现，并把 `NormalTheme` 的 `windowBackground` 一并改为黑色 |
| P2 | 原生 `VideoSurfaceHost`：SurfaceView 插入内容视图下层、按 rect 定位、owner 令牌交接、延迟销毁 | ✅ 已实现 |
| P3 | 接入 mpv：`vo=mediacodec_embed` + `--wid` + `android-surface-size`；播放页视频区域改为透明占位 | ✅ 已实现；`android-surface-size` 用视频编码尺寸，避免布局变化反复重建 |
| P4 | 适配：全屏/半屏/旋转/折叠屏/PiP；退出复位 `COLOR_MODE_HDR`；截图改为 PixelCopy | ✅ 已实现（旋转/镜像手势在 HDR 下禁用） |
| P5 | 收尾：移除旧的 hybrid PlatformView 路径与实验开关，文档更新 | ✅ 已实现，fork 只保留 `androidExternalSurface` |

## 四、风险

1. **全局透明 surface**：所有页面都走 RGBA 合成，需要确认没有透底、性能可接受；
2. **SurfaceView 定位**：需要跟随 Flutter 布局（含全屏、小窗、旋转、折叠屏），
   一帧延迟可能导致画面抖动；
3. **PiP**：SurfaceView 归属窗口变化时可能黑屏；
4. **设备差异**：个别 ROM 对透明 Flutter surface + 叠加视频层的支持不佳；
5. **`mediacodec_embed` 的硬解限制**：不支持 AV1/部分编码的设备会退回软解（无 HDR）。

## 五、回退策略

设置 → 播放设置 →「HDR 直通出画」关闭后，HDR 片源也走 8bit 纹理（只做色调映射）。
该开关默认开启；遇到个别 ROM 的透明图层/显示模式问题时可关闭后重开视频。
`hdrBackend` 也可切回 `gpu-next` / `gpu` 做对照实验。
