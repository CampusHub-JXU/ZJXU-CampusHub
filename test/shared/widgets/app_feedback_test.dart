import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/shared/widgets/app_feedback.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_dialog_route.dart';

Widget _host(void Function(BuildContext context) onPressed) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => onPressed(context),
            child: const Text('go'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(AppFeedback.resetDedupe);

  testWidgets('toast 先收起上一条再弹新的，不排队', (tester) async {
    var n = 0;
    await tester.pumpWidget(
      _host((context) => AppFeedback.toast(context, '第 ${++n} 条')),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(find.text('第 1 条'), findsOneWidget);

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('第 1 条'), findsNothing);
    expect(find.text('第 2 条'), findsOneWidget);
  });

  testWidgets('toast 带 action，点击触发回调', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _host(
        (context) => AppFeedback.toast(
          context,
          '链接打开失败',
          actionLabel: '复制链接',
          onAction: () => tapped = true,
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制链接'));
    expect(tapped, isTrue);
  });

  testWidgets('dedupeKey 在窗口期内合并同类提示', (tester) async {
    var n = 0;
    await tester.pumpWidget(
      _host(
        (context) => AppFeedback.toast(context, '第 ${++n} 条', dedupeKey: 'net'),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('第 1 条'), findsOneWidget);
    expect(n, 2, reason: '回调执行了两次，但第二条被去重');
  });

  testWidgets('没有 ScaffoldMessenger 时 toast 静默跳过', (tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            AppFeedback.toast(context, '不会显示');
            return const SizedBox();
          },
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirm：确认返回 true，取消与点遮罩返回 false，走亚克力弹层', (tester) async {
    final results = <bool>[];
    await tester.pumpWidget(
      _host((context) async {
        results.add(
          await AppFeedback.confirm(
            context,
            title: '退出登录？',
            message: '将同时退出统一认证与教务系统',
            confirmLabel: '退出',
            destructive: true,
          ),
        );
      }),
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('退出登录？'), findsOneWidget);
    expect(find.byType(GlassOverlaySurface), findsOneWidget);
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    expect(results, [true, false, false]);
  });

  testWidgets('destructive 确认按钮文字使用 error 色', (tester) async {
    await tester.pumpWidget(
      _host((context) {
        AppFeedback.confirm(context, title: '清除缓存？', destructive: true);
      }),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    final context = tester.element(find.text('确定'));
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '确定'),
    );
    final fg = button.style?.foregroundColor?.resolve(<WidgetState>{});
    expect(fg, Theme.of(context).colorScheme.error);
  });

  testWidgets('sheet 走亚克力底部弹层并返回结果', (tester) async {
    String? picked;
    await tester.pumpWidget(
      _host((context) async {
        picked = await AppFeedback.sheet<String>(
          context,
          builder: (sheetContext) => ListTile(
            title: const Text('3 号楼'),
            onTap: () => Navigator.of(sheetContext).pop('3'),
          ),
        );
      }),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byType(GlassOverlaySurface), findsOneWidget);
    await tester.tap(find.text('3 号楼'));
    await tester.pumpAndSettle();
    expect(picked, '3');
  });
}
