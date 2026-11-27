import 'dart:async';

import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/external_url_launcher.dart';
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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const AppAppBar(title: Text('意见反馈')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('无需 GitHub 账号即可提交。反馈公开发布到 GitHub Issue，回复和处理进度在 GitHub 查看。'),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () async {
            await context.pushNamed('feedback-new');
            await _load();
          },
          icon: const Icon(Icons.edit_outlined),
          label: const Text('提交反馈'),
        ),
        const SizedBox(height: 16),
        Text('本机提交记录', style: Theme.of(context).textTheme.titleMedium),
        const Text('仅保存提交成功的 Issue 链接。卸载、清除数据或换机后不会恢复。补充截图或评论需要登录 GitHub。'),
        if (busy) const LinearProgressIndicator(),
        if (error != null) Text(error!),
        if (items.isEmpty && !busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('暂无提交记录'),
          ),
        for (final item in items)
          ListTile(
            leading: const Icon(Icons.open_in_new),
            title: Text(item['title'] as String),
            subtitle: Text('#${item['number']} · 在 GitHub 查看回复与进度'),
            onTap: () =>
                openInExternalBrowser(item['url'] as String, logPrefix: '问题反馈'),
            trailing: IconButton(
              tooltip: '复制 Issue 链接',
              icon: const Icon(Icons.copy_outlined),
              onPressed: () async {
                try {
                  await Clipboard.setData(
                    ClipboardData(text: item['url'] as String),
                  );
                  if (context.mounted) {
                    AppFeedback.toast(context, '已复制 Issue 链接');
                  }
                } on PlatformException {
                  if (context.mounted) AppFeedback.toast(context, '复制失败，请重试');
                }
              },
            ),
          ),
      ],
    ),
  );
}
