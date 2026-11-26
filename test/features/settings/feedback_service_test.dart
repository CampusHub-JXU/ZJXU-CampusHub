import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/settings/feedback_service.dart';

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);

  final ResponseBody Function(RequestOptions options, Map<String, dynamic> body)
  handler;

  RequestOptions? lastOptions;
  Map<String, dynamic>? lastBody;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    final raw = options.data;
    if (raw is Map<String, dynamic>) {
      lastBody = raw;
    } else if (raw is String && raw.isNotEmpty) {
      lastBody = jsonDecode(raw) as Map<String, dynamic>;
    } else {
      lastBody = const {};
    }
    return handler(options, lastBody!);
  }
}

void main() {
  const testEnv = FeedbackEnvironment(
    appVersion: 'v0.13.5+2066',
    osInfo: 'android 15',
    buildMode: 'release',
  );

  FeedbackSubmission makeSubmission({
    FeedbackType type = FeedbackType.bug,
    String title = '实验课表无法导入',
    String description = '在教务页面点击导入实验课表后提示解析失败。',
    String contact = '123456@qq.com',
    String? diagnostics,
  }) {
    return FeedbackSubmission(
      type: type,
      title: title,
      description: description,
      campus: FeedbackCampus.lianglin,
      contact: contact,
      diagnostics: diagnostics,
      environment: testEnv,
    );
  }

  test('submit sends expected headers and payload and parses result', () async {
    final adapter = _StubAdapter((options, body) {
      return ResponseBody.fromString(
        jsonEncode({
          'ok': true,
          'issueNumber': 42,
          'issueUrl':
              'https://github.com/CampusHub-JXU/ZJXU-CampusHub/issues/42',
        }),
        201,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final service = FeedbackService(
      dio: dio,
      endpointUrl: 'https://feedback.fhfanshu.xyz/api/feedback',
      clientKey: 'secret-key',
    );

    final result = await service.submit(
      makeSubmission(diagnostics: 'line1\nline2'),
    );

    expect(result.issueNumber, 42);
    expect(
      result.issueUrl,
      'https://github.com/CampusHub-JXU/ZJXU-CampusHub/issues/42',
    );
    expect(adapter.lastOptions?.headers['X-App-Client'], 'jxu-campushub');
    expect(adapter.lastOptions?.headers['X-Client-Key'], 'secret-key');
    expect(adapter.lastBody?['type'], 'bug');
    expect(adapter.lastBody?['campus'], '梁林校区');
    expect(adapter.lastBody?['appVersion'], 'v0.13.5+2066');
    expect(adapter.lastBody?['diagnostics'], 'line1\nline2');
  });

  test('submit maps server error message and 429 rate limit', () async {
    final adapter429 = _StubAdapter((options, body) {
      return ResponseBody.fromString(
        jsonEncode({'ok': false, 'error': '提交过于频繁，请 10 分钟后再试'}),
        429,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    });
    final dio = Dio()..httpClientAdapter = adapter429;
    final service = FeedbackService(
      dio: dio,
      endpointUrl: 'https://feedback.fhfanshu.xyz/api/feedback',
    );

    await expectLater(
      service.submit(makeSubmission()),
      throwsA(
        isA<FeedbackSubmitException>().having(
          (e) => e.message,
          'message',
          '提交过于频繁，请 10 分钟后再试',
        ),
      ),
    );
  });

  test('buildFallbackMarkdown formats readable fallback report', () {
    final service = FeedbackService(
      endpointUrl: 'https://feedback.fhfanshu.xyz/api/feedback',
    );
    final markdown = service.buildFallbackMarkdown(
      makeSubmission(
        type: FeedbackType.feature,
        title: '支持深色模式自动切换',
        description: '希望可以跟随系统定时切换浅色和深色主题。',
        contact: '',
      ),
    );

    expect(markdown, contains('[建议] 支持深色模式自动切换'));
    expect(markdown, contains('- 类型：功能建议'));
    expect(markdown, contains('- 校区：梁林校区'));
    expect(markdown, contains('v0.13.5+2066 · android 15 · release'));
    expect(markdown, isNot(contains('- 联系：')));
  });
}
