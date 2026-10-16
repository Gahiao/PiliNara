import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';

/// 离线缓存的播放范围：全部缓存，或某一个合集（含 PGC 一季）。
enum DownloadPlaylistScope {
  all,
  season,
}

/// 打开缓存视频时携带的播放上下文，决定本地视频页里「上一集/下一集」的范围。
///
/// 通过路由参数传递，键名与 [toArguments] 保持一致，视频页用
/// [fromArguments] 还原；解析失败时按「全部缓存」处理。
class DownloadVideoPlayContext {
  final DownloadPlaylistScope scope;

  /// 合集标识，取 [DownloadSeasonInfo.playlistKey]。
  final String? seasonKey;

  const DownloadVideoPlayContext._({
    required this.scope,
    this.seasonKey,
  });

  const DownloadVideoPlayContext.all()
    : this._(scope: DownloadPlaylistScope.all);

  const DownloadVideoPlayContext.season(String key)
    : this._(
        scope: DownloadPlaylistScope.season,
        seasonKey: key,
      );

  bool get isSeason =>
      scope == DownloadPlaylistScope.season &&
      seasonKey != null &&
      seasonKey!.isNotEmpty;

  Map<String, dynamic> toArguments() => <String, dynamic>{
    'downloadPlaylistScope': scope.name,
    'downloadSeasonKey': ?seasonKey,
  };

  static DownloadVideoPlayContext? fromArguments(Map args) {
    final scope = switch (args['downloadPlaylistScope']) {
      'all' => DownloadPlaylistScope.all,
      'season' => DownloadPlaylistScope.season,
      _ => null,
    };
    if (scope == null) {
      return null;
    }
    if (scope == DownloadPlaylistScope.all) {
      return const DownloadVideoPlayContext.all();
    }
    final seasonKey = args['downloadSeasonKey'];
    return seasonKey is String && seasonKey.isNotEmpty
        ? DownloadVideoPlayContext.season(seasonKey)
        : null;
  }
}

/// 续播记录：只记最后一个可续播的缓存视频，以及它当时的播放范围。
class DownloadContinueRecord {
  final int cid;
  final int updatedAt;
  final DownloadPlaylistScope scope;
  final String? seasonKey;

  const DownloadContinueRecord({
    required this.cid,
    required this.updatedAt,
    required this.scope,
    this.seasonKey,
  });

  static DownloadContinueRecord? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final json = raw.cast<dynamic, dynamic>();
    final cid = switch (json['cid']) {
      final int value => value,
      final String value => int.tryParse(value),
      _ => null,
    };
    final updatedAt = json['updatedAt'];
    final scope = switch (json['scope']) {
      'all' => DownloadPlaylistScope.all,
      'season' => DownloadPlaylistScope.season,
      _ => null,
    };
    if (cid == null || updatedAt is! int || scope == null) {
      return null;
    }
    final seasonKey = json['seasonKey'];
    if (scope == DownloadPlaylistScope.season &&
        (seasonKey is! String || seasonKey.isEmpty)) {
      return null;
    }
    return DownloadContinueRecord(
      cid: cid,
      updatedAt: updatedAt,
      scope: scope,
      seasonKey: seasonKey is String ? seasonKey : null,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'cid': cid,
    'updatedAt': updatedAt,
    'scope': scope.name,
    'seasonKey': ?seasonKey,
  };
}

/// 续播目标：可续播的条目、恢复它时该用的播放范围、以及落盘进度。
class DownloadContinueTarget {
  final BiliDownloadEntryInfo entry;
  final DownloadVideoPlayContext playContext;
  final int progressMs;
  final int durationMs;

  const DownloadContinueTarget({
    required this.entry,
    required this.playContext,
    required this.progressMs,
    required this.durationMs,
  });
}
