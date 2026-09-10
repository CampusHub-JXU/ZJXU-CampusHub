import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../auth/cas_auth_broker.dart';
import '../logging/app_logger.dart';
import 'notice_model.dart';

const _jwcNoticeBaseUrl = 'https://jwc.zjxu.edu.cn/';
const _jwcNoticeListUrl = 'https://jwc.zjxu.edu.cn/list.jsp';

String? _decodeBodyAsUtf8(List<int>? body) {
  if (body == null || body.isEmpty) return null;
  return utf8.decode(body, allowMalformed: true);
}

/// 单次抓取的结果状态。
enum NoticeFetchStatus {
  /// 抓取并解析成功（列表结构存在；条目可能合法为空）。
  ok,

  /// 统一认证会话失效：后台同步应结束本轮，前台据此引导登录。
  authRequired,

  /// 网络失败、响应异常、页面结构缺失等一切不可用情况。
  unavailable,
}

/// 原始抓取结果。后台同步依赖「永不抛异常」的收敛保证：任何逃逸异常都
/// 映射为 [NoticeFetchStatus.unavailable]。
class NoticeFetchResult {
  const NoticeFetchResult._(this.status, this.notices, this.totalPages);

  factory NoticeFetchResult.ok(List<Notice> notices, {int? totalPages}) =>
      NoticeFetchResult._(
        NoticeFetchStatus.ok,
        List.unmodifiable(notices),
        totalPages,
      );

  const NoticeFetchResult.authRequired()
    : this._(NoticeFetchStatus.authRequired, const [], null);

  const NoticeFetchResult.unavailable()
    : this._(NoticeFetchStatus.unavailable, const [], null);

  final NoticeFetchStatus status;
  final List<Notice> notices;
  final int? totalPages;

  bool get isOk => status == NoticeFetchStatus.ok;
}

/// 前台展示路径的结果：允许缓存回退，但认证失效必须显式透传，
/// 不得被缓存吞掉（页面据此引导登录）。
class NoticeListResult {
  const NoticeListResult({
    required this.notices,
    required this.fromCache,
    required this.authRequired,
    this.failed = false,
  });

  final List<Notice> notices;

  /// 本次列表是否来自缓存回退。
  final bool fromCache;

  /// 刷新时统一认证失效。
  final bool authRequired;

  /// 网络失败且无任何可用数据（页面展示错误态）。
  final bool failed;
}

@visibleForTesting
bool looksLikeNoticeResponseNeedsUnifiedAuth(Response<List<int>> response) {
  return CasAuthBroker.isCasLoginExchange(
    realUrl: response.realUri.toString(),
    statusCode: response.statusCode,
    location: response.headers.value('location'),
    requestUri: response.requestOptions.uri,
    html: _decodeBodyAsUtf8(response.data),
  );
}

@visibleForTesting
List<Notice> parseJwcNoticeListHtml(String html) {
  return parseNoticeListDocument(html_parser.parse(html));
}

@visibleForTesting
List<Notice> parseNoticeListDocument(Document doc) {
  final listItems = doc.querySelectorAll('#ul1 li');
  final notices = <Notice>[];

  for (final item in listItems) {
    final link = item.querySelector('a.a1') ?? item.querySelector('a');
    if (link == null) continue;

    final title = link.text
        .trim()
        .replaceFirst(RegExp(r'\s*new$', caseSensitive: false), '')
        .trim();
    final href = link.attributes['href']?.trim() ?? '';
    if (title.isEmpty || href.isEmpty) continue;

    final dateText = item.querySelector('span.fr')?.text.trim() ?? item.text;
    final dateMatch = RegExp(r'20\d{2}[-./]\d{1,2}[-./]\d{1,2}')
        .firstMatch(dateText);
    final date = dateMatch?.group(0)?.replaceAll('/', '-').replaceAll('.', '-');

    notices.add(
      Notice(
        title: title,
        url: Uri.parse(_jwcNoticeBaseUrl).resolve(href).toString(),
        category: '通知公告',
        date: date,
      ),
    );
  }

  // 教务处列表页本身不严格按日期排（置顶/补录混排），按发布日期
  // 倒序重排后再交给展示与同步。
  return Notice.sortByDateDescStable(notices);
}

int? _extractJwcNoticeTotalPages(String html) {
  final doc = html_parser.parse(html);
  final pagerText = doc.querySelector('.pb_sys_common')?.text ?? '';
  final ratioMatch = RegExp(r'\b\d+\s*/\s*(\d+)\b').firstMatch(pagerText);
  if (ratioMatch != null) {
    return int.tryParse(ratioMatch.group(1) ?? '');
  }

  final lastPageHref = doc.querySelector('.p_last a')?.attributes['href'] ?? '';
  final pageMatch = RegExp(r'[?&]PAGENUM=(\d+)').firstMatch(lastPageHref);
  return int.tryParse(pageMatch?.group(1) ?? '');
}

class NoticeService {
  NoticeService._();
  static final NoticeService instance = NoticeService._();

  List<Notice>? _cachedNotices;
  int? _cachedTotalPages;

  Dio? _noticeDio;

  // ── 原始抓取协议：前台展示与后台同步共用 ────────────────────────────

  /// 抓取一页通知列表。
  ///
  /// 永不抛异常：共享 CAS 资源入口复用 Cookie 并完成站点真实回调。
  /// 会话明确失效归入 authRequired，其余一切异常
  /// 归入 unavailable，保留旧快照的决定权交给调用方。
  Future<NoticeFetchResult> fetchNoticesRaw({
    int page = 1,
    CancelToken? cancelToken,
    DateTime? deadline,
  }) async {
    try {
      final url = _buildNoticePageUrl(page);
      final resp = await CasAuthBroker.getResource(
        url,
        dio: _noticeDio,
        cancelToken: cancelToken,
        deadline: deadline,
      );
      final data = resp.data;
      if (data == null || data.isEmpty) {
        return const NoticeFetchResult.unavailable();
      }

      final html = utf8.decode(data, allowMalformed: true);
      final doc = html_parser.parse(html);
      if (doc.querySelector('#ul1') == null) {
        // 回退链路已过滤登录页；列表结构缺失视为改版/异常页，不可信。
        AppLogger.instance.network(
          LogLevel.warn,
          '通知公告页面缺少列表结构: page=$page, '
          'title=${doc.querySelector('title')?.text.trim()}',
        );
        return const NoticeFetchResult.unavailable();
      }

      final notices = parseNoticeListDocument(doc);
      final totalPages = _extractJwcNoticeTotalPages(html);
      _cachedTotalPages = page > 1
          ? (_cachedTotalPages ?? totalPages)
          : (totalPages ?? _cachedTotalPages);
      AppLogger.instance.network(
        LogLevel.info,
        '通知公告第 $page 页抓取成功，共 ${notices.length} 条',
      );
      return NoticeFetchResult.ok(notices, totalPages: totalPages);
    } on CasAuthExpiredException {
      return const NoticeFetchResult.authRequired();
    } catch (error, stackTrace) {
      AppLogger.instance.network(
        LogLevel.warn,
        '通知公告抓取失败: page=$page',
        error: error,
        stackTrace: stackTrace,
      );
      return const NoticeFetchResult.unavailable();
    }
  }

  // ── 前台展示路径 ────────────────────────────────────────────────────

  /// 首屏加载：抓取失败时回退内存缓存，认证失效透传给页面引导登录。
  Future<NoticeListResult> fetchNotices() async {
    final result = await fetchNoticesRaw(page: 1);
    switch (result.status) {
      case NoticeFetchStatus.ok:
        _cachedNotices = result.notices;
        return NoticeListResult(
          notices: result.notices,
          fromCache: false,
          authRequired: false,
        );
      case NoticeFetchStatus.authRequired:
        final cached = _cachedNotices;
        if (cached != null) {
          return NoticeListResult(
            notices: cached,
            fromCache: true,
            authRequired: true,
          );
        }
        return const NoticeListResult(
          notices: [],
          fromCache: false,
          authRequired: true,
        );
      case NoticeFetchStatus.unavailable:
        final cached = _cachedNotices;
        if (cached != null) {
          return NoticeListResult(
            notices: cached,
            fromCache: true,
            authRequired: false,
          );
        }
        return const NoticeListResult(
          notices: [],
          fromCache: false,
          authRequired: false,
          failed: true,
        );
    }
  }

  /// 列表页翻页：保留抛异常行为（页面捕获后提示重试）。
  Future<List<Notice>> fetchMoreNotices(int page) async {
    if (page < 1) return [];
    final totalPages = _cachedTotalPages;
    if (totalPages != null && page > totalPages) return [];

    final result = await fetchNoticesRaw(page: page);
    if (!result.isOk) {
      throw Exception('通知公告分页加载失败: page=$page, status=${result.status}');
    }
    return result.notices;
  }

  String _buildNoticePageUrl(int page) {
    final queryParameters = <String, String>{
      'urltype': 'tree.TreeTempUrl',
      'wbtreeid': '1046',
    };
    if (page > 1) {
      final totalPages = _cachedTotalPages;
      if (totalPages != null && totalPages > 0) {
        queryParameters['totalpage'] = '$totalPages';
      }
      queryParameters['PAGENUM'] = '$page';
    }

    return Uri.parse(_jwcNoticeListUrl)
        .replace(queryParameters: queryParameters)
        .toString();
  }

  @visibleForTesting
  void debugSetDio(Dio? dio) {
    _noticeDio = dio;
  }

  @visibleForTesting
  void debugReset() {
    _cachedNotices = null;
    _cachedTotalPages = null;
    _noticeDio = null;
  }
}
