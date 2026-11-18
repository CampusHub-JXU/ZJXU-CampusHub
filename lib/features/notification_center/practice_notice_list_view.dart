import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_status_tag.dart';
import 'notice_group_section.dart';

/// 实践通知的惰性列表视图。
///
/// 完整匹配数据（[itemCount] 条）保存在上层，本视图只构建首屏与已滚动到的
/// 窗口：初始放出 [pageSize]（默认 20）条，滚动接近可见窗口末端时再追加一页，
/// 底层用 [CustomScrollView] + [SliverList.builder] 真正按可视区域惰性构建，
/// 不会一次创建全部 widget，也不再被包在会吞掉惰性构建的分组卡片里。
///
/// 视图不绑定具体通知模型：行内容由 [itemBuilder] 决定，只负责「窗口 + 惰性
/// 滚动 + 顶部计数」，便于实践通知 Tab 复用并保持层级设计不变。
class PracticeNoticeListView extends StatefulWidget {
  const PracticeNoticeListView({
    super.key,
    required this.itemCount,
    required this.headerTitle,
    required this.itemBuilder,
    this.headerTrailing,
    this.onRefresh,
    this.resetKey,
    this.pageSize = defaultPageSize,
    this.onItemBuilt,
  });

  /// 每批放出的行数。
  static const int defaultPageSize = 20;

  /// 匹配结果总数；首屏只构建 [pageSize] 的行。
  final int itemCount;

  /// 固定表头标题（如「全部」/「匹配结果」）。
  final String headerTitle;

  /// 表头右侧计数文案（如「1518 条」）。
  final String? headerTrailing;

  /// 行构建回调，参数为**完整列表中的绝对索引**；只有进入可视窗口才被调用。
  final IndexedWidgetBuilder itemBuilder;

  /// 下拉刷新回调；为 null 时不包 [RefreshIndicator]。
  final Future<void> Function()? onRefresh;

  /// 重置令牌（一般传查询串）：变化时窗口回到首页并滚回顶部。
  final Object? resetKey;

  /// 每批放出的行数（默认 [defaultPageSize]）。
  final int pageSize;

  /// 测试钩子：行构建回调真正被调用时回调该行的绝对索引，用于证明惰性构建
  /// 边界（生产传 null，零开销）。
  @visibleForTesting
  final ValueChanged<int>? onItemBuilt;

  @override
  State<PracticeNoticeListView> createState() => PracticeNoticeListViewState();
}

class PracticeNoticeListViewState extends State<PracticeNoticeListView> {
  /// 触底追加阈值：距列表末端不足该逻辑像素时再放出一页。
  static const double _growThreshold = 320;

  final ScrollController _controller = ScrollController();
  late int _windowSize;
  bool _growScheduled = false;
  bool _fitScheduled = false;

  /// 当前放出的可见窗口大小；测试用。
  @visibleForTesting
  int get debugWindowSize => _windowSize;

  /// 测试钩子：把滚动位置直接移到末端（等价于用户滚动到底部），
  /// 用于确定性地验证「每批 +pageSize」的追加行为。
  @visibleForTesting
  void debugJumpToEnd() {
    if (_controller.hasClients) {
      _controller.jumpTo(_controller.position.maxScrollExtent);
    }
  }

  @override
  void initState() {
    super.initState();
    _windowSize = _initialWindow();
    _controller.addListener(_onScroll);
    _scheduleFitGrow();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PracticeNoticeListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.resetKey != oldWidget.resetKey) {
      // 查询 / 数据变更：窗口回到首屏，滚动位置回到顶部。
      _windowSize = _initialWindow();
      if (_controller.hasClients && _controller.offset != 0) {
        _controller.jumpTo(0);
      }
    } else if (_windowSize > widget.itemCount) {
      _windowSize = widget.itemCount;
    }
    _scheduleFitGrow();
  }

  int _initialWindow() => math.min(widget.pageSize, widget.itemCount);

  void _onScroll() {
    if (!_controller.hasClients) return;
    if (_windowSize >= widget.itemCount) return;
    final position = _controller.position;
    // 接近末端（含到达末端）才追加，避免滚动过程中每帧重建。
    if (position.pixels >= position.maxScrollExtent - _growThreshold) {
      _scheduleGrow();
    }
  }

  /// 内容不足以滚动（首屏行全部可见）时补放，保证更靠后的行仍可达。
  void _scheduleFitGrow() {
    if (_fitScheduled) return;
    _fitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fitScheduled = false;
      if (!mounted || _windowSize >= widget.itemCount) return;
      if (!_controller.hasClients) return;
      if (_controller.position.maxScrollExtent <= 0) _scheduleGrow();
    });
  }

  /// 每帧最多追加一次，且不超过总数：既节流 `setState`，也不会失控翻页。
  void _scheduleGrow() {
    if (_growScheduled) return;
    if (_windowSize >= widget.itemCount) return;
    _growScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _growScheduled = false;
      if (!mounted || _windowSize >= widget.itemCount) return;
      setState(() {
        _windowSize = math.min(_windowSize + widget.pageSize, widget.itemCount);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final visibleCount = math.min(_windowSize, widget.itemCount);
    final slivers = CustomScrollView(
      controller: _controller,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              NoticeListMetrics.pageMargin,
              AppSpacing.listGroupGap / 2,
              NoticeListMetrics.pageMargin,
              AppSpacing.sm,
            ),
            child: NoticeGroupHeader(
              widget.headerTitle,
              trailing: widget.headerTrailing,
            ),
          ),
        ),
        // 真正的惰性构建：只有进入可视区域（含缓存区）的行才会调用 itemBuilder。
        SliverList.builder(
          itemCount: visibleCount,
          itemBuilder: (context, index) {
            widget.onItemBuilt?.call(index);
            return widget.itemBuilder(context, index);
          },
        ),
        const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),
      ],
    );
    final onRefresh = widget.onRefresh;
    if (onRefresh == null) return slivers;
    return RefreshIndicator(onRefresh: onRefresh, child: slivers);
  }
}

/// 实践通知的惰性行：无框、无分隔线、无卡片，只有标题与日期 / 分类。
///
/// 水平边距只保留一层 [NoticeListMetrics.pageMargin]（不再叠加外层 gutter），
/// 标题给到 [NoticeListMetrics.titleMaxLines] 行后省略；点击打开详情
/// （`external-webview`）、长按复制链接的语义由调用方通过
/// [onTap] / [onLongPress] 注入；行本身不依赖通知模型。
class PracticeNoticeRow extends StatelessWidget {
  const PracticeNoticeRow({
    super.key,
    required this.title,
    required this.onTap,
    this.date,
    this.tag,
    this.onLongPress,
  });

  final String title;
  final String? date;
  final String? tag;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final publishDate = (date ?? '').trim();
    final showTag = (tag ?? '').trim().isNotEmpty;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: NoticeListMetrics.minRowHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NoticeListMetrics.pageMargin,
            vertical: NoticeListMetrics.rowVerticalPadding,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: text.rowTitle.copyWith(height: 1.4, color: cs.onSurface),
                maxLines: NoticeListMetrics.titleMaxLines,
                overflow: TextOverflow.ellipsis,
              ),
              if (publishDate.isNotEmpty || showTag) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (publishDate.isNotEmpty)
                      Flexible(
                        child: Text(
                          publishDate,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.secondary.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    if (showTag) ...[
                      if (publishDate.isNotEmpty) const SizedBox(width: 8),
                      AppStatusTag(tag!),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
