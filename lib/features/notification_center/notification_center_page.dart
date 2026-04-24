import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../notice/notice_model.dart';
import '../notice/notice_service.dart';
import '../sjjx_notice/sjjx_notice_model.dart';
import '../sjjx_notice/sjjx_notice_service.dart';
import '../../core/logging/app_logger.dart';

class NotificationCenterPage extends StatefulWidget {
  const NotificationCenterPage({super.key});

  @override
  State<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends State<NotificationCenterPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('通知中心'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '校园公告'),
            Tab(text: '实践通知'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [_CampusNoticeTab(), _PracticeNoticeTab()],
      ),
    );
  }
}

// --- Campus notices tab ---

class _CampusNoticeTab extends StatefulWidget {
  const _CampusNoticeTab();

  @override
  State<_CampusNoticeTab> createState() => _CampusNoticeTabState();
}

class _CampusNoticeTabState extends State<_CampusNoticeTab>
    with AutomaticKeepAliveClientMixin {
  List<Notice> _notices = [];
  bool _loading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final notices = await NoticeService.instance.fetchNotices();
      if (!mounted) return;
      setState(() {
        _notices = notices;
        _loading = false;
      });
    } catch (e, st) {
      AppLogger.instance.ui(
        LogLevel.error,
        '通知中心-校园公告加载失败',
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      setState(() {
        _error = '加载失败';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: Colors.grey[500])),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_notices.isEmpty) {
      return Center(
        child: Text('暂无校园公告', style: TextStyle(color: Colors.grey[500])),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: _notices.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final notice = _notices[index];
          return _buildNoticeTile(
            context,
            tag: notice.category,
            tagColor: notice.category == '通知公告'
                ? const Color(0xFF1565C0)
                : Colors.red,
            title: notice.title,
            date: notice.date,
            onTap: () => context.pushNamed(
              'external-webview',
              extra: {
                'title': notice.title,
                'url': notice.url,
                'emulateDingTalkEnvironment': false,
                'requireUnifiedAuthProtection': _shouldOpenViaUnifiedAuth(
                  notice.url,
                ),
                'serviceUrl': notice.url,
                'loginDescription': '通知公告可直连访问，但需先完成统一认证',
                'showWebViewBottomBackButton': true,
              },
            ),
          );
        },
      ),
    );
  }
}

// --- Practice notices tab ---

class _PracticeNoticeTab extends StatefulWidget {
  const _PracticeNoticeTab();

  @override
  State<_PracticeNoticeTab> createState() => _PracticeNoticeTabState();
}

class _PracticeNoticeTabState extends State<_PracticeNoticeTab>
    with AutomaticKeepAliveClientMixin {
  List<SjjxNotice> _notices = [];
  bool _loading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final notices = await SjjxNoticeService.instance.fetchAllNotices();
      if (!mounted) return;
      setState(() {
        _notices = notices;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载失败';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: Colors.grey[500])),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_notices.isEmpty) {
      return Center(
        child: Text('暂无实践通知', style: TextStyle(color: Colors.grey[500])),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: _notices.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final notice = _notices[index];
          final colorValue = SjjxNotice.categoryColors[notice.category];
          return _buildNoticeTile(
            context,
            tag: notice.category,
            tagColor: colorValue != null
                ? Color(colorValue)
                : const Color(0xFF757575),
            title: notice.title,
            date: notice.date,
            onTap: () => context.pushNamed(
              'external-webview',
              extra: {
                'title': notice.title,
                'url': notice.url,
                'emulateDingTalkEnvironment': false,
              },
            ),
          );
        },
      ),
    );
  }
}

// --- Shared tile ---

Widget _buildNoticeTile(
  BuildContext context, {
  required String tag,
  required Color tagColor,
  required String title,
  required String? date,
  required VoidCallback onTap,
}) {
  final cs = Theme.of(context).colorScheme;
  final publishDate = (date ?? '').trim();
  return Material(
    color: cs.surface,
    borderRadius: BorderRadius.circular(12),
    elevation: 0.5,
    shadowColor: Colors.black12,
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: tagColor,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                tag,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontSize: 15),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (publishDate.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      publishDate,
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 20, color: Colors.grey[400]),
          ],
        ),
      ),
    ),
  );
}

bool _shouldOpenViaUnifiedAuth(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return uri.host.toLowerCase() == 'jwc.zjxu.edu.cn';
}
