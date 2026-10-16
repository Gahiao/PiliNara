import 'dart:io' show Platform;

import 'package:PiliPlus/common/widgets/flutter/popup_menu.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/pages/download/utils/cache_export.dart';
import 'package:PiliPlus/pages/download/widgets/folder_dialog.dart';
import 'package:PiliPlus/services/download/download_folder_service.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 一次放进菜单的文件夹快捷项上限，其余走选择器。
const _quickAddLimit = 5;

/// 菜单里的「添加到文件夹」：一个选择器入口，加几个常用文件夹的快捷项。
List<PopupMenuEntry<void>> buildAddToFolderMenuItems({
  required BuildContext context,
  required Iterable<BiliDownloadEntryInfo> entries,
}) {
  final cids = entries.map((entry) => entry.cid).toList(growable: false);
  final folderService = Get.find<DownloadFolderService>();
  return [
    CustomPopupMenuItem<void>(
      height: 38,
      child: const Text('添加到文件夹…', style: TextStyle(fontSize: 13)),
      onTap: () async {
        final selected = await showDownloadFolderPickerDialog(
          context: context,
        );
        if (selected == null || selected.isEmpty) {
          return;
        }
        await folderService.addVideosToFolders(cids, selected);
        SmartDialog.showToast('已添加到文件夹');
      },
    ),
    for (final folder in folderService.folders.take(_quickAddLimit))
      CustomPopupMenuItem<void>(
        height: 38,
        child: Text(
          '添加到「${folder.title}」',
          style: const TextStyle(fontSize: 13),
        ),
        onTap: () async {
          await folderService.addVideosToFolders(cids, [folder.id]);
          SmartDialog.showToast('已添加到「${folder.title}」');
        },
      ),
  ];
}

/// 分组卡片（合集卡、视频页卡）菜单的附加项：导出整张卡片 + 加进文件夹。
///
/// 导出作用于卡片里的全部条目，而不是卡片上那一条——卡片代表的是整组缓存。
List<PopupMenuEntry<void>> buildGroupCardMenuItems({
  required BuildContext context,
  required Iterable<BiliDownloadEntryInfo> entries,
}) {
  final list = entries.toList(growable: false);
  if (list.isEmpty) {
    return const <PopupMenuEntry<void>>[];
  }
  return [
    if (Platform.isAndroid)
      CustomPopupMenuItem<void>(
        height: 38,
        child: const Text('导出', style: TextStyle(fontSize: 13)),
        onTap: () => exportDownloadEntries(list),
      ),
    ...buildAddToFolderMenuItems(context: context, entries: list),
  ];
}
