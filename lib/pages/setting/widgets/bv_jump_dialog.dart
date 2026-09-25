import 'package:PiliPlus/pages/setting/widgets/switch_item.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:material_ui/material_ui.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

const String kToastTextDefault = '已到达对应坐标~';

Future<void> showBvSwitchDialog(BuildContext context) async {
  var subtreeKey = UniqueKey();

  final textController = TextEditingController(
    text: GStorage.setting.get(
      SettingBoxKey.bvJumpToastText,
      defaultValue: kToastTextDefault,
    ),
  );

  final res = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        clipBehavior: Clip.hardEdge,
        title: const Text('设置项'),
        contentPadding: const EdgeInsets.only(top: 8, bottom: 4),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KeyedSubtree(
                key: subtreeKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SetSwitchItem(
                      title: '显示Toast',
                      subtitle: '跳转视频时显示Toast',
                      setKey: SettingBoxKey.showBvToast,
                      defaultVal: false,
                      contentPadding: EdgeInsets.symmetric(horizontal: 24),
                    ),

                    SetSwitchItem(
                      title: '每次启动时跳转',
                      subtitle: '启动时将忽略上次的BV号/链接' + (Pref.jumpDirec ? '然后直接跳转': '并显示跳转选项'),
                      setKey: SettingBoxKey.shouldJumpEveryTime,
                      defaultVal: false,
                      contentPadding: EdgeInsets.symmetric(horizontal: 24),
                    ),

                    SetSwitchItem(
                      title: '直接跳转',
                      subtitle: '关闭将显示手动跳转选项而不是直接跳转至视频',
                      setKey: SettingBoxKey.jumpDirec,
                      defaultVal: false,
                      contentPadding: EdgeInsets.symmetric(horizontal: 24),
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: TextField(
                  controller: textController,
                  maxLines: 1,
                  textInputAction: TextInputAction.done,
                  maxLength: 100,
                  decoration: const InputDecoration(
                    labelText: 'Toast 文本',
                    hintText: '已到坐标: {bvid}',
                    helperText: '可用占位符：{bvid}',
                    counterText: '',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(6)),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          TextButton(
            onPressed: () async {
              await GStorage.setting.put(SettingBoxKey.showBvToast, false);
              await GStorage.setting.put(SettingBoxKey.jumpDirec, false);
              await GStorage.setting.put(
                SettingBoxKey.bvJumpToastText,
                kToastTextDefault,
              );
              await GStorage.setting.put(SettingBoxKey.shouldJumpEveryTime, false);
              textController.text = kToastTextDefault;
              setState(() => subtreeKey = UniqueKey());
            },
            child: const Text('恢复默认'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, textController.text),
            child: const Text('关闭'),
          ),
        ],
      ),
    ),
  );

  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.bvJumpToastText, res);
  }
  textController.dispose();
}