import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';

class PortraitFeedItem {
  const PortraitFeedItem({
    required this.bvid,
    this.cid,
    this.aid,
    this.cover,
    this.title,
  });

  final String bvid;
  final int? cid;
  final int? aid;
  final String? cover;
  final String? title;
}

class PortraitFeedService {
  PortraitFeedService._();

  static final PortraitFeedService instance = PortraitFeedService._();

  static const int _maxHistory = 50;

  final List<PortraitFeedItem> _queue = [];
  final List<PortraitFeedItem> _history = [];

  String? _cursor;
  bool _filling = false;

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

  Future<PortraitFeedItem?> next({required String currentBvid}) async {
    PortraitFeedItem? take() {
      while (_queue.isNotEmpty) {
        final item = _queue.removeAt(0);
        if (item.bvid == currentBvid) {
          continue;
        }
        if (_history.any((e) => e.bvid == item.bvid)) {
          continue;
        }
        return item;
      }
      return null;
    }

    final item = take();
    if (item != null) {
      return item;
    }
    await _fill(bvid: currentBvid);
    return take();
  }

  Future<void> _fill({required String bvid}) async {
    if (_filling) {
      return;
    }
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