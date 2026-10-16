import 'dart:async' show unawaited;

import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/download/download_folder.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:collection/collection.dart';
import 'package:get/get.dart';

/// 手动文件夹：用户自己分的组，成员是条目 cid，顺序即用户排出的顺序。
///
/// 与自动分组（合集 / 视频页 / 分P）互不干涉：后者由条目自身的归属推导，删条目
/// 即自动出组；这里只维护用户显式建立的关联，所以条目被删时要修剪成员，而合集
/// 顺序这类自动排序只在用户点「按合集顺序」时用一次，写入成员顺序后不再覆盖。
class DownloadFolderService extends GetxService {
  static const _version = 1;

  final _downloadService = Get.find<DownloadService>();

  final flagNotifier = SetNotifier();

  /// 按用户排出的顺序暴露，UI 直接消费。
  final folders = RxList<DownloadFolder>();

  final List<DownloadFolder> _records = <DownloadFolder>[];
  final List<String> _folderOrder = <String>[];

  late final Future<void> waitForInitialization;

  @override
  void onInit() {
    super.onInit();
    waitForInitialization = _init();
  }

  @override
  void onClose() {
    _downloadService.flagNotifier.remove(_onDownloadChanged);
    super.onClose();
  }

  Future<void> _init() async {
    await _downloadService.waitForInitialization;
    // 新键不存在时才尝试导入旧数据，导入后立即落盘，之后不再重复导入。
    if (!_readFromStorage() && _importLegacy()) {
      await _save();
    } else {
      _publish();
    }
    await syncWithDownloads(notify: false);
    _downloadService.flagNotifier.add(_onDownloadChanged);
  }

  void _onDownloadChanged() => unawaited(syncWithDownloads());

  /// 读新键；返回是否读到了已保存的数据。
  bool _readFromStorage() {
    final raw = GStorage.localCache.get(LocalCacheKey.downloadFolders);
    if (raw is! Map) {
      return false;
    }
    final json = raw.cast<dynamic, dynamic>();
    _records
      ..clear()
      ..addAll(
        (json['folders'] as List? ?? const <dynamic>[])
            .whereType<Map>()
            .map((item) => DownloadFolder.fromJson(item.cast<String, dynamic>())),
      );
    _folderOrder
      ..clear()
      ..addAll(
        (json['folderOrder'] as List? ?? const <dynamic>[]).whereType<String>(),
      );
    _publish();
    return true;
  }

  /// 一次性导入 fork 时期的 `downloadCollections`，只取用户手工建的文件夹。
  ///
  /// 当时自动归组的合集文件夹带 `sourceKey`，内容现在由 `season_info` 表达，
  /// 一并导入会与合集卡片重复，所以只接收没有 sourceKey 的那些；成员按现有缓存
  /// 过滤，空文件夹不再恢复。
  bool _importLegacy() {
    final raw = GStorage.localCache.get(
      LocalCacheKey.legacyDownloadCollections,
    );
    if (raw is! Map) {
      return false;
    }
    final json = raw.cast<dynamic, dynamic>();
    final validCids = _downloadService.downloadList.map((e) => e.cid).toSet();
    final legacyOrder = (json['folderOrder'] as List? ?? const <dynamic>[])
        .whereType<String>()
        .toList();
    final manual = (json['folders'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map((item) => item.cast<dynamic, dynamic>())
        .where((item) => item['sourceKey'] == null)
        .toList()
      // 沿用当时的文件夹顺序，顺序键缺失的排在后面。
      ..sort((a, b) {
        final aIndex = legacyOrder.indexOf(a['id'] as String? ?? '');
        final bIndex = legacyOrder.indexOf(b['id'] as String? ?? '');
        return (aIndex < 0 ? legacyOrder.length : aIndex).compareTo(
          bIndex < 0 ? legacyOrder.length : bIndex,
        );
      });
    var stamp = DateTime.now().microsecondsSinceEpoch;
    for (final item in manual) {
      final cids = (item['videoCids'] as List? ?? const <dynamic>[])
          .whereType<int>()
          .where(validCids.contains)
          .toList();
      if (cids.isEmpty) {
        continue;
      }
      final folder = DownloadFolder(
        id: item['id'] as String? ?? (stamp++).toString(),
        title: item['title'] as String? ?? '',
        createdAt: item['createdAt'] as int? ?? 0,
        videoCids: cids,
      );
      _records.add(folder);
      _folderOrder.add(folder.id);
    }
    _publish();
    return _records.isNotEmpty;
  }

  Future<void> _save() {
    _publish();
    return GStorage.localCache.put(LocalCacheKey.downloadFolders, {
      'version': _version,
      'folders': _records.map((item) => item.toJson()).toList(),
      'folderOrder': _folderOrder,
    });
  }

  void _publish() {
    final ordered = <DownloadFolder>[];
    for (final id in _folderOrder) {
      final folder = _records.firstWhereOrNull((item) => item.id == id);
      if (folder != null) {
        ordered.add(folder);
      }
    }
    // 顺序键里没有的（新建后未落盘、导入时缺失）按创建时间倒序补在后面。
    ordered.addAll(
      _records.where((item) => !_folderOrder.contains(item.id)).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
    );
    folders.value = ordered;
    flagNotifier.refresh();
  }

  DownloadFolder? getFolder(String folderId) =>
      _records.firstWhereOrNull((item) => item.id == folderId);

  List<DownloadFolder> foldersOf(int cid) =>
      _records.where((item) => item.videoCids.contains(cid)).toList();

  List<BiliDownloadEntryInfo> resolveFolderEntries(
    String folderId, [
    List<BiliDownloadEntryInfo>? entries,
  ]) {
    final folder = getFolder(folderId);
    if (folder == null) {
      return const <BiliDownloadEntryInfo>[];
    }
    final source = entries ?? _downloadService.downloadList;
    final map = {for (final entry in source) entry.cid: entry};
    return folder.videoCids
        .map((cid) => map[cid])
        .whereType<BiliDownloadEntryInfo>()
        .toList();
  }

  String buildDefaultFolderTitle([String base = '新建文件夹']) {
    final titles = _records.map((item) => item.title).toSet();
    if (!titles.contains(base)) {
      return base;
    }
    var index = 2;
    while (titles.contains('$base $index')) {
      index++;
    }
    return '$base $index';
  }

  Future<DownloadFolder> createFolder(String title) async {
    final folder = DownloadFolder(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: title,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      videoCids: <int>[],
    );
    _records.add(folder);
    _folderOrder.add(folder.id);
    await _save();
    return folder;
  }

  Future<void> renameFolder(String folderId, String title) async {
    final folder = getFolder(folderId);
    if (folder == null || folder.title == title) {
      return;
    }
    folder.title = title;
    await _save();
  }

  /// 删除文件夹只断开关联，缓存文件与自动分组都不受影响。
  Future<void> deleteFolder(String folderId) async {
    _records.removeWhere((item) => item.id == folderId);
    _folderOrder.removeWhere((id) => id == folderId);
    await _save();
  }

  Future<void> reorderFolders(List<String> folderIds) async {
    _folderOrder
      ..clear()
      ..addAll(folderIds);
    await _save();
  }

  Future<void> addVideosToFolders(
    Iterable<int> cids,
    Iterable<String> folderIds,
  ) async {
    final videoIds = cids.toList();
    if (videoIds.isEmpty) {
      return;
    }
    var changed = false;
    for (final folderId in folderIds) {
      final folder = getFolder(folderId);
      if (folder == null) {
        continue;
      }
      for (final cid in videoIds) {
        if (!folder.videoCids.contains(cid)) {
          folder.videoCids.add(cid);
          changed = true;
        }
      }
    }
    if (changed) {
      await _save();
    }
  }

  Future<void> removeVideosFromFolders(
    Iterable<int> cids,
    Iterable<String> folderIds,
  ) async {
    final videoIds = cids.toSet();
    var changed = false;
    for (final folderId in folderIds) {
      final folder = getFolder(folderId);
      if (folder == null) {
        continue;
      }
      final before = folder.videoCids.length;
      folder.videoCids.removeWhere(videoIds.contains);
      if (folder.videoCids.length != before) {
        changed = true;
      }
    }
    if (changed) {
      await _save();
    }
  }

  Future<void> reorderFolderVideos(String folderId, List<int> cids) async {
    final folder = getFolder(folderId);
    if (folder == null) {
      return;
    }
    folder.videoCids
      ..clear()
      ..addAll(cids);
    await _save();
  }

  /// 按合集原顺序重排：合集成员先按 `SeasonInfo.id` 再按 `SeasonInfo.index` 升序，
  /// 同序号再按分P 序号；不属于合集的成员保持原有相对顺序排在最后。
  ///
  /// 对只装零散视频的文件夹是空操作。
  Future<void> applyCollectionOrder(String folderId) async {
    final entries = resolveFolderEntries(folderId);
    if (entries.length < 2) {
      return;
    }
    final origin = {
      for (var i = 0; i < entries.length; i++) entries[i].cid: i,
    };
    final sorted = entries.toList()
      ..sort((a, b) {
        final aSeason = a.seasonInfo;
        final bSeason = b.seasonInfo;
        if (aSeason == null && bSeason == null) {
          return origin[a.cid]!.compareTo(origin[b.cid]!);
        }
        if (aSeason == null) {
          return 1;
        }
        if (bSeason == null) {
          return -1;
        }
        final bySeason = aSeason.id.compareTo(bSeason.id);
        if (bySeason != 0) {
          return bySeason;
        }
        final byIndex = aSeason.index.compareTo(bSeason.index);
        return byIndex != 0 ? byIndex : a.sortKey.compareTo(b.sortKey);
      });
    await reorderFolderVideos(folderId, sorted.map((e) => e.cid).toList());
  }

  /// 按缓存时间重排，新缓存的在前。
  Future<void> resetFolderOrder(String folderId) async {
    final entries = resolveFolderEntries(folderId);
    if (entries.length < 2) {
      return;
    }
    final sorted = entries.toList()
      ..sort((a, b) => b.timeUpdateStamp.compareTo(a.timeUpdateStamp));
    await reorderFolderVideos(folderId, sorted.map((e) => e.cid).toList());
  }

  /// 修剪已删除的成员，避免文件夹里留下悬空引用。
  Future<void> syncWithDownloads({bool notify = true}) async {
    final validCids = _downloadService.downloadList
        .followedBy(_downloadService.waitDownloadQueue)
        .map((item) => item.cid)
        .toSet();
    var changed = false;
    for (final folder in _records) {
      final before = folder.videoCids.length;
      folder.videoCids.removeWhere((cid) => !validCids.contains(cid));
      if (folder.videoCids.length != before) {
        changed = true;
      }
    }
    if (changed) {
      await _save();
    } else if (notify) {
      flagNotifier.refresh();
    }
  }
}
