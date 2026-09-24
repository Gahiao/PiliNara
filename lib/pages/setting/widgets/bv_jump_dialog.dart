import 'package:PiliPlus/pages/setting/widgets/switch_item.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

const String kShowToastKey = 'showToast';

Future<void> showBvSwitchDialog(BuildContext context) {
  var subtreeKey = UniqueKey();

  return showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        clipBehavior: Clip.hardEdge,
        title: const Text('显示 Toast'),
        contentPadding: const EdgeInsets.only(top: 8, bottom: 4),
        content: KeyedSubtree(
          key: subtreeKey,
          child: const SetSwitchItem(
            title: '显示Toast',
            subtitle: '跳转视频时显示Toast',
            setKey: kShowToastKey,
            defaultVal: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 24),
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          TextButton(
            onPressed: () async {
              await GStorage.setting.put(kShowToastKey, true);
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