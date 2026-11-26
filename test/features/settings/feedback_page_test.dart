import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/settings/feedback_page.dart';
import 'package:jxu_campus_hub/features/settings/feedback_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _SuccessAdapter implements HttpClientAdapter {
  Map<String, dynamic>? capturedBody;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final raw = options.data;
    capturedBody = raw is Map<String, dynamic>
        ? raw
        : jsonDecode(raw as String) as Map<String, dynamic>;
    return ResponseBody.fromString(
      jsonEncode({
        'ok': true,
        'issueNumber': 88,
        'issueUrl': 'https://github.com/CampusHub-JXU/ZJXU-CampusHub/issues/88',
      }),
      201,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: '嘉兴大学',
      packageName: 'cn.edu.zjxu.campushub',
      version: '0.13.5',
      buildNumber: '2066',
      buildSignature: '',
    );
  });

  testWidgets('FeedbackPage validates input and submits issue', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final adapter = _SuccessAdapter();
    final service = FeedbackService(
      dio: Dio()..httpClientAdapter = adapter,
      endpointUrl: 'https://feedback.fhfanshu.xyz/api/feedback',
    );

    await tester.pumpWidget(MaterialApp(home: FeedbackPage(service: service)));
    await tester.pumpAndSettle();

    // 空标题拦截提示
    final submitFinder = find.text('提交反馈');
    await tester.ensureVisible(submitFinder);
    await tester.tap(submitFinder);
    await tester.pumpAndSettle();
    expect(find.text('请填写至少 2 个字的标题'), findsOneWidget);

    // 触发校验的 SnackBar 收起后再点击提交，避免遮挡底部按钮
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // 填写并提交
    await tester.enterText(find.byType(TextField).at(0), '成绩页面加载慢');
    await tester.enterText(
      find.byType(TextField).at(1),
      '点击成绩查询后转圈超过 10 秒才显示列表。',
    );
    await tester.ensureVisible(submitFinder);
    await tester.tap(submitFinder);
    await tester.pumpAndSettle();

    expect(adapter.capturedBody?['title'], '成绩页面加载慢');
    expect(adapter.capturedBody?['type'], 'bug');
    expect(find.text('提交成功'), findsOneWidget);
    expect(find.textContaining('#88'), findsOneWidget);
  });

  testWidgets('FeedbackPage copies fallback markdown to clipboard', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final service = FeedbackService(
      dio: Dio()..httpClientAdapter = _SuccessAdapter(),
      endpointUrl: 'https://feedback.fhfanshu.xyz/api/feedback',
    );
    await tester.pumpWidget(MaterialApp(home: FeedbackPage(service: service)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('功能建议'));
    await tester.enterText(find.byType(TextField).at(0), '增加深色小组件');
    await tester.enterText(
      find.byType(TextField).at(1),
      '桌面小组件希望可以跟随系统深色模式自动变暗。',
    );

    final copyFinder = find.text('复制反馈文本（网络不佳时备用）');
    await tester.ensureVisible(copyFinder);
    await tester.tap(copyFinder);
    await tester.pumpAndSettle();

    expect(copiedText, contains('[建议] 增加深色小组件'));
    expect(find.text('已复制反馈内容，可直接粘贴到群聊或邮件'), findsOneWidget);
  });
}
