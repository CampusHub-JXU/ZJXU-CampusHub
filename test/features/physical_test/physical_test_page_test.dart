import 'dart:async';

import 'package:material_ui/material_ui.dart';
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

PhysicalTestRecord _record({
  required String academicYear,
  String totalScore = '',
  String grade = '',
  List<PhysicalTestItem> items = const [],
}) {
  return PhysicalTestRecord(
    academicYear: academicYear,
    totalScore: totalScore,
    grade: grade,
    items: items,
  );
}

/// 历年选择器里第 [index] 个 chip（共享 `AppFilterChips` 渲染的自定义 tab，
/// 原 `ChoiceChip` 已移除；每个 tab 是 `Semantics(selected: …)` 包裹的
/// `InkWell`）。
Finder _yearChip(int index) => find
    .descendant(
      of: find.byKey(const Key('physical_test_year_chips')),
      matching: find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.selected != null,
      ),
    )
    .at(index);

bool _chipSelected(WidgetTester tester, int index) =>
    tester.widget<Semantics>(_yearChip(index)).properties.selected ?? false;

PhysicalTestSnapshot _multiYearSnapshot() {
  return PhysicalTestSnapshot(
    records: [
      _record(
        academicYear: '2025-2026',
        totalScore: '86.5',
        grade: '良好',
        items: const [
          PhysicalTestItem(
            name: '50 米跑',
            result: '7.2 秒',
            score: '90',
            level: '优秀',
          ),
          PhysicalTestItem(name: '立定跳远', result: '2.35 米', score: '83'),
        ],
      ),
      _record(
        academicYear: '2024-2025',
        totalScore: '78',
        grade: '及格',
        items: const [
          PhysicalTestItem(
            name: '1000 米跑',
            result: '4 分 10 秒',
            score: '70',
            level: '及格',
          ),
        ],
      ),
      _record(academicYear: '2023-2024'),
    ],
  );
}

/// 主读数区（学年 / 总分 / 等级）内的文本；避免与年份 chip 上同名学年文字重影。
Finder _readout(String text) => find.descendant(
  of: find.byKey(const Key('physical_test_primary_readout')),
  matching: find.text(text),
);

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

      // 主读数分层：学年 + 「最新」标签，总分与等级各自带标签、不拼成一串。
      expect(find.text('2025-2026'), findsOneWidget);
      expect(find.text('最新'), findsOneWidget);
      expect(find.text('总分'), findsOneWidget);
      expect(find.text('86.5'), findsOneWidget);
      expect(find.text('等级'), findsOneWidget);
      expect(find.text('良好'), findsOneWidget);

      // 单项：项目名在左、原始测量值在右、得分 / 评价各自带标签。
      expect(find.text('50 米跑'), findsOneWidget);
      expect(find.text('7.2 秒'), findsOneWidget);
      expect(find.text('立定跳远'), findsOneWidget);
      expect(find.text('2.35 米'), findsOneWidget);
      expect(find.text('得分'), findsNWidgets(2));
      expect(find.text('评价'), findsOneWidget);
      expect(find.text('90'), findsOneWidget);
      expect(find.text('83'), findsOneWidget);
      expect(find.text('优秀'), findsOneWidget);

      // 旧版 `总分 · 等级` / `结果 · 得分 · 等级` 单串拼接不得回归。
      expect(find.text('86.5 · 良好'), findsNothing);
      expect(find.text('7.2 秒 · 90 分 · 优秀'), findsNothing);

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

  // ── 新布局：最新学年主读数 / 历年切换 / 字段保真 ─────────────────────────────

  testWidgets('latest year total is primary and every record stays reachable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PhysicalTestPage(
          snapshotFetcher: () async => _multiYearSnapshot(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 最新学年在主读数，总分 + 等级 + 「最新」，第一屏可见。
    expect(_readout('2025-2026'), findsOneWidget);
    expect(_readout('最新'), findsOneWidget);
    expect(_readout('86.5'), findsOneWidget);
    expect(_readout('良好'), findsOneWidget);
    expect(find.text('50 米跑'), findsOneWidget);

    // 全部历史学年都可发现（横向选择器 + 每个记录一格）。
    expect(find.text('历年'), findsOneWidget);
    expect(_yearChip(0), findsOneWidget);
    expect(_yearChip(1), findsOneWidget);
    expect(_yearChip(2), findsOneWidget);
    expect(find.text('2024-2025'), findsOneWidget);
    expect(find.text('2023-2024'), findsOneWidget);

    // 切到历史学年：读数与明细同步切换，不再显示最新学年内容。
    await tester.tap(_yearChip(1));
    await tester.pumpAndSettle();

    expect(_readout('2024-2025'), findsOneWidget);
    expect(_readout('78'), findsOneWidget);
    expect(_readout('及格'), findsOneWidget);
    expect(find.text('1000 米跑'), findsOneWidget);
    expect(find.text('4 分 10 秒'), findsOneWidget);
    expect(_readout('最新'), findsNothing);
    expect(find.text('86.5'), findsNothing);
    expect(find.text('50 米跑'), findsNothing);
  });

  testWidgets('missing total and grade show truthful placeholders, not 0', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PhysicalTestPage(
          snapshotFetcher: () async => _multiYearSnapshot(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 2023-2024 无总分、无等级、无项目。
    await tester.tap(_yearChip(2));
    await tester.pumpAndSettle();

    expect(find.text('--'), findsOneWidget);
    expect(find.text('暂无等级'), findsOneWidget);
    expect(find.text('暂无项目数据'), findsOneWidget);
    expect(find.text('0'), findsNothing);
    expect(find.text('0 分'), findsNothing);
  });

  testWidgets('non-numeric results and long units are shown verbatim', (
    tester,
  ) async {
    final snapshot = PhysicalTestSnapshot(
      records: [
        _record(
          academicYear: '2025-2026',
          totalScore: '免测',
          grade: '免测',
          items: const [
            PhysicalTestItem(name: '肺活量', result: '4123.5 毫升'),
            PhysicalTestItem(name: '800 米跑', result: '4 分 05 秒', score: '72.5'),
            PhysicalTestItem(name: '引体向上', result: '未参加', level: '免测'),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PhysicalTestPage(snapshotFetcher: () async => snapshot),
      ),
    );
    await tester.pumpAndSettle();

    // 原始值原样呈现，不转换、不补 0、不补 %。
    expect(find.text('免测'), findsWidgets);
    expect(find.text('4123.5 毫升'), findsOneWidget);
    expect(find.text('4 分 05 秒'), findsOneWidget);
    expect(find.text('未参加'), findsOneWidget);
    expect(find.text('72.5'), findsOneWidget);
    expect(find.text('0'), findsNothing);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('missing item name and empty result use truthful placeholders', (
    tester,
  ) async {
    final snapshot = PhysicalTestSnapshot(
      records: [
        _record(
          academicYear: '2025-2026',
          totalScore: '80',
          grade: '良好',
          items: const [PhysicalTestItem(name: '', result: '')],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PhysicalTestPage(snapshotFetcher: () async => snapshot),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('未命名项目'), findsOneWidget);
    expect(find.text('--'), findsOneWidget);
  });

  testWidgets('duplicate year labels keep every record reachable', (
    tester,
  ) async {
    final snapshot = PhysicalTestSnapshot(
      records: [
        _record(
          academicYear: '2025-2026',
          totalScore: '86.5',
          grade: '良好',
          items: const [PhysicalTestItem(name: '第一份记录', result: '7.2 秒')],
        ),
        _record(
          academicYear: '2025-2026',
          totalScore: '70',
          grade: '及格',
          items: const [PhysicalTestItem(name: '第二份记录', result: '8.0 秒')],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PhysicalTestPage(snapshotFetcher: () async => snapshot),
      ),
    );
    await tester.pumpAndSettle();

    // 两个记录各自一格，不因学年同名被合并 / 丢弃。
    expect(_yearChip(0), findsOneWidget);
    expect(_yearChip(1), findsOneWidget);
    expect(find.text('第一份记录'), findsOneWidget);

    await tester.tap(_yearChip(1));
    await tester.pumpAndSettle();

    expect(find.text('第二份记录'), findsOneWidget);
    expect(find.text('8.0 秒'), findsOneWidget);
    expect(find.text('第一份记录'), findsNothing);
  });

  testWidgets('account change resets a historical selection to latest', (
    tester,
  ) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'student_A',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PhysicalTestPage(
          snapshotFetcher: () async => _multiYearSnapshot(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 先选到历史学年。
    await tester.tap(_yearChip(1));
    await tester.pumpAndSettle();
    expect(find.text('78'), findsOneWidget);

    // 换号后记录变化：选中项必须一致地重置回最新学年。
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'student_B',
    );
    UnifiedAuthService.instance.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.text('86.5'), findsOneWidget);
    expect(find.text('最新'), findsOneWidget);
    expect(find.text('78'), findsNothing);
  });

  testWidgets('refresh keeps the selected historical year when still present', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PhysicalTestPage(
          snapshotFetcher: () async {
            calls++;
            return _multiYearSnapshot();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);

    await tester.tap(_yearChip(1));
    await tester.pumpAndSettle();
    expect(_chipSelected(tester, 1), isTrue);
    expect(_readout('2024-2025'), findsOneWidget);

    // 点刷新：同样的数据回来后仍停在 2024-2025，不弹回最新学年。
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(_chipSelected(tester, 1), isTrue);
    expect(_chipSelected(tester, 0), isFalse);
    expect(_readout('2024-2025'), findsOneWidget);
    expect(_readout('最新'), findsNothing);
  });

  testWidgets('refresh falls back to latest when selected year disappears', (
    tester,
  ) async {
    var firstCall = true;
    await tester.pumpWidget(
      MaterialApp(
        home: PhysicalTestPage(
          snapshotFetcher: () async {
            if (firstCall) {
              firstCall = false;
              return _multiYearSnapshot();
            }
            return _snapshotWithRecords();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_yearChip(2));
    await tester.pumpAndSettle();
    expect(_readout('2023-2024'), findsOneWidget);

    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();

    expect(_readout('2025-2026'), findsOneWidget);
    expect(_readout('最新'), findsOneWidget);
  });

  testWidgets('narrow 360 screen with text scale 2 has no overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      MaterialApp(
        home: PhysicalTestPage(
          snapshotFetcher: () async => _multiYearSnapshot(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('86.5'), findsOneWidget);

    // 大字体下切换历史学年仍不溢出；窄屏上先把横向选择器滚到目标 chip。
    final chip1 = _yearChip(1);
    await tester.ensureVisible(chip1);
    await tester.pumpAndSettle();
    await tester.tap(chip1);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('1000 米跑'), findsOneWidget);
  });
}
