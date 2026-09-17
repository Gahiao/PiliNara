import 'dart:io';

import 'package:PiliPlus/pages/ai_chat/controller.dart';
import 'package:PiliPlus/pages/ai_chat/models.dart';
import 'package:PiliPlus/pages/common/slide/common_slide_page.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/services/ai_chat/ai_chat_service.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/common/widgets/flutter/text_field/controller.dart';
import 'package:PiliPlus/common/widgets/flutter/text_field/text_field.dart';
import 'package:material_ui/material_ui.dart' hide TextField;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_markdown_plus_latex/flutter_markdown_plus_latex.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:markdown/markdown.dart' as md;

class AiChatPage extends CommonSlidePage {
  const AiChatPage({super.key, required this.heroTag});

  final String heroTag;

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage>
    with SingleTickerProviderStateMixin, CommonSlideMixin {
  late final AiChatController chatCtl;
  final _inputCtl = RichTextEditingController();
  final _focusNode = FocusNode(onKeyEvent: _handleKeyEvent);
  final _scrollCtl = ScrollController();
  late List<AiPromptTemplate> _templates;
  int _selectedPromptIndex = 0;
  bool _isAtBottom = true;
  double _lastScrollOffset = 0;
  bool _scrollScheduled = false;

  /// 控制栏收起进度：0 完全展开，1 完全收起，由用户滚动位移驱动。
  final _barCollapse = ValueNotifier<double>(0);

  /// 顶部提示词栏的布局 key：取它布局后的自然高度，用于把滚动量换算成
  /// 收起进度，并保证滚动补偿与实际布局位移一致。
  final _promptBarKey = GlobalKey();

  /// 布局完成前的兜底高度，数值与提示词栏的默认高度接近。
  static const double _defaultPromptBarHeight = 64.0;

  /// 顶部提示词/分析栏的自然高度（含提示条、分割线）。
  double get _promptBarHeight =>
      _promptBarKey.currentContext?.size?.height ?? _defaultPromptBarHeight;

  /// 小屏设备（手表/小折叠屏）紧凑布局：仅压缩间距与控件密度，不缩放字号。
  bool get _isCompact => MediaQuery.sizeOf(context).height < 600;

  /// Desktop: Enter sends, Shift+Enter inserts newline.
  /// Mobile: consume Enter to prevent it from bubbling up to PlayerFocus
  /// (which would open the danmaku input panel).
  static KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter) {
      if (Platform.isAndroid || Platform.isIOS) {
        // On mobile, stop the KeyEvent from propagating to ancestor focus
        // handlers (e.g. PlayerFocus → send danmaku), but let the platform
        // IME process it as text input so the newline gets inserted.
        return KeyEventResult.skipRemainingHandlers;
      }
      if (!HardwareKeyboard.instance.isShiftPressed) {
        final state =
            node.context?.findAncestorStateOfType<_AiChatPageState>();
        if (state != null && !state.chatCtl.isAnalyzing.value) {
          state._sendCustomPrompt();
        }
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
    chatCtl = Get.find<AiChatController>(tag: widget.heroTag);
    _templates = AiChatService.getTemplates();
    _scrollCtl.addListener(_onScroll);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _inputCtl.dispose();
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    _scrollCtl
      ..removeListener(_onScroll)
      ..dispose();
    _barCollapse.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollCtl.hasClients) return;
    final pos = _scrollCtl.position;
    final offset = pos.pixels;
    if (offset < _lastScrollOffset) {
      if (_isAtBottom) setState(() => _isAtBottom = false);
    } else if (offset > _lastScrollOffset) {
      if (!_isAtBottom && pos.maxScrollExtent - offset <= 100) {
        setState(() => _isAtBottom = true);
      }
    }
    _lastScrollOffset = offset;
  }

  void _onFocusChanged() {
    if (!_focusNode.hasFocus) return;
    final value = _barCollapse.value;
    if (value == 0) return;
    final height = _promptBarHeight;
    _barCollapse.value = 0;
    // 控制栏弹回会把列表上边缘压下同样高度，补偿滚动位置避免消息跳动
    if (_scrollCtl.hasClients) {
      _scrollCtl.position.correctBy(value * height);
    }
  }

  /// 只有用户手势滚动才收放控制栏。
  ///
  /// [ScrollUpdateNotification.dragDetails]、[OverscrollNotification.dragDetails]
  /// 为空时说明是惯性滑动或程序自动滚动（AI 流式回复时的自动滚到底部），
  /// 此时控制栏保持不动；鼠标滚轮、触控板没有 dragDetails，
  /// 由 [_onPointerSignal] 单独处理。
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    if (notification is ScrollUpdateNotification) {
      if (notification.dragDetails == null) return false;
      _handleUserScroll(notification.scrollDelta ?? 0);
    } else if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      // 列表到顶/到底后继续拖拽也能把控制栏平移回来
      _updateBarCollapse(notification.overscroll, _promptBarHeight);
    }
    return false;
  }

  /// 鼠标滚轮、触控板滚动只发指针信号，不产生带 dragDetails 的滚动通知。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final scrollDelta = event.scrollDelta.dy;
    if (scrollDelta == 0) return;
    if (_scrollCtl.hasClients) {
      final position = _scrollCtl.position;
      // 已在边界时滚轮不会真的滚动，只收放控制栏，不补偿滚动位置
      final canScroll = scrollDelta > 0
          ? position.pixels < position.maxScrollExtent
          : position.pixels > position.minScrollExtent;
      if (!canScroll) {
        _updateBarCollapse(scrollDelta, _promptBarHeight);
        return;
      }
    }
    _handleUserScroll(scrollDelta);
  }

  /// 按用户滚动的位移量收放控制栏，并补偿列表滚动位置。
  void _handleUserScroll(double scrollDelta) {
    final height = _promptBarHeight;
    final value = _barCollapse.value;
    if (!_updateBarCollapse(scrollDelta, height)) return;
    // 顶栏收起会让列表上边缘上移同样高度，补偿滚动位置以保证内容跟手 1:1
    if (_scrollCtl.hasClients) {
      _scrollCtl.position.correctBy((value - _barCollapse.value) * height);
    }
  }

  /// 按滚动量更新控制栏进度，返回进度是否发生变化。
  ///
  /// [height] 为顶栏的实际高度：累计滚动量与它相等时正好完全收起。
  bool _updateBarCollapse(double scrollDelta, double height) {
    if (scrollDelta == 0 || height <= 0) return false;
    final next = clampDouble(
      _barCollapse.value + scrollDelta / height,
      0.0,
      1.0,
    );
    if (next == _barCollapse.value) return false;
    _barCollapse.value = next;
    return true;
  }

  void _jumpToLatest() {
    if (!_scrollCtl.hasClients) return;
    if (!_isAtBottom) {
      setState(() => _isAtBottom = true);
    }
    _scrollCtl.animateTo(
      _scrollCtl.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _scrollToBottom() {
    if (!_scrollCtl.hasClients || !_isAtBottom || _scrollScheduled) {
      return;
    }
    if (!Pref.aiAutoScroll) {
      _scrollScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollScheduled = false;
        if (mounted &&
            _scrollCtl.hasClients &&
            _isAtBottom &&
            _scrollCtl.position.maxScrollExtent -
                    _scrollCtl.position.pixels >
                100) {
          setState(() => _isAtBottom = false);
        }
      });
      return;
    }
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (_scrollCtl.hasClients && _isAtBottom) {
        _scrollCtl.animateTo(
          _scrollCtl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendSelectedPrompt() {
    if (_templates.isEmpty) return;
    if (!chatCtl.hasSubtitles) {
      SmartDialog.showToast('当前视频无字幕，请「载入上下文」后直接提问');
      return;
    }
    if (_selectedPromptIndex >= 0 && _selectedPromptIndex < _templates.length) {
      final t = _templates[_selectedPromptIndex];
      chatCtl.startAnalysis(t.prompt, templateName: t.name);
    }
  }

  void _sendCustomPrompt() {
    final text = _inputCtl.text.trim();
    if (text.isEmpty) return;
    _inputCtl.clear();
    chatCtl.sendFollowUp(text);
  }

  void _copyMessage(ChatMessage msg) {
    if (msg.content.isEmpty) return;
    Clipboard.setData(ClipboardData(text: msg.content));
    SmartDialog.showToast('已复制到剪贴板');
  }

  @override
  Widget buildPage(ThemeData theme) {
    _templates = AiChatService.getTemplates();
    final colorScheme = theme.colorScheme;
    return FocusScope(
      child: Material(
        color: colorScheme.surface,
        clipBehavior: Clip.antiAlias,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: Column(
          children: [
          // Drag handle
          GestureDetector(
            onTap: Get.back,
            child: SizedBox(
              height: _isCompact ? 24 : 35,
              child: Center(
                child: Container(
                  width: 32,
                  height: 3,
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    borderRadius: const BorderRadius.all(Radius.circular(3)),
                  ),
                ),
              ),
            ),
          ),

          // Title bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.auto_awesome, color: colorScheme.primary, size: _isCompact ? 18 : 22),
                const SizedBox(width: 8),
                Text(
                  'AI 视频助手',
                  style: (_isCompact ? theme.textTheme.titleSmall : theme.textTheme.titleMedium)?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                 ),
                 const Spacer(),
                 Obx(() {
                  if (chatCtl.messages.isNotEmpty) {
                    return TextButton.icon(
                      onPressed: chatCtl.clearMessages,
                      style: _isCompact
                          ? TextButton.styleFrom(visualDensity: VisualDensity.compact)
                          : null,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('重置'),
                    );
                  }
                  return const SizedBox.shrink();
                }),
              ],
            ),
          ),
          SizedBox(height: _isCompact ? 4 : 8),

          // Prompt selector + analyze button
          _collapsibleBar(
            slideUp: true,
            child: Column(
              key: _promptBarKey,
              children: [
                _buildPromptBar(theme),
                Divider(height: 1, color: colorScheme.outlineVariant),
                Obx(() {
                  if (!chatCtl.subtitleWarning.value) {
                    return const SizedBox.shrink();
                  }
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    color: colorScheme.errorContainer,
                    child: Text(
                      '提示：当前视频文本较长，AI 首次阅读需要几秒钟，请耐心等待',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onErrorContainer,
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),

          // Content area (slideable)
          Expanded(
            child: enableSlide ? slideList(theme) : buildList(theme),
          ),

          // Input bar
          _collapsibleBar(
            slideUp: false,
            child: _buildInputBar(theme),
          ),
        ],
      ),
      ),
    );
  }

  /// 让控制栏随 [_barCollapse] 连续平移收起与展开。
  ///
  /// [slideUp] 为 true（顶部提示词栏）时内容贴住容器下边缘向上平移滑出，
  /// 与首页顶栏的 CustomHeightWidget（高度减少 + 向上平移）等价；
  /// 为 false（底部输入栏）时内容贴住容器上边缘向下平移滑出，
  /// 被裁掉的是输入栏底部的留白。两者都是平移加高度减少，
  /// 高度减少腾出的空间由消息列表接管。
  ///
  /// 用 [SizeTransition] 而非 CustomHeightWidget：这里需要裁剪溢出内容，
  /// 提示词栏上方还有标题栏，不裁剪会画到标题栏上。
  Widget _collapsibleBar({required bool slideUp, required Widget child}) {
    return ValueListenableBuilder<double>(
      valueListenable: _barCollapse,
      child: child,
      builder: (context, progress, child) => SizeTransition(
        sizeFactor: AlwaysStoppedAnimation(1 - progress),
        alignment: slideUp ? Alignment.bottomLeft : Alignment.topLeft,
        child: child,
      ),
    );
  }

  @override
  Widget buildList(ThemeData theme) {
    return Listener(
      // 鼠标滚轮/触控板滚动没有 dragDetails，由指针信号单独跟随
      onPointerSignal: _onPointerSignal,
      child: _buildContent(theme),
    );
  }

  Widget _buildPromptBar(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: _isCompact ? 4 : 8),
      child: Row(
        children: [
          Expanded(
            child: _templates.isEmpty
                ? Text(
                    '暂无模板，请在设置中添加',
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.outline,
                    ),
                  )
                : DropdownButtonFormField<int>(
                    // ignore: deprecated_member_use
                    value: _selectedPromptIndex < _templates.length
                        ? _selectedPromptIndex
                        : 0,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: _isCompact ? 6 : 8,
                      ),
                      isDense: true,
                    ),
                    items: _templates.asMap().entries.map((entry) {
                      return DropdownMenuItem(
                        value: entry.key,
                        child: Text(
                          entry.value.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _selectedPromptIndex = value);
                      }
                    },
                  ),
          ),
          const SizedBox(width: 12),
          Obx(() {
            final analyzing = chatCtl.isAnalyzing.value;
            final hasContext = chatCtl.hasVideoContext.value;
            final hasSubs = chatCtl.hasSubtitles;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!hasContext || !hasSubs)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: IconButton(
                      onPressed: (analyzing || hasContext) ? null : () => chatCtl.loadVideoContext(),
                      icon: Icon(Icons.post_add, size: _isCompact ? 18 : 22),
                      tooltip: '载入上下文',
                    ),
                  ),
                FilledButton.icon(
                  onPressed: analyzing ? null : _sendSelectedPrompt,
                  style: _isCompact
                      ? FilledButton.styleFrom(visualDensity: VisualDensity.compact)
                      : null,
                  icon: analyzing
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow, size: 20),
                  label: const Text('分析'),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Obx(() {
      final msgs = chatCtl.messages;

      // Empty state
      if (msgs.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.auto_awesome,
                  size: 48,
                  color: colorScheme.outline,
                ),
                const SizedBox(height: 16),
                Text(
                  chatCtl.hasVideoContext.value
                      ? '视频上下文已载入，请输入你的问题'
                      : chatCtl.hasSubtitles
                          ? '选择提示词后点击「分析」或「载入上下文」'
                          : '输入问题开始对话',
                  style: TextStyle(color: colorScheme.outline),
                ),
              ],
            ),
          ),
        );
      }

      _scrollToBottom();

       return NotificationListener<ScrollNotification>(
         onNotification: _onScrollNotification,
         child: Stack(
           children: [
             ListView.builder(
               controller: _scrollCtl,
               padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
               itemCount: msgs.length,
               itemBuilder: (context, index) {
                 final msg = msgs[index];
                 if (msg.isDivider) return _buildDivider(theme);
                 if (msg.role == 'user') {
                   final displayText = msg.templateName != null
                       ? '/${msg.templateName}'
                       : msg.content;
                   return _buildUserMessage(displayText, theme);
                 }
                 return _buildAssistantMessage(msg, theme);
               },
             ),
             if (!_isAtBottom)
               Positioned(
                 right: 16,
                 bottom: 16,
                 child: FloatingActionButton.small(
                   heroTag: null,
                   tooltip: '回到最新',
                   onPressed: _jumpToLatest,
                   child: const Icon(Icons.keyboard_arrow_down_rounded),
                 ),
               ),
           ],
         ),
       );
    });
  }

  Widget _buildDivider(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: _isCompact ? 8 : 12),
      child: Row(
        children: [
          Expanded(child: Divider(color: colorScheme.outlineVariant)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '已载入视频上下文',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.outline,
              ),
            ),
          ),
          Expanded(child: Divider(color: colorScheme.outlineVariant)),
        ],
      ),
    );
  }

  Widget _buildUserMessage(String content, ThemeData theme) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * (_isCompact ? 0.92 : 0.8),
        ),
        margin: EdgeInsets.symmetric(vertical: _isCompact ? 2 : 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: Text(
          content,
          style: TextStyle(
            fontSize: 14,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }

  Widget _buildAssistantMessage(ChatMessage msg, ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * (_isCompact ? 0.95 : 0.85),
            ),
            margin: EdgeInsets.symmetric(vertical: _isCompact ? 2 : 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(4),
                bottomRight: Radius.circular(16),
              ),
            ),
            child: msg.content.isEmpty && msg.isStreaming
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'AI 正在思考...',
                        style: TextStyle(
                          fontSize: 13,
                          color: colorScheme.outline,
                        ),
                      ),
                    ],
                  )
                : SelectionArea(
                    child: MarkdownBody(
                      data: msg.content,
                      blockSyntaxes: [LatexBlockSyntax()],
                      inlineSyntaxes: [LatexInlineSyntax(), TimestampSyntax()],
                      builders: {
                        'latex': LatexElementBuilder(),
                        'timestamp': TimestampBuilder(
                          onTap: _seekToTimestamp,
                        ),
                      },
                      styleSheet: MarkdownStyleSheet(
                        p: TextStyle(
                          inherit: false,
                          fontSize: 15,
                          height: 1.6,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        h1: TextStyle(
                          inherit: false,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                          height: 1.5,
                        ),
                        h2: TextStyle(
                          inherit: false,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                          height: 1.5,
                        ),
                        h3: TextStyle(
                          inherit: false,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                          height: 1.4,
                        ),
                        h4: TextStyle(
                          inherit: false,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                          height: 1.4,
                        ),
                        h5: TextStyle(
                          inherit: false,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                          height: 1.4,
                        ),
                        h6: TextStyle(
                          inherit: false,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                          height: 1.4,
                        ),
                        a: TextStyle(
                          color: colorScheme.primary,
                          inherit: false,
                        ),
                        blockquote: TextStyle(
                          inherit: false,
                          fontSize: 15,
                          height: 1.6,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        blockquoteDecoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: colorScheme.primary,
                              width: 3,
                            ),
                          ),
                        ),
                        blockquotePadding: const EdgeInsets.only(left: 12),
                        code: TextStyle(
                          inherit: false,
                          fontSize: 13,
                          color: colorScheme.primary,
                          backgroundColor: colorScheme.surfaceContainerHigh,
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        codeblockPadding: const EdgeInsets.all(12),
                        listBullet: TextStyle(
                          inherit: false,
                          fontSize: 14,
                          color: colorScheme.primary,
                        ),
                        listIndent: 24,
                        blockSpacing: 8,
                        tableHead: TextStyle(
                          inherit: false,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                        ),
                        tableBody: TextStyle(
                          inherit: false,
                          fontSize: 14,
                          height: 1.5,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        tableHeadAlign: TextAlign.center,
                        tableBorder: TableBorder.all(
                          color: colorScheme.outlineVariant,
                        ),
                        tableCellsPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        tableHeadCellsPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        tableHeadCellsDecoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHigh,
                        ),
                        tableCellsDecoration: const BoxDecoration(),
                        tablePadding: const EdgeInsets.only(bottom: 4),
                        checkbox: TextStyle(
                          inherit: false,
                          fontSize: 14,
                          color: colorScheme.primary,
                        ),
                        horizontalRuleDecoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(
                              color: colorScheme.outlineVariant,
                              width: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          // Copy button at bottom-right of bubble, after streaming ends
          if (!msg.isStreaming && msg.content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Material(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(16),
                elevation: 2,
                child: InkWell(
                  onTap: () => _copyMessage(msg),
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      Icons.copy,
                      size: 16,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _seekToTimestamp(int seconds) {
    try {
      final videoCtl = Get.find<VideoDetailController>(tag: widget.heroTag);
      final duration = videoCtl.plPlayerController.duration.value;
      if (duration > 0 && seconds > duration) {
        SmartDialog.showToast('时间戳超出视频时长');
        return;
      }
      videoCtl.plPlayerController.seekTo(
        Duration(seconds: seconds),
        isSeek: false,
      );
    } catch (_) {
      SmartDialog.showToast('跳转失败');
    }
  }

  Widget _buildInputBar(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final safeBottom = MediaQuery.of(context).viewPadding.bottom;
    final bottomPadding = bottomInset > 0 ? bottomInset + 4.0 : safeBottom + (_isCompact ? 8.0 : 16.0);
    return Container(
      padding: EdgeInsets.fromLTRB(16, _isCompact ? 4 : 8, 8, bottomPadding),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: RichTextField(
              controller: _inputCtl,
              focusNode: _focusNode,
              maxLines: 3,
              minLines: 1,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: '输入问题继续对话...',
                hintStyle: TextStyle(color: colorScheme.outline),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: _isCompact ? 6 : 10,
                ),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Obx(() => IconButton.filled(
                onPressed: chatCtl.isAnalyzing.value ? null : _sendCustomPrompt,
                icon: const Icon(Icons.send),
              )),
        ],
      ),
    );
  }
}

/// Matches timestamps like 00:12, 01:23:45 in any context.
/// Avoids matching IP addresses (192.168.x.x:80) and URLs.
class TimestampSyntax extends md.InlineSyntax {
  TimestampSyntax()
      : super(
        r'(?<![.\d])(?:\[| ［|【|[\(])?(\d{1,2})[：:](\d{2})(?:[：:](\d{2}))?(?:\]| ［|】|[\)])?(?![.\d])',
        );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final g1 = int.parse(match.group(1)!);
    final g2 = int.parse(match.group(2)!);
    final g3 = match.group(3) != null ? int.parse(match.group(3)!) : null;

    // Validate: minutes/seconds must be 0-59
    if (g2 > 59 || (g3 != null && g3 > 59)) return false;

    int seconds;
    if (g3 != null) {
      // HH:MM:SS
      seconds = g1 * 3600 + g2 * 60 + g3;
    } else {
      // MM:SS
      seconds = g1 * 60 + g2;
    }

    final element = md.Element.text('timestamp', match.group(0)!);
    element.attributes['seconds'] = '$seconds';
    parser.addNode(element);
    return true;
  }
}

/// Renders timestamps as tappable colored text.
class TimestampBuilder extends MarkdownElementBuilder {
  TimestampBuilder({required this.onTap});

  final void Function(int seconds) onTap;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final seconds = int.tryParse(element.attributes['seconds'] ?? '') ?? 0;
    final text = element.textContent;
    final style = (parentStyle ?? const TextStyle()).copyWith(
      color: Theme.of(context).colorScheme.primary,
    );

    return GestureDetector(
      onTap: () => onTap(seconds),
      child: Text(text, style: style),
    );
  }
}
