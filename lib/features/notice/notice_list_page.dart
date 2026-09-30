import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/logging/app_logger.dart';
import '../../core/notice/notice_detail.dart';
import '../../core/notice/notice_fetch_service.dart';
import '../../core/notice/notice_model.dart';
import '../../core/notice/notice_relevance.dart';
import '../../core/profile/user_profile_controller.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/copy_text_feedback.dart';
import '../../shared/widgets/login_shell.dart';

bool shouldOpenNoticeViaUnifiedAuth(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;

  return uri.host.toLowerCase() == 'jwc.zjxu.edu.cn';
}

class NoticeListPage extends StatefulWidget {
  const NoticeListPage({super.key});

  @override
  State<NoticeListPage> createState() => _NoticeListPageState();
}

class _NoticeListPageState extends State<NoticeListPage> {
  List<Notice> _notices = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _authRequired = false;
  int _currentPage = 1;
  String? _error;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadNotices();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loadingMore || !_hasMore) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
    if (currentScroll >= maxScroll - 200) {
      _loadMore();
    }
  }

  Future<void> _loadNotices() async {
    setState(() {
      _loading = true;
      _error = null;
      _authRequired = false;
    });
    _currentPage = 1;
    final result = await NoticeService.instance.fetchNotices();
    if (!mounted) return;
    if (result.failed) {
      AppLogger.instance.ui(LogLevel.error, '通知公告页首屏加载失败');
      setState(() {
        _notices = [];
        _loading = false;
        _hasMore = false;
        _error = '无法连接教务处通知公告';
      });
      return;
    }
    setState(() {
      _notices = _relevanceOrdered(result.notices);
      _loading = false;
      _hasMore = true;
      _authRequired = result.authRequired;
    });
  }

  /// 年级相关性排序：明确指向其他年级的通知沉底，组内日期倒序。
  List<Notice> _relevanceOrdered(List<Notice> notices) {
    return NoticeRelevance.orderByRelevanceThenDate(
      notices,
      UserProfileController.instance.effectiveEnrollmentYear,
    );
  }

  Future<void> _presentLoginPrompt() async {
    final ok = await showUnifiedAuthLoginModal(
      context,
      title: '登录统一认证',
      description: '登录后可查看通知公告与校园公告',
    );
    if (ok && mounted) {
      await _loadNotices();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    _currentPage++;
    try {
      final more = await NoticeService.instance.fetchMoreNotices(_currentPage);
      if (!mounted) return;
      setState(() {
        if (more.isEmpty) {
          _hasMore = false;
        } else {
          _notices = _relevanceOrdered([..._notices, ...more]);
        }
        _loadingMore = false;
      });
    } catch (error, stackTrace) {
      AppLogger.instance.ui(
        LogLevel.error,
        '通知公告页分页加载失败: page=$_currentPage',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      _currentPage--;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('加载更多失败，请稍后重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final showAuthBanner = _authRequired && _notices.isNotEmpty;
    return Scaffold(
      appBar: AppAppBar(
        title: const Text('通知公告'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadNotices),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? AppErrorView(message: _error, onRetry: _loadNotices)
          : _authRequired && _notices.isEmpty
          ? AuthRequiredView(
              title: '登录后查看通知公告',
              message: '校外访问通知公告需要统一认证会话，登录后即可同步最新通知。',
              buttonLabel: '登录统一认证',
              onAction: _presentLoginPrompt,
              icon: Icons.campaign_outlined,
            )
          : _notices.isEmpty
          ? const AppEmptyView(title: '暂无通知', icon: Icons.article_outlined)
          : RefreshIndicator(
              onRefresh: _loadNotices,
              child: ListView.separated(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                itemCount:
                    _notices.length +
                    (_hasMore ? 1 : 0) +
                    (showAuthBanner ? 1 : 0),
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  var offset = 0;
                  if (showAuthBanner) {
                    if (index == 0) {
                      return _AuthStaleBanner(onLoginTap: _presentLoginPrompt);
                    }
                    offset = 1;
                  }
                  final noticeIndex = index - offset;
                  if (noticeIndex >= _notices.length) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  }
                  final notice = _notices[noticeIndex];
                  return _NoticeCard(
                    notice: notice,
                    colorScheme: cs,
                    onTap: () {
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
                          'requireUnifiedAuthProtection':
                              shouldOpenNoticeViaUnifiedAuth(notice.url),
                          'serviceUrl': notice.url,
                          'loginDescription': '通知公告可直连访问，但需先完成统一认证',
                          'showWebViewBottomBackButton': true,
                          'warmUpAsResource': true,
                        },
                      );
                    },
                  );
                },
              ),
            ),
    );
  }
}

/// 有缓存可看但刷新时认证失效：列表照常展示，顶部提示登录以恢复同步。
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

class _NoticeCard extends StatelessWidget {
  final Notice notice;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  const _NoticeCard({
    required this.notice,
    required this.colorScheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isNotice = notice.category == '通知公告';
    final tagColor = isNotice ? colorScheme.primary : colorScheme.error;
    final tagForeground = isNotice
        ? colorScheme.onPrimary
        : colorScheme.onError;
    final publishDate = (notice.date ?? '').trim();

    return Material(
      color: colorScheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(12),
      elevation: 0.5,
      shadowColor: colorScheme.shadow.withValues(alpha: 0.12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: notice.url.isEmpty
            ? null
            : () => copyTextWithFeedback(context, notice.url),
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
                  notice.category,
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
                      notice.title,
                      style: TextStyle(
                        fontSize: 15,
                        color: colorScheme.onSurface,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (publishDate.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '发布日期：$publishDate',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
