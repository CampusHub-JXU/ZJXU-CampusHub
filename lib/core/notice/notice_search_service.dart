import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../auth/cas_auth_broker.dart';
import '../logging/app_logger.dart';
import 'notice_model.dart';

/// 教务处站内全文检索（博达 VSB `sousuo.jsp`）。
///
/// 与列表同一条认证链：未登录 302 到 `clogin.jsp` → CAS，经
/// `CasAuthBroker.getResource` 逐跳建立 CMS Cookie（资源 URL，不是 CAS
/// service）。检索覆盖标题与正文、全站全部年份；参数固定为精确匹配
/// （`range=0`）+ 按时间倒序（`order=1`），每页 10 条。
@immutable
sealed class NoticeSearchResult {
  const NoticeSearchResult();
}

class NoticeSearchLoaded extends NoticeSearchResult {
  const NoticeSearchLoaded({
    required this.notices,
    required this.page,
    required this.total,
    required this.totalPages,
  });

  final List<Notice> notices;
  final int page;

  /// 站点报告的命中总数；0 表示无结果。
  final int total;
  final int totalPages;

  bool get hasMore => page < totalPages;
}

class NoticeSearchAuthRequired extends NoticeSearchResult {
  const NoticeSearchAuthRequired();
}

/// 网络失败或结果页结构不认识。
class NoticeSearchUnavailable extends NoticeSearchResult {
  const NoticeSearchUnavailable();
}

const String _jwcOrigin = 'https://jwc.zjxu.edu.cn';

/// 构造检索 URL：关键词按站点 JS 的做法 UTF-8 → Base64 放进 `newskeycode2`。
String buildNoticeSearchUrl(String keyword, {int page = 1}) {
  return Uri.parse('$_jwcOrigin/sousuo.jsp')
      .replace(
        queryParameters: <String, String>{
          'wbtreeid': '1046',
          'searchScope': '1',
          'newskeycode2': base64.encode(utf8.encode(keyword)),
          'range': '0',
          'order': '1',
          'currentnum': '$page',
        },
      )
      .toString();
}

final RegExp _cnDate = RegExp(r'(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日');
final RegExp _total = RegExp(r'共有\s*(\d+)\s*条');
final RegExp _pages = RegExp(r'共有\s*(\d+)\s*页');

/// 解析检索结果页；结构不认识返回 null（fail closed）。
///
/// 模板标识：结果区 `table.listFrame` 与排序下拉 `#orderSelect`——
/// 零结果页同样保留它们，所以「无命中」与「页面不认识」可区分。
@visibleForTesting
NoticeSearchLoaded? parseNoticeSearchHtml(String html, {required int page}) {
  final doc = html_parser.parse(html);
  if (doc.querySelector('table.listFrame') == null ||
      doc.querySelector('#orderSelect') == null) {
    return null;
  }

  final notices = <Notice>[];
  final seen = <String>{};
  for (final anchor in doc.querySelectorAll('a.fk-newsListTitle')) {
    final href = anchor.attributes['href']?.trim() ?? '';
    final title = anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (href.isEmpty || title.isEmpty) continue;
    final uri = Uri.parse('$_jwcOrigin/').resolve(href);
    if (uri.host != 'jwc.zjxu.edu.cn') continue;
    final url = uri.replace(scheme: 'https').toString();
    if (!seen.add(url)) continue;
    notices.add(
      Notice(title: title, url: url, category: '教务处', date: _dateNear(anchor)),
    );
  }

  final text = doc.body?.text ?? '';
  final total =
      int.tryParse(_total.firstMatch(text)?.group(1) ?? '') ?? notices.length;
  final totalPages =
      int.tryParse(_pages.firstMatch(text)?.group(1) ?? '') ??
      (notices.isEmpty ? 0 : page);
  return NoticeSearchLoaded(
    notices: notices,
    page: page,
    total: total,
    totalPages: totalPages,
  );
}

/// 日期在标题所在行（同一 `tr`）右侧单元格：`2026年08月29日`。
String? _dateNear(dom.Element anchor) {
  dom.Element? row = anchor.parent;
  while (row != null && row.localName != 'tr') {
    row = row.parent;
  }
  final match = _cnDate.firstMatch(row?.text ?? '');
  if (match == null) return null;
  return '${match.group(1)}-${match.group(2)!.padLeft(2, '0')}-'
      '${match.group(3)!.padLeft(2, '0')}';
}

class NoticeSearchService {
  NoticeSearchService._();

  static final NoticeSearchService instance = NoticeSearchService._();

  static const Duration _budget = Duration(seconds: 20);

  Dio? _dio;

  /// 永不抛异常；空关键词直接返回空结果、不触网。
  Future<NoticeSearchResult> search(
    String keyword, {
    int page = 1,
    CancelToken? cancelToken,
  }) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      return NoticeSearchLoaded(
        notices: const [],
        page: page,
        total: 0,
        totalPages: 0,
      );
    }
    try {
      final resp = await CasAuthBroker.getResource(
        buildNoticeSearchUrl(trimmed, page: page),
        dio: _dio,
        cancelToken: cancelToken,
        timeout: _budget,
      );
      final data = resp.data;
      if (data == null || data.isEmpty) return const NoticeSearchUnavailable();
      final parsed = parseNoticeSearchHtml(
        utf8.decode(data, allowMalformed: true),
        page: page,
      );
      if (parsed == null) {
        AppLogger.instance.network(LogLevel.warn, '教务处站内检索结果结构无法识别');
        return const NoticeSearchUnavailable();
      }
      return parsed;
    } on CasAuthExpiredException {
      return const NoticeSearchAuthRequired();
    } catch (error, stackTrace) {
      if (error is DioException && CancelToken.isCancel(error)) {
        return const NoticeSearchUnavailable();
      }
      AppLogger.instance.network(
        LogLevel.warn,
        '教务处站内检索失败',
        error: error,
        stackTrace: stackTrace,
      );
      return const NoticeSearchUnavailable();
    }
  }

  @visibleForTesting
  void debugSetDio(Dio? dio) => _dio = dio;
}
