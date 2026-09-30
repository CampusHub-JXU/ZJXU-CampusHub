import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'sjjx_notice_model.dart';
import 'sjjx_notice_service.dart';
import '../../core/auth/cas_auth_broker.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/app_filter_chips.dart';
import '../../shared/widgets/app_list_tile.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/refresh_status_line.dart';
import '../../shared/widgets/skeleton_box.dart';

class SjjxNoticeListPage extends StatefulWidget {
  const SjjxNoticeListPage({super.key});

  @override
  State<SjjxNoticeListPage> createState() => _SjjxNoticeListPageState();
}

class _SjjxNoticeListPageState extends State<SjjxNoticeListPage> {
  static const _pageSize = 20;

  final ScrollController _scrollController = ScrollController();
  List<SjjxNotice> _allNotices = [];
  List<SjjxNotice> _filteredNotices = [];
  List<SjjxNotice> _visibleNotices = [];
  List<String> _categories = [];
  String? _selectedCategory;
  bool _loading = true;
  bool _loadingMore = false;
  bool _authRequired = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    _loadNotices();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadNotices() async {
    setState(() {
      _loading = true;
      _error = null;
      _authRequired = false;
    });
    try {
      final notices = await SjjxNoticeService.instance.fetchAllNotices();
      if (!mounted) return;
      final cats = _extractCategories(notices);
      setState(() {
        _allNotices = notices;
        _categories = cats;
        _filteredNotices = _selectedCategory == null
            ? notices
            : notices.where((n) => n.category == _selectedCategory).toList();
        _visibleNotices = _filteredNotices.take(_pageSize).toList();
        _loadingMore = false;
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
        _error = e.toString();
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
      await _loadNotices();
    }
  }

  List<String> _extractCategories(List<SjjxNotice> notices) {
    final seen = <String>{};
    final ordered = <String>[];
    for (final cat in SjjxNotice.categoryOrder) {
      if (notices.any((n) => n.category == cat)) {
        seen.add(cat);
        ordered.add(cat);
      }
    }
    for (final n in notices) {
      if (!seen.contains(n.category)) {
        seen.add(n.category);
        ordered.add(n.category);
      }
    }
    return ordered;
  }

  void _filterByCategory(String? category) {
    setState(() {
      if (_selectedCategory == category) {
        _selectedCategory = null;
        _filteredNotices = _allNotices;
      } else {
        _selectedCategory = category;
        _filteredNotices = category == null
            ? _allNotices
            : _allNotices.where((n) => n.category == category).toList();
      }
      _visibleNotices = _filteredNotices.take(_pageSize).toList();
      _loadingMore = false;
    });
  }

  void _handleScroll() {
    if (!_scrollController.hasClients || _loading || _loadingMore) return;
    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent - 240) return;
    if (_visibleNotices.length >= _filteredNotices.length) return;

    setState(() {
      _loadingMore = true;
      final nextCount = (_visibleNotices.length + _pageSize).clamp(
        0,
        _filteredNotices.length,
      );
      _visibleNotices = _filteredNotices.take(nextCount).toList();
      _loadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppAppBar(
        title: const Text('实践通知'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadNotices),
        ],
      ),
      body: _loading
          ? _buildSkeleton()
          : _authRequired
          ? AuthRequiredView(
              title: '登录后查看实践通知',
              message: '实践通知需要统一认证会话（校外经 WebVPN 访问），登录后即可刷新。',
              buttonLabel: '登录统一认证',
              onAction: _presentLoginPrompt,
              icon: Icons.sports_kabaddi_outlined,
            )
          : _error != null
          ? AppErrorView(message: '无法连接实践教学管理平台', onRetry: _loadNotices)
          : _allNotices.isEmpty
          ? const AppEmptyView(title: '暂无通知', icon: Icons.article_outlined)
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: AppFilterChips<String?>(
                    options: [
                      const AppFilterOption(null, '全部'),
                      for (final cat in _categories) AppFilterOption(cat, cat),
                    ],
                    selected: _selectedCategory,
                    onSelected: _filterByCategory,
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _loadNotices,
                    child: _filteredNotices.isEmpty
                        ? ListView(
                            controller: _scrollController,
                            children: [
                              SizedBox(
                                height:
                                    MediaQuery.of(context).size.height * 0.4,
                                child: Center(
                                  child: Text(
                                    '该分类下暂无通知',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(color: cs.onSurfaceVariant),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.fromLTRB(
                              AppSpacing.pageMargin,
                              0,
                              AppSpacing.pageMargin,
                              AppSpacing.xl,
                            ),
                            itemCount:
                                _visibleNotices.length + (_loadingMore ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index >= _visibleNotices.length) {
                                return const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                );
                              }
                              return Padding(
                                padding: const EdgeInsets.only(
                                  bottom: AppSpacing.sm,
                                ),
                                child: _noticeTile(
                                  _visibleNotices[index],
                                  onTap: () {
                                    context.pushNamed(
                                      'external-webview',
                                      extra: {
                                        'title': _visibleNotices[index].title,
                                        'url': _visibleNotices[index].url,
                                        'emulateDingTalkEnvironment': false,
                                      },
                                    );
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
    );
  }

  /// 分类与日期合并进元信息行，不用彩色分类块（分类不是状态）。
  Widget _noticeTile(SjjxNotice notice, {required VoidCallback onTap}) {
    final publishDate = (notice.date ?? '').trim();
    return AppListTile(
      title: notice.title,
      titleMaxLines: 2,
      meta: [
        notice.category,
        publishDate,
      ].where((part) => part.isNotEmpty).join(' · '),
      onTap: onTap,
    );
  }

  Widget _buildSkeleton() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.sm,
        AppSpacing.pageMargin,
        AppSpacing.xl,
      ),
      children: [
        const RefreshStatusLine(refreshing: true, loadingLabel: '正在获取实践通知…'),
        const SizedBox(height: AppSpacing.md),
        for (var i = 0; i < 4; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.sm),
          const SkeletonBox(height: 68, radius: 16),
        ],
      ],
    );
  }
}
