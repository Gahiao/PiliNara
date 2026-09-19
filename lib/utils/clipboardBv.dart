import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart';

final _urlPattern = RegExp(r'https?://\S*(?:bilibili\.com|b23\.tv)/\S*');
final _bvPattern = RegExp(r'[Bb][Vv]1[0-9A-Za-z]{9}');

abstract final class ClipboardBv {
  

  static Future<void> check() async {
    if (!Pref.BV_jump) return;

    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty) return;

    if (text == Pref.lastBvClipboard) return;

    final url = _urlPattern.firstMatch(text)?.group(0);
    final bvid = _bvPattern.firstMatch(text)?.group(0);
    final target = url ??
        (bvid == null ? null : 'https://www.bilibili.com/video/$bvid');

    if (target == null) return;

    Pref.lastBvClipboard = text;

    await _openUrl(target);
  }

  static Future<void> _openUrl(String url) async {
    try {
      await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
    }
  }
}
