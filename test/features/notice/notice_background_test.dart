import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/auth_operation_coordinator.dart';
import 'package:jxu_campus_hub/core/auth/automatic_login.dart';
import 'package:jxu_campus_hub/core/auth/background_cas_recovery.dart';
import 'package:jxu_campus_hub/core/auth/background_session_gate.dart';
import 'package:jxu_campus_hub/core/notice/notice_fetch_service.dart';
import 'package:jxu_campus_hub/core/notice/notice_sync_service.dart';
import 'package:jxu_campus_hub/features/notice/notice_background.dart';

import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late List<String> sent;

  setUp(() async {
    await resetTestEnvironment();
    dir = await Directory.systemTemp.createTemp('notice_bg_test');
    BackgroundSessionGate.instance.debugReset();
    BackgroundSessionGate.instance.debugDirectoryProvider = () async => dir;
    sent = [];
    NoticeSyncService.instance.debugNow = () => DateTime(2026, 9, 1, 10);
    NoticeSyncService.instance.debugNotificationsEnabled = () async => true;
    NoticeSyncService.instance.debugShowNotification =
        ({required id, required title, required body, required payload}) async {
          sent.add(title);
          return true;
        };
  });

  tearDown(() async {
    BackgroundSessionGate.instance.debugReset();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  const expired = NoticeSyncOutcome(
    skipped: false,
    fetchStatus: NoticeFetchStatus.authRequired,
  );

  /// 走完整链路：真实 BackgroundCasRecovery（注入桩）+ NoticeBackground 决策。
  Future<void> runWith({
    required String? account,
    required AuthRecoveryDecision decision,
    required bool loggedIn,
  }) async {
    final recovery = BackgroundCasRecovery.debugNew(
      gate: BackgroundSessionGate.instance,
      eligibility: (_) async => decision,
      credentialAccount: () async => account,
      restoreSession: () async {},
      isLoggedIn: () => loggedIn,
      currentAccount: () => loggedIn ? account : null,
      validateSession: () async => false,
      readEpoch: () async => 1,
      attempt: (a, t) async => const AutomaticLoginAttemptResult(
        outcome: AutomaticLoginOutcome.failed,
      ),
    );
    final result = await recovery.recover();
    await NoticeBackground.instance.handleRecoveryResult(result, expired);
  }

  test('fresh install (no account) never notifies', () async {
    await runWith(
      account: null,
      decision: AuthRecoveryDecision.disabled,
      loggedIn: false,
    );
    expect(sent, isEmpty);
  });

  test('explicit user logout never notifies', () async {
    await runWith(
      account: '2020001',
      decision: AuthRecoveryDecision.revoked,
      loggedIn: false,
    );
    expect(sent, isEmpty);
  });

  test('expired identity without auto recovery notifies once, then is '
      'rate limited across foreground entries', () async {
    final gate = BackgroundSessionGate.instance;
    Future<void> check() => runWith(
      account: '2020001',
      decision: AuthRecoveryDecision.disabled,
      loggedIn: true,
    );

    await check();
    expect(sent, hasLength(1));

    // 用户打开应用（前台进入）再退到后台，后台下一轮检查仍在 12 小时限频内。
    await gate.enterForeground(coldStart: true, waitForClaim: Duration.zero);
    await gate.leaveForeground();
    await check();
    await gate.enterForeground(waitForClaim: Duration.zero);
    await gate.leaveForeground();
    await check();
    expect(sent, hasLength(1));
  });
}
