import 'dart:io';

import 'package:PiliPlus/models/common/video/audio_quality.dart';
import 'package:PiliPlus/models/common/video/live_quality.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/pages/setting/widgets/cdn_node_dialog.dart';
import 'package:PiliPlus/pages/setting/widgets/cdn_select_dialog.dart';
import 'package:PiliPlus/pages/setting/widgets/ordered_multi_select_dialog.dart';
import 'package:PiliPlus/pages/setting/widgets/select_dialog.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/audio_output_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/hdr_config.dart';
import 'package:PiliPlus/plugin/pl_player/models/hwdec_type.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/filtering_text.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart';

List<SettingsModel> get videoSettings => [
  const SwitchModel(
    title: '开启硬解',
    subtitle: '以较低功耗播放视频，若异常卡死请关闭',
    leading: Icon(Icons.flash_on_outlined),
    setKey: SettingBoxKey.enableHA,
    defaultVal: true,
  ),
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
      return '当前：${mode.label}。${mode.desc}（切换画质或重开视频生效）';
    },
    onTap: _showHdrHwdecDialog,
  ),
  SwitchModel(
    title: 'HDR 直通出画',
    subtitle:
        'HDR / 杜比视界片源改用 Flutter 之下的 SurfaceView 直通送显，由解码器直接输出 HDR；'
        'SDR 片源仍走纹理，弹幕/控制栏照常叠加。切换后需重新打开视频生效。'
        '若个别设备出现黑屏，请关闭此开关或开启「杜比视界兼容模式」后重开视频',
    leading: const Icon(Icons.hdr_strong),
    setKey: SettingBoxKey.hdrSurface,
    defaultVal: true,
    onChanged: (_) => SmartDialog.showToast('重新打开视频后生效'),
  ),
  NormalModel(
    title: 'HDR 渲染后端',
    leading: const Icon(Icons.tune),
    getSubtitle: () {
      final backend = HdrBackend.fromValue(Pref.hdrBackend);
      final desc = switch (backend) {
        HdrBackend.gpuNext =>
          'libplacebo 渲染，可尝试 target-colorspace-hint；当前 libmpv 构建通常无法真正输出 HDR',
        HdrBackend.gpu => '兼容性好，但几乎无法激发 HDR',
        HdrBackend.mediacodecEmbed =>
          '解码器直接送显，HDR 由系统直通。唯一确定能点亮 HDR 的后端，需要开启硬解',
      };
      return '当前：${backend.label}。$desc（重新打开视频生效）';
    },
    onTap: _showHdrBackendDialog,
  ),
  SwitchModel(
    title: '杜比视界兼容模式',
    subtitle: '部分设备无法硬解杜比视界（Dolby Vision）元数据，开启后在存在同分辨率 HDR10 片源时自动改用 HDR10',
    leading: const Icon(Icons.brightness_high),
    setKey: SettingBoxKey.dolbyVisionFallback,
    defaultVal: false,
  ),
  NormalModel(
    title: 'HDR 状态诊断',
    subtitle: '查看当前片源的 mpv 色彩、解码方式与色调映射参数，用于排查 HDR 不生效',
    leading: const Icon(Icons.bug_report),
    onTap: _showHdrDebugDialog,
  ),
  const SwitchModel(
    title: '免登录1080P',
    subtitle: '免登录查看1080P视频',
    leading: Icon(Icons.hd_outlined),
    setKey: SettingBoxKey.p1080,
    defaultVal: true,
  ),
  NormalModel(
    title: 'B站定向流量支持',
    subtitle: '若套餐含B站定向流量，则会自动使用。可查阅运营商的流量记录确认。',
    leading: const Icon(Icons.perm_data_setting_outlined),
    getTrailing: (theme) => IgnorePointer(
      child: Transform.scale(
        scale: 0.8,
        alignment: Alignment.centerRight,
        child: Switch(
          value: true,
          onChanged: (_) {},
          thumbIcon: WidgetStateProperty.all(
            const Icon(Icons.lock_outline_rounded),
          ),
        ),
      ),
    ),
  ),
  NormalModel(
    title: 'CDN 设置',
    leading: const Icon(MdiIcons.cloudPlusOutline),
    getSubtitle: () =>
        '当前使用：${VideoUtils.effectiveCdnDesc()}，部分 CDN 可能失效，如无法播放请尝试切换',
    onTap: _showCDNDialog,
  ),
  NormalModel(
    title: '直播 CDN 设置',
    leading: const Icon(MdiIcons.cloudPlusOutline),
    getSubtitle: () => '当前使用：${Pref.liveCdnUrl ?? "默认"}',
    onTap: _showLiveCDNDialog,
  ),
  const SwitchModel(
    title: 'CDN 测速',
    leading: Icon(Icons.speed),
    subtitle: '测速通过模拟加载视频实现，注意流量消耗，结果仅供参考',
    setKey: SettingBoxKey.cdnSpeedTest,
    defaultVal: true,
  ),
  SwitchModel(
    title: '音频不跟随 CDN 设置',
    subtitle: '直接采用备用 URL，可解决部分视频无声',
    leading: const Icon(MdiIcons.musicNotePlus),
    setKey: SettingBoxKey.disableAudioCDN,
    defaultVal: false,
    onChanged: (value) => VideoUtils.disableAudioCDN = value,
  ),
  if (Platform.isAndroid || Platform.isIOS)
    NormalModel(
      title: '半屏默认画质',
      leading: const Icon(Icons.video_settings_outlined),
      getSubtitle: () {
        final qa = Pref.defaultVideoQaHalfScreen;
        if (qa == null) {
          return '跟随全屏画质'
              '（WiFi ${VideoQuality.fromCode(Pref.defaultVideoQa).desc}'
              '｜蜂窝 ${VideoQuality.fromCode(Pref.defaultVideoQaCellular).desc}）';
        }
        // 半屏实际画质 = min(半屏设置, 当前网络的全屏画质)，被夹持时提示实际值
        final clamped = [
          if (Pref.defaultVideoQa < qa)
            'WiFi 下实际 ${VideoQuality.fromCode(Pref.defaultVideoQa).desc}',
          if (Pref.defaultVideoQaCellular < qa)
            '蜂窝下实际 ${VideoQuality.fromCode(Pref.defaultVideoQaCellular).desc}',
        ];
        final desc = VideoQuality.fromCode(qa).desc;
        return clamped.isEmpty
            ? '当前画质：$desc'
            : '当前画质：$desc（${clamped.join('｜')}）';
      },
      onTap: _showVideoQaHalfScreenDialog,
    ),
  NormalModel(
    title: '全屏默认画质',
    leading: const Icon(Icons.video_settings_outlined),
    getSubtitle: () =>
        '当前画质：${VideoQuality.fromCode(Pref.defaultVideoQa).desc}',
    onTap: _showVideoQaDialog,
  ),
  NormalModel(
    title: '全屏蜂窝网络画质',
    leading: const Icon(Icons.video_settings_outlined),
    getSubtitle: () =>
        '当前画质：${VideoQuality.fromCode(Pref.defaultVideoQaCellular).desc}',
    onTap: _showVideoCellularQaDialog,
  ),
  NormalModel(
    title: '默认音质',
    leading: const Icon(Icons.music_video_outlined),
    getSubtitle: () =>
        '当前音质：${AudioQuality.fromCode(Pref.defaultAudioQa).desc}',
    onTap: _showAudioQaDialog,
  ),
  NormalModel(
    title: '蜂窝网络音质',
    leading: const Icon(Icons.music_video_outlined),
    getSubtitle: () =>
        '当前音质：${AudioQuality.fromCode(Pref.defaultAudioQaCellular).desc}',
    onTap: _showAudioCellularQaDialog,
  ),
  NormalModel(
    title: '直播默认画质',
    leading: const Icon(Icons.video_settings_outlined),
    getSubtitle: () => '当前画质：${LiveQuality.fromCode(Pref.liveQuality).desc}',
    onTap: _showLiveQaDialog,
  ),
  NormalModel(
    title: '蜂窝网络直播默认画质',
    leading: const Icon(Icons.video_settings_outlined),
    getSubtitle: () =>
        '当前画质：${LiveQuality.fromCode(Pref.liveQualityCellular).desc}',
    onTap: _showLiveCellularQaDialog,
  ),
  NormalModel(
    title: '首选解码格式',
    leading: const Icon(Icons.movie_creation_outlined),
    getSubtitle: () =>
        '首选解码格式：${(Pref.preferCodecs.map((i) => i.name).join(","))}，请根据设备支持情况与需求调整',
    onTap: _showCodecsDialog,
  ),
  NormalModel(
    title: '蜂窝网络首选解码格式',
    leading: const Icon(Icons.movie_creation_outlined),
    getSubtitle: () =>
        '首选解码格式：${(Pref.preferCodecsCellular.map((i) => i.name).join(","))}，请根据设备支持情况与需求调整',
    onTap: _showCellularCodecsDialog,
  ),
  if (kDebugMode || Platform.isAndroid)
    NormalModel(
      title: '音频输出设备',
      leading: const Icon(Icons.speaker_outlined),
      getSubtitle: () => '当前：${Pref.audioOutput}',
      onTap: _showAudioOutputDialog,
    ),
  SwitchModel(
    title: '允许与其他应用同时播放',
    subtitle:
        '开启后支持与其他应用的音频同时播放。'
        '${Platform.isIOS ? '\n开启后锁屏/通知栏/控制中心/车载不会显示正在播放的歌曲且不支持线控和Siri切歌（测试功能）' : ''}',
    leading: const Icon(Icons.compare_arrows_outlined),
    setKey: SettingBoxKey.mixWithOthers,
    defaultVal: false,
    onChanged: (value) {
      audioSessionHandler?.reconfigure();
    },
  ),
  NormalModel(
    title: '缓冲大小',
    leading: const Icon(Icons.storage_outlined),
    getSubtitle: () =>
        '当前：${Pref.bufferSize}MB。点播视频的前向和后向缓冲区大小（此选项即mpv的--demuxer-max-bytes，--demuxer-max-back-bytes）。直播流请设置下方的直播缓冲大小',
    onTap: _showBufferSizeDialog,
  ),
  NormalModel(
    title: '缓冲时长',
    leading: const Icon(Icons.av_timer),
    getSubtitle: () =>
        '当前：${Pref.bufferSec}s。点播视频的实际缓冲为大小与时长二者的最小值（此选项即mpv的--cache-secs）。直播流该选项无效，请设置下方的直播缓冲时长',
    onTap: _showBufferSecDialog,
  ),
  NormalModel(
    title: '直播缓冲大小',
    leading: const Icon(Icons.storage_outlined),
    getSubtitle: () =>
        '当前：${Pref.liveBufferSize > 0 ? '${Pref.liveBufferSize}MB' : '跟随缓冲大小（${(Pref.bufferSize * 2).toStringAsFixed(0)}MB）'}。仅对直播流生效，小于等于0时使用缓冲大小的2倍（此选项即mpv的--demuxer-max-bytes）',
    onTap: _showLiveBufferSizeDialog,
  ),
  NormalModel(
    title: '直播缓冲时长',
    leading: const Icon(Icons.av_timer),
    getSubtitle: () =>
        '当前：${Pref.liveBufferSec > 0 ? '${Pref.liveBufferSec}s' : '不限制'}。仅对直播流生效，大于0时可限制直播缓冲时长以降低延迟（此选项即mpv的--cache-secs）',
    onTap: _showLiveBufferSecDialog,
  ),
  NormalModel(
    title: '自动同步',
    leading: const Icon(Icons.sync_rounded),
    getSubtitle: () => '当前：${Pref.autosync}（此项即mpv的--autosync）',
    onTap: _showAutoSyncDialog,
  ),
  NormalModel(
    title: '视频同步',
    leading: const Icon(Icons.view_timeline_outlined),
    getSubtitle: () => '当前：${Pref.videoSync}（此项即mpv的--video-sync）',
    onTap: _showVideoSyncDialog,
  ),
  NormalModel(
    title: '硬解模式',
    leading: const Icon(Icons.memory_outlined),
    getSubtitle: () => '当前：${Pref.hardwareDecoding}（此项即mpv的--hwdec）',
    onTap: _showHwDecDialog,
  ),
];

Future<void> _showCDNDialog(BuildContext context, VoidCallback setState) async {
  final res = await showDialog<CdnSelectResult>(
    context: context,
    builder: (context) => const CdnSelectDialog(),
  );
  if (res != null) {
    await applyCdnSelectResult(res);
    setState();
  }
}

Future<void> _showLiveCDNDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  String host = Pref.liveCdnUrl ?? '';
  String? res = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('输入CDN host'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            initialValue: host,
            autofocus: true,
            onChanged: (value) => host = value,
          ),
          const SizedBox(height: 4),
          TextButton.icon(
            icon: const Icon(Icons.travel_explore_outlined, size: 18),
            label: const Text('从节点列表选择'),
            onPressed: () async {
              final node = await showDialog<String>(
                context: context,
                builder: (context) => const CdnNodeDialog(isLive: true),
              );
              if (node != null && context.mounted) {
                Navigator.pop(context, node);
              }
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: Get.back,
          child: Text(
            '取消',
            style: TextStyle(color: ColorScheme.of(context).outline),
          ),
        ),
        TextButton(
          onPressed: () => Get.back(result: host),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  if (res != null) {
    if (res.isEmpty) {
      res = null;
      await GStorage.setting.delete(SettingBoxKey.liveCdnUrl);
    } else {
      if (!res.startsWith('http')) {
        res = 'https://$res';
      }
      await GStorage.setting.put(SettingBoxKey.liveCdnUrl, res);
    }
    VideoUtils.liveCdnUrl = res;
    setState();
  }
}

Future<void> _showVideoQaDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '全屏默认画质',
      value: Pref.defaultVideoQa,
      values: VideoQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.defaultVideoQa, res);
    setState();
  }
}

Future<void> _showVideoQaHalfScreenDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final currentQa = Pref.defaultVideoQaHalfScreen;
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '半屏默认画质',
      value: currentQa ?? -1,
      values: [
        (-1, '跟随全屏画质'),
        ...VideoQuality.values.map((e) => (e.code, e.desc)),
      ],
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.defaultVideoQaHalfScreen, res);
    setState();
  }
}

Future<void> _showVideoCellularQaDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '全屏蜂窝网络画质',
      value: Pref.defaultVideoQaCellular,
      values: VideoQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(
      SettingBoxKey.defaultVideoQaCellular,
      res,
    );
    setState();
  }
}

Future<void> _showAudioQaDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '默认音质',
      value: Pref.defaultAudioQa,
      values: AudioQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.defaultAudioQa, res);
    setState();
  }
}

Future<void> _showAudioCellularQaDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '蜂窝网络音质',
      value: Pref.defaultAudioQaCellular,
      values: AudioQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(
      SettingBoxKey.defaultAudioQaCellular,
      res,
    );
    setState();
  }
}

Future<void> _showLiveQaDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '直播默认画质',
      value: Pref.liveQuality,
      values: LiveQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.liveQuality, res);
    setState();
  }
}

Future<void> _showLiveCellularQaDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '蜂窝网络直播默认画质',
      value: Pref.liveQualityCellular,
      values: LiveQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.liveQualityCellular, res);
    setState();
  }
}

Future<void> _showCodecsDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<List<VideoDecodeFormatType>>(
    context: context,
    builder: (context) => OrderedMultiSelectDialog<VideoDecodeFormatType>(
      title: const Text('首选解码格式'),
      initValues: Pref.preferCodecs,
      values: {for (final e in VideoDecodeFormatType.values) e: e.name},
    ),
  );
  if (res != null && res.isNotEmpty) {
    await GStorage.setting.put(
      SettingBoxKey.preferCodecs,
      res.map((i) => i.name).toList(),
    );
    setState();
  }
}

Future<void> _showCellularCodecsDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<List<VideoDecodeFormatType>>(
    context: context,
    builder: (context) => OrderedMultiSelectDialog<VideoDecodeFormatType>(
      title: const Text('蜂窝网络首选解码格式'),
      initValues: Pref.preferCodecsCellular,
      values: {for (final e in VideoDecodeFormatType.values) e: e.name},
    ),
  );
  if (res != null && res.isNotEmpty) {
    await GStorage.setting.put(
      SettingBoxKey.preferCodecsCellular,
      res.map((i) => i.name).toList(),
    );
    setState();
  }
}

Future<void> _showAudioOutputDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<List<String>>(
    context: context,
    builder: (context) => OrderedMultiSelectDialog<String>(
      title: const Text('音频输出设备'),
      initValues: Pref.audioOutput.split(','),
      values: {
        for (final e in AudioOutput.values) e.name: e.label,
      },
    ),
  );
  if (res != null && res.isNotEmpty) {
    await GStorage.setting.put(
      SettingBoxKey.audioOutput,
      res.join(','),
    );
    setState();
  }
}

Future<void> _showVideoSyncDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<String>(
    context: context,
    builder: (context) => SelectDialog<String>(
      title: '视频同步',
      value: Pref.videoSync,
      values: const [
        'audio',
        'display-resample',
        'display-resample-vdrop',
        'display-resample-desync',
        'display-tempo',
        'display-vdrop',
        'display-adrop',
        'display-desync',
        'desync',
      ].map((e) => (e, e)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.videoSync, res);
    setState();
  }
}

Future<void> _showHwDecDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<List<String>>(
    context: context,
    builder: (context) => OrderedMultiSelectDialog<String>(
      title: const Text('硬解模式'),
      initValues: Pref.hardwareDecoding.split(','),
      values: {
        for (final e in HwDecType.values) e.hwdec: '${e.hwdec}\n${e.desc}',
      },
    ),
  );
  if (res != null && res.isNotEmpty) {
    await GStorage.setting.put(
      SettingBoxKey.hardwareDecoding,
      res.join(','),
    );
    setState();
  }
}

void _showAutoSyncDialog(BuildContext context, VoidCallback setState) {
  String autosync = Pref.autosync.toString();
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('自动同步'),
      content: TextFormField(
        autofocus: true,
        initialValue: autosync,
        keyboardType: TextInputType.number,
        onChanged: (value) => autosync = value,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      ),
      actions: [
        TextButton(
          onPressed: Get.back,
          child: Text(
            '取消',
            style: TextStyle(color: ColorScheme.of(context).outline),
          ),
        ),
        TextButton(
          onPressed: () async {
            try {
              // validate
              int.parse(autosync);
              Get.back();
              await GStorage.setting.put(SettingBoxKey.autosync, autosync);
              setState();
            } catch (e) {
              SmartDialog.showToast(e.toString());
            }
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

void _showDecimalDialog(
  BuildContext context,
  VoidCallback setState, {
  required String key,
  required double defVal,
  required String title,
  required String? suffix,
}) {
  String value = (GStorage.setting.get(key) ?? defVal).toString();
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextFormField(
        autofocus: true,
        initialValue: value,
        keyboardType: const .numberWithOptions(decimal: true),
        onChanged: (val) => value = val,
        inputFormatters: FilteringText.decimal,
        decoration: suffix == null ? null : InputDecoration(suffixText: suffix),
      ),
      actions: [
        TextButton(
          onPressed: Get.back,
          child: Text(
            '取消',
            style: TextStyle(color: ColorScheme.of(context).outline),
          ),
        ),
        TextButton(
          onPressed: () async {
            try {
              final val = double.parse(value);
              Get.back();
              await GStorage.setting.put(key, val);
              setState();
            } catch (e) {
              SmartDialog.showToast(e.toString());
            }
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

void _showBufferSizeDialog(BuildContext context, VoidCallback setState) =>
    _showDecimalDialog(
      context,
      setState,
      key: SettingBoxKey.bufferSize,
      defVal: Pref.bufferSize,
      title: '缓冲大小',
      suffix: 'MB',
    );

void _showBufferSecDialog(BuildContext context, VoidCallback setState) =>
    _showDecimalDialog(
      context,
      setState,
      key: SettingBoxKey.bufferSec,
      defVal: Pref.bufferSec,
      title: '缓冲时长',
      suffix: 's',
    );

void _showLiveBufferSizeDialog(BuildContext context, VoidCallback setState) =>
    _showDecimalDialog(
      context,
      setState,
      key: SettingBoxKey.liveBufferSize,
      defVal: Pref.liveBufferSize,
      title: '直播缓冲大小',
      suffix: 'MB',
    );

void _showLiveBufferSecDialog(BuildContext context, VoidCallback setState) =>
    _showDecimalDialog(
      context,
      setState,
      key: SettingBoxKey.liveBufferSec,
      defVal: Pref.liveBufferSec,
      title: '直播缓冲时长',
      suffix: 's',
    );

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
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('HDR 状态诊断'),
      content: SingleChildScrollView(
        child: SelectableText(
          info,
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
    SmartDialog.showToast('切换画质或重新打开视频后生效');
    setState();
  }
}
