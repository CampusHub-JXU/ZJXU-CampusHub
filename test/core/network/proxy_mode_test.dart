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

    test('retries socket failures wrapped as Dio unknown', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/cas/login'),
        type: DioExceptionType.unknown,
        error: const SocketException('Failed host lookup'),
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

  group('resolveHttpProxyForUri', () {
    test('uses the request uri instead of a hardcoded CAS host', () async {
      final seen = <Uri>[];
      debugSystemProxyLookup = (uri) async {
        seen.add(uri);
        if (uri.host == 'jwzx.zjxu.edu.cn') {
          return 'PROXY 127.0.0.1:8888';
        }
        return 'DIRECT';
      };

      expect(
        await resolveHttpProxyForUri(
          Uri.parse('https://jwzx.zjxu.edu.cn/jwglxt'),
        ),
        'PROXY 127.0.0.1:8888',
      );
      expect(
        await resolveHttpProxyForUri(
          Uri.parse('https://newca.zjxu.edu.cn/cas/login'),
        ),
        isNull,
      );
      expect(seen.map((uri) => uri.host), [
        'jwzx.zjxu.edu.cn',
        'newca.zjxu.edu.cn',
      ]);
    });

    test('treats NO_PROXY / DIRECT targets as no retryable proxy', () async {
      debugSystemProxyLookup = (uri) async {
        if (uri.host.endsWith('zjxu.edu.cn')) return 'DIRECT';
        return 'PROXY 127.0.0.1:8888';
      };

      expect(
        await resolveHttpProxyForUri(Uri.parse('https://newca.zjxu.edu.cn/')),
        isNull,
      );
    });
  });
}
