import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:jxu_campus_hub/features/settings/feedback_page.dart';
import 'package:jxu_campus_hub/features/settings/feedback_service.dart';
import 'package:jxu_campus_hub/features/settings/feedback_hub_page.dart';

import '../../helpers/feedback_test_support.dart';

class ReportService extends FeedbackService {
  int reports = 0;
  final sent = <FeedbackSubmission>[];
  Completer<FeedbackSubmitResult>? pending;
  bool fail = false;
  @override
  Future<FeedbackEnvironment> collectEnvironment() async =>
      const FeedbackEnvironment(
        appVersion: 'test',
        osInfo: 'Android',
        buildMode: 'debug',
      );
  @override
  Future<String> collectDiagnostics(String version) async =>
      '已预览的报告 ${++reports}';
  @override
  Future<FeedbackSubmitResult> submit(FeedbackSubmission submission) async {
    sent.add(submission);
    if (fail) {
      throw const FeedbackSubmitException(
        '请求超时，Issue 可能已创建，请先查看 GitHub 反馈列表，避免重复提交',
      );
    }
    return pending != null
        ? pending!.future
        : const FeedbackSubmitResult(
            issueNumber: 42,
            issueUrl:
                'https://github.com/CampusHub-JXU/ZJXU-CampusHub/issues/42',
          );
  }
}

void main() {
  late MemoryFeedbackStore store;
  late ReportService service;
  setUp(() {
    store = MemoryFeedbackStore();
    service = ReportService();
  });

  Future<void> form(WidgetTester tester, {bool fill = true}) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: FeedbackPage(service: service, store: store),
      ),
    );
    await tester.pumpAndSettle();
    if (fill) {
      await tester.enterText(find.byType(TextField).at(0), '网络连接问题');
      await tester.enterText(find.byType(TextField).at(1), '刷新页面后显示连接失败。');
    }
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.ensureVisible(find.text('提交反馈'));
    await tester.tap(find.text('提交反馈'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认公开并提交'));
    await tester.pump();
  }

  testWidgets('logs default off and public cancellation makes no request', (
    tester,
  ) async {
    await form(tester);
    await tester.enterText(
      find.byType(TextField).at(2),
      'test@example.invalid',
    );
    await tester.ensureVisible(find.text('提交反馈'));
    await tester.tap(find.text('提交反馈'));
    await tester.pumpAndSettle();
    expect(find.textContaining('联系方式将发布到公开 GitHub Issue'), findsOneWidget);
    expect(service.sent, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.sent, isEmpty);
    await confirm(tester);
    await tester.pumpAndSettle();
    expect(service.sent, hasLength(1));
    expect(service.sent.single.diagnostics, isNull);
    expect(service.reports, 0);
    expect(store.records, hasLength(1));
    expect(store.preferences['draft'], isNull);
    expect(find.text('提交成功'), findsOneWidget);
  });

  testWidgets('only the exact previewed report is submitted', (tester) async {
    await form(tester);
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('诊断报告预览'), findsOneWidget);
    expect(find.text('已预览的报告 1'), findsOneWidget);
    await tester.tap(find.text('确认附带并公开'));
    await tester.pumpAndSettle();
    await confirm(tester);
    await tester.pumpAndSettle();
    expect(service.sent.single.diagnostics, '已预览的报告 1');
    expect(service.reports, 1);
  });

  testWidgets('declining diagnostic preview keeps logs off', (tester) async {
    await form(tester);
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不附带'));
    await tester.pumpAndSettle();
    await confirm(tester);
    await tester.pumpAndSettle();
    expect(service.sent.single.diagnostics, isNull);
  });

  testWidgets('timeout retains draft and does not retry automatically', (
    tester,
  ) async {
    service.fail = true;
    await form(tester);
    await confirm(tester);
    await tester.pumpAndSettle();
    expect(service.sent, hasLength(1));
    expect(store.records, isEmpty);
    expect(jsonDecode(store.preferences['draft']!)['title'], '网络连接问题');
    expect(find.textContaining('Issue 可能已创建'), findsOneWidget);
    expect(find.text('提交成功'), findsNothing);
    await tester.pump(const Duration(minutes: 1));
    expect(service.sent, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await form(tester, fill: false);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
      '网络连接问题',
    );
  });

  testWidgets('restored draft never enables or stores diagnostics', (
    tester,
  ) async {
    store.preferences['draft'] = jsonEncode({
      'title': '草稿标题',
      'description': '已有的草稿描述',
      'diagnostics': true,
    });
    await form(tester, fill: false);
    expect(tester.widget<Switch>(find.byType(Switch)).value, false);
    await confirm(tester);
    await tester.pumpAndSettle();
    expect(service.sent.single.diagnostics, isNull);
  });

  testWidgets(
    'leaving during submission saves successful link without disposed controller access',
    (tester) async {
      service.pending = Completer<FeedbackSubmitResult>();
      await form(tester);
      await confirm(tester);
      expect(service.sent, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      service.pending!.complete(
        const FeedbackSubmitResult(
          issueNumber: 42,
          issueUrl: 'https://github.com/CampusHub-JXU/ZJXU-CampusHub/issues/42',
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(store.records, hasLength(1));
      expect(store.preferences['draft'], isNull);
    },
  );

  testWidgets(
    'local storage failure does not turn successful Issue into failed submission',
    (tester) async {
      store.failWrites = true;
      await form(tester);
      await confirm(tester);
      await tester.pumpAndSettle();
      expect(service.sent, hasLength(1));
      expect(find.text('提交成功'), findsOneWidget);
      expect(
        find.textContaining(
          'https://github.com/CampusHub-JXU/ZJXU-CampusHub/issues/42',
        ),
        findsWidgets,
      );
    },
  );

  testWidgets(
    'hub lists local links without synchronization or notification controls',
    (tester) async {
      store.records.add({
        'title': '已有反馈',
        'number': 42,
        'url': 'https://github.com/CampusHub-JXU/ZJXU-CampusHub/issues/42',
      });
      await tester.pumpWidget(MaterialApp(home: FeedbackHubPage(store: store)));
      await tester.pumpAndSettle();
      expect(find.text('已有反馈'), findsOneWidget);
      expect(find.text('复制 Issue 链接'), findsNothing);
      expect(find.byType(SwitchListTile), findsNothing);
    },
  );
}
