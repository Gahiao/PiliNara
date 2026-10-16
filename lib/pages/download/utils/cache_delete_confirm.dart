import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/download/download_info.dart';
import 'package:PiliPlus/services/download/download_library_service.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 删除前的统一确认。
///
/// 缓存只有一层，所以不再区分「移出分组」与「删除文件」，只报出涉及多少条、
/// 会释放多少空间。
Future<bool> showDeleteConfirm({
  required BuildContext context,
  required Iterable<BiliDownloadEntryInfo> entries,
  String? title,
  String? confirmText,
}) {
  final list = _uniqueEntries(entries);
  if (list.isEmpty) {
    return Future.value(false);
  }
  final totalBytes = list.fold<int>(0, (sum, entry) => sum + entry.totalBytes);
  final messages = <String>[
    '将删除 ${list.length} 个本地离线缓存，释放约 ${totalBytes.formatSize}。',
    '删除后无法恢复。',
  ];
  final colorScheme = ColorScheme.of(context);
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        title ?? (list.length == 1 ? '确定删除该视频？' : '确定删除选中视频？'),
      ),
      content: Builder(
        builder: (context) {
          final textStyle = Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(height: 1.3);
          return Column(
            spacing: 8,
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final message in messages)
                Text(message, style: textStyle),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: Get.back,
          child: Text(
            '取消',
            style: TextStyle(color: colorScheme.outline),
          ),
        ),
        TextButton(
          onPressed: () => Get.back(result: true),
          child: Text(
            confirmText ?? '删除',
            style: TextStyle(color: colorScheme.error),
          ),
        ),
      ],
    ),
  ).then((value) => value ?? false);
}

/// 条目层删除：缓存文件、观看进度与续播记录一起清掉。
Future<void> deleteLocalEntries({
  required DownloadService downloadService,
  required Iterable<BiliDownloadEntryInfo> entries,
}) async {
  final libraryService = Get.find<DownloadLibraryService>();
  for (final entry in _uniqueEntries(entries)) {
    await GStorage.watchProgress.delete(entry.cid.toString());
    await libraryService.clearLastLocalPlayedIfCid(entry.cid);
    await downloadService.deleteDownload(
      entry: entry,
      removeList: true,
      refresh: false,
      downloadNext: false,
    );
  }
  downloadService.flagNotifier.refresh();
}

/// 确认后删除给定条目。
Future<bool> confirmDeleteEntries({
  required BuildContext context,
  required DownloadService downloadService,
  required Iterable<BiliDownloadEntryInfo> entries,
  String? title,
}) async {
  final list = _uniqueEntries(entries);
  if (list.isEmpty) {
    return false;
  }
  if (!await showDeleteConfirm(
    context: context,
    entries: list,
    title: title,
  )) {
    return false;
  }
  SmartDialog.showLoading();
  await deleteLocalEntries(downloadService: downloadService, entries: list);
  SmartDialog.dismiss();
  return true;
}

/// 页/合集层删除：按目录整块删。
///
/// 不含确认，供已经确认过的调用点复用；需要确认时用 [confirmDeletePages]。
Future<void> deletePages({
  required DownloadService downloadService,
  required Iterable<DownloadPageInfo> pages,
}) async {
  final pageList = pages.toList();
  final entries = _uniqueEntries([
    for (final page in pageList) ...page.entries,
  ]);
  if (entries.isEmpty) {
    return;
  }
  final libraryService = Get.find<DownloadLibraryService>();
  await GStorage.watchProgress.deleteAll(
    entries.map((entry) => entry.cid.toString()),
  );
  for (final entry in entries) {
    await libraryService.clearLastLocalPlayedIfCid(entry.cid);
  }
  for (final page in pageList) {
    await downloadService.deletePage(
      pageDirPath: page.dirPath,
      refresh: false,
    );
  }
  downloadService.flagNotifier.refresh();
}

/// 确认后按目录整块删除页/合集，确认里报出涉及多少条缓存与总体积。
Future<bool> confirmDeletePages({
  required BuildContext context,
  required DownloadService downloadService,
  required Iterable<DownloadPageInfo> pages,
  String? title,
}) async {
  final pageList = pages.toList();
  final entries = _uniqueEntries([
    for (final page in pageList) ...page.entries,
  ]);
  if (entries.isEmpty) {
    return false;
  }
  if (!await showDeleteConfirm(
    context: context,
    entries: entries,
    title: title,
  )) {
    return false;
  }
  SmartDialog.showLoading();
  await deletePages(downloadService: downloadService, pages: pageList);
  SmartDialog.dismiss();
  return true;
}

List<BiliDownloadEntryInfo> _uniqueEntries(
  Iterable<BiliDownloadEntryInfo> entries,
) {
  final map = <int, BiliDownloadEntryInfo>{};
  for (final entry in entries) {
    map[entry.cid] = entry;
  }
  return map.values.toList();
}
