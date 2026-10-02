import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/plain_list.dart';

/// 通知页的分组：灰色小标题（可带右侧计数）+ squircle 圆角卡片。
///
/// 与设置 / 体测等页面同一套 [PlainListGroup] 卡面，左右留 [AppSpacing.listGutter]，
/// 分组之间留 [AppSpacing.listGroupGap]。
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
        AppSpacing.listGutter,
        AppSpacing.listGroupGap / 2,
        AppSpacing.listGutter,
        AppSpacing.listGroupGap / 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NoticeGroupHeader(title, trailing: trailing),
          PlainListGroup(children: children),
        ],
      ),
    );
  }
}

/// 分组小标题：左缘贴齐卡片边缘，右侧可带灰色计数。
class NoticeGroupHeader extends StatelessWidget {
  const NoticeGroupHeader(this.title, {super.key, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final style = context.appText.label;
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Expanded(child: Text(title, style: style)),
            if (trailing != null) Text(trailing!, style: style),
          ],
        ),
      ),
    );
  }
}
