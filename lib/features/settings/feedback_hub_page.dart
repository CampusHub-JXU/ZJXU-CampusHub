import 'dart:async';

import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_banner.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/app_icon_badge.dart';
import '../../shared/widgets/app_status_tag.dart';
import '../../shared/widgets/external_url_launcher.dart';
import '../../shared/widgets/plain_list.dart';
import '../../shared/widgets/refresh_status_line.dart';
import 'feedback_service.dart';
import 'feedback_store.dart';

class FeedbackHubPage extends StatefulWidget {
  const FeedbackHubPage({super.key, this.store});
  final FeedbackStore? store;

  @override
  State<FeedbackHubPage> createState() => _FeedbackHubPageState();
}

class _FeedbackHubPageState extends State<FeedbackHubPage> {
  late final store = widget.store ?? FeedbackStore.instance;
  List<Map<String, Object?>> items = [];
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (busy || !mounted) return;
    setState(() => busy = true);
    try {
      final loaded = await store.submissions();
      if (mounted) {
        setState(() {
          items = loaded;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '无法读取本机记录，仍可提交反馈。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _copyIssueUrl(String url) async {
    try {
      await Clipboard.setData(ClipboardData(text: url));
      if (mounted) AppFeedback.toast(context, '已复制 Issue 链接');
    } on PlatformException {
      if (mounted) AppFeedback.toast(context, '复制失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    return Scaffold(
      appBar: const AppAppBar(title: Text('意见反馈')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          kPlainListGutter,
          AppSpacing.sm,
          kPlainListGutter,
          AppSpacing.xl,
        ),
        children: [
          PlainListGroup(
            children: [
              PlainListRow(
                leading: AppIconBadge(
                  icon: Icons.edit_outlined,
                  accentColor: cs.primary,
                  size: AppIconBadgeSize.small,
                ),
                title: '提交新反馈',
                onTap: () async {
                  await context.pushNamed('feedback-new');
                  await _load();
                },
              ),
              PlainListRow(
                leading: AppIconBadge(
                  icon: Icons.open_in_new_rounded,
                  accentColor: cs.secondary,
                  size: AppIconBadgeSize.small,
                ),
                title: '查看 GitHub 反馈列表',
                onTap: () => openInExternalBrowser(
                  FeedbackService.githubIssuesUrl,
                  logPrefix: '问题反馈',
                ),
              ),
            ],
          ),
          const SizedBox(height: kPlainListGroupGap),
          const PlainSectionHeader('本机提交记录'),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.sm),
              child: RefreshStatusLine(
                refreshing: true,
                loadingLabel: '正在读取本机记录…',
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: AppBanner(
                message: error!,
                icon: Icons.info_outline_rounded,
                tone: AppBannerTone.neutral,
              ),
            ),
          PlainListGroup(
            children: [
              if (items.isEmpty && !busy)
                const PlainListRow(title: '暂无提交记录', showChevron: false)
              else
                for (final item in items)
                  PlainListRow(
                    title: item['title'] as String,
                    subtitle: '#${item['number']}',
                    onTap: () => openInExternalBrowser(
                      item['url'] as String,
                      logPrefix: '问题反馈',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const AppStatusTag('已提交', tone: AppStatusTone.positive),
                        const SizedBox(width: AppSpacing.xs),
                        IconButton(
                          tooltip: '复制 Issue 链接',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.copy_outlined, size: 18),
                          onPressed: () => _copyIssueUrl(item['url'] as String),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: Text(
              '仅保存提交成功的 Issue 链接；补充截图或评论需登录 GitHub。',
              style: text.meta,
            ),
          ),
        ],
      ),
    );
  }
}
