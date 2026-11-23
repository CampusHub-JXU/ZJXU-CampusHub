import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/notice/notice_fetch_service.dart';
import 'package:jxu_campus_hub/core/notice/notice_sync_store.dart';
import 'package:jxu_campus_hub/features/notification_center/notification_center_page.dart';
import 'package:jxu_campus_hub/features/notification_center/practice_notice_list_view.dart';
import 'package:jxu_campus_hub/features/sjjx_notice/sjjx_notice_model.dart';
import 'package:jxu_campus_hub/shared/widgets/app_error_view.dart';
import 'package:jxu_campus_hub/shared/widgets/auth_required_view.dart';

import '../../helpers/test_setup.dart';

/// 通知中心「实践通知」Tab 的端到端（离线）回归。
///
/// 用可注入 loader 喂入固定 1518 条合成实践通知，验证：总匹配数展示、首屏
/// 有界惰性构建、滚动可达最后一条、搜索覆盖全量并点击打开 external-webview、
/// 清空/刷新/反复切换的稳定性，以及认证失败 / 错误 / 空态与窄屏大字号。

/// 合成实践通知：标题唯一且可搜索，url 带唯一 nid，便于断言打开目标。
List<SjjxNotice> syntheticNotices(int count) => [
  for (var i = 0; i < count; i++)
    SjjxNotice(
      title: '实践通知 ${i.toString().padLeft(4, '0')}',
      url: 'http://sjjx.zjxu.edu.cn/sjjx/detail.aspx?nid=$i',
      category: const ['学科竞赛', '毕业设计', '实验教学', '实践平台', '创新训练'][i % 5],
      date: '2026-01-${(i % 28 + 1).toString().padLeft(2, '0')}',
    ),
];

Map<String, Object?>? capturedExtra;

/// 通知中心依赖的收件箱状态：注入空收件箱并短路磁盘 reload，避免测试的
/// 假异步区里文件锁 / 磁盘 I/O 永不完成。
void _seedEmptyInbox() {
  NoticeSyncStore.instance
    ..debugReset()
    ..debugReloadNoop = true
    ..debugInjectState(
      NoticeSyncSnapshot(
        snapshotIds: const {},
        inbox: const [],
        unreadIds: const {},
        pendingNotifyIds: const {},
        notifiedIds: const {},
        pendingBackfillPage: null,
        baselineBuilt: true,
      ),
    );
}

Future<void> pumpPage(
  WidgetTester tester, {
  required Future<List<SjjxNotice>> Function() loader,
  Size size = const Size(412, 900),
  void Function(Future<void> Function() reload)? onPracticeTabReady,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  capturedExtra = null;
  final router = GoRouter(
    initialLocation: '/notifications',
    routes: [
      GoRoute(
        name: 'notifications',
        path: '/notifications',
        builder: (_, _) => NotificationCenterPage(
          practiceNoticeLoader: loader,
          debugOnPracticeTabReady: onPracticeTabReady,
        ),
      ),
      GoRoute(
        name: 'external-webview',
        path: '/external-webview',
        builder: (context, state) {
          capturedExtra = state.extra as Map<String, Object?>?;
          return const Scaffold(body: Text('external-webview-page'));
        },
      ),
      GoRoute(
        name: 'notice-detail',
        path: '/notice-detail',
        builder: (_, _) => const Scaffold(body: Text('notice-detail-page')),
      ),
    ],
  );
  await tester.pumpWidget(
    MaterialApp.router(
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: ThemeMode.system,
      routerConfig: router,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openPracticeTab(WidgetTester tester) async {
  await tester.tap(find.text('实践通知'));
  await tester.pumpAndSettle();
}

/// 搜索框 autofocus 后光标持续闪烁，`pumpAndSettle` 永不收敛；改用有界 pump。
Future<void> _pumpFocused(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() async {
    await resetTestEnvironment();
    NoticeService.instance.debugReset();
    _seedEmptyInbox();
  });

  tearDown(() {
    NoticeSyncStore.instance.debugReset();
  });

  testWidgets('实践 Tab 顶部显示总匹配数，首屏只构建有界行数', (tester) async {
    var loads = 0;
    await pumpPage(
      tester,
      loader: () async {
        loads++;
        return syntheticNotices(1518);
      },
    );
    await openPracticeTab(tester);

    expect(loads, 1);
    expect(find.text('1518 条'), findsOneWidget);
    final builtRows = find.byType(PracticeNoticeRow).evaluate().length;
    expect(builtRows, greaterThan(0));
    expect(
      builtRows,
      lessThanOrEqualTo(20),
      reason: '首屏应只构建窗口内的少数行，实际 $builtRows',
    );
  });

  testWidgets('滚动可到达末尾第 1518 条且顺序正确', (tester) async {
    await pumpPage(tester, loader: () async => syntheticNotices(1518));
    await openPracticeTab(tester);

    const lastTitle = '实践通知 1517';
    var reached = false;
    for (var i = 0; i < 300; i++) {
      if (find.text(lastTitle).evaluate().isNotEmpty) {
        reached = true;
        break;
      }
      await tester.drag(
        find.byType(PracticeNoticeListView),
        const Offset(0, -4000),
      );
      await tester.pumpAndSettle();
    }

    expect(reached, isTrue, reason: '向下滚动应最终到达第 1518 条');
    expect(find.text(lastTitle), findsOneWidget);
    expect(find.text('实践通知 1516'), findsOneWidget);
  });

  testWidgets('搜索覆盖全量命中末尾记录并可点击打开外链', (tester) async {
    await pumpPage(tester, loader: () async => syntheticNotices(1518));
    await openPracticeTab(tester);

    // 搜索框 autofocus 后光标会持续闪烁，pumpAndSettle 永不收敛，用有界 pump。
    await tester.tap(find.byIcon(Icons.search_rounded));
    await _pumpFocused(tester);
    await tester.enterText(find.byType(TextField), '实践通知 1517');
    await tester.pump();

    // 搜索覆盖全部 1518 条，而不是只看当前窗口。
    expect(find.text('匹配结果'), findsOneWidget);
    expect(find.text('1 条'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PracticeNoticeRow),
        matching: find.text('实践通知 1517'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byType(PracticeNoticeRow).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('external-webview-page'), findsOneWidget);
    expect(
      capturedExtra?['url'],
      'http://sjjx.zjxu.edu.cn/sjjx/detail.aspx?nid=1517',
    );
  });

  testWidgets('清空查询后恢复完整列表', (tester) async {
    await pumpPage(tester, loader: () async => syntheticNotices(1518));
    await openPracticeTab(tester);

    await tester.tap(find.byIcon(Icons.search_rounded));
    await _pumpFocused(tester);
    await tester.enterText(find.byType(TextField), '实践通知 1517');
    await tester.pump();
    expect(find.text('1 条'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(find.text('1518 条'), findsOneWidget);
  });

  testWidgets('反复切换 Tab 不重复加载、行数不放大', (tester) async {
    var loads = 0;
    await pumpPage(
      tester,
      loader: () async {
        loads++;
        return syntheticNotices(1518);
      },
    );
    await openPracticeTab(tester);
    final baselineRows = find.byType(PracticeNoticeRow).evaluate().length;

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('教务处公告'));
      await tester.pumpAndSettle();
      await openPracticeTab(tester);
    }

    expect(loads, 1, reason: 'keepAlive 的 Tab 不应每次切换重新拉取');
    final rows = find.byType(PracticeNoticeRow).evaluate().length;
    expect(rows, lessThanOrEqualTo(baselineRows));
  });

  testWidgets('认证失效显示登录视图', (tester) async {
    await pumpPage(
      tester,
      loader: () async => throw const CasAuthExpiredException('expired'),
    );
    await openPracticeTab(tester);
    expect(find.byType(AuthRequiredView), findsOneWidget);
    expect(find.text('登录后查看实践通知'), findsOneWidget);
  });

  testWidgets('服务端异常显示错误态', (tester) async {
    await pumpPage(tester, loader: () async => throw Exception('boom'));
    await openPracticeTab(tester);
    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.text('加载失败'), findsOneWidget);
  });

  testWidgets('空数据显示空态', (tester) async {
    await pumpPage(tester, loader: () async => const <SjjxNotice>[]);
    await openPracticeTab(tester);
    expect(find.text('暂无实践通知'), findsOneWidget);
  });

  testWidgets('搜索无结果显示无匹配空态', (tester) async {
    await pumpPage(tester, loader: () async => syntheticNotices(5));
    await openPracticeTab(tester);
    await tester.tap(find.byIcon(Icons.search_rounded));
    await _pumpFocused(tester);
    await tester.enterText(find.byType(TextField), '不存在的关键词');
    await tester.pump();
    expect(find.text('没有匹配的通知'), findsOneWidget);
  });

  testWidgets('窄屏 / 大字号 / 深浅色下长标题不溢出', (tester) async {
    Future<List<SjjxNotice>> longTitles() async => [
      for (var i = 0; i < 30; i++)
        SjjxNotice(
          title: i == 0 ? ('超长实践通知标题' * 30) : '实践通知 $i',
          url: 'http://sjjx.zjxu.edu.cn/sjjx/detail.aspx?nid=$i',
          category: '学科竞赛',
          date: '2026-09-01',
        ),
    ];

    for (final width in [360.0, 412.0]) {
      for (final scale in [1.5, 2.0]) {
        for (final brightness in Brightness.values) {
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          addTearDown(
            tester.platformDispatcher.clearPlatformBrightnessTestValue,
          );

          await pumpPage(tester, loader: longTitles, size: Size(width, 900));
          await openPracticeTab(tester);

          expect(
            tester.takeException(),
            isNull,
            reason: 'width=$width scale=$scale brightness=$brightness',
          );
          expect(
            find.byType(PracticeNoticeRow),
            findsWidgets,
            reason: 'width=$width scale=$scale brightness=$brightness',
          );
        }
      }
    }
  });

  // 迟到结果保护：同一次挂载内后发起的请求胜出（latest-wins）。
  // 该守卫只按调用序计数，**不读账号身份**；跨账号隔离未验证（见源码注释）。
  group('迟到结果不覆盖新结果（same-Tab call order guard）', () {
    // loader 挂起时 Tab 显示持续转圈的 loading 态，pumpAndSettle 永不收敛，
    // 因此这里用有界 pump 打开 Tab / 推进状态。
    Future<void> openBounded(WidgetTester tester) async {
      await tester.tap(find.text('实践通知'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
    }

    testWidgets('更早的旧成功结果迟到，不覆盖最新结果', (tester) async {
      final gates = <Completer<List<SjjxNotice>>>[];
      Future<void> Function()? reload;
      await pumpPage(
        tester,
        loader: () {
          final gate = Completer<List<SjjxNotice>>();
          gates.add(gate);
          return gate.future;
        },
        onPracticeTabReady: (r) => reload = r,
      );
      await openBounded(tester); // 挂载 -> 第 1 次 _load（尚在途）
      expect(reload, isNotNull);
      expect(gates.length, 1);

      reload!(); // 第 2 次 _load（更新）
      await settle(tester);
      expect(gates.length, 2);

      // 最新请求先完成，返回 3 条。
      gates[1].complete(syntheticNotices(3));
      await settle(tester);
      expect(find.text('3 条'), findsOneWidget);

      // 更早的请求迟到完成，返回 5 条，必须被丢弃。
      gates[0].complete(syntheticNotices(5));
      await settle(tester);
      expect(find.text('3 条'), findsOneWidget);
      expect(find.text('5 条'), findsNothing);
    });

    testWidgets('迟到的认证失效结果不覆盖最新成功结果', (tester) async {
      final gates = <Completer<List<SjjxNotice>>>[];
      Future<void> Function()? reload;
      await pumpPage(
        tester,
        loader: () {
          final gate = Completer<List<SjjxNotice>>();
          gates.add(gate);
          return gate.future;
        },
        onPracticeTabReady: (r) => reload = r,
      );
      await openBounded(tester);
      expect(reload, isNotNull);
      expect(gates.length, 1);

      reload!();
      await settle(tester);
      gates[1].complete(syntheticNotices(7));
      await settle(tester);
      expect(find.text('7 条'), findsOneWidget);

      // 更早的请求迟到抛认证失效，必须被丢弃，不能把已成功的列表翻成登录态。
      gates[0].completeError(const CasAuthExpiredException('late'));
      await settle(tester);
      expect(find.text('7 条'), findsOneWidget);
      expect(find.byType(AuthRequiredView), findsNothing);
    });

    testWidgets('更早的旧成功结果迟到，不覆盖最新认证失效状态', (tester) async {
      final gates = <Completer<List<SjjxNotice>>>[];
      Future<void> Function()? reload;
      await pumpPage(
        tester,
        loader: () {
          final gate = Completer<List<SjjxNotice>>();
          gates.add(gate);
          return gate.future;
        },
        onPracticeTabReady: (r) => reload = r,
      );
      await openBounded(tester);
      expect(reload, isNotNull);
      expect(gates.length, 1);

      reload!();
      await settle(tester);
      gates[1].completeError(const CasAuthExpiredException('expired'));
      await settle(tester);
      expect(find.byType(AuthRequiredView), findsOneWidget);

      // 更早的请求迟到返回成功数据，必须被丢弃，不能推翻最新认证态。
      gates[0].complete(syntheticNotices(9));
      await settle(tester);
      expect(find.byType(AuthRequiredView), findsOneWidget);
      expect(find.text('9 条'), findsNothing);
    });
  });
}
