import 'dart:io' show Platform;

import 'package:PiliPlus/common/widgets/appbar/appbar.dart';
import 'package:PiliPlus/common/widgets/flutter/pop_scope.dart';
import 'package:PiliPlus/common/widgets/flutter/popup_menu.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/view_sliver_safe_area.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/download/download_playback.dart';
import 'package:PiliPlus/pages/common/multi_select/base.dart'
    show BaseMultiSelectMixin;
import 'package:PiliPlus/pages/download/detail/widgets/item.dart';
import 'package:PiliPlus/pages/download/download_action_mixin.dart';
import 'package:PiliPlus/pages/download/sort/view.dart';
import 'package:PiliPlus/pages/download/utils/cache_delete_confirm.dart';
import 'package:PiliPlus/pages/download/utils/cache_export.dart';
import 'package:PiliPlus/pages/download/utils/card_menu.dart';
import 'package:PiliPlus/pages/download/widgets/folder_dialog.dart';
import 'package:PiliPlus/services/download/download_folder_service.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart'
    hide SliverGridDelegateWithMaxCrossAxisExtent;

enum _FolderSortAction {
  manual,
  collection,
  cacheTime,
}

/// 手动文件夹的详情：成员平铺成一张网格，顺序即用户排出的顺序。
///
/// 打开成员时播放范围就是本文件夹，所以在文件夹里连播不会跑到文件夹外的缓存。
class DownloadFolderPage extends StatefulWidget {
  const DownloadFolderPage({
    super.key,
    required this.folderId,
  });

  final String folderId;

  @override
  State<DownloadFolderPage> createState() => _DownloadFolderPageState();
}

class _DownloadFolderPageState extends State<DownloadFolderPage>
    with
        BaseMultiSelectMixin<BiliDownloadEntryInfo>,
        GridMixin,
        BaseDownloadActionMixin<DownloadFolderPage, BiliDownloadEntryInfo>,
        CommonDownloadActionMixin<DownloadFolderPage> {
  final _folderService = Get.find<DownloadFolderService>();
  final _entries = RxList<BiliDownloadEntryInfo>();
  final _progress = ChangeNotifier();

  @override
  RxList<BiliDownloadEntryInfo> get list => _entries;
  @override
  RxList<BiliDownloadEntryInfo> get state => _entries;

  @override
  final downloadService = Get.find<DownloadService>();

  @override
  BaseMultiSelectMixin<BiliDownloadEntryInfo> get multiSelectCtr => this;

  @override
  void initState() {
    super.initState();
    _loadList();
    _folderService.flagNotifier.add(_loadList);
  }

  @override
  void dispose() {
    _progress.dispose();
    _folderService.flagNotifier.remove(_loadList);
    super.dispose();
  }

  Future<void> _loadList() async {
    await _folderService.waitForInitialization;
    if (!mounted) {
      return;
    }
    final hadEntries = _entries.isNotEmpty;
    if (_folderService.getFolder(widget.folderId) == null) {
      _entries.clear();
      // 文件夹被删掉时退出这一层，避免停在空列表上。
      if (hadEntries && mounted) {
        Get.back();
      }
      return;
    }
    _entries.value = _folderService.resolveFolderEntries(widget.folderId);
    rxCount.value = allChecked.length;
    if (checkedCount == 0) {
      enableMultiSelect.value = false;
    }
  }

  Future<void> _addSelectedToFolder() async {
    final folderIds = await showDownloadFolderPickerDialog(context: context);
    if (folderIds == null || folderIds.isEmpty) {
      return;
    }
    await _folderService.addVideosToFolders(
      allChecked.map((entry) => entry.cid),
      folderIds,
    );
    handleSelect();
    SmartDialog.showToast('已更新文件夹');
  }

  @override
  void onRemove() {
    confirmRemoveFromFolders(
      context: context,
      folderId: widget.folderId,
      entries: allChecked,
    ).then((removed) {
      if (removed) {
        handleSelect();
      }
    });
  }

  Future<void> _exportSelected() async {
    final entries = allChecked.toList();
    handleSelect();
    await exportDownloadEntries(entries);
  }

  Future<void> _openSortPage() async {
    if (_entries.isEmpty) {
      return;
    }
    await Get.to(
      DownloadVideoSortPage(
        title: '排序: ${_folderService.getFolder(widget.folderId)?.title ?? ''}',
        entries: _entries,
        onSave: (cids) =>
            _folderService.reorderFolderVideos(widget.folderId, cids),
      ),
    );
  }

  Future<void> _applyCollectionOrder() async {
    await _folderService.applyCollectionOrder(widget.folderId);
    SmartDialog.showToast('已按合集顺序排列');
  }

  Future<void> _resetOrder() async {
    await _folderService.resetFolderOrder(widget.folderId);
    SmartDialog.showToast('已按缓存时间排列');
  }

  void _onSortSelected(_FolderSortAction action) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }
      switch (action) {
        case _FolderSortAction.manual:
          await _openSortPage();
        case _FolderSortAction.collection:
          await _applyCollectionOrder();
        case _FolderSortAction.cacheTime:
          await _resetOrder();
      }
    });
  }

  Future<void> _renameFolder() async {
    final currentTitle = _folderService.getFolder(widget.folderId)?.title ?? '';
    final name = await showDownloadFolderNameDialog(
      context: context,
      title: '重命名文件夹',
      initialValue: currentTitle,
    );
    if (name == null || name == currentTitle) {
      return;
    }
    await _folderService.renameFolder(widget.folderId, name);
  }

  Future<void> _deleteFolder() async {
    final folder = _folderService.getFolder(widget.folderId);
    if (folder == null) {
      return;
    }
    final deleted = await confirmDeleteFolders(
      context: context,
      folders: [folder],
    );
    if (deleted && mounted) {
      Get.back();
    }
  }

  Widget _buildSortBtn() {
    return Builder(
      builder: (context) => IconButton(
        tooltip: '排序',
        icon: const Icon(Icons.sort),
        onPressed: () {
          showStaticPositionMenu<_FolderSortAction>(
            context: context,
            items: const [
              CustomPopupMenuItem(
                value: _FolderSortAction.manual,
                child: Text('手动排序'),
              ),
              CustomPopupMenuItem(
                value: _FolderSortAction.collection,
                child: Text('按合集顺序'),
              ),
              CustomPopupMenuItem(
                value: _FolderSortAction.cacheTime,
                child: Text('按缓存时间'),
              ),
            ],
          ).then((value) {
            if (value != null) {
              _onSortSelected(value);
            }
          });
        },
      ),
    );
  }

  Widget _buildFolderMenu() {
    return Builder(
      builder: (context) => IconButton(
        tooltip: '文件夹',
        icon: const Icon(Icons.more_vert),
        onPressed: () {
          showStaticPositionMenu<int>(
            context: context,
            items: [
              const CustomPopupMenuItem(value: 0, child: Text('重命名')),
              CustomPopupMenuItem(
                value: 1,
                child: Text(
                  '删除文件夹',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ],
          ).then((value) {
            if (value == 0) {
              _renameFolder();
            } else if (value == 1) {
              _deleteFolder();
            }
          });
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final enableMultiSelect = this.enableMultiSelect.value;
      final folder = _folderService.getFolder(widget.folderId);
      return popScope(
        canPop: !enableMultiSelect,
        onPopInvokedWithResult: (didPop, result) {
          if (enableMultiSelect) {
            handleSelect();
          }
        },
        child: SimpleScaffold(
          appBar: MultiSelectAppBarWidget(
            ctr: this,
            visible: enableMultiSelect,
            actions: [
              updateBtn(),
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: checkedCount == 0 ? null : _addSelectedToFolder,
                child: const Text('添加到'),
              ),
              if (Platform.isAndroid)
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: checkedCount == 0 ? null : _exportSelected,
                  child: const Text('导出'),
                ),
            ],
            child: AppBar(
              title: Text(folder?.title ?? '文件夹'),
              actions: [
                _buildSortBtn(),
                _buildFolderMenu(),
                IconButton(
                  tooltip: '多选',
                  onPressed: () {
                    if (enableMultiSelect) {
                      handleSelect();
                    } else {
                      this.enableMultiSelect.value = true;
                    }
                  },
                  icon: const Icon(Icons.edit_note),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
          body: CustomScrollView(
            slivers: [
              ViewSliverSafeArea(
                sliver: Obx(() {
                  if (_entries.isEmpty) {
                    return const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: Center(
                          child: Text('文件夹里还没有视频'),
                        ),
                      ),
                    );
                  }
                  return SliverGrid.builder(
                    gridDelegate: gridDelegate,
                    itemCount: _entries.length,
                    itemBuilder: (context, index) {
                      final entry = _entries[index];
                      return DetailItem(
                        entry: entry,
                        progress: _progress,
                        downloadService: downloadService,
                        showTitle: true,
                        controller: this,
                        playContext: DownloadVideoPlayContext.folder(
                          widget.folderId,
                        ),
                        onDelete: () => deleteLocalEntries(
                          downloadService: downloadService,
                          entries: [entry],
                        ),
                        extraMoreItemsBuilder: (menuContext) => [
                          CustomPopupMenuItem<void>(
                            height: 38,
                            child: const Text(
                              '移出文件夹',
                              style: TextStyle(fontSize: 13),
                            ),
                            onTap: () => confirmRemoveFromFolders(
                              context: menuContext,
                              folderId: widget.folderId,
                              entries: [entry],
                            ),
                          ),
                          ...buildAddToFolderMenuItems(
                            context: menuContext,
                            entries: [entry],
                          ),
                        ],
                      );
                    },
                  );
                }),
              ),
            ],
          ),
        ),
      );
    });
  }
}
