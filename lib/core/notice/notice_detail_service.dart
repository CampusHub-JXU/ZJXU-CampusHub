import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';
import '../network/dio_client.dart';
import 'jwc_html_fetch.dart';
import 'notice_detail.dart';

/// 详情抓取结果。
@immutable
sealed class NoticeDetailResult {
  const NoticeDetailResult();
}

class NoticeDetailLoaded extends NoticeDetailResult {
  const NoticeDetailLoaded(this.detail);

  final NoticeDetail detail;
}

/// 统一认证会话失效，需要登录后重试。
class NoticeDetailAuthRequired extends NoticeDetailResult {
  const NoticeDetailAuthRequired();
}

/// 网络失败或页面结构不认识：调用方回退原网页。
class NoticeDetailUnavailable extends NoticeDetailResult {
  const NoticeDetailUnavailable({required this.structureMismatch});

  /// true 表示页面拿到了但不是已知模板（改版），重试无意义。
  final bool structureMismatch;
}

/// 教务处公告详情的原生阅读抓取。
///
/// 与列表同一条认证链：`CasAuthBroker.getResource` 逐跳建立 CMS Cookie
/// （资源 URL，不是 CAS service），20 秒总预算到期取消传输。永不抛异常。
/// 公告正文属受保护资源，不落盘缓存。
class NoticeDetailService {
  NoticeDetailService._();

  static final NoticeDetailService instance = NoticeDetailService._();

  Dio? _dio;

  Future<NoticeDetailResult> fetch(
    String url, {
    CancelToken? cancelToken,
  }) async {
    final result = await fetchJwcHtml(
      url,
      failureLabel: '教务处公告详情抓取失败',
      dio: _dio,
      cancelToken: cancelToken,
    );
    switch (result) {
      case JwcHtmlAuthRequired():
        return const NoticeDetailAuthRequired();
      case JwcHtmlUnavailable():
        return const NoticeDetailUnavailable(structureMismatch: false);
      case JwcHtmlOk(:final html):
        try {
          final detail = parseNoticeDetailHtml(html, pageUrl: url);
          if (detail == null) {
            AppLogger.instance.network(LogLevel.warn, '教务处公告详情结构无法识别，回退原网页');
            return const NoticeDetailUnavailable(structureMismatch: true);
          }
          return NoticeDetailLoaded(detail);
        } catch (error, stackTrace) {
          AppLogger.instance.network(
            LogLevel.warn,
            '教务处公告详情抓取失败',
            error: error,
            stackTrace: stackTrace,
          );
          return const NoticeDetailUnavailable(structureMismatch: false);
        }
    }
  }

  /// 附件下载交给系统 DownloadManager（不共享 Dio Cookie）：取统一认证
  /// CookieJar 中目标 URL 的 Cookie 拼成请求头。取不到返回 null。
  Future<String?> cookieHeaderFor(String url) async {
    try {
      await DioClient.instance.ensureInitialized();
      final cookies = await DioClient.instance.unifiedAuthCookieJar
          .loadForRequest(Uri.parse(url));
      if (cookies.isEmpty) return null;
      return cookies.map((c) => '${c.name}=${c.value}').join('; ');
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  void debugSetDio(Dio? dio) => _dio = dio;
}
