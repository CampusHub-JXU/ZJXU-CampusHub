import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/features/physical_test/physical_test_model.dart';
import 'package:jxu_campus_hub/features/physical_test/physical_test_page.dart';
import 'package:jxu_campus_hub/features/physical_test/physical_test_service.dart';
import 'package:jxu_campus_hub/shared/widgets/app_empty_view.dart';
import 'package:jxu_campus_hub/shared/widgets/app_error_view.dart';
import 'package:jxu_campus_hub/shared/widgets/auth_required_view.dart';
import 'package:jxu_campus_hub/shared/widgets/login_shell.dart';
import 'package:jxu_campus_hub/shared/widgets/unified_auth_protected_webview_page.dart';
import 'package:jxu_campus_hub/shared/widgets/webview_page.dart';

import '../../helpers/test_setup.dart';

PhysicalTestSnapshot _snapshotWithRecords({
  String academicYear = '2025-2026',
  String totalScore = '86.5',
  String grade = '良好',
  String runName = '50 米跑',
  String runResult = '7.2 秒',
}) {
  return PhysicalTestSnapshot(
    records: [
      PhysicalTestRecord(
        academicYear: academicYear,
        totalScore: totalScore,
        grade: grade,
        items: [
          PhysicalTestItem(
            name: runName,
            result: runResult,
            score: '90',
            level: '优秀',
          ),
          const PhysicalTestItem(name: '立定跳远', result: '2.35 米', score: '83'),
        ],
      ),
    ],
  );
}

void main() {
  setUp(() async {
    await resetTestEnvironment();
    PhysicalTestService.instance.debugReset();
  });

  tearDown(() {
    PhysicalTestService.instance.debugReset();
  });

  testWidgets(
    'renders native physical test scores and never mounts a webview',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PhysicalTestPage(
            snapshotFetcher: () async => _snapshotWithRecords(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('体测成绩'), findsOneWidget);
      expect(find.text('2025-2026'), findsOneWidget);
      expect(find.text('86.5 · 良好'), findsOneWidget);
      expect(find.text('50 米跑'), findsOneWidget);
      expect(find.text('7.2 秒 · 90 分 · 优秀'), findsOneWidget);
      expect(find.text('立定跳远'), findsOneWidget);

      // 原生页面不得再挂 CAS 受保护 WebView，也不得出现登录 H5 的快速填充。
      expect(find.byType(WebViewPage), findsNothing);
      expect(find.byType(UnifiedAuthProtectedWebViewPage), findsNothing);
      expect(find.text('一键填充'), findsNothing);
      expect(find.text('一卡通快速填充'), findsNothing);
    },
  );

  testWidgets('shows native auth required guidance when not logged in', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: PhysicalTestPage()));
    await tester.pumpAndSettle();

    expect(find.byType(AuthRequiredView), findsOneWidget);
    expect(find.text('需要统一认证后继续'), findsOneWidget);
    expect(find.text('登录统一认证'), findsOneWidget);
    expect(find.byType(AppEmptyView), findsNothing);
    expect(find.byType(AppErrorView), findsNothing);
    expect(find.byType(WebViewPage), findsNothing);
    expect(find.byType(UnifiedAuthProtectedWebViewPage), findsNothing);
    expect(find.text(PhysicalTestService.unavailableMessage), findsNothing);
  });

  testWidgets(
    'login guidance triggers unified auth modal and refetches on success',
    (tester) async {
      var calls = 0;
      var loggedIn = false;

      await tester.pumpWidget(
        MaterialApp(
          home: PhysicalTestPage(
            snapshotFetcher: () async {
              calls++;
              if (!loggedIn) {
                throw const CasAuthExpiredException();
              }
              return _snapshotWithRecords();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.byType(AuthRequiredView), findsOneWidget);

      // 点击登录统一认证按钮弹出登录模态框
      await tester.tap(find.text('登录统一认证'));
      await tester.pump();
      expect(find.byType(LoginShell), findsOneWidget);

      // 模拟登录成功：关闭弹窗并返回 true，更新登录态
      loggedIn = true;
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '20260001',
      );
      Navigator.of(
        tester.element(find.byType(LoginShell)),
        rootNavigator: true,
      ).pop(true);
      await tester.pumpAndSettle();

      expect(find.byType(LoginShell), findsNothing);
      expect(find.byType(AuthRequiredView), findsNothing);
      expect(find.text('50 米跑'), findsOneWidget);
      expect(find.text('2025-2026'), findsOneWidget);
      expect(calls, greaterThanOrEqualTo(2));
    },
  );

  testWidgets('empty state refresh re-queries the boundary', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PhysicalTestPage(
          snapshotFetcher: () async {
            calls++;
            return const PhysicalTestSnapshot(message: '本次没有记录');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.byType(AppEmptyView), findsOneWidget);
    expect(find.text('暂无体测成绩'), findsOneWidget);
    expect(find.text('本次没有记录'), findsOneWidget);

    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    expect(calls, 2);
  });

  testWidgets('failure shows error view and retry re-fetches', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PhysicalTestPage(
          snapshotFetcher: () async {
            calls++;
            if (calls == 1) {
              throw StateError('offline');
            }
            return _snapshotWithRecords();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.text('体测成绩加载失败，请稍后重试'), findsOneWidget);
    expect(calls, 1);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(AppErrorView), findsNothing);
    expect(find.text('50 米跑'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('account change clears old records and loads new account data', (
    tester,
  ) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'student_A',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PhysicalTestPage(
          snapshotFetcher: () async {
            final account = UnifiedAuthService.instance.currentAccount;
            if (account == 'student_A') {
              return _snapshotWithRecords(runName: 'A君的50米跑');
            } else if (account == 'student_B') {
              return _snapshotWithRecords(runName: 'B君的1000米跑');
            }
            throw const CasAuthExpiredException();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('A君的50米跑'), findsOneWidget);
    expect(find.text('B君的1000米跑'), findsNothing);

    // 切换账号为 student_B
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'student_B',
    );
    UnifiedAuthService.instance.notifyListeners();
    await tester.pumpAndSettle();

    // A君的成绩已被清除，展示B君的成绩
    expect(find.text('A君的50米跑'), findsNothing);
    expect(find.text('B君的1000米跑'), findsOneWidget);
  });

  testWidgets(
    'logout immediately clears records and displays auth required view',
    (tester) async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'student_A',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: PhysicalTestPage(
            snapshotFetcher: () async => _snapshotWithRecords(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('50 米跑'), findsOneWidget);
      expect(find.byType(AuthRequiredView), findsNothing);

      // 用户登出
      await UnifiedAuthService.instance.markLoggedOut();
      await tester.pumpAndSettle();

      // 旧成绩立即被清空，展示登录引导
      expect(find.text('50 米跑'), findsNothing);
      expect(find.byType(AuthRequiredView), findsOneWidget);
      expect(find.text('需要统一认证后继续'), findsOneWidget);
    },
  );

  testWidgets(
    'late arrival from superseded load or switched account is discarded',
    (tester) async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'student_A',
      );

      final completerA = Completer<PhysicalTestSnapshot>();
      final completerB = Completer<PhysicalTestSnapshot>();

      await tester.pumpWidget(
        MaterialApp(
          home: PhysicalTestPage(
            snapshotFetcher: () {
              final account = UnifiedAuthService.instance.currentAccount;
              if (account == 'student_A') {
                return completerA.future;
              } else {
                return completerB.future;
              }
            },
          ),
        ),
      );
      await tester.pump(); // loading student_A

      // 在 A 的请求还在等待时，切换到 student_B
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'student_B',
      );
      UnifiedAuthService.instance.notifyListeners();
      await tester.pump(); // starts student_B load

      // 迟到的 A 结果到达
      completerA.complete(_snapshotWithRecords(runName: '迟到的A成绩'));
      await tester.pump();

      // 迟到的 A 成绩绝不能显示
      expect(find.text('迟到的A成绩'), findsNothing);

      // B 的正常结果到达
      completerB.complete(_snapshotWithRecords(runName: 'B君成绩'));
      await tester.pumpAndSettle();

      expect(find.text('B君成绩'), findsOneWidget);
      expect(find.text('迟到的A成绩'), findsNothing);
    },
  );
}
