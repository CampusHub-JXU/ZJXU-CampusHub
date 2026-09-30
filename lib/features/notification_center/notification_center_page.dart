import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/cas_auth_broker.dart';
import '../../core/notice/notice_detail.dart';
import '../../core/notice/notice_fetch_service.dart';
import '../../core/notice/notice_model.dart';
import '../../core/notice/notice_relevance.dart';
import '../../core/notice/notice_sync_service.dart';
import '../../core/notice/notice_sync_store.dart';
import '../../core/profile/user_profile_controller.dart';
import '../sjjx_notice/sjjx_notice_model.dart';
import '../sjjx_notice/sjjx_notice_service.dart';
import 'campus_notice_site_search.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/app_search_field.dart';
import '../../shared/widgets/copy_text_feedback.dart';
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
  bool _searchOpen = false;
  int _unreadCount = NoticeSyncStore.instance.unreadSummary.value.count;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
    NoticeSyncStore.instance.unreadSummary.addListener(_onUnreadChanged);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    NoticeSyncStore.instance.unreadSummary.removeListener(_onUnreadChanged);
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) setState(() {});
  }

  void _onUnreadChanged() {
    if (!mounted) return;
    setState(() {
      _unreadCount = NoticeSyncStore.instance.unreadSummary.value.count;
    });
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _searchController.clear();
        _query = '';
      }
    });
  }

  Future<void> _markAllRead() => NoticeSyncStore.instance.markAllRead();

  @override
  Widget build(BuildContext context) {
    final canMarkAllRead = _tabController.index == 0 && _unreadCount > 0;
    return Scaffold(
      appBar: AppAppBar(
        centerTitle: _searchOpen ? false : null,
        titleSpacing: _searchOpen ? 0 : null,
        title: _searchOpen
            ? AppSearchField(
                controller: _searchController,
                hintText: '搜索标题、类型或日期',
                compact: true,
                autofocus: true,
                onChanged: (value) => setState(() => _query = value),
                onClear: () => setState(() {
                  _searchController.clear();
                  _query = '';
                }),
              )
            : const Text(
                '通知',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
        actions: [
          IconButton(
            onPressed: _toggleSearch,
            tooltip: _searchOpen ? '关闭搜索' : '搜索',
            icon: Icon(
              _searchOpen ? Icons.close_rounded : Icons.search_rounded,
            ),
          ),
          IconButton(
            onPressed: canMarkAllRead ? _markAllRead : null,
            tooltip: '全部标为已读',
            icon: const Icon(Icons.done_all_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: _NoticeTabPills(
              controller: _tabController,
              unreadCount: _unreadCount,
            ),
          ),
          const SizedBox(height: 8),
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

/// 两颗胶囊 Tab：校园公告（带未读数）/ 实践通知。
class _NoticeTabPills extends StatelessWidget {
  const _NoticeTabPills({required this.controller, required this.unreadCount});

  final TabController controller;
  final int unreadCount;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Row(
          children: [
            _NoticePillChip(
              label: unreadCount > 0 ? '校园公告 · $unreadCount' : '校园公告',
              selected: controller.index == 0,
              onTap: () => controller.animateTo(0),
            ),
            const SizedBox(width: 8),
            _NoticePillChip(
              label: '实践通知',
              selected: controller.index == 1,
              onTap: () => controller.animateTo(1),
            ),
          ],
        );
      },
    );
  }
}

class _NoticePillChip extends StatelessWidget {
  const _NoticePillChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? cs.primary.withValues(alpha: 0.14)
          : cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: selected ? cs.primary : cs.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
        ),
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

  /// 收件箱之外的更早通知：在线分页拉取，只在内存里展示——不写收件箱，
  /// 否则会污染未读与待播报队列。收件箱通常覆盖前两页，分页从第 2 页起，
  /// 与收件箱重叠的条目按 id 去重。
  List<Notice> _older = const [];
  int _nextPage = _olderFirstPage;
  bool _hasMore = true;
  bool _loadingMore = false;
  bool _loadMoreFailed = false;
  int _olderEpoch = 0;

  static const int _olderFirstPage = 2;

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
    _resetOlder();
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

  void _resetOlder() {
    _olderEpoch++;
    if (!mounted) return;
    setState(() {
      _older = const [];
      _nextPage = _olderFirstPage;
      _hasMore = true;
      _loadingMore = false;
      _loadMoreFailed = false;
    });
  }

  /// 滚动到列表底部时由页脚触发：抓取下一页并去重追加。
  /// 刷新 / 登录会推进 epoch，迟到的旧结果直接丢弃。
  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final epoch = _olderEpoch;
    final page = _nextPage;
    setState(() {
      _loadingMore = true;
      _loadMoreFailed = false;
    });
    final result = await NoticeService.instance.fetchNoticesRaw(page: page);
    if (!mounted || epoch != _olderEpoch) return;
    switch (result.status) {
      case NoticeFetchStatus.ok:
        final seen = <String>{
          for (final n in _notices) n.id,
          for (final n in _older) n.id,
        };
        final fresh = [
          for (final n in result.notices)
            if (seen.add(n.id)) n,
        ];
        final totalPages = result.totalPages;
        setState(() {
          _older = [..._older, ...fresh];
          _nextPage = page + 1;
          _hasMore =
              result.notices.isNotEmpty &&
              (totalPages == null || page < totalPages);
          _loadingMore = false;
        });
      case NoticeFetchStatus.authRequired:
        setState(() {
          _authRequired = true;
          _loadMoreFailed = true;
          _loadingMore = false;
        });
      case NoticeFetchStatus.unavailable:
        setState(() {
          _loadMoreFailed = true;
          _loadingMore = false;
        });
    }
  }

  Future<void> _presentLoginPrompt() async {
    final ok = await showUnifiedAuthLoginModal(
      context,
      title: '登录统一认证',
      description: '登录后可同步教务处通知公告',
    );
    if (!ok || !mounted) return;
    _resetOlder();
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

  void _openNotice(Notice notice) {
    if (_unreadIds.contains(notice.id)) {
      unawaited(NoticeSyncStore.instance.markRead([notice.id]));
    }
    if (isJwcNoticeDetailUrl(notice.url)) {
      context.pushNamed(
        'notice-detail',
        extra: {'title': notice.title, 'url': notice.url},
      );
      return;
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

  Widget _tileFor(Notice notice) => _NoticeTile(
    title: notice.title,
    date: notice.date,
    unread: _unreadIds.contains(notice.id),
    onTap: () => _openNotice(notice),
    onLongPress: () => copyTextWithFeedback(context, notice.url),
  );

  /// 搜索态：先列本地收件箱命中（最近同步的一批，零延迟），再接教务处
  /// 站内全文检索补齐更早的通知（去重）。
  Widget _buildSearchResults(String query) {
    final local = _notices
        .where(
          (notice) =>
              _noticeMatchesQuery(notice.title, query) ||
              _noticeMatchesQuery(notice.category, query) ||
              _noticeMatchesQuery(notice.date, query),
        )
        .toList(growable: false);
    final divider = Divider(
      height: 1,
      thickness: 1,
      indent: 28,
      color: Theme.of(context).colorScheme.outlineVariant
          .withValues(alpha: 0.25),
    );
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        if (local.isNotEmpty) ...[
          CampusNoticeSectionLabel('最近通知', trailing: '${local.length} 条'),
          for (var i = 0; i < local.length; i++) ...[
            if (i > 0) divider,
            _tileFor(local[i]),
          ],
        ],
        CampusNoticeSiteSearch(
          query: widget.query,
          excludeIds: {for (final n in local) n.id},
          tileBuilder: _tileFor,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    final query = widget.query.trim().toLowerCase();
    if (query.isNotEmpty) return _buildSearchResults(query);
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
    final showAuthBanner = _authRequired;
    final visibleNotices = [..._notices, ..._older];
    final bannerCount = showAuthBanner ? 1 : 0;
    final footerCount = _hasMore || _loadMoreFailed ? 1 : 0;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: bannerCount + visibleNotices.length + footerCount,
        separatorBuilder: (_, index) {
          if (showAuthBanner && index == 0) return const SizedBox.shrink();
          return Divider(
            height: 1,
            thickness: 1,
            indent: 28,
            color: Theme.of(context).colorScheme.outlineVariant
                .withValues(alpha: 0.25),
          );
        },
        itemBuilder: (context, index) {
          if (showAuthBanner && index == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: _AuthStaleBanner(onLoginTap: _presentLoginPrompt),
            );
          }
          final noticeIndex = index - bannerCount;
          if (noticeIndex >= visibleNotices.length) {
            return _buildLoadMoreFooter();
          }
          return _tileFor(visibleNotices[noticeIndex]);
        },
      ),
    );
  }

  /// 列表页脚：惰性构建即「滚到底部」，此时自动拉下一页；失败后停止自动
  /// 重试，改为点击重试，避免断网时反复请求。
  Widget _buildLoadMoreFooter() {
    if (_loadMoreFailed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: TextButton(
            onPressed: _authRequired ? _presentLoginPrompt : _loadMore,
            child: Text(_authRequired ? '登录后加载更早通知' : '加载失败，点击重试'),
          ),
        ),
      );
    }
    if (!_loadingMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadMore());
      });
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
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
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: visibleNotices.length,
        separatorBuilder: (_, _) => Divider(
          height: 1,
          thickness: 1,
          indent: 28,
          color: cs.outlineVariant.withValues(alpha: 0.25),
        ),
        itemBuilder: (context, index) {
          final notice = visibleNotices[index];
          return _NoticeTile(
            title: notice.title,
            date: notice.date,
            tag: notice.category,
            tagColor: _sjjxCategoryColor(notice.category, cs),
            onTap: () => context.pushNamed(
              'external-webview',
              extra: {
                'title': notice.title,
                'url': notice.url,
                'emulateDingTalkEnvironment': false,
              },
            ),
            onLongPress: () => copyTextWithFeedback(context, notice.url),
          );
        },
      ),
    );
  }
}

// --- Shared tile ---

/// 无卡片、无边框的通知行：未读圆点 + 标题 + 日期，例外标签（如分类差异明显
/// 的实践通知）才追加小色块；「每条都一样」的标签（如校园公告固定的
/// 「通知公告」）不再展示。
class _NoticeTile extends StatelessWidget {
  const _NoticeTile({
    required this.title,
    required this.date,
    required this.onTap,
    this.onLongPress,
    this.unread = false,
    this.tag,
    this.tagColor,
  });

  final String title;
  final String? date;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool unread;
  final String? tag;
  final Color? tagColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final publishDate = (date ?? '').trim();
    final showTag = (tag ?? '').trim().isNotEmpty;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 8,
              child: unread
                  ? Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: cs.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.45,
                      fontWeight: unread ? FontWeight.w500 : FontWeight.w400,
                      color: unread ? cs.onSurface : cs.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        publishDate,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      if (showTag) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: (tagColor ?? cs.tertiary).withValues(
                              alpha: 0.16,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            tag!,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: tagColor ?? cs.tertiary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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
