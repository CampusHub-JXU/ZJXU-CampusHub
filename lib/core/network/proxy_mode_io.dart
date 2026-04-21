import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

void applyProxyModeToDio(Dio dio, {required bool ignoreSystemProxy}) {
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      if (ignoreSystemProxy) {
        client.findProxy = (_) => 'DIRECT';
      }
      return client;
    },
  );
}

Future<String?> detectSystemProxy({
  String testUrl = 'https://newca.zjxu.edu.cn/',
}) async {
  final lookup = debugSystemProxyLookup;
  if (lookup != null) {
    return _normalizeProxyRules(await lookup(Uri.parse(testUrl)));
  }

  final rules = HttpClient.findProxyFromEnvironment(Uri.parse(testUrl));
  return _normalizeProxyRules(rules);
}

String describeSystemProxyRetryReason(Object error) {
  if (_looksLikeTlsHandshakeFailure(error)) {
    return 'TLS 握手失败';
  }
  if (error is TimeoutException) {
    return '请求超时';
  }
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
        return '连接超时';
      case DioExceptionType.receiveTimeout:
        return '响应超时';
      case DioExceptionType.connectionError:
        return '连接异常';
      default:
        break;
    }
  }
  return '网络异常';
}

bool shouldRetryWithSystemProxyForError(
  Object error, {
  required bool ignoreSystemProxy,
}) {
  if (!ignoreSystemProxy) return false;
  if (error is TimeoutException || error is HandshakeException) return true;
  if (error is DioException) {
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.connectionError ||
        error.error is HandshakeException) {
      return true;
    }
  }
  return _looksLikeTlsHandshakeFailure(error);
}

bool _looksLikeTlsHandshakeFailure(Object error) {
  final buffer = StringBuffer(error.toString().toLowerCase());
  if (error is DioException) {
    final message = error.message;
    if (message != null && message.isNotEmpty) {
      buffer.write(' ');
      buffer.write(message.toLowerCase());
    }
    final innerError = error.error;
    if (innerError != null) {
      buffer.write(' ');
      buffer.write(innerError.toString().toLowerCase());
    }
  }
  final text = buffer.toString();
  return text.contains('handshakeexception') ||
      text.contains('connection terminated during handshake') ||
      text.contains('tls') && text.contains('handshake');
}

String? _normalizeProxyRules(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return null;
  final rules = text
      .split(';')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
  if (rules.isEmpty) return null;
  final nonDirectRule = rules.firstWhere(
    (item) => item.toUpperCase() != 'DIRECT',
    orElse: () => '',
  );
  return nonDirectRule.isEmpty ? null : nonDirectRule;
}

@visibleForTesting
FutureOr<String?> Function(Uri uri)? debugSystemProxyLookup;
