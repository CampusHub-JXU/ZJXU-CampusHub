import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/cas_auth_broker.dart';
import '../../core/notice/notice_fetch_service.dart';
import '../../core/notice/notice_model.dart';
import '../../core/notice/notice_relevance.dart';
import '../../core/notice/notice_sync_service.dart';
import '../../core/notice/notice_sync_store.dart';
import '../../core/profile/user_profile_controller.dart';
import '../sjjx_notice/sjjx_notice_model.dart';
import '../sjjx_notice/sjjx_notice_service.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/app_search_field.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/login_shell.dart';

class NotificationCenterPage extends StatefulWidget {
  const NotificationCenterPage({super.key});

  @override
  State<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends State<NotificationCenterPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(
        title: const Text('通知中心'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '校园公告'),
            Tab(text: '实践通知'),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: AppSearchField(
              controller: _searchController,
              hintText: '搜索标题、类型或日期',
              onChanged: (value) => setState(() => _query = value),
              onClear: () => setState(() {
                _searchController.clear();
                _query = '';
              }),
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _CampusNoticeTab(query: _query),
                _PracticeNoticeTab(query: _query),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 通知过滤：标题 / 类型 / 日期任一字段命中即保留（大小写不敏感）。
bool _noticeMatchesQuery(String? text, String query) {
  if (query.isEmpty) return true;
  final value = (text ?? '').trim().toLowerCase();
  return value.contains(query);
}

// --- Campus notices tab ---

class _CampusNoticeTab extends StatefulWidget {
  const _CampusNoticeTab({this.query = ''});

  final String query;

  @override
  State<_CampusNoticeTab> createState() => _CampusNoticeTabState();
}

class _CampusNoticeTabState extends State<_CampusNoticeTab>
    with AutomaticKeepAliveClientMixin {
  List<Notice> _notices = const [];
  Set<String> _unreadIds = const {};
  bool _loading = true;
  bool _authRequired = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    NoticeSyncStore.instance.unreadSummary.addListener(_onStoreChanged);
    _reloadFromDisk();
  }

  @override
  void dispose() {
    NoticeSyncStore.instance.unreadSummary.removeListener(_onStoreChanged);
    super.dispose();
  }

  /// 收件箱数据源是磁盘状态：进页面先无条件重载（后台 isolate 可能刚
  /// 写入过新通知，且 reload 不受网络节流影响），此后的写操作经
  /// unreadSummary 通知回流刷新。
  Future<void> _reloadFromDisk() async {
    await NoticeSyncStore.instance.reload();
    if (!mounted) return;
    _applySnapshot();
    setState(() => _loading = false);
  }

  void _onStoreChanged() {
    if (!mounted) return;
    _applySnapshot();
  }

  void _applySnapshot() {
    final snapshot = NoticeSyncStore.instance.state;
    setState(() {
      // 收件箱本身已按日期倒序；再按用户年级把明确不相关的沉底。
      _notices = NoticeRelevance.orderByRelevanceThenDate(
        snapshot.inbox,
        UserProfileController.instance.effectiveEnrollmentYear,
      );
      _unreadIds = Set<String>.of(snapshot.unreadIds);
    });
  }

  /// 手动刷新：force 同步（绕过时间节流、不弹系统通知）后重载收件箱。
  /// 同步结果中的认证失效要显式呈现——收件箱有历史数据时不能只表现为
  /// 「刷新没反应」。
  Future<void> _refresh() async {
    try {
      final outcome = await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.manualRefresh,
      );
      if (!mounted) return;
      setState(() {
        _authRequired =
            !outcome.skipped &&
            outcome.fetchStatus == NoticeFetchStatus.authRequired;
      });
    } finally {
      await NoticeSyncStore.instance.reload();
    }
  }

  Future<void> _presentLoginPrompt() async {
    final ok = await showUnifiedAuthLoginModal(
      context,
      title: '登录统一认证',
      description: '登录后可同步教务处通知公告',
    );
    if (!ok || !mounted) return;
    final outcome = await NoticeSyncService.instance.sync(
      trigger: NoticeSyncTrigger.afterLogin,
    );
    if (!mounted) return;
    setState(() {
      _authRequired =
          !outcome.skipped &&
          outcome.fetchStatus == NoticeFetchStatus.authRequired;
    });
    await NoticeSyncStore.instance.reload();
  }

  Future<void> _markAllRead() => NoticeSyncStore.instance.markAllRead();

  void _openNotice(Notice notice) {
    if (_unreadIds.contains(notice.id)) {
      unawaited(NoticeSyncStore.instance.markRead([notice.id]));
    }
    context.pushNamed(
      'external-webview',
      extra: {
        'title': notice.title,
        'url': notice.url,
        'emulateDingTalkEnvironment': false,
        'requireUnifiedAuthProtection': shouldOpenCampusNoticeViaUnifiedAuth(
          notice.url,
        ),
        'serviceUrl': notice.url,
        'loginDescription': '通知公告可直连访问，但需先完成统一认证',
        'showWebViewBottomBackButton': true,
        'warmUpAsResource': true,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_notices.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          children: const [
            SizedBox(height: 120),
            AppEmptyView(title: '暂无校园公告\n下拉刷新拉取', icon: Icons.article_outlined),
          ],
        ),
      );
    }
    final unreadCount = _unreadIds.length;
    final showAuthBanner = _authRequired;
    final query = widget.query.trim().toLowerCase();
    final visibleNotices = query.isEmpty
        ? _notices
        : _notices
              .where(
                (notice) =>
                    _noticeMatchesQuery(notice.title, query) ||
                    _noticeMatchesQuery(notice.category, query) ||
                    _noticeMatchesQuery(notice.date, query),
              )
              .toList();
    final showHeader = query.isEmpty;
    if (visibleNotices.isEmpty && query.isNotEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          children: const [
            SizedBox(height: 120),
            AppEmptyView(title: '没有匹配的通知', icon: Icons.search_off_rounded),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount:
            visibleNotices.length +
            (showHeader ? 1 : 0) +
            (showAuthBanner ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (showAuthBanner && index == 0) {
            return _AuthStaleBanner(onLoginTap: _presentLoginPrompt);
          }
          var headerIndex = showAuthBanner ? index - 1 : index;
          if (showHeader) {
            if (headerIndex == 0) {
              return Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: unreadCount == 0 ? null : _markAllRead,
                  child: Text(unreadCount > 0 ? '全部已读（$unreadCount）' : '全部已读'),
                ),
              );
            }
            headerIndex--;
          }
          final notice = visibleNotices[headerIndex];
          return _buildNoticeTile(
            context,
            tag: notice.category,
            tagColor: notice.category == '通知公告' ? cs.primary : cs.error,
            title: notice.title,
            date: notice.date,
            unread: _unreadIds.contains(notice.id),
            onTap: () => _openNotice(notice),
          );
        },
      ),
    );
  }
}

// --- Practice notices tab ---

class _PracticeNoticeTab extends StatefulWidget {
  const _PracticeNoticeTab({this.query = ''});

  final String query;

  @override
  State<_PracticeNoticeTab> createState() => _PracticeNoticeTabState();
}

class _PracticeNoticeTabState extends State<_PracticeNoticeTab>
    with AutomaticKeepAliveClientMixin {
  List<SjjxNotice> _notices = [];
  bool _loading = true;
  bool _authRequired = false;
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
      _authRequired = false;
    });
    try {
      final notices = await SjjxNoticeService.instance.fetchAllNotices();
      if (!mounted) return;
      setState(() {
        _notices = notices;
        _loading = false;
      });
    } on CasAuthExpiredException {
      if (!mounted) return;
      setState(() {
        _authRequired = true;
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

  Future<void> _presentLoginPrompt() async {
    final ok = await showUnifiedAuthLoginModal(
      context,
      title: '登录统一认证',
      description: '登录后可查看实践通知',
    );
    if (ok && mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_authRequired) {
      return AuthRequiredView(
        title: '登录后查看实践通知',
        message: '实践通知需要统一认证会话（校外经 WebVPN 访问），登录后即可刷新。',
        buttonLabel: '登录统一认证',
        onAction: _presentLoginPrompt,
        icon: Icons.sports_kabaddi_outlined,
      );
    }
    if (_error != null) {
      return AppErrorView(title: _error!, onRetry: _load);
    }
    if (_notices.isEmpty) {
      return const AppEmptyView(title: '暂无实践通知', icon: Icons.article_outlined);
    }
    final query = widget.query.trim().toLowerCase();
    final visibleNotices = query.isEmpty
        ? _notices
        : _notices
              .where(
                (notice) =>
                    _noticeMatchesQuery(notice.title, query) ||
                    _noticeMatchesQuery(notice.category, query) ||
                    _noticeMatchesQuery(notice.date, query),
              )
              .toList();
    if (visibleNotices.isEmpty) {
      return const AppEmptyView(
        title: '没有匹配的通知',
        icon: Icons.search_off_rounded,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: visibleNotices.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final notice = visibleNotices[index];
          return _buildNoticeTile(
            context,
            tag: notice.category,
            tagColor: _sjjxCategoryColor(notice.category, cs),
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
  bool unread = false,
}) {
  final cs = Theme.of(context).colorScheme;
  final publishDate = (date ?? '').trim();
  final tagForeground = _contrastOn(tagColor);
  return Material(
    color: cs.surfaceContainerLowest,
    borderRadius: BorderRadius.circular(12),
    elevation: 0.5,
    shadowColor: cs.shadow.withValues(alpha: 0.12),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            if (unread) ...[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: cs.primary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
            ],
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: tagColor,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                tag,
                style: TextStyle(
                  color: tagForeground,
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
                    style: TextStyle(fontSize: 15, color: cs.onSurface),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (publishDate.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      publishDate,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 20, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    ),
  );
}

bool shouldOpenCampusNoticeViaUnifiedAuth(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return uri.host.toLowerCase() == 'jwc.zjxu.edu.cn';
}

/// 收件箱有历史数据但刷新时认证失效：列表照常展示，顶部提示登录恢复。
class _AuthStaleBanner extends StatelessWidget {
  const _AuthStaleBanner({required this.onLoginTap});

  final VoidCallback onLoginTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.errorContainer.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.lock_outline, size: 16, color: cs.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '统一认证已失效，以下为缓存内容，登录后恢复同步',
                style: TextStyle(fontSize: 13, color: cs.onErrorContainer),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: onLoginTap,
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: const Text('登录'),
            ),
          ],
        ),
      ),
    );
  }
}

Color _sjjxCategoryColor(String category, ColorScheme cs) {
  final index = SjjxNotice.categoryOrder.indexOf(category);
  final hueOffset = index < 0 ? category.hashCode.abs() % 360 : index * 38.0;
  final hsl = HSLColor.fromColor(cs.primary);
  final isDark = cs.brightness == Brightness.dark;
  return hsl
      .withHue((hsl.hue + hueOffset) % 360.0)
      .withSaturation((hsl.saturation * 0.86).clamp(0.42, 0.92))
      .withLightness(isDark ? 0.66 : 0.42)
      .toColor();
}

Color _contrastOn(Color background) {
  return background.computeLuminance() > 0.45 ? Colors.black : Colors.white;
}
