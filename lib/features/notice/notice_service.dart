import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;

import '../../core/auth/cas_auth_broker.dart';
import '../../core/logging/app_logger.dart';
import '../../core/network/dio_client.dart';
import '../../core/network/legacy_dio_factory.dart';
import '../../core/network/network_settings.dart';
import 'notice_model.dart';

const _jwcNoticeBaseUrl = 'https://jwc.zjxu.edu.cn/';
const _jwcNoticeListUrl = 'https://jwc.zjxu.edu.cn/list.jsp';

String? _decodeBodyAsUtf8(List<int>? body) {
  if (body == null || body.isEmpty) return null;
  return utf8.decode(body, allowMalformed: true);
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
  final doc = html_parser.parse(html);
  final listItems = doc.querySelectorAll('#ul1 li');
  final notices = <Notice>[];

  for (final item in listItems) {
    final link = item.querySelector('a.a1') ?? item.querySelector('a');
    if (link == null) continue;

    final title = link.text.trim();
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

  return notices;
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

  Future<List<Notice>> fetchNotices() async {
    try {
      AppLogger.instance.network(LogLevel.info, '开始加载通知公告列表');
      _cachedTotalPages = null;
      final notices = await _fetchNoticePage(1);
      _cachedNotices = notices;
      AppLogger.instance.network(
        LogLevel.info,
        '通知公告列表加载成功，共 ${notices.length} 条',
      );
      return notices;
    } catch (error, stackTrace) {
      final cachedNotices = _cachedNotices;
      if (cachedNotices != null) {
        AppLogger.instance.network(
          LogLevel.warn,
          '通知公告加载失败，回退缓存 ${cachedNotices.length} 条',
          error: error,
          stackTrace: stackTrace,
        );
        return cachedNotices;
      }
      AppLogger.instance.network(
        LogLevel.error,
        '通知公告加载失败',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<List<Notice>> fetchMoreNotices(int page) async {
    if (page < 1) return [];
    final totalPages = _cachedTotalPages;
    if (totalPages != null && page > totalPages) return [];

    try {
      return await _fetchNoticePage(page);
    } catch (error, stackTrace) {
      AppLogger.instance.network(
        LogLevel.error,
        '通知公告分页加载失败: page=$page',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<List<Notice>> _fetchNoticePage(int page) async {
    final url = _buildNoticePageUrl(page);
    final resp = await _getWithUnifiedAuthFallback(url);
    if (resp.data == null || resp.data!.isEmpty) return [];

    final html = utf8.decode(resp.data!, allowMalformed: true);
    final notices = parseJwcNoticeListHtml(html);
    _cachedTotalPages ??= _extractJwcNoticeTotalPages(html);
    if (notices.isEmpty) {
      final doc = html_parser.parse(html);
      final title = doc.querySelector('title')?.text.trim() ?? '';
      final hasUl1 = doc.querySelector('#ul1') != null;
      final listCount = doc.querySelectorAll('#ul1 li').length;
      AppLogger.instance.network(
        LogLevel.warn,
        '通知公告解析结果为空: page=$page, title=$title, hasUl1=$hasUl1, listCount=$listCount, bytes=${resp.data!.length}',
      );
    }
    return notices;
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

  Dio _createNoticeDio() {
    return createCampusBytesDio();
  }

  Future<Dio> _ensureNoticeDio() async {
    await NetworkSettings.instance.ensureInitialized();
    final existing = _noticeDio;
    if (existing != null) return existing;

    final created = _createNoticeDio();
    _noticeDio = created;
    return created;
  }

  Future<Response<List<int>>> _getWithUnifiedAuthFallback(String url) async {
    final directDio = await _ensureNoticeDio();
    final Response<List<int>> directResponse;
    try {
      directResponse = await directDio.get<List<int>>(url);
    } on DioException catch (error, stackTrace) {
      AppLogger.instance.network(
        LogLevel.warn,
        '通知公告直连失败，尝试通过统一认证访问: $url',
        error: error,
        stackTrace: stackTrace,
      );
      return _getThroughUnifiedAuth(url, error: error, stackTrace: stackTrace);
    } catch (error, stackTrace) {
      AppLogger.instance.network(
        LogLevel.error,
        '通知公告请求异常',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }

    if (!looksLikeNoticeResponseNeedsUnifiedAuth(directResponse)) {
      return directResponse;
    }

    AppLogger.instance.network(
      LogLevel.warn,
      '通知公告直连命中统一认证登录页，尝试恢复统一认证会话: $url',
    );
    // 统一认证路径的错误直接抛给调用方，不并入直连的 catch，避免重复回退。
    return _getThroughUnifiedAuth(url);
  }

  Future<Response<List<int>>> _getThroughUnifiedAuth(
    String url, {
    Object? error,
    StackTrace? stackTrace,
  }) async {
    final sessionStatus = await CasSession.ensure(
      url,
      syncWebViewCookies: false,
    );
    if (sessionStatus != CasSessionStatus.active) {
      AppLogger.instance.network(
        LogLevel.warn,
        '通知公告统一认证会话不可用，无法继续访问: $url',
        error: error,
        stackTrace: stackTrace,
      );
      if (error is DioException) {
        throw error;
      }
      throw StateError('通知公告统一认证会话不可用');
    }

    try {
      final response = await DioClient.instance.unifiedAuthDio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          validateStatus: (status) => status != null && status < 1000,
        ),
      );
      if (looksLikeNoticeResponseNeedsUnifiedAuth(response)) {
        AppLogger.instance.network(LogLevel.warn, '通知公告统一认证回退后仍返回登录页: $url');
        throw const CasAuthExpiredException('通知公告统一认证会话已失效，请重新登录');
      }
      AppLogger.instance.network(LogLevel.info, '通知公告已通过统一认证直连加载');
      return response;
    } on DioException catch (fallbackError, fallbackStackTrace) {
      AppLogger.instance.network(
        LogLevel.error,
        '通知公告统一认证直连回退失败',
        error: fallbackError,
        stackTrace: fallbackStackTrace,
      );
      rethrow;
    }
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
