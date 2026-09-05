import 'dart:convert';

import 'package:charset/charset.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;

import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/auth/zhengfang_auth.dart';
import 'sjjx_notice_model.dart';

const _sjjxNoticeBaseUrl = 'http://sjjx.zjxu.edu.cn/sjjx/';
const _sjjxNoticeListUrl =
    'http://sjjx.zjxu.edu.cn/sjjx/morenews.aspx?NewsType=gonggao';

@visibleForTesting
bool looksLikeSjjxResponseNeedsUnifiedAuth(Response<List<int>> response) {
  final exchangeHit = CasAuthBroker.isCasLoginExchange(
    realUrl: response.realUri.toString(),
    statusCode: response.statusCode,
    location: response.headers.value('location'),
    requestUri: response.requestOptions.uri,
  );
  if (exchangeHit) {
    return true;
  }

  final body = response.data;
  if (body == null || body.isEmpty) {
    return false;
  }

  final html = utf8.decode(body, allowMalformed: true);
  if (looksLikeSjjxNoticeListHtml(html)) {
    return false;
  }
  return looksLikeUnifiedAuthLoginHtml(html);
}

@visibleForTesting
bool looksLikeSjjxNoticeListHtml(String html) {
  if (html.trim().isEmpty) {
    return false;
  }

  final doc = html_parser.parse(html);
  if (doc.querySelectorAll('.List_R02').isNotEmpty) {
    return true;
  }

  final title = doc.querySelector('title')?.text.trim() ?? '';
  if (!title.contains('实践')) {
    return false;
  }

  return doc.querySelector('.List_R02_L a') != null;
}

@visibleForTesting
String decodeSjjxNoticeHtml(Response<List<int>> response) {
  final body = response.data;
  if (body == null || body.isEmpty) {
    return '';
  }

  final contentType = (response.headers.value(Headers.contentTypeHeader) ?? '')
      .toLowerCase();
  if (contentType.contains('utf-8')) {
    return utf8.decode(body, allowMalformed: true);
  }
  if (contentType.contains('gbk') ||
      contentType.contains('gb2312') ||
      contentType.contains('gb18030')) {
    return gbk.decode(body, allowMalformed: true);
  }

  final utf8Html = utf8.decode(body, allowMalformed: true);
  if (looksLikeUnifiedAuthLoginHtml(utf8Html)) {
    return utf8Html;
  }
  return gbk.decode(body, allowMalformed: true);
}

@visibleForTesting
List<SjjxNotice> parseSjjxNoticeListHtml(String html) {
  final doc = html_parser.parse(html);
  final items = doc.querySelectorAll('.List_R02');
  final notices = <SjjxNotice>[];

  for (final item in items) {
    final linkEl = item.querySelector('.List_R02_L a');
    final dateEl = item.querySelector('.List_R02_R');
    if (linkEl == null) continue;

    final rawTitle = linkEl.attributes['title']?.trim() ?? '';
    final href = linkEl.attributes['href']?.trim() ?? '';
    if (rawTitle.isEmpty || href.isEmpty) continue;

    final rawText = linkEl.text.trim();
    final catMatch = RegExp(r'^\[(.+?)\]').firstMatch(rawText);
    final category = catMatch?.group(1) ?? '其他';

    final dateText = dateEl?.text.trim() ?? '';
    final dateMatch = RegExp(r'20\d{2}[-/]\d{1,2}[-/]\d{1,2}')
        .firstMatch(dateText);
    final date = dateMatch?.group(0)?.replaceAll('/', '-');

    notices.add(
      SjjxNotice(
        title: rawTitle,
        url: href.startsWith('http') ? href : '$_sjjxNoticeBaseUrl$href',
        category: category,
        date: date,
      ),
    );
  }

  return notices;
}

class SjjxNoticeService {
  SjjxNoticeService._();
  static final SjjxNoticeService instance = SjjxNoticeService._();

  List<SjjxNotice>? _cachedNotices;

  Future<List<SjjxNotice>> fetchAllNotices() async {
    try {
      AppLogger.instance.network(LogLevel.info, '开始加载实践通知列表');
      final resp = await _getDirect(_sjjxNoticeListUrl);
      if (resp.data == null || resp.data!.isEmpty) {
        AppLogger.instance.network(LogLevel.warn, '实践通知列表响应为空');
        return [];
      }

      final html = decodeSjjxNoticeHtml(resp);
      if (!looksLikeSjjxNoticeListHtml(html)) {
        throw StateError('实践通知响应缺少列表结构');
      }
      final parsed = parseSjjxNoticeListHtml(html);
      final viaWebVpn = resp.realUri.host == 'webvpn.zjxu.edu.cn';
      final notices = viaWebVpn
          ? parsed
                .map(
                  (notice) => SjjxNotice(
                    title: notice.title,
                    url: ZhengfangAuth.instance.buildWebVpnProxyUrl(notice.url),
                    category: notice.category,
                    date: notice.date,
                  ),
                )
                .toList()
          : parsed;
      if (notices.isEmpty) {
        final doc = html_parser.parse(html);
        final title = doc.querySelector('title')?.text.trim() ?? '';
        final itemCount = doc.querySelectorAll('.List_R02').length;
        AppLogger.instance.network(
          LogLevel.warn,
          '实践通知解析结果为空: title=$title, itemCount=$itemCount, bytes=${resp.data!.length}',
        );
      }
      AppLogger.instance.network(
        LogLevel.info,
        '实践通知列表加载成功，共 ${notices.length} 条',
      );

      _cachedNotices = notices;
      return notices;
    } on CasAuthExpiredException {
      rethrow;
    } catch (error, stackTrace) {
      final cachedNotices = _cachedNotices;
      if (cachedNotices != null) {
        AppLogger.instance.network(
          LogLevel.warn,
          '实践通知加载失败，回退缓存 ${cachedNotices.length} 条',
          error: error,
          stackTrace: stackTrace,
        );
        return cachedNotices;
      }
      AppLogger.instance.network(
        LogLevel.error,
        '实践通知加载失败',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Dio? _testDio;

  Future<Response<List<int>>> _getDirect(String url) async {
    final response = await CasAuthBroker.getResource(
      url,
      dio: _testDio,
      needsLogin: looksLikeSjjxResponseNeedsUnifiedAuth,
    );
    if (looksLikeSjjxNoticeListHtml(decodeSjjxNoticeHtml(response))) {
      return response;
    }
    // 校外直连可能只落到网关首页，使用已登记并经浏览器验证的代理路径。
    if (response.realUri.host == 'webvpn.zjxu.edu.cn') {
      return CasAuthBroker.getResource(
        ZhengfangAuth.instance.buildWebVpnProxyUrl(url),
        dio: _testDio,
        needsLogin: looksLikeSjjxResponseNeedsUnifiedAuth,
      );
    }
    return response;
  }

  @visibleForTesting
  void debugSetDio(Dio? dio) => _testDio = dio;

  @visibleForTesting
  void debugReset() {
    _testDio = null;
    _cachedNotices = null;
  }
}
