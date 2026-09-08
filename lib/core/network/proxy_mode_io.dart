import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

/// Applies Dart HttpClient proxy policy. Default is DIRECT.
///
/// When [ignoreSystemProxy] is false, HttpClient uses
/// [HttpClient.findProxyFromEnvironment] (HTTP_PROXY / HTTPS_PROXY / NO_PROXY).
/// This is not a phone-VPN bypass and does not read Android Wi-Fi proxy.
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
}) {
  return resolveHttpProxyForUri(Uri.parse(testUrl));
}

/// First non-DIRECT rule for [uri], or null when the target is DIRECT / unset.
/// Honors NO_PROXY via [HttpClient.findProxyFromEnvironment] (or [debugSystemProxyLookup]).
Future<String?> resolveHttpProxyForUri(Uri uri) async {
  final lookup = debugSystemProxyLookup;
  if (lookup != null) {
    return _normalizeProxyRules(await lookup(uri));
  }
  return _normalizeProxyRules(HttpClient.findProxyFromEnvironment(uri));
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
  if (error is TimeoutException ||
      error is HandshakeException ||
      error is SocketException) {
    return true;
  }
  if (error is DioException) {
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.connectionError ||
        error.error is HandshakeException ||
        error.error is SocketException) {
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
