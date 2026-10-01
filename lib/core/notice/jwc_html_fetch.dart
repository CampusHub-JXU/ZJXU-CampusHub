import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../auth/cas_auth_broker.dart';
import '../logging/app_logger.dart';

/// 教务处（jwc）HTML 资源抓取的三态结果。
@immutable
sealed class JwcHtmlResult {
  const JwcHtmlResult();
}

/// 拿到非空 body（UTF-8 宽松解码后的 HTML）。
class JwcHtmlOk extends JwcHtmlResult {
  const JwcHtmlOk(this.html);

  final String html;
}

/// 统一认证会话明确失效（[CasAuthExpiredException]），需登录后重试。
class JwcHtmlAuthRequired extends JwcHtmlResult {
  const JwcHtmlAuthRequired();
}

/// 其余一切：空 body、网络失败、预算到期、取消。
class JwcHtmlUnavailable extends JwcHtmlResult {
  const JwcHtmlUnavailable();
}

/// 经 [CasAuthBroker.getResource] 抓取 jwc 资源页并解码为 HTML。
///
/// 永不抛异常。[failureLabel] 是异常日志文案；调用方主动
/// 取消（[CancelToken]）不记日志。总预算默认 [CasAuthBroker.defaultResourceBudget]，
/// 传 [deadline] 时以绝对截止时间为准。
Future<JwcHtmlResult> fetchJwcHtml(
  String url, {
  required String failureLabel,
  Dio? dio,
  CancelToken? cancelToken,
  Duration timeout = CasAuthBroker.defaultResourceBudget,
  DateTime? deadline,
}) async {
  try {
    final resp = await CasAuthBroker.getResource(
      url,
      dio: dio,
      cancelToken: cancelToken,
      timeout: timeout,
      deadline: deadline,
    );
    final data = resp.data;
    if (data == null || data.isEmpty) return const JwcHtmlUnavailable();
    return JwcHtmlOk(utf8.decode(data, allowMalformed: true));
  } on CasAuthExpiredException {
    return const JwcHtmlAuthRequired();
  } catch (error, stackTrace) {
    if (error is DioException && CancelToken.isCancel(error)) {
      return const JwcHtmlUnavailable();
    }
    AppLogger.instance.network(
      LogLevel.warn,
      failureLabel,
      error: error,
      stackTrace: stackTrace,
    );
    return const JwcHtmlUnavailable();
  }
}
