import 'package:PiliPlus/pages/setting/widgets/switch_item.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:material_ui/material_ui.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/services.dart';

const String kToastTextDefault = '已到坐标~';
const kWaitSecDefault = 5;

Future<void> showBvSwitchDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _BvSwitchDialog(),
  );
}

class _BvSwitchDialog extends StatefulWidget {
  const _BvSwitchDialog();

  @override
  State<_BvSwitchDialog> createState() => _BvSwitchDialogState();
}

class _BvSwitchDialogState extends State<_BvSwitchDialog> {
  late final TextEditingController _toast;
  late final TextEditingController _wait;
  var _subtreeKey = UniqueKey();

  @override
  void initState() {
    super.initState();
    _toast = TextEditingController(
      text: GStorage.setting.get(
        SettingBoxKey.bvJumpToastText,
        defaultValue: kToastTextDefault,
      ),
    );

    final savedWait = GStorage.setting.get(
      SettingBoxKey.bvJumpWaitSec,
      defaultValue: kWaitSecDefault.toString(),
    );
    _wait = TextEditingController(
      text: savedWait?.toString() ?? kWaitSecDefault.toString(),
    );
  }

  @override
  void dispose() {
    _toast.dispose();
    _wait.dispose();
    super.dispose();
  }

  int get _waitSeconds {
    final parsed = int.tryParse(_wait.text.trim());
    if (parsed == null || parsed <= 0) return kWaitSecDefault;
    return parsed > 10 ? 10 : parsed;
  }

  Future<void> _resetAll() async {
    await GStorage.setting.put(SettingBoxKey.showBvToast, false);
    await GStorage.setting.put(SettingBoxKey.jumpDirec, false);
    await GStorage.setting.put(SettingBoxKey.bvJumpToastText, kToastTextDefault);
    await GStorage.setting.put(
      SettingBoxKey.bvJumpWaitSec,
      kWaitSecDefault.toString(),
    );
    await GStorage.setting.put(SettingBoxKey.shouldJumpEveryTime, false);

    if (!mounted) return;
    setState(() {
      _toast.text = kToastTextDefault;
      _wait.text = kWaitSecDefault.toString();
      _subtreeKey = UniqueKey();
    });
  }

  Future<void> _saveAndClose() async {
    final seconds = _waitSeconds;

    await GStorage.setting.put(
      SettingBoxKey.bvJumpToastText,
      _toast.text.trim(),
    );
    await GStorage.setting.put(
      SettingBoxKey.bvJumpWaitSec,
      seconds.toString(),
    );

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      clipBehavior: Clip.hardEdge,
      title: const Text('设置项'),
      contentPadding: const EdgeInsets.only(top: 8, bottom: 4),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            KeyedSubtree(
              key: _subtreeKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SetSwitchItem(
                    title: '显示Toast',
                    subtitle: '跳转视频时显示Toast',
                    setKey: SettingBoxKey.showBvToast,
                    defaultVal: false,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                    onChanged: (_) => setState(() {}),
                  ),
                  SetSwitchItem(
                    title: '每次启动时跳转',
                    subtitle: '启动时将忽略上次的BV号/链接${Pref.jumpDirec ? '然后直接跳转' : '并显示跳转选项'}',
                    setKey: SettingBoxKey.shouldJumpEveryTime,
                    defaultVal: false,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  ),
                  SetSwitchItem(
                    title: '直接跳转',
                    subtitle: '关闭将显示手动跳转选项而不是直接跳转至视频',
                    setKey: SettingBoxKey.jumpDirec,
                    defaultVal: false,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                    onChanged: (_) => setState(() {}),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topCenter,
              child: !Pref.showBvToast
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: TextField(
                  controller: _toast,
                  textInputAction: TextInputAction.done,
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
            ),
            const SizedBox(height: 8),

            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topCenter,
              child: Pref.jumpDirec
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: TextField(
                  controller: _wait,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLines: 1,
                  maxLength: 2,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: '等待时间',
                    hintText: '5',
                    helperText: '询问Toast停留时间(1~10s)',
                    counterText: '',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(6)),
                    ),
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
          onPressed: _resetAll,
          child: const Text('恢复默认'),
        ),
        FilledButton(
          onPressed: _saveAndClose,
          child: const Text('关闭'),
        ),
      ],
    );
  }
}