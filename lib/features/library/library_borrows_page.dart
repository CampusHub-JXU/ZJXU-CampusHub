import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/zhengfang_auth.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/app_status_tag.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/refresh_status_line.dart';
import '../../shared/widgets/skeleton_box.dart';
import 'library_models.dart';
import 'library_page.dart';
import 'library_service.dart';
import 'library_session.dart';
import 'library_token_reader.dart';

/// 原生「我的借阅」页（PRD 0.7.0 §32–§34）。
///
/// 数据链：`LibraryTokenReader`（隐藏 WebView 读图书馆 localStorage 里 Parse
/// 用户对象的 `access_token`）→ `LibraryService.fetchBorrows` → 汇图
/// `/user/borrows[/history]`；续借走 `POST /book/renew`（body `{cid: renewID}`）。
class LibraryBorrowsPage extends StatefulWidget {
  const LibraryBorrowsPage({super.key});

  @override
  State<LibraryBorrowsPage> createState() => _LibraryBorrowsPageState();
}

class _LibraryBorrowsPageState extends State<LibraryBorrowsPage> {
  @override
  void initState() {
    super.initState();
    unawaited(_fetch());
  }

  /// 与 `LibraryService._mapDioError` 的 401 文案一致；命中即清缓存令牌。
  static const _notLoggedIn = '未登录图书馆';
  static const _expiredTokenMessage = '图书馆登录已过期，请重新登录';

  bool _history = false;
  String? _token;

  // 缓存优先：已有数据时刷新不换骨架、不替换列表；仅首次（无数据）显示骨架 /
  // 整页错误。[_gen] 让切换分段 / 重复刷新后的旧结果被丢弃。
  LibraryBorrowPage? _page;
  Object? _error;
  bool _loading = true;
  bool _refreshFailed = false;
  DateTime? _updatedAt;
  int _gen = 0;
  final Set<String> _renewing = <String>{};

  Future<LibraryBorrowPage> _load() async {
    final guard = LibrarySession.instance.captureGuard();
    final token = await _resolveToken(guard);
    LibrarySession.instance.ensureGuard(guard);
    _token = token;
    if (token == null || token.isEmpty) {
      throw const LibraryApiException(_notLoggedIn);
    }
    try {
      final page = await LibraryService.instance.fetchBorrows(
        accessToken: token,
        history: _history,
      );
      // 响应回来前登出 / 切号：结果属于旧账号，丢弃。
      LibrarySession.instance.ensureGuard(guard);
      return page;
    } on LibraryApiException catch (error) {
      if (error.message == _expiredTokenMessage) {
        LibrarySession.instance.clearToken();
      }
      rethrow;
    }
  }

  /// 令牌优先用 [LibrarySession] 从已打开的图书馆 WebView 里缓存的（可靠）；
  /// 缓存为空时才退回隐藏 WebView 兜底（冷启动/直接进入借阅页时可能命中）。
  ///
  /// 兜底读到的令牌同样必须绑定当前统一认证身份，且每个 await 边界都校验
  /// [guard]，防止读取期间登出 / 切号后旧账号令牌被采用。
  Future<String?> _resolveToken(LibrarySessionGuard guard) async {
    final cached = LibrarySession.instance.accessToken;
    if (cached != null && cached.trim().isNotEmpty) return cached;
    final candidates = <String>[
      ZhengfangAuth.instance.buildWebVpnProxyUrl(LibraryPage.libraryUrl),
      LibraryPage.libraryUrl,
    ];
    for (final url in candidates) {
      final token = await LibraryTokenReader.instance.readAccessToken(url);
      if (token != null && token.trim().isNotEmpty) {
        LibrarySession.instance.ensureGuard(guard);
        return LibrarySession.instance.bindToken(token) ? token : null;
      }
      LibrarySession.instance.ensureGuard(guard);
    }
    return null;
  }

  String _errorMessage(Object? error) => error is LibraryApiException
      ? error.message
      : error is LibrarySessionChangedException
      ? error.message
      : '请检查网络后重试';

  /// 拉取借阅。已有数据时保持列表可见，失败只置「刷新失败」并 toast；
  /// 身份已变化 / 未登录图书馆时旧数据不再属于当前会话，丢弃并走整页状态。
  Future<void> _fetch() async {
    final gen = ++_gen;
    setState(() {
      _loading = true;
      _refreshFailed = false;
    });
    try {
      final page = await _load();
      if (!mounted || gen != _gen) return;
      setState(() {
        _page = page;
        _error = null;
        _loading = false;
        _updatedAt = DateTime.now();
      });
    } catch (error) {
      if (!mounted || gen != _gen) return;
      final dropData =
          error is LibrarySessionChangedException ||
          (error is LibraryApiException && error.message == _notLoggedIn);
      if (_page != null && !dropData) {
        setState(() {
          _loading = false;
          _refreshFailed = true;
        });
        AppFeedback.toast(context, _errorMessage(error));
      } else {
        setState(() {
          _page = null;
          _updatedAt = null;
          _error = error;
          _loading = false;
        });
      }
    }
  }

  /// 下拉刷新：等到结果（成功或失败）落定再收起指示器。
  Future<void> _refresh() => _fetch();

  Future<void> _renew(LibraryBorrowItem item) async {
    final token = _token;
    if (token == null || token.isEmpty) return;
    final guard = LibrarySession.instance.captureGuard();
    setState(() => _renewing.add(item.renewId));
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      // 令牌解析后、请求发出前登出 / 切号：不得用旧令牌续借旧账号的书。
      LibrarySession.instance.ensureGuard(guard);
      await LibraryService.instance.renewBorrow(
        accessToken: token,
        cid: item.renewId,
      );
      if (messenger != null) AppFeedback.toastOn(messenger, '续借成功');
      if (mounted) unawaited(_fetch());
    } on LibraryApiException catch (error) {
      if (error.message == _expiredTokenMessage) {
        LibrarySession.instance.clearToken();
      }
      if (messenger != null) AppFeedback.toastOn(messenger, error.message);
    } on LibrarySessionChangedException catch (error) {
      if (messenger != null) AppFeedback.toastOn(messenger, error.message);
    } finally {
      if (mounted) setState(() => _renewing.remove(item.renewId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(title: const Text('我的借阅')),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.pageMargin,
              AppSpacing.sm,
              AppSpacing.pageMargin,
              AppSpacing.sm,
            ),
            child: SegmentedButton<bool>(
              segments: const <ButtonSegment<bool>>[
                ButtonSegment<bool>(value: false, label: Text('借阅中')),
                ButtonSegment<bool>(value: true, label: Text('历史借阅')),
              ],
              selected: <bool>{_history},
              onSelectionChanged: (selection) {
                // 历史 / 在借是两份不同数据：先清空再走首次加载（骨架）。
                setState(() {
                  _history = selection.first;
                  _page = null;
                  _error = null;
                  _updatedAt = null;
                });
                unawaited(_fetch());
              },
            ),
          ),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final page = _page;
    if (page == null) {
      if (_loading) return _buildSkeleton();
      final error = _error;
      if (error is LibraryApiException && error.message == _notLoggedIn) {
        return _buildLoginRequired(context);
      }
      return AppErrorView(
        title: '借阅记录加载失败',
        message: _errorMessage(error),
        onRetry: () => unawaited(_fetch()),
      );
    }
    if (page.isEmpty) {
      return AppEmptyView(
        title: _history ? '暂无历史借阅' : '没有借阅',
        message: '当前没有可显示的借阅记录',
        icon: Icons.menu_book_outlined,
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageMargin,
          0,
          AppSpacing.pageMargin,
          AppSpacing.xl,
        ),
        itemCount: page.items.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: RefreshStatusLine(
                updatedAt: _updatedAt,
                refreshing: _loading,
                failed: _refreshFailed,
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: _buildItem(context, page.items[index - 1]),
          );
        },
      ),
    );
  }

  Widget _buildLoginRequired(BuildContext context) {
    return AuthRequiredView(
      title: '未登录图书馆',
      message: '请先在图书馆页面完成一卡通登录，再查看借阅记录',
      buttonLabel: '打开图书馆',
      icon: Icons.menu_book_outlined,
      onAction: () => context.pushNamed('library'),
    );
  }

  Widget _buildSkeleton() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        0,
        AppSpacing.pageMargin,
        AppSpacing.xl,
      ),
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.sm),
          const SkeletonBox(height: 120, radius: 16),
        ],
      ],
    );
  }

  Widget _buildItem(BuildContext context, LibraryBorrowItem item) {
    final text = context.appText;
    final busy = _renewing.contains(item.renewId);
    final hint = item.dueHint;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  item.bookName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.rowTitle.copyWith(height: 1.25),
                ),
              ),
              if (hint != null) ...<Widget>[
                const SizedBox(width: 8),
                AppStatusTag(hint, tone: AppStatusTone.danger),
              ],
            ],
          ),
          if (item.author.isNotEmpty) ...<Widget>[
            const SizedBox(height: 3),
            Text(item.author, style: text.secondary),
          ],
          if (item.desc.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              item.desc,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: text.meta,
            ),
          ],
          const SizedBox(height: 8),
          if (_history)
            _BorrowLine(label: '归还', value: item.returnTime)
          else
            _BorrowLine(label: '到期', value: item.endTime),
          if (item.borrowTime.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            _BorrowLine(label: '借入', value: item.borrowTime),
          ],
          if (item.returnCode.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            _BorrowLine(label: '归还码', value: item.returnCode),
          ],
          if (item.canRenew) ...<Widget>[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: busy ? null : () => _renew(item),
                child: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('续借'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BorrowLine extends StatelessWidget {
  const _BorrowLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final meta = context.appText.meta;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(width: 56, child: Text(label, style: meta)),
        Expanded(
          child: Text(
            value.isEmpty ? '—' : value,
            style: meta.copyWith(color: cs.onSurface),
          ),
        ),
      ],
    );
  }
}
