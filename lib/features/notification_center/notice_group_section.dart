import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';

/// 通知列表的无框行内指标（feature-local）。
///
/// 通知页不再复用设置页的 squircle 分组卡面（`PlainListGroup`，见
/// `lib/shared/widgets/plain_list.dart`）：公告 / 实践通知 / 站内搜索的列表
/// 直接落在页面底色上，用间距、字重与日期组织内容。这里集中定义单层页边距、
/// 未读标记列宽度、行高与标题行数上限，供校园公告行、实践通知行与站内搜索行
/// 共用，避免「外层 listGutter + 行内 inset」两重水平缩进叠加。
abstract final class NoticeListMetrics {
  /// 页面边缘**唯一**的水平安全边距（约 16dp），不再叠加第二层 inset。
  static const double pageMargin = AppSpacing.pageMargin;

  /// 未读圆点列的固定宽度：读 / 未读标题首字对齐，圆点本身占最小宽度。
  static const double markerWidth = 12;

  /// 行上下内边距。
  static const double rowVerticalPadding = 12;

  /// 整行最小点按高度（整行可点 / 长按）。
  static const double minRowHeight = 48;

  /// 标题最多行数：长中文标题给到 3 行，仍是有界高度，不会撑成巨型单项。
  static const int titleMaxLines = 3;
}

/// 通知页的分组：灰色小标题（可带右侧计数）+ **无框**通知行。
///
/// 与设置 / 体测等页面不同，通知列表不套 `PlainListGroup` 卡面——外层只保留
/// 一层 [NoticeListMetrics.pageMargin] 水平边距，分组之间以
/// [AppSpacing.listGroupGap] 留白分隔。分组标题仍以 header 语义暴露给读屏。
class NoticeGroupSection extends StatelessWidget {
  const NoticeGroupSection({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
  });

  final String title;
  final String? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NoticeListMetrics.pageMargin,
        AppSpacing.listGroupGap / 2,
        NoticeListMetrics.pageMargin,
        AppSpacing.listGroupGap / 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NoticeGroupHeader(
            title,
            trailing: trailing,
            leadingGap: NoticeListMetrics.markerWidth,
          ),
          ...children,
        ],
      ),
    );
  }
}

/// 分组小标题：与行标题同一条左缘，右侧可带灰色计数。
class NoticeGroupHeader extends StatelessWidget {
  const NoticeGroupHeader(
    this.title, {
    super.key,
    this.trailing,
    this.leadingGap = 0,
  });

  final String title;
  final String? trailing;

  /// 标题左侧预留的空列宽度：传入 [NoticeListMetrics.markerWidth] 即可与带
  /// 未读标记列的行标题首字对齐；没有标记列的列表（实践通知）保持 0。
  final double leadingGap;

  @override
  Widget build(BuildContext context) {
    final style = context.appText.label;
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            if (leadingGap > 0) SizedBox(width: leadingGap),
            Expanded(child: Text(title, style: style)),
            if (trailing != null) Text(trailing!, style: style),
          ],
        ),
      ),
    );
  }
}
