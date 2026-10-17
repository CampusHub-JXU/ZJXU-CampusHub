import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/background_session_gate.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_background.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_subscription_service.dart';

const _empty = SecondClassroomMonitorResult(
  subscriptionCount: 0,
  checkedActivityCount: 0,
  notificationCount: 0,
);

void main() {
  late Directory dir;
  late BackgroundSessionGate gate;
  late int checks;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sc_background_test');
    gate = BackgroundSessionGate.debugNew(directoryProvider: () async => dir);
    checks = 0;
  });

  tearDown(() async {
    gate.debugReset();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  SecondClassroomBackground build({
    Future<SecondClassroomMonitorResult> Function()? check,
    Duration budget = const Duration(seconds: 5),
    Duration grace = const Duration(seconds: 1),
  }) => SecondClassroomBackground.debugNew(
    gate: gate,
    budget: budget,
    hardStopGrace: grace,
    check:
        check ??
        () async {
          checks++;
          return _empty;
        },
  );

  test('background isolate claims the gate, checks, and releases', () async {
    expect(await build().runMonitor(), isTrue);
    expect(checks, 1);
    final claim = await gate.tryClaim();
    expect(claim, isNotNull, reason: '申领应已释放');
  });

  test(
    'foreground fresh (seen from another isolate): skip without error',
    () async {
      // 心跳已落盘，但本 isolate 没有在发心跳 => 视为后台 isolate。
      await gate.enterForeground(coldStart: true, waitForClaim: Duration.zero);
      gate.stopHeartbeat();
      expect(await build().runMonitor(), isTrue);
      expect(checks, 0);
    },
  );

  test('claim held by another background task: skip without error', () async {
    expect(await gate.tryClaim(), isNotNull);
    expect(await build().runMonitor(), isTrue);
    expect(checks, 0);
  });

  test('foreground host runs the check without claiming', () async {
    await gate.enterForeground(coldStart: true, waitForClaim: Duration.zero);
    expect(gate.isForegroundHost, isTrue);
    expect(await build().runMonitor(), isTrue);
    gate.stopHeartbeat();
    expect(checks, 1);
  });

  test(
    'a hung check is abandoned within budget and the claim released',
    () async {
      final never = Completer<SecondClassroomMonitorResult>();
      final stopwatch = Stopwatch()..start();
      final ok = await build(
        check: () => never.future,
        budget: const Duration(milliseconds: 50),
        grace: const Duration(milliseconds: 50),
      ).runMonitor();
      stopwatch.stop();
      expect(ok, isFalse);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(await gate.tryClaim(), isNotNull);
    },
  );

  test('check failure returns false and releases the claim', () async {
    final ok = await build(check: () async => throw StateError('net'))
        .runMonitor();
    expect(ok, isFalse);
    expect(await gate.tryClaim(), isNotNull);
  });
}
