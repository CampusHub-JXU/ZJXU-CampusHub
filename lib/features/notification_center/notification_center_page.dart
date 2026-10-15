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
import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../sjjx_notice/sjjx_notice_model.dart';
import '../sjjx_notice/sjjx_notice_service.dart';
import 'campus_notice_site_search.dart';
import 'notice_group_section.dart';
import 'practice_notice_list_view.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_banner.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/app_filter_chips.dart';
import '../../shared/widgets/app_search_field.dart';
import '../../shared/widgets/copy_text_feedback.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/login_shell.dart';

class NotificationCenterPage extends StatefulWidget {
  const NotificationCenterPage({
    super.key,
    this.practiceNoticeLoader,
    this.debugOnPracticeTabReady,
  });

  /// 实践通知数据源。为 null 时用
  /// [SjjxNoticeService.instance.fetchAllNotices]（真实抓取，走 CAS/WebVPN）。
  /// 测试可注入合成数据，避免请求真实校园环境。
  final Future<List<SjjxNotice>> Function()? practiceNoticeLoader;

  /// 测试钩子：实践通知 Tab 挂载后回传它的重新加载入口，用于确定性地驱动
  /// 同一次挂载内的多次 `_load`（验证迟到结果不覆盖新结果）。生产传 null。
  @visibleForTesting
  final void Function(Future<void> Function() reload)? debugOnPracticeTabReady;

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
            : const Text('通知'),
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
            padding: const EdgeInsets.only(top: 12, bottom: 4),
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
                _PracticeNoticeTab(
                  query: _query,
                  loader: widget.practiceNoticeLoader,
                  onReady: widget.debugOnPracticeTabReady,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 两颗 chip：校园公告（带未读数）/ 实践通知，用共享的 [AppFilterChips]。
class _NoticeTabPills extends StatelessWidget {
  const _NoticeTabPills({required this.controller, required this.unreadCount});

  final TabController controller;
  final int unreadCount;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return AppFilterChips<int>(
          options: [
            AppFilterOption(
              0,
              unreadCount > 0 ? '校园公告 · $unreadCount' : '校园公告',
            ),
            const AppFilterOption(1, '实践通知'),
          ],
          selected: controller.index,
          onSelected: controller.animateTo,
        );
      },
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
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        if (local.isNotEmpty)
          NoticeGroupSection(
            title: '最近通知',
            trailing: '${local.length} 条',
            children: [for (final n in local) _tileFor(n)],
          ),
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
    // 圆角分组卡片：未读 / 最近（收件箱其余）/ 更早（在线分页），与设置、
    // 体测等页面同一套 squircle 卡面，不再用通栏分隔线。
    final unread = [
      for (final n in _notices)
        if (_unreadIds.contains(n.id)) n,
    ];
    final read = [
      for (final n in _notices)
        if (!_unreadIds.contains(n.id)) n,
    ];
    final showFooter = _hasMore || _loadMoreFailed;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        children: [
          if (_authRequired)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.pageMargin,
                4,
                AppSpacing.pageMargin,
                4,
              ),
              child: AppBanner(
                icon: Icons.lock_outline,
                tone: AppBannerTone.error,
                message: '统一认证已失效，以下为缓存内容，登录后恢复同步',
                actionLabel: '登录',
                onAction: _presentLoginPrompt,
              ),
            ),
          if (unread.isNotEmpty)
            NoticeGroupSection(
              title: '未读',
              trailing: '${unread.length} 条',
              children: [for (final n in unread) _tileFor(n)],
            ),
          if (read.isNotEmpty)
            NoticeGroupSection(
              title: unread.isEmpty ? '最近' : '已读',
              children: [for (final n in read) _tileFor(n)],
            ),
          if (_older.isNotEmpty)
            NoticeGroupSection(
              title: '更早',
              children: [for (final n in _older) _tileFor(n)],
            ),
          if (showFooter) _buildLoadMoreFooter(),
        ],
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
  const _PracticeNoticeTab({this.query = '', this.loader, this.onReady});

  final String query;
  final Future<List<SjjxNotice>> Function()? loader;

  /// 测试钩子：State 挂载后回传 `_load` 入口（生产为 null）。
  final void Function(Future<void> Function() reload)? onReady;

  @override
  State<_PracticeNoticeTab> createState() => _PracticeNoticeTabState();
}

class _PracticeNoticeTabState extends State<_PracticeNoticeTab>
    with AutomaticKeepAliveClientMixin {
  List<SjjxNotice> _notices = [];
  bool _loading = true;
  bool _authRequired = false;
  String? _error;

  /// 加载纪元：同一 Tab 内每次 `_load` 自增的调用序计数器。它只保证
  /// **同一次挂载内、后发起的请求胜出**（迟到旧结果直接丢弃），
  /// **不是账号身份隔离**：不读取任何账号 / 会话 revision。
  /// 跨账号（A 账号在途响应落到 B 登录态）的安全性本轮**未验证**；
  /// `SjjxNoticeService._cachedNotices` 全局兜底缓存仍非按账号作用域
  /// （既有行为，本 PR 未改）。
  int _loadEpoch = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    widget.onReady?.call(_load);
  }

  Future<void> _load() async {
    final epoch = ++_loadEpoch;
    setState(() {
      _loading = true;
      _error = null;
      _authRequired = false;
    });
    try {
      final notices =
          await (widget.loader ?? SjjxNoticeService.instance.fetchAllNotices)();
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _notices = notices;
        _loading = false;
      });
    } on CasAuthExpiredException {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _authRequired = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || epoch != _loadEpoch) return;
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
    final matchedNotices = query.isEmpty
        ? _notices
        : _notices
              .where(
                (notice) =>
                    _noticeMatchesQuery(notice.title, query) ||
                    _noticeMatchesQuery(notice.category, query) ||
                    _noticeMatchesQuery(notice.date, query),
              )
              .toList();
    if (matchedNotices.isEmpty) {
      return const AppEmptyView(
        title: '没有匹配的通知',
        icon: Icons.search_off_rounded,
      );
    }
    // 完整匹配数据留在内存，列表只惰性构建可见窗口：顶部显示总匹配数，行本身
    // 无框、无卡片、无分隔线。查询变化经 resetKey 重置窗口与滚动位置。
    return PracticeNoticeListView(
      resetKey: query,
      headerTitle: query.isEmpty ? '全部' : '匹配结果',
      headerTrailing: '${matchedNotices.length} 条',
      itemCount: matchedNotices.length,
      onRefresh: _load,
      itemBuilder: (context, index) {
        final notice = matchedNotices[index];
        return PracticeNoticeRow(
          title: notice.title,
          date: notice.date,
          tag: notice.category,
          onTap: () => _openPracticeNotice(notice),
          onLongPress: () => copyTextWithFeedback(context, notice.url),
        );
      },
    );
  }

  /// 与实践通知原有语义一致：点开外部 WebView（同旧实现，不带统一认证保护 /
  /// 预热），长按复制链接。
  void _openPracticeNotice(SjjxNotice notice) {
    context.pushNamed(
      'external-webview',
      extra: {
        'title': notice.title,
        'url': notice.url,
        'emulateDingTalkEnvironment': false,
      },
    );
  }
}

// --- Shared tile ---

/// 无框通知行：未读圆点 + 标题 + 日期，例外标签（如分类差异明显的实践
/// 通知）才追加小色块；「每条都一样」的标签不再展示。行本身没有卡片 / 轮廓 /
/// 分隔线，水平边距由外层分组（[NoticeGroupSection]）保留一层
/// [NoticeListMetrics.pageMargin]，未读圆点占最小固定列、读 / 未读标题首字对齐。
class _NoticeTile extends StatelessWidget {
  const _NoticeTile({
    required this.title,
    required this.date,
    required this.onTap,
    this.onLongPress,
    this.unread = false,
  });

  final String title;
  final String? date;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool unread;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final publishDate = (date ?? '').trim();
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: NoticeListMetrics.minRowHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: NoticeListMetrics.rowVerticalPadding,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 圆点列固定宽度：已读 / 未读行的标题保持同一条左缘。
              SizedBox(
                width: NoticeListMetrics.markerWidth,
                child: unread
                    ? Padding(
                        padding: const EdgeInsets.only(top: 7),
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: cs.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                      )
                    : null,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 高密度未读列表：行标题字号，已读常规字重、未读 w500；
                    // 长标题给到 3 行后省略，日期始终可见。
                    Text(
                      title,
                      style: text.rowTitle.copyWith(
                        height: 1.4,
                        fontWeight: unread ? FontWeight.w500 : FontWeight.w400,
                        color: unread ? cs.onSurface : cs.onSurfaceVariant,
                      ),
                      maxLines: NoticeListMetrics.titleMaxLines,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (publishDate.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        publishDate,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.secondary.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
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
