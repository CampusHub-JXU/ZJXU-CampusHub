import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/zhengfang_auth.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_error_view.dart';
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
  bool _history = false;
  String? _token;
  late Future<LibraryBorrowPage> _future = _load();
  final Set<String> _renewing = <String>{};

  Future<LibraryBorrowPage> _load() async {
    _token = await _resolveToken();
    final token = _token;
    if (token == null || token.isEmpty) {
      throw const LibraryApiException('未登录图书馆');
    }
    return LibraryService.instance.fetchBorrows(
      accessToken: token,
      history: _history,
    );
  }

  /// 令牌优先用 [LibrarySession] 从已打开的图书馆 WebView 里缓存的（可靠）；
  /// 缓存为空时才退回隐藏 WebView 兜底（冷启动/直接进入借阅页时可能命中）。
  Future<String?> _resolveToken() async {
    final cached = LibrarySession.instance.accessToken;
    if (cached != null && cached.trim().isNotEmpty) return cached;
    final candidates = <String>[
      ZhengfangAuth.instance.buildWebVpnProxyUrl(LibraryPage.libraryUrl),
      LibraryPage.libraryUrl,
    ];
    for (final url in candidates) {
      final token = await LibraryTokenReader.instance.readAccessToken(url);
      if (token != null && token.trim().isNotEmpty) return token;
    }
    return null;
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _renew(LibraryBorrowItem item) async {
    final token = _token;
    if (token == null || token.isEmpty) return;
    setState(() => _renewing.add(item.renewId));
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await LibraryService.instance.renewBorrow(
        accessToken: token,
        cid: item.renewId,
      );
      messenger?.showSnackBar(const SnackBar(content: Text('续借成功')));
      if (mounted) _reload();
    } on LibraryApiException catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text(error.message)));
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
                setState(() {
                  _history = selection.first;
                  _future = _load();
                });
              },
            ),
          ),
          Expanded(
            child: FutureBuilder<LibraryBorrowPage>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final page = snapshot.data;
                if (page == null) {
                  final error = snapshot.error;
                  if (error is LibraryApiException &&
                      error.message == '未登录图书馆') {
                    return _buildLoginRequired(context);
                  }
                  return AppErrorView(
                    title: '借阅记录加载失败',
                    message: error is LibraryApiException
                        ? error.message
                        : '请检查网络后重试',
                    onRetry: _reload,
                  );
                }
                if (page.isEmpty) {
                  return AppEmptyView(
                    title: _history ? '暂无历史借阅' : '没有借阅',
                    message: '当前没有可显示的借阅记录',
                    icon: Icons.menu_book_outlined,
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.pageMargin,
                    0,
                    AppSpacing.pageMargin,
                    AppSpacing.xl,
                  ),
                  itemCount: page.items.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: _buildItem(context, page.items[index]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoginRequired(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.lock_outline,
              size: 40,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '未登录图书馆',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '请先在图书馆页面完成一卡通登录，再查看借阅记录',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton.tonal(
              onPressed: () => context.pushNamed('library'),
              child: const Text('打开图书馆'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItem(BuildContext context, LibraryBorrowItem item) {
    final cs = Theme.of(context).colorScheme;
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
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                    height: 1.25,
                  ),
                ),
              ),
              if (hint != null) ...<Widget>[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: cs.errorContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    hint,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: cs.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (item.author.isNotEmpty) ...<Widget>[
            const SizedBox(height: 3),
            Text(
              item.author,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ],
          if (item.desc.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              item.desc,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Text(
            value.isEmpty ? '—' : value,
            style: TextStyle(fontSize: 12.5, color: cs.onSurface),
          ),
        ),
      ],
    );
  }
}
