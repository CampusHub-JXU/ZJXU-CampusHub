import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/logging/app_logger.dart';
import 'package:jxu_campus_hub/features/notice/notice_service.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
    NoticeService.instance.debugReset();
  });

  tearDown(() {
    NoticeService.instance.debugReset();
  });

  test('logs error when notice list load fails without cache', () async {
    final dio = Dio(BaseOptions(responseType: ResponseType.bytes))
      ..httpClientAdapter = MockHttpClientAdapter();
    NoticeService.instance.debugSetDio(dio);

    await expectLater(NoticeService.instance.fetchNotices(), throwsA(anything));

    final messages = AppLogger.instance.entries.map((entry) => entry.message);
    expect(messages, contains('开始加载通知公告列表'));
    expect(messages, contains('通知公告加载失败'));
    expect(
      AppLogger.instance.entries.any((entry) => entry.level == LogLevel.error),
      isTrue,
    );
  });
}
