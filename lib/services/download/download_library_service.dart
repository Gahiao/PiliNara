import 'dart:async' show unawaited;
import 'dart:io' show Directory;

import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/download/download_info.dart';
import 'package:PiliPlus/models_new/download/download_playback.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:collection/collection.dart';
import 'package:get/get.dart';

/// 离线缓存的派生视图与续播状态。
///
/// 分组不落盘：归属由条目自己携带（`season_info` / `seasonId` / `pageData`），
/// 这里只把它摊成 合集 → 视频/分P 页 → 条目 三层，供页面与播放列表使用。
/// 因此条目一删就自动出组，不存在需要同步的第二份数据。
class DownloadLibraryService extends GetxService {
  final _downloadService = Get.find<DownloadService>();

  /// 起播 5 秒内不记续播；距结束 400ms 内视为已看完。
  static const _minContinueProgressMs = 5000;
  static const _completedThresholdMs = 400;

  final flagNotifier = SetNotifier();

  final seasons = RxList<DownloadSeasonInfo>();

  final continueTarget = Rxn<DownloadContinueTarget>();

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
    await loadSeasons(notify: false);
    _downloadService.flagNotifier.add(_onDownloadChanged);
  }

  void _onDownloadChanged() => unawaited(loadSeasons());

  Future<void> loadSeasons({bool notify = true}) async {
    await _downloadService.waitForInitialization;
    if (isClosed) {
      return;
    }
    seasons.value = groupSeasons(_downloadService.downloadList);
    continueTarget.value = resolveLastLocalPlayed();
    if (notify) {
      flagNotifier.refresh();
    }
  }

  Future<void> refreshContinueTarget() async {
    await _downloadService.waitForInitialization;
    if (isClosed) {
      return;
    }
    continueTarget.value = resolveLastLocalPlayed();
  }

  /// 合集 → 视频/分P 页 → 条目 三层分组，顺序跟随缓存列表（新缓存的在前）。
  ///
  /// 归属来自条目自身：`seasonInfo` 决定合集，`pageId`（PGC 为 seasonId、UGC 为
  /// avid）决定视频页，`sortKey` 决定页内分P/集序号。合集内视频的页顺序恒为
  /// 合集原顺序，即 [SeasonInfo.index]。
  static List<DownloadSeasonInfo> groupSeasons(
    Iterable<BiliDownloadEntryInfo> entries,
  ) {
    final list = <DownloadSeasonInfo>[];
    for (final entry in entries) {
      final pageId = entry.pageId;
      final seasonInfo = entry.seasonInfo;
      final season = seasonInfo != null
          ? list.firstWhereOrNull((e) => e.seasonInfo == seasonInfo)
          : list.firstWhereOrNull((e) => e.pageId == pageId);
      if (season == null) {
        list.add(
          DownloadSeasonInfo(
            pageId: pageId,
            seasonInfo: seasonInfo,
            pages: [
              entry.toDownloadPageInfo(pageId, sortKey: seasonInfo?.index),
            ],
          ),
        );
        continue;
      }
      final page = season.pages.firstWhereOrNull((e) => e.pageId == pageId);
      if (page == null) {
        season.pages.add(
          entry.toDownloadPageInfo(pageId, sortKey: seasonInfo!.index),
        );
        continue;
      }
      // 合集成员保持合集原顺序；非合集（分P）才收敛到最小的分P序号。
      if (seasonInfo == null && entry.sortKey < page.sortKey) {
        page
          ..cover = entry.cover
          ..sortKey = entry.sortKey;
      }
      page.entries.add(entry);
    }
    return list;
  }

  DownloadSeasonInfo? seasonByKey(String seasonKey) =>
      seasons.firstWhereOrNull((e) => e.playlistKey == seasonKey);

  List<BiliDownloadEntryInfo> entriesOfSeason(DownloadSeasonInfo season) => [
    for (final page in season.pages) ...page.entries,
  ];

  /// 本地视频页的播放列表：合集 → 视频/分P 页 → 分P序号，只保留已缓存完成的。
  ///
  /// [context] 为空或不是合集范围时，返回全部缓存。
  List<BiliDownloadEntryInfo> resolvePlaylist(
    DownloadVideoPlayContext? context,
  ) {
    final seasonKey = context?.isSeason == true ? context!.seasonKey : null;
    final list = <BiliDownloadEntryInfo>[];
    for (final season in seasons) {
      if (seasonKey != null && season.playlistKey != seasonKey) {
        continue;
      }
      for (final page in season.pages) {
        final items = page.entries.toList()..sort(downloadEntrySort);
        list.addAll(items.where((e) => e.isCompleted));
      }
    }
    return list;
  }

  bool _isContinueProgress(int progressMs, int durationMs) =>
      durationMs > 0 &&
      progressMs > _minContinueProgressMs &&
      progressMs < durationMs - _completedThresholdMs;

  Future<void> updateLastLocalPlayed({
    required BiliDownloadEntryInfo entry,
    required int progressMs,
    required DownloadVideoPlayContext playContext,
  }) async {
    if (!_isContinueProgress(progressMs, entry.totalTimeMilli)) {
      await clearLastLocalPlayedIfCid(entry.cid);
      return;
    }
    final scope = playContext.isSeason
        ? DownloadPlaylistScope.season
        : DownloadPlaylistScope.all;
    await GStorage.localCache.put(
      LocalCacheKey.lastLocalPlayed,
      DownloadContinueRecord(
        cid: entry.cid,
        updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        scope: scope,
        seasonKey: scope == DownloadPlaylistScope.season
            ? playContext.seasonKey
            : null,
      ).toJson(),
    );
  }

  Future<void> clearLastLocalPlayed() =>
      GStorage.localCache.delete(LocalCacheKey.lastLocalPlayed);

  Future<void> clearLastLocalPlayedIfCid(int cid) async {
    final record = DownloadContinueRecord.fromJson(
      GStorage.localCache.get(LocalCacheKey.lastLocalPlayed),
    );
    if (record?.cid == cid) {
      await clearLastLocalPlayed();
    }
  }

  /// 解析续播目标：条目、缓存进度都还在，且记录里的合集仍包含它时才返回。
  DownloadContinueTarget? resolveLastLocalPlayed() {
    final raw = GStorage.localCache.get(LocalCacheKey.lastLocalPlayed);
    final record = DownloadContinueRecord.fromJson(raw);
    if (raw != null && record == null) {
      unawaited(clearLastLocalPlayed());
      return null;
    }
    if (record == null) {
      return null;
    }
    final entry = _downloadService.downloadList.firstWhereOrNull(
      (item) => item.cid == record.cid && item.isCompleted,
    );
    if (entry == null ||
        entry.totalTimeMilli <= 0 ||
        !Directory(entry.entryDirPath).existsSync()) {
      unawaited(clearLastLocalPlayed());
      return null;
    }
    final progressMs = GStorage.watchProgress.get(record.cid.toString());
    if (progressMs == null ||
        !_isContinueProgress(progressMs, entry.totalTimeMilli)) {
      unawaited(clearLastLocalPlayed());
      return null;
    }
    var playContext = const DownloadVideoPlayContext.all();
    final seasonKey = record.seasonKey;
    if (record.scope == DownloadPlaylistScope.season && seasonKey != null) {
      final season = seasonByKey(seasonKey);
      if (season != null &&
          entriesOfSeason(season).any((e) => e.cid == record.cid)) {
        playContext = DownloadVideoPlayContext.season(seasonKey);
      }
    }
    return DownloadContinueTarget(
      entry: entry,
      playContext: playContext,
      progressMs: progressMs,
      durationMs: entry.totalTimeMilli,
    );
  }
}
