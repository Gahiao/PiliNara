import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/pages/setting/widgets/select_dialog.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/hdr_config.dart';
import 'package:PiliPlus/plugin/pl_player/utils/native_video_surface_channel.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// HDR / 杜比视界专项设置页。
///
/// 从「音视频设置」进入，避免这些低频选项把主列表撑得过长。
class HdrSettingsPage extends StatelessWidget {
  const HdrSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SimpleScaffold(
      appBar: AppBar(title: const Text('HDR / 杜比视界')),
      body: ListView.builder(
        padding: const EdgeInsets.only(bottom: 100),
        itemCount: hdrSettings.length,
        itemBuilder: (context, index) => hdrSettings[index].widget,
      ),
    );
  }
}

List<SettingsModel> get hdrSettings => [
  SwitchModel(
    title: 'HDR 支持',
    subtitle: '为 HDR / 杜比视界片源启用色调映射与广色域处理，关闭后保持默认渲染',
    leading: const Icon(Icons.hdr_on),
    setKey: SettingBoxKey.enableHdr,
    defaultVal: true,
    onChanged: (value) => PlPlayerController.instance?.applyHdrOptions(),
  ),
  NormalModel(
    title: 'HDR 输出模式',
    leading: const Icon(Icons.hdr_auto),
    getSubtitle: () {
      final mode = HdrOutputMode.fromValue(Pref.hdrOutputMode);
      return '当前：${mode.label}\n${mode.desc}';
    },
    onTap: _showHdrOutputModeDialog,
  ),
  NormalModel(
    title: 'HDR 色调映射',
    leading: const Icon(Icons.gradient_outlined),
    getSubtitle: () =>
        '当前：${HdrToneMapping.fromValue(Pref.hdrToneMapping).label}（此项即mpv的--tone-mapping）',
    onTap: _showHdrToneMappingDialog,
  ),
  NormalModel(
    title: 'HDR 目标峰值亮度',
    leading: const Icon(Icons.brightness_6_outlined),
    getSubtitle: () =>
        '当前：${HdrConfig.targetPeakLabel(Pref.hdrTargetPeak)}。自动时由片源与显示设备能力决定（此项即mpv的--target-peak）',
    onTap: _showHdrTargetPeakDialog,
  ),
  SwitchModel(
    title: 'HDR 动态峰值检测',
    subtitle: '逐帧统计画面峰值亮度，高光细节更完整，会增加少量 GPU 开销（此项即mpv的--hdr-compute-peak）',
    leading: const Icon(Icons.auto_graph),
    setKey: SettingBoxKey.hdrComputePeak,
    defaultVal: true,
    onChanged: (value) => PlPlayerController.instance?.applyHdrOptions(),
  ),
  NormalModel(
    title: 'HDR 解码方式',
    leading: const Icon(Icons.memory_outlined),
    getSubtitle: () {
      final mode = HdrHwdecMode.fromValue(Pref.hdrHwdecMode);
      return '当前：${mode.label}。${mode.desc}';
    },
    onTap: _showHdrHwdecDialog,
  ),
  const SwitchModel(
    title: 'HDR 直通出画',
    subtitle:
        'HDR / 杜比视界片源改用 Flutter 之下的 SurfaceView 出画：'
        'MediaCodec 直通由解码器送显，gpu-next 则通过 Vulkan 交换链协商 HDR；',
    leading: const Icon(Icons.hdr_strong),
    setKey: SettingBoxKey.hdrSurface,
    defaultVal: true,
  ),
  NormalModel(
    title: 'HDR 渲染后端',
    leading: const Icon(Icons.tune),
    getSubtitle: () {
      final backend = HdrBackend.fromValue(Pref.hdrBackend);
      return '当前：${backend.label}。${backend.desc}';
    },
    onTap: _showHdrBackendDialog,
  ),
  const SwitchModel(
    title: '杜比视界兼容模式',
    subtitle:
        '仅对 profile 5 生效：mediacodec_embed / gpu 直通会把它当成 SDR 导致偏色，开启后若存在同分辨率 HDR10 片源则改用 HDR10；'
        'gpu-next 会直接解析 DoVi RPU，选择它时本开关不再回退。'
        '(似乎无效?)',
    leading: const Icon(Icons.brightness_high),
    setKey: SettingBoxKey.dolbyVisionFallback,
    defaultVal: true,
  ),
  const SwitchModel(
    title: 'profile 5 Media3 解码（实验）',
    subtitle:
        '用 ExoPlayer/MediaCodec 解码 profile 5，作为 mediacodec_embed / gpu 的兜底；'
        '选择 gpu-next 时优先由 libplacebo 出画，本开关不生效。'
        '音频仍由 mpv 播放，视频位置会与 mpv 同步。可能有音画不同步',
    leading: const Icon(Icons.movie_filter_outlined),
    setKey: SettingBoxKey.media3Dovi,
    defaultVal: false,
  ),
  NormalModel(
    title: 'Media3 音画偏移',
    leading: const Icon(Icons.sync_alt),
    getSubtitle: () =>
        '当前：${Pref.doviAudioOffset} ms（仅 profile 5 Media3 路径；正值让视频目标位置更靠后）',
    onTap: _showDoviAudioOffsetDialog,
  ),
  NormalModel(
    title: 'HDR 状态诊断',
    subtitle: '查看当前片源的 mpv 色彩、解码方式与色调映射参数，用于排查 HDR 不生效',
    leading: const Icon(Icons.bug_report),
    onTap: _showHdrDebugDialog,
  ),
];

Future<void> _showHdrBackendDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<String>(
    context: context,
    builder: (context) => SelectDialog<String>(
      title: 'HDR 渲染后端',
      value: Pref.hdrBackend,
      values: HdrBackend.values.map((e) => (e.value, e.label)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.hdrBackend, res);
    // 用户主动切换后端时允许重新尝试 Vulkan；失败后仍会自动回退。
    PlPlayerController.resetVulkanFallback();
    SmartDialog.showToast('重新打开视频后生效');
    setState();
  }
}

Future<void> _showHdrDebugDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final info =
      PlPlayerController.instance?.hdrDebugInfo ??
      PlPlayerController.lastHdrInfo;
  final surfaceInfo = await NativeVideoSurfaceChannel.surfaceInfo();
  final detail = surfaceInfo == null
      ? info
      : '$info\n\n--- 原生层 ---\n$surfaceInfo';
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('HDR 状态诊断'),
      content: SingleChildScrollView(
        child: SelectableText(
          detail,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
      actions: [
        TextButton(onPressed: Get.back, child: const Text('关闭')),
      ],
    ),
  );
}

Future<void> _showHdrOutputModeDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<String>(
    context: context,
    builder: (context) => SelectDialog<String>(
      title: 'HDR 输出模式',
      value: Pref.hdrOutputMode,
      values: HdrOutputMode.values.map((e) => (e.value, e.label)).toList(),
      subtitleBuilder: (context, index) => Text(
        HdrOutputMode.values[index].desc,
        style: TextTheme.of(context).labelSmall?.copyWith(
          color: ColorScheme.of(context).outline,
        ),
      ),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.hdrOutputMode, res);
    PlPlayerController.instance?.applyHdrOptions();
    setState();
  }
}

Future<void> _showHdrToneMappingDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<String>(
    context: context,
    builder: (context) => SelectDialog<String>(
      title: 'HDR 色调映射',
      value: Pref.hdrToneMapping,
      values: HdrToneMapping.values.map((e) => (e.value, e.label)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.hdrToneMapping, res);
    PlPlayerController.instance?.applyHdrOptions();
    setState();
  }
}

Future<void> _showHdrTargetPeakDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: 'HDR 目标峰值亮度',
      value: Pref.hdrTargetPeak,
      values: HdrConfig.targetPeakChoices
          .map((e) => (e, HdrConfig.targetPeakLabel(e)))
          .toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.hdrTargetPeak, res);
    PlPlayerController.instance?.applyHdrOptions();
    setState();
  }
}

Future<void> _showHdrHwdecDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<String>(
    context: context,
    builder: (context) => SelectDialog<String>(
      title: 'HDR 解码方式',
      value: Pref.hdrHwdecMode,
      values: HdrHwdecMode.values.map((e) => (e.value, e.label)).toList(),
      subtitleBuilder: (context, index) => Text(
        HdrHwdecMode.values[index].desc,
        style: TextTheme.of(context).labelSmall?.copyWith(
          color: ColorScheme.of(context).outline,
        ),
      ),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.hdrHwdecMode, res);
    setState();
  }
}

Future<void> _showDoviAudioOffsetDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  var value = Pref.doviAudioOffset.clamp(-500, 500).toDouble();
  final result = await showDialog<int>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Media3 音画偏移'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${value.round()} ms'),
            Slider(
              value: value,
              min: -500,
              max: 500,
              divisions: 100,
              label: '${value.round()} ms',
              onChanged: (v) => setDialogState(() => value = v),
            ),
            Text(
              '正值让视频目标位置更靠后；调大/调小直到口型与声音对齐。仅影响 profile 5 Media3 路径。',
              style: TextTheme.of(context).labelSmall?.copyWith(
                color: ColorScheme.of(context).outline,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: Get.back, child: const Text('取消')),
          TextButton(
            onPressed: () => Get.back(result: value.round()),
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  if (result != null) {
    await GStorage.setting.put(SettingBoxKey.doviAudioOffset, result);
    setState();
  }
}
