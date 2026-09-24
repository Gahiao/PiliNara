import 'package:PiliPlus/grpc/bilibili/app/im/v1.pb.dart';
import 'package:PiliPlus/pages/setting/widgets/switch_item.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:PiliPlus/utils/storage_key.dart';


Future<void> showBvSwitchDialog(BuildContext context) {
  var subtreeKey = UniqueKey();

  return showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        clipBehavior: Clip.hardEdge,
        title: const Text('设置项'),
        contentPadding: const EdgeInsets.only(top: 8, bottom: 4),
        content: KeyedSubtree(
          key: subtreeKey,
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SetSwitchItem(
              title: '显示Toast',
              subtitle: '跳转视频时显示Toast',
              setKey: SettingBoxKey.showBvToast,
              defaultVal: false,
              contentPadding: EdgeInsets.symmetric(horizontal: 24),
            ),
              SetSwitchItem(
                title: '直接跳转',
                subtitle: '关闭将显示手动跳转选项而不是直接跳转至视频',
                setKey: SettingBoxKey.jumpDirec,
                defaultVal: false,
                contentPadding: EdgeInsets.symmetric(horizontal: 24)
              ),
          ],
        ),
      ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          TextButton(
            onPressed: () async {
              await GStorage.setting.put(SettingBoxKey.showBvToast, false);
              await GStorage.setting.put(SettingBoxKey.jumpDirec, false);
              setState(() => subtreeKey = UniqueKey());
            },
            child: const Text('恢复默认'),
          ),
          FilledButton(onPressed: Get.back, child: const Text('保存')),
        ],
      ),
    ),
  );
}