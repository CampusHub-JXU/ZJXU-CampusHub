import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/async/debouncer.dart';
import '../../core/notice/notice_model.dart';
import '../../core/notice/notice_search_service.dart';
import '../../shared/widgets/login_shell.dart';

/// 校园公告搜索的「教务处全站」分区：本地收件箱只有最近同步的一批，
/// 更早的通知靠站内全文检索补齐。输入停顿后自动检索，关键词变化即取消
/// 在途请求并丢弃旧结果。
class CampusNoticeSiteSearch extends StatefulWidget {
  const CampusNoticeSiteSearch({
    super.key,
    required this.query,
    required this.excludeIds,
    required this.tileBuilder,
  });

  final String query;

  /// 已在「最近通知」分区展示的条目，全站结果里不重复。
  final Set<String> excludeIds;
  final Widget Function(Notice notice) tileBuilder;

  @override
  State<CampusNoticeSiteSearch> createState() => _CampusNoticeSiteSearchState();
}

enum _Status { loading, loaded, authRequired, failed }

class _CampusNoticeSiteSearchState extends State<CampusNoticeSiteSearch> {
  final Debouncer _debouncer = Debouncer(const Duration(milliseconds: 500));
  CancelToken? _cancelToken;
  int _generation = 0;

  _Status _status = _Status.loading;
  final List<Notice> _notices = [];
  int _page = 0;
  int _total = 0;
  bool _hasMore = false;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant CampusNoticeSiteSearch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query.trim() != widget.query.trim()) _schedule();
  }

  @override
  void dispose() {
    _debouncer.cancel();
    _cancelToken?.cancel();
    super.dispose();
  }

  void _schedule() {
    _debouncer.cancel();
    _cancelToken?.cancel();
    _generation++;
    setState(() {
      _status = _Status.loading;
      _notices.clear();
      _page = 0;
      _total = 0;
      _hasMore = false;
      _loadingMore = false;
    });
    _debouncer.run(() => _fetch(page: 1));
  }

  Future<void> _fetch({required int page}) async {
    final generation = _generation;
    final token = CancelToken();
    _cancelToken = token;
    final result = await NoticeSearchService.instance.search(
      widget.query,
      page: page,
      cancelToken: token,
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _loadingMore = false;
      switch (result) {
        case NoticeSearchLoaded():
          _status = _Status.loaded;
          final known = _notices.map((n) => n.id).toSet();
          _notices.addAll(result.notices.where((n) => known.add(n.id)));
          _page = result.page;
          _total = result.total;
          _hasMore = result.hasMore;
        case NoticeSearchAuthRequired():
          // 翻页中途失效：保留已加载结果，只收起「加载更多」。
          if (page == 1) _status = _Status.authRequired;
          _hasMore = page == 1 ? false : _hasMore;
        case NoticeSearchUnavailable():
          if (page == 1) _status = _Status.failed;
      }
    });
  }

  void _loadMore() {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    _fetch(page: _page + 1);
  }

  Future<void> _login() async {
    final ok = await showUnifiedAuthLoginModal(
      context,
      title: '登录统一认证',
      description: '登录后可搜索教务处全部通知',
    );
    if (ok && mounted) _schedule();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final visible = _notices
        .where((n) => !widget.excludeIds.contains(n.id))
        .toList(growable: false);

    Widget hint(String text, {Widget? action}) => Padding(
      padding: const EdgeInsets.fromLTRB(32, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          ?action,
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionLabel(
          '教务处全站',
          trailing: _status == _Status.loaded && _total > 0
              ? '共 $_total 条'
              : null,
        ),
        switch (_status) {
          _Status.loading => const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            ),
          ),
          _Status.authRequired => hint(
            '登录统一认证后可搜索全部通知',
            action: TextButton(onPressed: _login, child: const Text('登录')),
          ),
          _Status.failed => hint(
            '全站搜索暂时不可用',
            action: TextButton(onPressed: _schedule, child: const Text('重试')),
          ),
          _Status.loaded when visible.isEmpty && !_hasMore => hint(
            _notices.isEmpty ? '没有找到相关通知' : '没有更多结果',
          ),
          _Status.loaded => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < visible.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: 28,
                    color: cs.outlineVariant.withValues(alpha: 0.25),
                  ),
                widget.tileBuilder(visible[i]),
              ],
              if (_hasMore)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: _loadingMore
                        ? const SizedBox.square(
                            dimension: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          )
                        : TextButton(
                            onPressed: _loadMore,
                            child: const Text('加载更多'),
                          ),
                  ),
                ),
            ],
          ),
        },
      ],
    );
  }
}

/// 搜索结果分区标题：与列表标题同一左缘（圆点列之后）。
class CampusNoticeSectionLabel extends StatelessWidget {
  const CampusNoticeSectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) => _SectionLabel(text, trailing: trailing);
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {this.trailing});

  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: cs.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 16, 16, 4),
      child: Row(
        children: [
          Expanded(child: Text(text, style: style)),
          if (trailing != null) Text(trailing!, style: style),
        ],
      ),
    );
  }
}
