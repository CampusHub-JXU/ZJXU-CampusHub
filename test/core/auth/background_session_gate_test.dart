import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/background_session_gate.dart';

void main() {
  late Directory dir;
  late DateTime now;
  late BackgroundSessionGate gate;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bg_gate_test');
    now = DateTime(2026, 9, 30, 10);
    gate = BackgroundSessionGate.debugNew(
      directoryProvider: () async => dir,
      now: () => now,
    );
  });

  tearDown(() async {
    gate.debugReset();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  void advance(Duration d) => now = now.add(d);

  Future<void> enterColdStart() =>
      gate.enterForeground(coldStart: true, waitForClaim: Duration.zero);

  test('claim granted when no foreground heartbeat', () async {
    final claim = await gate.tryClaim();
    expect(claim, isNotNull);
    expect(await gate.shouldYield(claim!), isFalse);
  });

  test('claim refused while foreground heartbeat is fresh', () async {
    await enterColdStart();
    expect(await gate.isForegroundActive(), isTrue);
    expect(await gate.tryClaim(), isNull);
  });

  test('stale foreground heartbeat no longer blocks claim', () async {
    await enterColdStart();
    gate.stopHeartbeat();
    advance(
      BackgroundSessionGate.foregroundFreshFor + const Duration(seconds: 1),
    );
    expect(await gate.tryClaim(), isNotNull);
  });

  test('leaveForeground lets background claim immediately', () async {
    await enterColdStart();
    await gate.leaveForeground();
    expect(await gate.tryClaim(), isNotNull);
  });

  test('second claim refused until first released or expired', () async {
    final first = await gate.tryClaim();
    expect(await gate.tryClaim(), isNull);
    await gate.release(first!);
    expect(await gate.tryClaim(), isNotNull);
  });

  test('claim expires after TTL', () async {
    final first = await gate.tryClaim();
    advance(BackgroundSessionGate.claimTtl + const Duration(seconds: 1));
    expect(await gate.shouldYield(first!), isTrue);
    expect(await gate.tryClaim(), isNotNull);
  });

  test('holder yields when foreground returns', () async {
    final claim = await gate.tryClaim();
    expect(await gate.shouldYield(claim!), isFalse);
    await enterColdStart();
    expect(await gate.shouldYield(claim), isTrue);
  });

  test(
    'released change is reported once; cold start only sets the baseline',
    () async {
      final claim = await gate.tryClaim();
      advance(const Duration(seconds: 5));
      await gate.release(claim!, change: BackgroundSessionChangeKind.committed);

      expect(
        await gate.enterForeground(
          coldStart: true,
          waitForClaim: Duration.zero,
        ),
        isNull,
      );
      expect(await gate.enterForeground(waitForClaim: Duration.zero), isNull);

      await gate.leaveForeground();
      advance(const Duration(minutes: 5));
      final second = await gate.tryClaim();
      advance(const Duration(seconds: 5));
      await gate.release(second!, change: BackgroundSessionChangeKind.revoked);

      final change = await gate.enterForeground(waitForClaim: Duration.zero);
      expect(change?.kind, BackgroundSessionChangeKind.revoked);
      expect(await gate.enterForeground(waitForClaim: Duration.zero), isNull);
    },
  );

  test('enterForeground waits for an active claim to be released', () async {
    final claim = await gate.tryClaim();
    final entering = gate.enterForeground(
      coldStart: true,
      waitForClaim: const Duration(seconds: 3),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await gate.release(claim!);
    await entering;
    expect(await gate.isForegroundActive(), isTrue);
  });

  test(
    'expired-prompt is rate limited; rollback and foreground reset it',
    () async {
      expect(await gate.claimExpiredPrompt(), isTrue);
      expect(await gate.claimExpiredPrompt(), isFalse);

      await gate.rollbackExpiredPrompt();
      expect(await gate.claimExpiredPrompt(), isTrue);

      advance(
        BackgroundSessionGate.promptMinInterval + const Duration(minutes: 1),
      );
      expect(await gate.claimExpiredPrompt(), isTrue);

      expect(await gate.claimExpiredPrompt(), isFalse);
      await enterColdStart();
      expect(await gate.claimExpiredPrompt(), isTrue);
    },
  );

  test('committed recovery clears the expired-prompt record', () async {
    expect(await gate.claimExpiredPrompt(), isTrue);
    final claim = await gate.tryClaim();
    await gate.release(claim!, change: BackgroundSessionChangeKind.committed);
    expect(await gate.claimExpiredPrompt(), isTrue);
  });

  test('corrupt state file is treated as empty state', () async {
    await File(
      '${dir.path}${Platform.pathSeparator}'
      '${BackgroundSessionGate.stateFileName}',
    ).writeAsString('not json');
    expect(await gate.tryClaim(), isNotNull);
  });
}
