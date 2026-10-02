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

    test(
      'watchdog: a leaked hold expires so whenIdle and isBusy self-heal',
      () async {
        activity.debugMaxHold = const Duration(milliseconds: 40);
        activity.acquire(); // 漏配对的登记
        expect(activity.isBusy, isTrue);

        final stopwatch = Stopwatch()..start();
        await activity.whenIdle();
        expect(stopwatch.elapsedMilliseconds, lessThan(1000));
        expect(activity.active.value, isFalse, reason: '看门狗清掉陈旧计数');
        expect(activity.isBusy, isFalse);

        // 清掉之后新的转场仍然正常计数。
        activity.acquire();
        expect(activity.isBusy, isTrue);
        activity.release();
        expect(activity.isBusy, isFalse);
      },
    );

    test(
      'isBusy reports idle for a stale hold and acquire resets it',
      () async {
        activity.debugMaxHold = const Duration(milliseconds: 20);
        activity.acquire();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(activity.active.value, isTrue, reason: '原始计数尚未被清');
        expect(activity.isBusy, isFalse, reason: '陈旧登记不再让路');

        activity.acquire(); // 先清陈旧计数，再计一次
        activity.release();
        expect(activity.active.value, isFalse, reason: '陈旧计数不会让新转场永远算作进行中');
      },
    );

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
