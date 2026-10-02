import 'dart:async';
import 'dart:math';

import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/loading_widget/loading_widget.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/sliver/sliver_pinned_header.dart';
import 'package:PiliPlus/common/widgets/view_insets_safe_area.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/dynamic/dyn_mention/group.dart';
import 'package:PiliPlus/models_new/dynamic/dyn_mention/item.dart';
import 'package:PiliPlus/pages/dynamics_mention/controller.dart';
import 'package:PiliPlus/pages/dynamics_mention/widgets/item.dart';
import 'package:PiliPlus/pages/search/controller.dart' show DebounceStreamState;
import 'package:PiliPlus/utils/extension/context_ext.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class DynMentionPanel extends StatefulWidget {
  const DynMentionPanel({
    super.key,
    this.scrollController,
    this.onCachePos,
    this.upMid,
  });

  final ScrollController? scrollController;
  final ValueChanged<double>? onCachePos;

  /// 置顶项的 mid，不在返回里则不置顶
  final int? upMid;

  static Future<Object? /* ListOr<MentionItem> */> onDynMention(
    BuildContext context, {
    double offset = 0,
    ValueChanged<double>? onCachePos,
    int? upMid,
  }) {
    return showModalBottomSheet(
      context: Get.context!,
      useSafeArea: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxWidth: min(600, context.mediaQueryShortestSide),
      ),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        snap: true,
        minChildSize: 0,
        maxChildSize: 1,
        initialChildSize: offset == 0 ? 0.65 : 1,
        initialScrollOffset: offset,
        snapSizes: const [0.65],
        builder: (context, scrollController) => DynMentionPanel(
          scrollController: scrollController,
          onCachePos: onCachePos,
          upMid: upMid,
        ),
      ),
    );
  }

  @override
  State<DynMentionPanel> createState() => _DynMentionPanelState();
}

class _DynMentionPanelState
    extends DebounceStreamState<DynMentionPanel, String> {
  final _controller = Get.put(DynMentionController());
  @override
  Duration get duration => const Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    if (_controller.loadingState.value is Error) {
      _controller.onReload();
    }
  }

  @override
  void onValueChanged(String value) => _controller
    ..enableClear.value = value.isNotEmpty
    ..onRefresh().whenComplete(
      () => WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.scrollController?.jumpToTop(),
      ),
    );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final padding = MediaQuery.paddingOf(context).bottom;
    return Column(
      children: [
        SizedBox(
          height: 35,
          child: Center(
            child: Container(
              width: 32,
              height: 3,
              decoration: BoxDecoration(
                color: theme.colorScheme.outline,
                borderRadius: const BorderRadius.all(Radius.circular(3)),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 16, bottom: 5),
          child: TextField(
            focusNode: _controller.focusNode,
            controller: _controller.controller,
            onChanged: ctr!.add,
            decoration: InputDecoration(
              visualDensity: .standard,
              border: const OutlineInputBorder(
                gapPadding: 0,
                borderSide: BorderSide.none,
                borderRadius: BorderRadius.all(Radius.circular(25)),
              ),
              isDense: true,
              filled: true,
              fillColor: theme.colorScheme.onInverseSurface,
              hintText: '输入你想@的人',
              hintStyle: const TextStyle(fontSize: 14),
              prefixIcon: const Padding(
                padding: EdgeInsets.only(left: 12, right: 4),
                child: Icon(Icons.search, size: 20),
              ),
              prefixIconConstraints: const .new(minHeight: 0, minWidth: 0),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 6,
              ),
              suffixIcon: Obx(
                () => _controller.enableClear.value
                    ? Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: GestureDetector(
                          child: Container(
                            padding: const EdgeInsetsDirectional.all(2),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: theme.colorScheme.secondaryContainer,
                            ),
                            child: Icon(
                              Icons.clear,
                              size: 16,
                              color: theme.colorScheme.onSecondaryContainer,
                            ),
                          ),
                          onTap: () => _controller
                            ..enableClear.value = false
                            ..controller.clear()
                            ..onRefresh().whenComplete(
                              () =>
                                  WidgetsBinding.instance.addPostFrameCallback(
                                    (_) => widget.scrollController?.jumpToTop(),
                                  ),
                            ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              suffixIconConstraints: const BoxConstraints(
                minHeight: 0,
                minWidth: 0,
              ),
            ),
          ),
        ),
        Expanded(
          child: ScaffoldLayout(
            body: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is UserScrollNotification) {
                  if (_controller.focusNode.hasFocus) {
                    _controller.focusNode.unfocus();
                  }
                } else if (notification is ScrollEndNotification) {
                  widget.onCachePos?.call(notification.metrics.pixels);
                }
                return false;
              },
              child: CustomScrollView(
                controller: widget.scrollController,
                slivers: [
                  Obx(
                    () => _buildBody(theme, _controller.loadingState.value),
                  ),
                  SliverToBoxAdapter(child: SizedBox(height: padding + 100)),
                ],
              ),
            ),
            fab: Obx(() {
              return Padding(
                padding: .only(
                  right: kFloatingActionButtonMargin,
                  bottom: kFloatingActionButtonMargin + padding,
                ),
                child: ViewInsetsSafeArea(
                  child: AnimatedSlide(
                    offset: _controller.showBtn.value
                        ? .zero
                        : const Offset(0, 3),
                    duration: const Duration(milliseconds: 120),
                    child: FloatingActionButton(
                      onPressed: () {
                        if (_controller.mentionList.isNullOrEmpty) {
                          _controller.showBtn.value = false;
                          return;
                        }
                        Get.back(result: _controller.mentionList);
                        _controller.showBtn.value = false;
                      },
                      child: const Icon(Icons.check),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildBody(
    ThemeData theme,
    LoadingState<List<MentionGroup>?> loadingState,
  ) {
    return switch (loadingState) {
      Loading() => const SliverPadding(
        padding: EdgeInsets.only(top: 8),
        sliver: linearLoading,
      ),
      Success<List<MentionGroup>?>(:final response) =>
        response != null && response.isNotEmpty
            ? _buildGroups(theme, response)
            : HttpError(onReload: _controller.onReload),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: _controller.onReload,
      ),
    };
  }

  Widget _buildGroups(ThemeData theme, List<MentionGroup> groups) {
    // 置顶项从原分组摘掉：多选状态存在 item 上，渲染两遍会两边各自勾选
    final pinned = _pinnedItem(groups);
    return SliverMainAxisGroup(
      slivers: [
        if (pinned != null) _buildGroup(theme, '当前UP主', [pinned]),
        ...groups.map((group) {
          final items = group.items;
          if (items.isNullOrEmpty) {
            return const SliverToBoxAdapter();
          }
          final rest = <MentionItem>[
            for (final item in items!)
              if (pinned == null || item.uid != pinned.uid) item,
          ];
          return rest.isEmpty
              ? const SliverToBoxAdapter()
              : _buildGroup(theme, group.groupName!, rest);
        }),
      ],
    );
  }

  Widget _buildGroup(ThemeData theme, String name, List<MentionItem> items) {
    return SliverMainAxisGroup(
      slivers: [
        SliverPinnedHeader(
          backgroundColor: theme.bottomSheetTheme.backgroundColor,
          child: Padding(
            padding: const .symmetric(horizontal: 16, vertical: 10),
            child: Text(name),
          ),
        ),
        SliverList.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return DynMentionItem(
              item: item,
              onTap: () => Get.back(result: item),
              onCheck: (value) => _controller.onCheck(value, item),
            );
          },
        ),
      ],
    );
  }

  MentionItem? _pinnedItem(List<MentionGroup> groups) {
    final upMid = widget.upMid;
    if (upMid == null || upMid <= 0) {
      return null;
    }
    final uid = upMid.toString();
    for (final group in groups) {
      for (final item in group.items ?? const <MentionItem>[]) {
        if (item.uid == uid) {
          return item;
        }
      }
    }
    return null;
  }
}
