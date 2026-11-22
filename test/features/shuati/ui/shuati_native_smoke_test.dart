// 原生刷题助手完整界面（阶段 2b）测试：首页概览/继续上次/搜索/重命名、
// 导入报告与快捷开练、练习页提交/收藏/答题卡/自动前进/错题重做/断点恢复、
// 错题本详情与移出、设置页合并与覆盖恢复。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:jxu_campus_hub/features/shuati/domain/shuati_models.dart';
import 'package:jxu_campus_hub/features/shuati/persistence/shuati_store.dart';
import 'package:jxu_campus_hub/features/shuati/ui/shuati_native_home_page.dart';
import 'package:jxu_campus_hub/features/shuati/ui/shuati_native_import_page.dart';
import 'package:jxu_campus_hub/features/shuati/ui/shuati_native_practice_page.dart';
import 'package:jxu_campus_hub/features/shuati/ui/shuati_native_settings_page.dart';
import 'package:jxu_campus_hub/features/shuati/ui/shuati_native_wrong_page.dart';
import 'package:jxu_campus_hub/features/shuati/ui/shuati_services.dart';

import '../../../helpers/shuati_test_support.dart';

class _FakeIo implements ShuatiFileIo {
  PickedShuatiFile? next;

  @override
  Future<PickedShuatiFile?> pickFile({
    required List<String> extensions,
  }) async => next;

  @override
  Future<String?> saveFile(String fileName, Uint8List bytes) async => null;

  @override
  Future<void> shareFile(String fileName, Uint8List bytes) async {}
}

/// 让真实异步（sqflite_ffi / isolate）跑完，再推进几帧。
Future<void> settle(WidgetTester tester, {int steps = 8}) async {
  for (var i = 0; i < steps; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump();
  }
}

/// 等待页面顶部 `LinearProgressIndicator` 消失（确保事务与 isolate 全部结束）。
Future<void> settleWhileBusy(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    if (i >= 2 && find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      break;
    }
  }
}

Future<ShuatiStore> setUpStore(WidgetTester tester, ShuatiFileIo io) async {
  final store = (await tester.runAsync(openTestStore))!;
  ShuatiServices.instance.debugUse(store, io: io);
  addTearDown(ShuatiServices.instance.debugReset);
  return store;
}

Future<void> pump(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(MaterialApp(home: page));
  await settle(tester);
}

void main() {
  late _FakeIo io;

  setUp(() => io = _FakeIo());

  testWidgets(
    'home shows empty state, overview stats, resume card, search, and rename',
    (tester) async {
      final store = await setUpStore(tester, io);
      await pump(tester, const ShuatiNativeHomePage());
      expect(find.text('还没有题库'), findsOneWidget);

      await tester.runAsync(() async {
        await seedBank(store, 'b1', [
          question('q1', 'b1'),
          question('q2', 'b1'),
        ], name: '操作系统');
        await seedBank(store, 'b2', [question('q3', 'b2')], name: '计算机网络');
        await store.savePracticeAnswer(
          record('b1', 'q1', status: AnswerStatus.correct, userAnswer: ['A']),
        );
        await store.saveLastPracticeSession(
          bankId: 'b1',
          mode: PracticeMode.sequential,
          currentIndex: 1,
          questionIds: ['q1', 'q2'],
        );
      });

      await tester.pumpWidget(const SizedBox());
      await pump(tester, const ShuatiNativeHomePage());

      expect(find.text('学习概览'), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);
      expect(find.text('近 7 天正确率'), findsOneWidget);
      expect(find.text('继续上次'), findsOneWidget);
      expect(find.text('2/2'), findsOneWidget);
      // 「操作系统」同时出现在「继续上次」与「我的题库」两处
      expect(find.text('操作系统'), findsNWidgets(2));
      expect(find.text('计算机网络'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '网络');
      await tester.pump();
      expect(find.text('计算机网络'), findsOneWidget);
      // 搜索过滤后题库列表中的「操作系统」被隐藏，仅保留「继续上次」处 1 个
      expect(find.text('操作系统'), findsOneWidget);

      await tester.tap(find.byTooltip('清除搜索'));
      await tester.pump();
      expect(find.text('操作系统'), findsNWidgets(2));

      await tester.tap(find.text('操作系统').last);
      await settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('错题练习'), findsOneWidget);
      expect(find.text('题库管理'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('重命名题库'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('重命名题库'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, '操作系统精讲');
      await tester.tap(find.text('保存'));
      await settle(tester);

      expect(find.text('操作系统精讲'), findsWidgets);
    },
  );

  testWidgets('import page shows typed report and start practice button', (
    tester,
  ) async {
    final store = await setUpStore(tester, io);
    io.next = PickedShuatiFile(
      'sample.json',
      Uint8List.fromList(
        utf8.encode(
          jsonEncode([
            {
              'question': '1+1=?',
              'options': {'A': '1', 'B': '2'},
              'answer': 'B',
            },
            {'question': '', 'answer': 'A'},
          ]),
        ),
      ),
    );
    await pump(tester, const ShuatiNativeImportPage());
    await tester.tap(find.text('选择文件'));
    await settle(tester);

    expect(find.text('新增题目'), findsOneWidget);
    expect(find.text('无效条目'), findsOneWidget);
    expect(find.text('无效 · 缺少题干'), findsOneWidget);
    expect(find.text('开始练习'), findsOneWidget);
    final banks = (await tester.runAsync(store.banks.getAllBanks))!;
    expect(banks.single.questionCount, 1);
  });

  testWidgets(
    'practice supports favorite, answer sheet jump, auto-advance, and option explanations',
    (tester) async {
      final store = await setUpStore(tester, io);
      await tester.runAsync(
        () => seedBank(store, 'b1', [
          question(
            'q1',
            'b1',
            answer: const ['A'],
          ).copyWith(optionExplanations: const {'A': 'Alpha 解析说明'}),
          question('q2', 'b1', text: 'Second question'),
        ]),
      );
      await pump(
        tester,
        const ShuatiNativePracticePage(
          bankId: 'b1',
          mode: PracticeMode.sequential,
        ),
      );
      expect(find.text('Question q1'), findsOneWidget);

      // 收藏题目
      await tester.tap(find.byTooltip('收藏题目'));
      await settle(tester);
      expect(find.byTooltip('取消收藏'), findsOneWidget);
      final favs = (await tester.runAsync(
        () => store.favorites.questionIds('b1'),
      ))!;
      expect(favs, ['q1']);

      // 答题卡跳转到第 2 题再跳回第 1 题
      await tester.tap(find.byTooltip('答题卡'));
      await tester.pumpAndSettle();
      expect(find.text('填空简答'), findsOneWidget);
      await tester.tap(find.text('2'));
      await settle(tester);
      expect(find.text('Second question'), findsOneWidget);

      await tester.tap(find.byTooltip('答题卡'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1'));
      await settle(tester);
      expect(find.text('Question q1'), findsOneWidget);

      // 提交正确答案：展示逐项解析，并在 650ms 后自动前进到第 2 题
      await tester.tap(find.text('Alpha'));
      await tester.pump();
      await tester.tap(find.text('提交答案'));
      await settle(tester);
      expect(find.text('回答正确'), findsOneWidget);
      expect(find.text('Alpha 解析说明'), findsOneWidget);

      final records = (await tester.runAsync(store.records.getAll))!;
      expect(records.single.status, AnswerStatus.correct);

      await tester.pump(const Duration(milliseconds: 700));
      await settle(tester);
      expect(find.text('Second question'), findsOneWidget);
    },
  );

  testWidgets('practice resumes saved session and allows wrong-mode redo', (
    tester,
  ) async {
    final store = await setUpStore(tester, io);
    await tester.runAsync(() async {
      await seedBank(store, 'b1', [
        question('q1', 'b1', answer: const ['A']),
        question('q2', 'b1', text: 'Resumed question', answer: const ['A']),
      ]);
      await store.saveLastPracticeSession(
        bankId: 'b1',
        mode: PracticeMode.sequential,
        currentIndex: 1,
        questionIds: ['q1', 'q2'],
      );
      await store.savePracticeAnswer(
        record('b1', 'q1', status: AnswerStatus.wrong, userAnswer: ['B']),
      );
    });

    await pump(
      tester,
      const ShuatiNativePracticePage(
        bankId: 'b1',
        mode: PracticeMode.sequential,
        resume: true,
      ),
    );
    expect(find.text('Resumed question'), findsOneWidget);

    await pump(
      tester,
      const ShuatiNativePracticePage(bankId: 'b1', mode: PracticeMode.wrong),
    );
    await tester.tap(find.text('Beta'));
    await tester.pump();
    await tester.tap(find.text('提交答案'));
    await settle(tester);
    expect(find.text('重做本题'), findsOneWidget);

    await tester.tap(find.text('重做本题'));
    await tester.pump();
    expect(find.text('提交答案'), findsOneWidget);
  });

  testWidgets('wrong book previews details and removes an item explicitly', (
    tester,
  ) async {
    final store = await setUpStore(tester, io);
    await tester.runAsync(() async {
      await seedBank(store, 'b1', [
        question('q1', 'b1', explanation: '错题详情解析'),
      ]);
      await store.savePracticeAnswer(
        record('b1', 'q1', status: AnswerStatus.wrong, userAnswer: ['B']),
      );
    });
    await pump(tester, const ShuatiNativeWrongPage(bankId: 'b1'));
    expect(find.text('Question q1'), findsOneWidget);
    expect(find.textContaining('错 1 次'), findsOneWidget);

    await tester.tap(find.text('Question q1'));
    await tester.pumpAndSettle();
    expect(find.text('参考答案'), findsOneWidget);
    expect(find.text('错题详情解析'), findsOneWidget);
    await tester.tap(find.text('移出错题本'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移出'));
    await settle(tester);
    expect(find.text('没有错题'), findsOneWidget);
  });

  testWidgets(
    'settings restores merge/replaceAll backups and exposes legacy entry',
    (tester) async {
      final bytes = Uint8List.fromList(
        utf8.encode(jsonEncode(syntheticBackup(banks: 1, questionsPerBank: 2))),
      );
      final store = await setUpStore(tester, io);
      await tester.runAsync(
        () => seedBank(store, 'old-b', [question('oq', 'old-b')]),
      );
      io.next = PickedShuatiFile('backup.json', bytes);

      var legacyTapped = false;
      final router = GoRouter(
        initialLocation: '/settings',
        routes: [
          GoRoute(
            path: '/settings',
            builder: (_, _) => const ShuatiNativeSettingsPage(),
          ),
          GoRoute(
            path: '/legacy',
            name: 'shuati-legacy',
            builder: (_, _) {
              legacyTapped = true;
              return const Scaffold(body: Text('legacy'));
            },
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await settle(tester);

      // 合并恢复保留本地旧题库
      await tester.tap(find.text('恢复备份（合并）'));
      await tester.pump();
      await settleWhileBusy(tester);
      expect(find.textContaining('恢复结果'), findsOneWidget);
      var banks = (await tester.runAsync(store.banks.getAllBanks))!;
      expect(banks.map((b) => b.id), containsAll(['old-b', 'bank-1']));

      // 覆盖恢复清空本地旧题库
      await tester.tap(find.text('恢复备份（覆盖全部）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择备份并覆盖'));
      await tester.pump();
      await settleWhileBusy(tester);
      banks = (await tester.runAsync(store.banks.getAllBanks))!;
      expect(banks.map((b) => b.id).toList(), ['bank-1']);

      // 旧版迁移入口可达
      await tester.scrollUntilVisible(
        find.text('打开旧版刷题助手（导出旧数据）'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('打开旧版刷题助手（导出旧数据）'));
      await tester.pumpAndSettle();
      expect(legacyTapped, isTrue);
    },
  );
}
