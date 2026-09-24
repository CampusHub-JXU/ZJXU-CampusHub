import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_service.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        'test/$folderName';
    await DioClient.instance.ensureInitialized();
  });

  test('changxing requests use unified auth dio', () async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '20260001',
    );
    await const FlutterSecureStorage().write(
      key: ChangxingJiadaService.tokenStorageKeyV2,
      value: ChangxingJiadaService.encodeTokenEnvelope(
        owner: '20260001',
        token: 'test-token',
      ),
    );

    final requestPath = Uri.parse(
      'https://zhx.zjxu.edu.cn/api/msg/getNoReadCount',
    ).path;

    final sentTokens = <String?>[];
    final unifiedAdapter = MockHttpClientAdapter()
      ..register('GET', requestPath, (options) async {
        sentTokens.add(options.headers['token']?.toString());
        return ResponseBody.fromString(
          jsonEncode({
            'data': {'code': '20000', 'count': 3},
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      });
    final zhengfangAdapter = MockHttpClientAdapter();

    DioClient.instance.unifiedAuthDio.httpClientAdapter = unifiedAdapter;
    DioClient.instance.dio.httpClientAdapter = zhengfangAdapter;

    final count = await ChangxingJiadaService.instance.fetchUnreadCount();

    expect(count, 3);
    expect(unifiedAdapter.requestLog, ['GET $requestPath']);
    expect(zhengfangAdapter.requestLog, isEmpty);
    expect(sentTokens, ['test-token']);
  });
}
