import 'package:PiliPlus/grpc/bilibili/app/viewunite/v1.pbjson.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/common/widgets/action_toast.dart';


final _urlPattern = RegExp(r'https?://\S*(?:bilibili\.com|b23\.tv)/\S*');
final _bvPattern = RegExp(r'[Bb][Vv]1[0-9A-Za-z]{9}');

abstract final class ClipboardBv {
  

  static Future<void> check() async {
    if (!Pref.bvJump) return;

    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty) return;

    if (text == Pref.lastBvClipboard) return;

    final url = _urlPattern.firstMatch(text)?.group(0);
    final bvid = _bvPattern.firstMatch(text)?.group(0);
    final target = url ??
        (bvid == null ? null : 'https://www.bilibili.com/video/$bvid');

    if (target == null) return;

    Pref.lastBvClipboard = text;

    if (Pref.jumpDirec) {
      await _openUrl(target);
    }else{
        final ok = await showActionToast(msg: '是否跳转到来自剪切板的视频?', actionText: '跳转');
        if (ok) await _openUrl(target);
    }
  }

  static Future<void> _openUrl(String url) async {
    final handled = await PiliScheme.routePushFromUrl(url, selfHandle: true);
    if (handled) {
      if (Pref.showBvToast) {
        final text = Pref.bvJumpToastText;
        SmartDialog.showToast(
          text.isEmpty? "已到达对应坐标~":
              text.replaceAll('{bvid}',
              _bvPattern.firstMatch(url)?.group(0) ?? '',)

        );
        return;
      }
    }
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }
}
