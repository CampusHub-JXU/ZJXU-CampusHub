import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/cache/private_cache_store.dart';
import 'package:jxu_campus_hub/features/exam/exam_page.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';

import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

  Map<String, Object?> examItem() => {
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

  testWidgets('shows cached exams for the current explicit identity', (
    tester,
  ) async {
    await seedOwnedExamCache('2025000001');
    expect(await ExamService.instance.restoreCache(), isTrue);

    await tester.pumpWidget(const MaterialApp(home: ExamPage()));
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
}
