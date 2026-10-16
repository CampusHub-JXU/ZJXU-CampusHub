import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/app/campus_widget_background.dart';
import 'package:jxu_campus_hub/app/background_task_dispatcher.dart';
import 'package:jxu_campus_hub/core/auth/background_auth_context.dart';
import 'package:jxu_campus_hub/core/auth/background_session_gate.dart';
import 'package:jxu_campus_hub/core/system_surface/widget_refresh_state.dart';

void main() {
  late Directory dir;
  late BackgroundSessionGate gate;
  late WidgetRefreshState state;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('widget_background_');
    gate = BackgroundSessionGate.debugNew(directoryProvider: () async => dir);
    state = WidgetRefreshState(directory: () async => dir);
  });
  tearDown(() async {
    gate.debugReset();
    await dir.delete(recursive: true);
  });
  test('前台心跳新鲜时零恢复、零联网、零推送', () async {
    await gate.enterForeground(coldStart: true);
    final runner = CampusWidgetBackground(
      gate: gate,
      state: state,
      restore: () async => fail('restore'),
      refreshers: [() async => throw StateError('fetch')],
      push: () async => throw StateError('push'),
      online: () async => throw StateError('online'),
    );
    expect(await runner.run(), isTrue);
    expect(
      (await state.load())!.lastOutcome,
      WidgetRefreshOutcome.skippedForeground,
    );
  });
  test('单项失败仍刷新其余项并推送，落盘 partial', () async {
    final events = <String>[];
    final runner = CampusWidgetBackground(
      gate: gate,
      state: state,
      restore: () async {
        events.add('restore');
      },
      online: () async => true,
      refreshers: [
        () async {
          events.add('schedule');
          throw StateError('offline');
        },
        () async {
          events.add('exam');
          return WidgetRefreshOutcome.ok;
        },
      ],
      push: () async {
        events.add('push');
        return true;
      },
    );
    expect(await runner.run(), isTrue);
    expect(events, ['restore', 'schedule', 'exam', 'push']);
    final record = await state.load();
    expect(record!.lastOutcome, WidgetRefreshOutcome.partial);
    expect(record.lastSuccessAt, record.lastAttemptAt);
  });
  test('缓存补推不联网也不覆盖周期任务记录', () async {
    await state.record(WidgetRefreshOutcome.authFailed);
    var pushes = 0;
    final runner = CampusWidgetBackground(
      gate: gate,
      state: state,
      restore: () async {},
      online: () async => throw StateError('network'),
      refreshers: [() async => throw StateError('fetch')],
      push: () async {
        pushes++;
        return true;
      },
    );
    expect(await runner.run(cacheOnly: true), isTrue);
    expect(pushes, 1);
    expect((await state.load())!.lastOutcome, WidgetRefreshOutcome.authFailed);
  });
  test('离线只推缓存，失败不冒充成功', () async {
    final runner = CampusWidgetBackground(
      gate: gate,
      state: state,
      restore: () async {},
      online: () async => false,
      refreshers: [() async => throw StateError('fetch')],
      push: () async => true,
    );
    await runner.run();
    expect((await state.load())!.lastOutcome, WidgetRefreshOutcome.offline);
    expect((await state.load())!.lastSuccessAt, isNull);
  });
  test('插件推送失败不更新成功时间', () async {
    final at = DateTime(2026, 10, 15);
    await state.record(WidgetRefreshOutcome.ok, at: at);
    final runner = CampusWidgetBackground(
      gate: gate,
      state: state,
      restore: () async {},
      online: () async => true,
      refreshers: [() async => WidgetRefreshOutcome.ok],
      push: () async => false,
    );
    expect(await runner.run(), isFalse);
    expect((await state.load())!.lastOutcome, WidgetRefreshOutcome.error);
    expect((await state.load())!.lastSuccessAt, at);
  });
  test('刷新期间前台回来：取消嵌套登录、放弃后续请求与推送', () async {
    final runner = CampusWidgetBackground(
      gate: gate,
      state: state,
      restore: () async {},
      online: () async => true,
      refreshers: [
        () async {
          final context = BackgroundAuthContext.current!;
          await gate.enterForeground(coldStart: true);
          expect(await context.allowed(), isFalse);
          expect(context.cancelToken.isCancelled, isTrue);
          return WidgetRefreshOutcome.ok;
        },
        () async => throw StateError('late fetch'),
      ],
      push: () async => throw StateError('late push'),
    );
    await runner.run();
    expect(
      (await state.load())!.lastOutcome,
      WidgetRefreshOutcome.skippedForeground,
    );
  });
  test('缓存恢复失败保留原生快照，申领可再次获取', () async {
    final runner = CampusWidgetBackground(
      gate: gate,
      state: state,
      restore: () async => throw StateError('corrupt'),
      push: () async => throw StateError('push'),
    );
    expect(await runner.run(), isFalse);
    expect((await state.load())!.lastOutcome, WidgetRefreshOutcome.error);
    expect(await gate.tryClaim(), isNotNull);
  });
  test('原业务失败仍补推，补推失败不篡改业务重试返回值', () async {
    var pushed = false;
    expect(
      await runBackgroundTaskAndPush(
        action: () async => false,
        push: () async {
          pushed = true;
          throw StateError('plugin');
        },
      ),
      isFalse,
    );
    expect(pushed, isTrue);
    pushed = false;
    await expectLater(
      runBackgroundTaskAndPush(
        action: () async => throw StateError('task'),
        push: () async {
          pushed = true;
          return true;
        },
      ),
      throwsStateError,
    );
    expect(pushed, isTrue);
  });
  test('桌面没放组件时不恢复、不联网、不记录', () async {
    final runner = CampusWidgetBackground(
      gate: gate,
      state: state,
      installedWidgets: () async => 0,
      restore: () async => fail('restore'),
      refreshers: [() async => throw StateError('fetch')],
      push: () async => throw StateError('push'),
      online: () async => throw StateError('online'),
    );
    expect(await runner.run(), isTrue);
    expect(await state.load(), isNull);
  });
  test('组件数未知时照常刷新', () async {
    var pushes = 0;
    final runner = CampusWidgetBackground(
      gate: gate,
      state: state,
      installedWidgets: () async => throw StateError('plugin'),
      restore: () async {},
      online: () async => true,
      refreshers: [() async => WidgetRefreshOutcome.ok],
      push: () async {
        pushes++;
        return true;
      },
    );
    expect(await runner.run(), isTrue);
    expect(pushes, 1);
    expect((await state.load())!.lastOutcome, WidgetRefreshOutcome.ok);
  });
  test('申领被别的后台任务占用：交给 WorkManager 重试，不记成前台', () async {
    final held = await gate.tryClaim();
    expect(held, isNotNull);
    final runner = CampusWidgetBackground(
      gate: gate,
      state: state,
      installedWidgets: () async => 1,
      restore: () async => fail('restore'),
      refreshers: [() async => throw StateError('fetch')],
      push: () async => throw StateError('push'),
      online: () async => throw StateError('online'),
    );
    expect(await runner.run(), isFalse);
    expect(await state.load(), isNull);
  });
  test('推送失败时保留登录失败原因，不改记 error', () async {
    final runner = CampusWidgetBackground(
      gate: gate,
      state: state,
      installedWidgets: () async => 1,
      restore: () async {},
      online: () async => true,
      refreshers: [() async => WidgetRefreshOutcome.authFailed],
      push: () async => false,
    );
    expect(await runner.run(), isFalse);
    expect((await state.load())!.lastOutcome, WidgetRefreshOutcome.authFailed);
  });
  test('结果落盘失败不改变本轮返回值', () async {
    final runner = CampusWidgetBackground(
      gate: gate,
      state: WidgetRefreshState(directory: () async => throw StateError('io')),
      installedWidgets: () async => 1,
      restore: () async {},
      online: () async => true,
      refreshers: [() async => WidgetRefreshOutcome.ok],
      push: () async => true,
    );
    expect(await runner.run(), isTrue);
  });
}
