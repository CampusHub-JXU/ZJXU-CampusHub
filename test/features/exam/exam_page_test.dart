import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/cache/private_cache_store.dart';
import 'package:jxu_campus_hub/core/academic/exam_model.dart';
import 'package:jxu_campus_hub/features/exam/exam_page.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';
import 'package:jxu_campus_hub/shared/widgets/refresh_status_line.dart';
import 'package:jxu_campus_hub/shared/widgets/skeleton_box.dart';

import '../../helpers/test_setup.dart';
import '../../helpers/credential_store_test_ext.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

  Map<String, dynamic> examItem() => {
    'kcmc': '高等数学',
    'kch': 'MATH101',
    'kssj': '第8周 周三(2026-07-01) 14:00-16:00',
    'cdmc': '教学楼A301',
    'cdxqmc': '本部',
    'zwh': '15',
    'ksmc': '期末考试',
    'kkxy': '理学院',
    'cxbj': '',
    'xnmc': '2025-2026',
    'xqmmc': '第二学期',
  };

  ExamEntry examEntry(String courseName) =>
      ExamEntry.fromJson({...examItem(), 'kcmc': courseName});

  Future<void> seedOwnedExamCache(String owner) async {
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: owner);
    await CredentialStore.instance.saveZhengfangSession(owner);
    final epoch = (await AuthSessionPersistence.instance.read(
      CredentialSessionDomain.academic,
    )).epoch;
    final store = SharedPreferencesPrivateCacheStore(ExamService.cacheKey);
    await store.write(
      PrivateCacheEnvelope(
        owner: owner,
        updatedAt: DateTime.now(),
        epoch: epoch,
        payload: [examItem()],
      ),
    );
  }

  Future<void> pumpExamPage(
    WidgetTester tester, {
    ExamFetcher? fetchExams,
  }) async {
    await tester.pumpWidget(
      MaterialApp(home: ExamPage(fetchExams: fetchExams)),
    );
    await tester.pump();
  }

  Future<void> pumpUntilFound(
    WidgetTester tester,
    Finder finder, {
    String? reason,
  }) async {
    for (
      var elapsed = Duration.zero;
      elapsed < const Duration(seconds: 5) && finder.evaluate().isEmpty;
      elapsed += const Duration(milliseconds: 50)
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(finder, findsWidgets, reason: reason);
  }

  testWidgets('shows cached exams for the current explicit identity', (
    tester,
  ) async {
    await seedOwnedExamCache('2025000001');
    expect(await ExamService.instance.restoreCache(), isTrue);

    await pumpExamPage(tester);
    await tester.pump();

    expect(find.text('高等数学'), findsOneWidget);
    expect(find.text('登录后查看考试安排'), findsNothing);
  });

  test('logout does not expose the previous account cached exams', () async {
    await seedOwnedExamCache('2025000001');
    expect(await ExamService.instance.restoreCache(), isTrue);
    expect(ExamService.instance.cachedExams, isNotNull);

    await ZhengfangAuth.instance.markLoggedOut();

    expect(ExamService.instance.cachedExams, isNull);
    expect(ExamService.instance.nextExam, isNull);
    // 登出后即使再次冷恢复，也不把前账号数据当当前账号展示。
    expect(await ExamService.instance.restoreCache(), isFalse);
  });

  Future<void> pumpLoginView(
    WidgetTester tester, {
    required bool automaticLoginPaused,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildExamLoginView(
            automaticLoginPaused: automaticLoginPaused,
            onAction: () {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('paused automatic login shows manual-login guidance', (
    tester,
  ) async {
    await pumpLoginView(tester, automaticLoginPaused: true);

    expect(find.text('需要手动登录'), findsOneWidget);
    expect(find.textContaining('自动登录已暂停'), findsOneWidget);
    expect(find.text('登录教务系统'), findsOneWidget);
    expect(find.text('登录后查看考试安排'), findsNothing);
  });

  testWidgets('not paused keeps the original login guidance', (tester) async {
    await pumpLoginView(tester, automaticLoginPaused: false);

    expect(find.text('登录后查看考试安排'), findsOneWidget);
    expect(find.textContaining('考试信息依赖教务系统会话'), findsOneWidget);
    expect(find.text('登录教务系统'), findsOneWidget);
    expect(find.text('需要手动登录'), findsNothing);
  });

  // ── 身份隔离：账号切换 / 迟到结果 / 同账号重登 / 登出 / 过期 ──────────────

  testWidgets('switching account clears the previous owner exams', (
    tester,
  ) async {
    final bCompleter = Completer<List<ExamEntry>>();

    Future<List<ExamEntry>> fetchExams({bool forceRefresh = false}) {
      if (ZhengfangAuth.instance.currentStudentId == '2025000002') {
        return bCompleter.future;
      }
      return Future.value([examEntry('A专属考试')]);
    }

    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
    await pumpExamPage(tester, fetchExams: fetchExams);
    await pumpUntilFound(tester, find.text('A专属考试'));

    // debugSetSession 只改状态不通知；markLoggedIn 才让页面收到身份变化通知。
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000002',
    );
    await ZhengfangAuth.instance.markLoggedIn();
    await tester.pump();

    // B 的抓取尚未返回：A 的考试必须已经消失，绝不能等到新数据到达才清。
    expect(find.text('A专属考试'), findsNothing);

    bCompleter.complete([examEntry('B专属考试')]);
    await tester.pump();
    await pumpUntilFound(
      tester,
      find.text('B专属考试'),
      reason: '账号切换后应拉取并展示新账号的考试',
    );

    // 登录为 B 后绝不允许 A 的考试出现，哪怕一帧。
    expect(find.text('B专属考试'), findsOneWidget);
    expect(find.text('A专属考试'), findsNothing);
  });

  testWidgets('late result from the previous owner is discarded', (
    tester,
  ) async {
    final aCompleter = Completer<List<ExamEntry>>();

    Future<List<ExamEntry>> fetchExams({bool forceRefresh = false}) {
      if (ZhengfangAuth.instance.currentStudentId == '2025000002') {
        return Future.value([examEntry('B专属考试')]);
      }
      return aCompleter.future;
    }

    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
    await pumpExamPage(tester, fetchExams: fetchExams);
    await tester.pump();
    // A 的抓取仍在途，页面不应展示任何结果。
    expect(find.text('A专属考试'), findsNothing);

    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000002',
    );
    await ZhengfangAuth.instance.markLoggedIn();
    await tester.pump();
    await pumpUntilFound(tester, find.text('B专属考试'));

    // A 账号的抓取此时才迟到完成，不得覆盖 B 账号的页面。
    aCompleter.complete([examEntry('A专属考试')]);
    await tester.pump();
    await tester.pump();

    expect(find.text('B专属考试'), findsOneWidget);
    expect(find.text('A专属考试'), findsNothing);
  });

  testWidgets('same-account re-login invalidates the prior in-flight fetch', (
    tester,
  ) async {
    final firstCompleter = Completer<List<ExamEntry>>();
    var callCount = 0;

    Future<List<ExamEntry>> fetchExams({bool forceRefresh = false}) {
      callCount++;
      if (callCount == 1) return firstCompleter.future;
      return Future.value([examEntry('A的新考试')]);
    }

    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
    await pumpExamPage(tester, fetchExams: fetchExams);
    await tester.pump();

    // 同账号重登：active/studentId 不变，仅身份修订推进。
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
      forceRevision: true,
    );
    await ZhengfangAuth.instance.markLoggedIn();
    await tester.pump();
    await pumpUntilFound(
      tester,
      find.text('A的新考试'),
      reason: '同账号重登应作废旧在途抓取并重新拉取',
    );

    // 重登前的旧抓取迟到完成，不得覆盖新会话结果。
    firstCompleter.complete([examEntry('A的旧考试')]);
    await tester.pump();
    await tester.pump();

    expect(find.text('A的新考试'), findsOneWidget);
    expect(find.text('A的旧考试'), findsNothing);
  });

  testWidgets('logout clears the previous owner exams', (tester) async {
    Future<List<ExamEntry>> fetchExams({bool forceRefresh = false}) async => [
      examEntry('A专属考试'),
    ];

    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
    await pumpExamPage(tester, fetchExams: fetchExams);
    await pumpUntilFound(tester, find.text('A专属考试'));

    await ZhengfangAuth.instance.markLoggedOut();
    await tester.pump();

    expect(find.text('A专属考试'), findsNothing);
    expect(find.text('登录后查看考试安排'), findsOneWidget);

    // 登出按既有行为会拉起教务登录弹窗，弹窗内部会做连通性探测；
    // 推进足够 fake 时长，避免测试结束时留下未收敛的探测计时器。
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  });

  testWidgets(
    'auth expiry clears the previous owner exams and keeps guidance',
    (tester) async {
      var callCount = 0;

      Future<List<ExamEntry>> fetchExams({bool forceRefresh = false}) async {
        callCount++;
        if (callCount == 1) return [examEntry('A专属考试')];
        throw const ExamAuthExpiredException(automaticLoginPaused: true);
      }

      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '2025000001',
      );
      await pumpExamPage(tester, fetchExams: fetchExams);
      await pumpUntilFound(tester, find.text('A专属考试'));

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      await tester.pump();

      // 过期即身份不可信：旧账号考试必须立即消失，并保留手动登录引导。
      expect(find.text('A专属考试'), findsNothing);
      expect(find.text('需要手动登录'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
    },
  );

  testWidgets('failed refresh keeps the current owner exams', (tester) async {
    var callCount = 0;

    Future<List<ExamEntry>> fetchExams({bool forceRefresh = false}) async {
      callCount++;
      if (callCount == 1) return [examEntry('A专属考试')];
      throw const ExamRequestException('网络不可用');
    }

    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
    await pumpExamPage(tester, fetchExams: fetchExams);
    await pumpUntilFound(tester, find.text('A专属考试'));

    // 同账号手动刷新失败：保留既有数据，不回到登录/空态。
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    await tester.pump();

    expect(find.text('A专属考试'), findsOneWidget);
    expect(find.text('登录后查看考试安排'), findsNothing);
    expect(find.textContaining('获取考试信息失败'), findsNothing);

    // 推进 SnackBar 计时器，避免测试结束时留下 pending timer。
    await tester.pump(const Duration(seconds: 4));
  });

  // ── 列表页形态（docs/ui-unification-plan.md 第 2 批）──────────────────────

  testWidgets('无缓存首次加载显示骨架与状态行，不整页转圈', (tester) async {
    final pending = Completer<List<ExamEntry>>();
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
    await pumpExamPage(
      tester,
      fetchExams: ({bool forceRefresh = false}) {
        return pending.future;
      },
    );

    expect(find.byType(SkeletonBox), findsWidgets);
    expect(find.text('正在获取考试…'), findsOneWidget);
    expect(
      find.byType(CircularProgressIndicator),
      findsOneWidget,
      reason: '只有状态行里的 12px 小转圈',
    );

    pending.complete([examEntry('高等数学')]);
    await pumpUntilFound(tester, find.text('高等数学'));
    expect(find.byType(SkeletonBox), findsNothing);
    expect(find.byType(RefreshStatusLine), findsOneWidget);
    expect(find.textContaining('更新'), findsOneWidget);
  });

  testWidgets('有数据时下拉刷新会强制重新获取', (tester) async {
    final forceFlags = <bool>[];
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
    await pumpExamPage(
      tester,
      fetchExams: ({bool forceRefresh = false}) async {
        forceFlags.add(forceRefresh);
        return [examEntry('高等数学')];
      },
    );
    await pumpUntilFound(tester, find.text('高等数学'));

    await tester.fling(find.text('高等数学'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();

    expect(forceFlags.last, isTrue);
    expect(forceFlags.length, greaterThanOrEqualTo(2));
  });

  testWidgets('刷新失败时状态行标出「刷新失败」并保留数据', (tester) async {
    var callCount = 0;
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
    await pumpExamPage(
      tester,
      fetchExams: ({bool forceRefresh = false}) async {
        callCount++;
        if (callCount == 1) return [examEntry('高等数学')];
        throw const ExamRequestException('网络不可用');
      },
    );
    await pumpUntilFound(tester, find.text('高等数学'));

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    await tester.pump();

    expect(find.text('高等数学'), findsOneWidget);
    expect(find.textContaining('刷新失败'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });
}
