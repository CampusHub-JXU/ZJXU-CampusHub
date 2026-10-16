import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/app/background_task_dispatcher.dart';

void main() {
  group('scheduleFeatureBackgroundTasks 逐项隔离', () {
    // 首项 / 中间项 / 末项分别失败，其余项都必须照常执行。
    for (final failing in const <int>{0, 1, 2, 3}) {
      test('注册项 $failing 抛错后其余项仍执行', () async {
        final ran = <int>[];

        Future<void> step(int index) async {
          ran.add(index);
          if (index == failing) {
            throw StateError('schedule $index failed');
          }
        }

        await scheduleFeatureBackgroundTasks(
          scheduleDormElectricity: () => step(0),
          scheduleSecondClassroom: () => step(1),
          scheduleNotice: () => step(2),
          scheduleWidget: () => step(3),
        );

        expect(ran, [0, 1, 2, 3], reason: 'failing index $failing');
      });
    }
  });

  group('runForegroundBackgroundChecks', () {
    test('通知磁盘状态重载先于独立网络检查发起', () async {
      final reloadGate = Completer<void>();
      final order = <String>[];

      final future = runForegroundBackgroundChecks(
        reloadNoticeState: () {
          order.add('reload');
          return reloadGate.future;
        },
        runSecondClassroomMonitor: () async => order.add('second'),
        checkDormElectricity: () async => order.add('electricity'),
        syncNotice: () async => order.add('notice'),
      );

      // 重载被 Completer 卡住时，后续网络检查一律尚未发起。
      await Future<void>.delayed(Duration.zero);
      expect(order, ['reload']);

      reloadGate.complete();
      await future;

      expect(order.first, 'reload');
      expect(order.toSet(), {'reload', 'second', 'electricity', 'notice'});
    });

    test('重载异常不阻断后续独立检查', () async {
      final ran = <String>[];

      await runForegroundBackgroundChecks(
        reloadNoticeState: () async {
          ran.add('reload');
          throw StateError('reload failed');
        },
        runSecondClassroomMonitor: () async => ran.add('second'),
        checkDormElectricity: () async => ran.add('electricity'),
        syncNotice: () async => ran.add('notice'),
      );

      expect(ran.toSet(), {'reload', 'second', 'electricity', 'notice'});
    });

    // 二课 / 电费 / 通知同步任一项网络失败，其余两项的更新都不能丢。
    for (final failing in const {'second', 'electricity', 'notice'}) {
      test('独立检查项 $failing 异常后其余项仍执行', () async {
        final ran = <String>[];

        Future<void> step(String name) async {
          ran.add(name);
          if (name == failing) {
            throw StateError('$name failed');
          }
        }

        await runForegroundBackgroundChecks(
          reloadNoticeState: () async => ran.add('reload'),
          runSecondClassroomMonitor: () => step('second'),
          checkDormElectricity: () => step('electricity'),
          syncNotice: () => step('notice'),
        );

        expect(ran.toSet(), {
          'reload',
          'second',
          'electricity',
          'notice',
        }, reason: 'failing $failing');
      });
    }

    test('notice 同步只在重载完成后才发起', () async {
      final reloadGate = Completer<void>();
      var syncStarted = false;

      final future = runForegroundBackgroundChecks(
        reloadNoticeState: () => reloadGate.future,
        runSecondClassroomMonitor: () async {},
        checkDormElectricity: () async {},
        syncNotice: () async => syncStarted = true,
      );

      await Future<void>.delayed(Duration.zero);
      expect(syncStarted, isFalse);

      reloadGate.complete();
      await future;
      expect(syncStarted, isTrue);
    });
  });

  group('initializeAndScheduleBackgroundTasks 启动兜底', () {
    test('初始化成功时注册并返回 true', () async {
      final events = <String>[];

      final result = await initializeAndScheduleBackgroundTasks(
        initialize: () async => events.add('init'),
        schedule: () async => events.add('schedule'),
      );

      expect(result, isTrue);
      expect(events, ['init', 'schedule']);
    });

    test('初始化失败时不注册、不抛出并返回 false', () async {
      final events = <String>[];

      final result = await initializeAndScheduleBackgroundTasks(
        initialize: () async {
          events.add('init');
          throw StateError('workmanager init failed');
        },
        schedule: () async => events.add('schedule'),
      );

      expect(result, isFalse);
      expect(events, ['init']);
    });
  });
}
