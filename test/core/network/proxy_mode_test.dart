import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/network/proxy_mode.dart';

void main() {
  tearDown(() {
    debugSystemProxyLookup = null;
  });

  group('shouldRetryWithSystemProxyForError', () {
    test('retries tls handshake failures wrapped by Dio', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/cas/login'),
        type: DioExceptionType.unknown,
        error: HandshakeException('Connection terminated during handshake'),
        message: 'HandshakeException: Connection terminated during handshake',
      );

      expect(
        shouldRetryWithSystemProxyForError(error, ignoreSystemProxy: true),
        isTrue,
      );
    });

    test('does not retry when system proxy is already enabled', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/cas/login'),
        type: DioExceptionType.connectionError,
        error: const SocketException('Failed host lookup'),
      );

      expect(
        shouldRetryWithSystemProxyForError(error, ignoreSystemProxy: false),
        isFalse,
      );
    });
  });

  group('detectSystemProxy', () {
    test('returns first non-direct proxy rule', () async {
      debugSystemProxyLookup = (_) async => 'PROXY 127.0.0.1:8888; DIRECT';

      expect(await detectSystemProxy(), 'PROXY 127.0.0.1:8888');
    });

    test('returns null when rules are direct only', () async {
      debugSystemProxyLookup = (_) async => 'DIRECT';

      expect(await detectSystemProxy(), isNull);
    });
  });
}
