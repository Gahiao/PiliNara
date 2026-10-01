import 'package:PiliPlus/pages/setting/widgets/switch_item.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:material_ui/material_ui.dart';
import 'package:PiliPlus/utils/storage_pref.dart';


Future<void> portraitSlideDialog(BuildContext context) async {
  var subtreeKey = UniqueKey();

  final textController = TextEditingController();

  await showDialog<String>(
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
                    SetSwitchItem(
                      title: '推荐来源使用首页推荐',
                      subtitle: '点击切换 当前推荐来源: ' + (Pref.portraitRC ? '首页推荐(这可能极大减少能刷到的视频)' : '相关推荐'),
                      setKey: SettingBoxKey.portraitRC,
                      defaultVal: false,
                      contentPadding: EdgeInsets.symmetric(horizontal: 24),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SetSwitchItem(
                      title: '刷新推荐',
                      subtitle: '当没符合条件的视频时刷新一次推荐',
                      setKey: SettingBoxKey.portraitNewv,
                      defaultVal: false,
                      contentPadding: EdgeInsets.symmetric(horizontal: 24),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          TextButton(
            onPressed: () async {
              await GStorage.setting.put(SettingBoxKey.portraitRC, false);
              await GStorage.setting.put(SettingBoxKey.portraitNewv, false);

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

  textController.dispose();
}