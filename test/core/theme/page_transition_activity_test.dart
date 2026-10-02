import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/app/theme.dart';
import 'package:jxu_campus_hub/core/theme/app_colors.dart';
import 'package:jxu_campus_hub/core/theme/page_transition_activity.dart';

void main() {
  final activity = PageTransitionActivity.instance;

  setUp(activity.debugReset);
  tearDown(activity.debugReset);

  group('PageTransitionActivity', () {
    test('counts overlapping transitions and only idles when all end', () {
      expect(activity.active.value, isFalse);
      activity.acquire();
      activity.acquire();
      expect(activity.active.value, isTrue);
      activity.release();
      expect(activity.active.value, isTrue);
      activity.release();
      expect(activity.active.value, isFalse);
    });

    test('extra release is ignored and never goes negative', () {
      activity.release();
      activity.acquire();
      expect(activity.active.value, isTrue);
      activity.release();
      expect(activity.active.value, isFalse);
    });

    test('whenIdle completes immediately when idle', () async {
      var done = false;
      await activity.whenIdle().then((_) => done = true);
      expect(done, isTrue);
    });

    test('whenIdle waits until the last transition ends', () async {
      activity.acquire();
      var done = false;
      final future = activity.whenIdle().then((_) => done = true);
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      activity.release();
      await future;
      expect(done, isTrue);
    });
  });

  group('page transition registers with PageTransitionActivity', () {
    Future<void> pumpHome(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkThemeFor(AppColors.primary),
        home: const Scaffold(body: Text('home-page')),
      ),
    );

    NavigatorState nav(WidgetTester tester) =>
        tester.state<NavigatorState>(find.byType(Navigator));

    testWidgets('push and pop each hold the signal only while animating', (
      tester,
    ) async {
      await pumpHome(tester);
      expect(activity.active.value, isFalse);

      nav(tester).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('sub-page')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(activity.active.value, isTrue, reason: 'push 转场进行中');

      await tester.pumpAndSettle();
      expect(activity.active.value, isFalse, reason: 'push 结束后释放');

      nav(tester).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(activity.active.value, isTrue, reason: 'pop 转场进行中');

      await tester.pumpAndSettle();
      expect(activity.active.value, isFalse, reason: 'pop 结束后释放');
    });

    testWidgets('route disposed mid-transition still releases its hold', (
      tester,
    ) async {
      await pumpHome(tester);
      nav(tester).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('sub-page')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(activity.active.value, isTrue);

      // 整棵树被换掉（路由在转场中途销毁）：登记必须归还，否则首页永远「转场中」。
      await tester.pumpWidget(const SizedBox.shrink());
      expect(activity.active.value, isFalse);
    });
  });
}
