import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

/// 播放页根节点的不透明黑色底 + 视频矩形挖孔。
///
/// 原生 HDR 视频由 Flutter **之下**的 SurfaceView 输出，Flutter 里任何不透明
/// 绘制都会把它盖住。这里不再让整页透明（非视频区域会透出窗口/下层页面），
/// 而是在根节点显式铺一层黑色，只把当前视频矩形留空：
///
/// * 非视频区域：黑色（页面里的简介/评论/侧栏再各自铺主题表面色）；
/// * 视频矩形：透明，透出底层原生 SurfaceView；
/// * 弹幕/字幕/控制栏仍然画在孔的上方，不受影响。
class HdrHolePunch extends StatefulWidget {
  const HdrHolePunch({
    super.key,
    required this.controller,
    required this.child,
  });

  final PlPlayerController controller;
  final Widget child;

  @override
  State<HdrHolePunch> createState() => _HdrHolePunchState();
}

class _HdrHolePunchState extends State<HdrHolePunch> {
  final _rootKey = GlobalKey();
  Rect? _hole;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    widget.controller.nativeContentRect.addListener(_update);
    _scheduleSync();
  }

  @override
  void dispose() {
    widget.controller.nativeContentRect.removeListener(_update);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant HdrHolePunch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.nativeContentRect.removeListener(_update);
      widget.controller.nativeContentRect.addListener(_update);
      _update();
    }
  }

  /// 矩形随滚动/转屏/全屏动画变化，逐帧检查（不主动申请帧）。
  void _scheduleSync() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      _update();
      _scheduleSync();
    });
  }

  void _update() {
    if (!mounted) return;
    final box = _rootKey.currentContext?.findRenderObject();
    final global = widget.controller.nativeContentRect.value;
    final useNative = widget.controller.useNativeSurface;
    Rect? hole;
    if (box is RenderBox &&
        box.hasSize &&
        useNative &&
        global != null &&
        !global.isEmpty) {
      final topLeft = box.globalToLocal(global.topLeft);
      final bottomRight = box.globalToLocal(global.bottomRight);
      final local = Rect.fromPoints(
        topLeft,
        bottomRight,
      ).intersect(Offset.zero & box.size);
      if (!local.isEmpty) {
        hole = local;
      }
    }
    if (hole != _hole) {
      setState(() => _hole = hole);
    }
    widget.controller.nativeHoleRect.value = hole;
    widget.controller.nativePageSize.value = box is RenderBox && box.hasSize
        ? box.size
        : null;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: CustomPaint(painter: _HolePunchPainter(_hole)),
        ),
        Positioned.fill(
          child: SizedBox.expand(key: _rootKey, child: widget.child),
        ),
      ],
    );
  }
}

class _HolePunchPainter extends CustomPainter {
  const _HolePunchPainter(this.hole);

  final Rect? hole;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Offset.zero & size;
    final paint = Paint()..color = const Color(0xFF000000);
    final hole = this.hole;
    if (hole == null || hole.isEmpty) {
      canvas.drawRect(full, paint);
      return;
    }
    final rect = hole.intersect(full);
    if (rect.isEmpty) {
      canvas.drawRect(full, paint);
      return;
    }
    // 四块黑边，中间留空（真正透明），透出底层原生视频。
    canvas
      ..drawRect(
        Rect.fromLTRB(full.left, full.top, full.right, rect.top),
        paint,
      )
      ..drawRect(
        Rect.fromLTRB(full.left, rect.bottom, full.right, full.bottom),
        paint,
      )
      ..drawRect(
        Rect.fromLTRB(full.left, rect.top, rect.left, rect.bottom),
        paint,
      )
      ..drawRect(
        Rect.fromLTRB(rect.right, rect.top, full.right, rect.bottom),
        paint,
      );
  }

  @override
  bool shouldRepaint(_HolePunchPainter oldDelegate) => oldDelegate.hole != hole;
}
