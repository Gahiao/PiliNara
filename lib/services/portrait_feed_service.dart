import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/models/model_rec_video_item.dart';
import 'package:PiliPlus/models_new/video/video_detail/dimension.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

class PortraitFeedItem {
  PortraitFeedItem({
    required this.bvid,
    this.cid,
    this.aid,
    this.cover,
    this.title,
    this.dimension,
  });

  final String bvid;
  int? cid;
  final int? aid;
  final String? cover;
  final String? title;
  Dimension? dimension;

  bool get isVertical => dimension?.isVertical == true;
}

class PortraitFeedService {
  PortraitFeedService._();

  static final PortraitFeedService instance = PortraitFeedService._();

  static const int _maxHistory = 50;
  static const int _maxProbe = 30;

  final List<PortraitFeedItem> _queue = [];
  final List<PortraitFeedItem> _history = [];

  String? _cursor;
  bool _filling = false;
  int _homeIdx = 0;
  bool _refreshing = false;
  DateTime? _lastRefreshAt;
  static const Duration _refreshCooldown = Duration(seconds: 5);
  final Set<String> _rejected = <String>{};

  String? get cursor => _cursor;

  int get historyLength => _history.length;

  bool get canGoPrevious => _history.isNotEmpty;

  void visit(String bvid) {
    if (_cursor == bvid) {
      return;
    }
    final int index = _history.indexWhere((e) => e.bvid == bvid);
    if (index == -1) {
      _queue.clear();
      _history.clear();
    } else {
      _history.removeRange(index, _history.length);
    }
    _cursor = bvid;
  }

  void push(PortraitFeedItem item) {
    if (_history.isNotEmpty && _history.last.bvid == item.bvid) {
      return;
    }
    _history.add(item);
    if (_history.length > _maxHistory) {
      _history.removeAt(0);
    }
  }

  PortraitFeedItem? pop() => _history.isEmpty ? null : _history.removeLast();

  void markCursor(PortraitFeedItem item) => _cursor = item.bvid;

  void clear() {
    _queue.clear();
    _history.clear();
    _cursor = null;
  }


  Future<bool> _refreshFeed(String currentBvid) async {
    if (_refreshing) return false;
    final now = DateTime.now();
    if (_lastRefreshAt != null &&
        now.difference(_lastRefreshAt!) < _refreshCooldown) {
      return false;
    }
    _refreshing = true;
    _lastRefreshAt = now;
    try {
      _queue.clear();
      if (Pref.portraitRC) {
        await _fillHomeRcmd();
      } else {
        await _fillRelated(bvid: currentBvid);
      }
      return true;
    } finally {
      _refreshing = false;
    }
  }



  Future<PortraitFeedItem?> next({required String currentBvid}) async {
    bool refreshed = false;
    for (int i = 0; i < _maxProbe; i++) {
      var item = _take(currentBvid);
      if (item == null) {
        await _fill(bvid: currentBvid);
        item = _take(currentBvid);
      }
      if (item == null) {
        if (Pref.portraitNewv) {
          if (refreshed || !await _refreshFeed(currentBvid)) {
            return null;
          }
          refreshed = true;
          continue;
        }
          return null;
      }
      if (await _ensureVertical(item)) {
        return item;
      }
      if (item.dimension != null) {
        _rejected.add(item.bvid);
      }
    }
    return null;
  }

  PortraitFeedItem? _take(String currentBvid) {
    while (_queue.isNotEmpty) {
      final item = _queue.removeAt(0);
      if (item.bvid == currentBvid) continue;
      if (_history.any((e) => e.bvid == item.bvid)) continue;
      if (_rejected.contains(item.bvid)) continue;
      return item;
    }
    return null;
  }

  Future<bool> _ensureVertical(PortraitFeedItem item) async {
    if (item.isVertical) {
      return true;
    }
    if (item.dimension != null) {
      return false;
    }
    try {
      final res = await SearchHttp.ab2cWithDimension(
        aid: item.aid,
        bvid: item.bvid,
      );
      if (res == null) {
        return false;
      }
      item.cid ??= res.cid;
      item.dimension = res.dimension;
      return item.isVertical;
    } catch (_) {
      return false;
    }
  }

  Future<void> _fill({required String bvid}) async {
    if (Pref.portraitRC) {
      await _fillHomeRcmd();
    } else {
      await _fillRelated(bvid: bvid);
    }
  }

  Future<void> _fillHomeRcmd() async {
    final res = await VideoHttp.rcmdVideoList(ps: 20, freshIdx: _homeIdx);
    if (res case Success(:final response)) {
      _homeIdx++;
      for (final e in response) {
        final String? bvid = e.bvid;
        if (bvid == null || bvid.isEmpty) {
          continue;
        }
        _queue.add(
          PortraitFeedItem(
            bvid: bvid,
            cid: e.cid,
            aid: e.aid,
            cover: e.cover,
            title: e.title,
            dimension: e.dimension,
          ),
        );
      }
    }
  }

  Future<void> _fillRelated({required String bvid}) async {
    if (_filling) return;
    _filling = true;
    try {
      final res = await VideoHttp.relatedVideoList(bvid: bvid);
      if (res case Success(:final response)) {
        for (final HotVideoItemModel e
        in response ?? const <HotVideoItemModel>[]) {
          if (e.isLive == true || e.isPugv == true) {
            continue;
          }
          if (e.redirectUrl?.isNotEmpty == true) {
            continue;
          }
          if (e.dimension != null && !e.dimension!.isVertical) {
            continue;
          }
          final String? itemBvid = e.bvid;
          if (itemBvid == null || itemBvid.isEmpty) {
            continue;
          }
          _queue.add(
            PortraitFeedItem(
              bvid: itemBvid,
              cid: e.cid,
              aid: e.aid,
              cover: e.cover,
              title: e.title,
              dimension: e.dimension,
            ),
          );
        }
      }
    } catch (_) {
    } finally {
      _filling = false;
    }
  }
}