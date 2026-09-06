import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/epay_electricity_gateway.dart';

import '../../helpers/test_setup.dart';

HeadlessEpay100Gateway get _gateway =>
    Epay100Gateway.instance as HeadlessEpay100Gateway;

void main() {
  setUp(() async {
    await resetTestEnvironment();
  });

  group('账户绑定与变更销毁（共享网关隔离）', () {
    test('切换账号：作废会话并标记连指纹一起清理', () {
      _gateway.debugReset();
      _gateway.debugBindAccount('A');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');

      _gateway.debugHandleAuthChanged();

      expect(_gateway.debugBoundAccount, isNull);
      expect(_gateway.debugNeedsFullReset, isTrue);
    });

    test('登出（账号变 null）：同样作废并标记清理，A 的凭据不可复用', () {
      _gateway.debugReset();
      _gateway.debugBindAccount('A');
      UnifiedAuthService.instance.debugSetSession(active: false);

      _gateway.debugHandleAuthChanged();

      expect(_gateway.debugBoundAccount, isNull);
      expect(_gateway.debugNeedsFullReset, isTrue);
    });

    test('同一账号的会话通知不触发会话销毁', () {
      _gateway.debugReset();
      _gateway.debugBindAccount('A');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');

      _gateway.debugHandleAuthChanged();

      expect(_gateway.debugBoundAccount, 'A');
      expect(_gateway.debugNeedsFullReset, isFalse);
    });

    test('未绑定会话（尚未启动）时账号通知不触发清理', () {
      _gateway.debugReset();
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');

      _gateway.debugHandleAuthChanged();

      expect(_gateway.debugBoundAccount, isNull);
      expect(_gateway.debugNeedsFullReset, isFalse);
    });

    test('统一认证 notifier 真实登出联动作废会话', () async {
      _gateway.debugReset();
      _gateway.debugBindAccount('A');

      await UnifiedAuthService.instance.markLoggedOut();

      expect(_gateway.debugBoundAccount, isNull);
      expect(_gateway.debugNeedsFullReset, isTrue);
    });
  });

  group('会话 epoch（同账号 logout→login 凭据组已换新）', () {
    test('同一账号登出再登录：epoch 逐次递增，不依赖账号相等判定', () {
      _gateway.debugReset();
      _gateway.debugBindAccount('A');
      final epoch0 = _gateway.debugAuthEpoch;

      // 登出：epoch +1，销毁会话。
      UnifiedAuthService.instance.debugSetSession(active: false);
      _gateway.debugHandleAuthChanged();
      expect(_gateway.debugAuthEpoch, epoch0 + 1);
      expect(_gateway.debugBoundAccount, isNull);
      expect(_gateway.debugNeedsFullReset, isTrue);

      // 同账号重新登录：凭据组已换新，epoch 再 +1。
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      _gateway.debugHandleAuthChanged();
      expect(_gateway.debugAuthEpoch, epoch0 + 2);
      // 会话尚未重新启动，不自动重绑；下次 _start 重新绑定。
      expect(_gateway.debugBoundAccount, isNull);
    });

    test('ensureSameSession：epoch 不一致即拒绝，仅账号相等不足', () {
      _gateway.debugReset();
      _gateway.debugBindAccount('A');
      final epoch0 = _gateway.debugAuthEpoch;

      // 同 epoch 同账号放行；未绑定会话（null）放行。
      expect(
        () =>
            HeadlessEpay100Gateway.ensureSameSession('A', epoch0, 'A', epoch0),
        returnsNormally,
      );
      expect(
        () =>
            HeadlessEpay100Gateway.ensureSameSession(null, epoch0, 'B', epoch0),
        returnsNormally,
      );

      // 同账号但 epoch 已前进（logout→login）：拒绝。
      expect(
        () => HeadlessEpay100Gateway.ensureSameSession(
          'A',
          epoch0,
          'A',
          epoch0 + 2,
        ),
        throwsA(isA<EpaySessionUnavailableException>()),
      );

      // 同 epoch 但账号不同：拒绝。
      expect(
        () =>
            HeadlessEpay100Gateway.ensureSameSession('A', epoch0, 'B', epoch0),
        throwsA(isA<EpaySessionUnavailableException>()),
      );
    });
  });

  group('入队身份固定与启动生命周期（gated transport）', () {
    test('已登录入队 + startup 跳过 restore：epoch 稳定，首次 RPC 守卫不误判', () async {
      _gateway.debugReset();
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      final epochAtEnqueue = _gateway.debugAuthEpoch;
      final gate = Completer<void>();
      _gateway.debugStartupGate = gate;

      final op = _gateway.call('app.electric.getRoomBalance', const {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(_gateway.debugBoundAccount, isNull); // 闸门前未绑定

      _gateway.debugStartupGate = null;
      gate.complete();
      // 测试环境 startup 在 CAS 校验处失败；关键断言：已登录时 startup
      // 不做 restoreSession，epoch 不被推进，入队身份 (A, N) 不失配。
      await expectLater(op, throwsA(isA<EpaySessionUnavailableException>()));
      expect(_gateway.debugAuthEpoch, epochAtEnqueue);
      expect(_gateway.debugBoundAccount, 'A');
      expect(_gateway.debugRpcSendCount, 0);
    });

    test('真实 restore notifier 链：冷启动 stored session 入队身份与 epoch 对齐', () async {
      _gateway.debugReset();
      UnifiedAuthService.instance.debugSetSession(active: false);
      await CredentialStore.instance.saveUnifiedAuthSession('A');
      final epochAtEnqueue = _gateway.debugAuthEpoch;
      var notifications = 0;
      void listener() => notifications++;
      UnifiedAuthService.instance.addListener(listener);

      final op = _gateway.call('app.electric.getRoomBalance', const {});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      UnifiedAuthService.instance.removeListener(listener);
      // 真实 restoreSession 通知链：恰好一次身份变化通知 → epoch +1。
      expect(notifications, 1);
      expect(_gateway.debugAuthEpoch, epochAtEnqueue + 1);
      expect(UnifiedAuthService.instance.currentAccount, 'A');
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      expect(_gateway.debugBoundAccount, 'A');
      await expectLater(op, throwsA(isA<EpaySessionUnavailableException>()));
      expect(_gateway.debugRpcSendCount, 0);
    });

    test('restore 存储读取等待中外部 logout：不得复活旧身份并发送 RPC', () async {
      _gateway.debugReset();
      UnifiedAuthService.instance.debugSetSession(active: false);
      final epochAtEnqueue = _gateway.debugAuthEpoch;
      final started = Completer<void>();
      final loadGate = Completer<void>();
      UnifiedAuthService.instance.debugSessionMetadataLoader = () async {
        if (!started.isCompleted) started.complete();
        await loadGate.future;
        return 'A';
      };

      final op = _gateway.call('app.electric.getRoomBalance', const {});
      await started.future;

      await UnifiedAuthService.instance.markLoggedOut();
      loadGate.complete();

      await expectLater(op, throwsA(isA<EpaySessionUnavailableException>()));
      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
      expect(UnifiedAuthService.instance.currentAccount, isNull);
      expect(_gateway.debugBoundAccount, isNull);
      expect(_gateway.debugRpcSendCount, 0);
      expect(_gateway.debugAuthEpoch, greaterThan(epochAtEnqueue));
    });

    test('冷启动未登录但有 stored session：restore 正常建立身份并绑定 A', () async {
      _gateway.debugReset();
      UnifiedAuthService.instance.debugSetSession(active: false);
      await CredentialStore.instance.saveUnifiedAuthSession('A');
      final epochAtEnqueue = _gateway.debugAuthEpoch;

      final op = _gateway.call('app.electric.getRoomBalance', const {});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // restoreSession 真实建立身份（恰好一次通知 → epoch 恰好 +1），
      // startup 正常绑定 A；随后在 CAS 校验处因测试环境失败。
      expect(_gateway.debugBoundAccount, 'A');
      expect(_gateway.debugAuthEpoch, epochAtEnqueue + 1);
      await expectLater(op, throwsA(isA<EpaySessionUnavailableException>()));
      expect(_gateway.debugRpcSendCount, 0);
    });

    test('A 排队的 RPC 在切到 B 后拒绝发送；B 的新调用绑定 B', () async {
      _gateway.debugReset();
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      final epochAtEnqueue = _gateway.debugAuthEpoch;
      final gate = Completer<void>();
      _gateway.debugStartupGate = gate;

      final opA = _gateway.call('app.electric.getRoomBalance', const {});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
      _gateway.debugHandleAuthChanged();
      expect(_gateway.debugAuthEpoch, epochAtEnqueue + 1);

      _gateway.debugStartupGate = null;
      gate.complete();
      // 绑定发生在闸门后：startup 以当前身份（B）继续；opA 的入队身份
      // (A, N) 在发送前会被 epoch 失配守卫拒绝（生产路径），此处以
      // sendCount==0 + B 绑定证明排队 RPC 未发给 B。
      await expectLater(opA, throwsA(isA<EpaySessionUnavailableException>()));
      expect(_gateway.debugRpcSendCount, 0);
      expect(_gateway.debugBoundAccount, 'B');

      final opB = _gateway.call('app.electric.getAreaList', const {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(_gateway.debugBoundAccount, 'B');
      await expectLater(opB, throwsA(isA<EpaySessionUnavailableException>()));
      expect(_gateway.debugRpcSendCount, 0);
    });

    test('同账号 logout→login 发生在启动等待中：绑定新凭据身份、零发送', () async {
      _gateway.debugReset();
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      final epochAtEnqueue = _gateway.debugAuthEpoch;
      final gate = Completer<void>();
      _gateway.debugStartupGate = gate;

      final op = _gateway.call('app.electric.getRoomBalance', const {});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // 登出（epoch+1）后同账号重新登录：saveUnifiedAuthSession 落盘 +
      // restoreSession 真实身份变化（null→A）→ 恰好一次通知 → epoch+1
      await UnifiedAuthService.instance.markLoggedOut();
      await CredentialStore.instance.saveUnifiedAuthSession('A');
      await UnifiedAuthService.instance.restoreSession(
        syncWebViewCookies: false,
      );
      expect(_gateway.debugAuthEpoch, epochAtEnqueue + 2);

      _gateway.debugStartupGate = null;
      gate.complete();
      // 旧 startup 已被两次 epoch 推进作废；入队身份 (A, N) 在发送前守卫
      // 被拒（生产路径），此处 startup 以当前（重登后的）身份绑定。
      await expectLater(op, throwsA(isA<EpaySessionUnavailableException>()));
      expect(_gateway.debugRpcSendCount, 0);
      expect(_gateway.debugBoundAccount, 'A');
    });

    test('A 在执行且 B 已排队时 logout/invalidate 不死锁，旧 RPC 零发送', () async {
      _gateway.debugReset();
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      final gate = Completer<void>();
      _gateway.debugStartupGate = gate;

      final opA = _gateway.call('app.electric.getRoomBalance', const {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final opB = _gateway.call('app.electric.getAreaList', const {});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final logout = UnifiedAuthService.instance.markLoggedOut();
      final invalidating = _gateway.invalidate();
      _gateway.debugStartupGate = null;
      gate.complete();

      await expectLater(
        Future.wait<void>([
          logout,
          invalidating,
          opA.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
          opB.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        ]).timeout(const Duration(seconds: 2)),
        completes,
      );
      await expectLater(opA, throwsA(isA<EpaySessionUnavailableException>()));
      await expectLater(opB, throwsA(isA<EpaySessionUnavailableException>()));
      expect(_gateway.debugRpcSendCount, 0);
    });
  });

  group('RPC 信封错误映射（C900901 vs C900903）', () {
    test('C900901：绑定缺失，直接失败，不重建，日志不含 msg/body', () {
      final action = HeadlessEpay100Gateway.classifyRpcError(
        method: 'app.yktservice.getPayQrcode',
        json: {
          'code': 'C900901',
          'msg': 'DO-NOT-LOG-THIS-MSG',
          'body': 'secret-qr',
        },
      );
      expect(action, isNotNull);
      expect(action!.exception, isA<EpayBindingRequiredException>());
      expect(
        action.exception.toString(),
        EpayBindingRequiredException.defaultMessage,
      );
      expect(action.giveUp, isNull);
      expect(action.logLine, contains('C900901'));
      expect(action.logLine, isNot(contains('DO-NOT-LOG')));
      expect(action.logLine, isNot(contains('secret-qr')));
    });

    test('getSetting C900901 同样不可吞、不可当会话失效', () {
      final action = HeadlessEpay100Gateway.classifyRpcError(
        method: 'app.yktservice.getSetting',
        json: {'code': 'C900901'},
      );
      expect(action!.exception, isA<EpayBindingRequiredException>());
      expect(action.exception, isNot(isA<EpaySessionUnavailableException>()));
    });

    test('C900903：重建重试，giveUp 才是会话不可用', () {
      final action = HeadlessEpay100Gateway.classifyRpcError(
        method: 'app.yktservice.getPayQrcode',
        json: {'code': 'C900903', 'msg': '客户端识别码已失效'},
      );
      expect(action!.exception, isNull);
      expect(action.giveUp, isA<EpaySessionUnavailableException>());
      expect(action.logLine, contains('登录态失效'));
      expect(action.logLine, isNot(contains('客户端识别码已失效')));
    });

    test('no-session：重建；空信封：重建为网关异常；200：放行', () {
      expect(
        HeadlessEpay100Gateway.classifyRpcError(
          method: 'app.electric.getRoomBalance',
          json: {'code': 'no-session'},
        )!.giveUp,
        isA<EpaySessionUnavailableException>(),
      );
      expect(
        HeadlessEpay100Gateway.classifyRpcError(
          method: 'app.yktservice.getPayQrcode',
          json: {'code': '', 'status': '302', 'nf': false},
        )!.giveUp,
        isA<EpayGatewayException>(),
      );
      expect(
        HeadlessEpay100Gateway.classifyRpcError(
          method: 'app.yktservice.getPayQrcode',
          json: {'code': '200', 'body': '{}'},
        ),
        isNull,
      );
    });
  });

  group('隐藏 WebView UA（普通 H5，无 DingTalk 后缀）', () {
    test('headlessWebViewSettings 不追加 DingTalk/7.0.0', () {
      final settings = HeadlessEpay100Gateway.headlessWebViewSettings();
      expect(settings.applicationNameForUserAgent, isNot(contains('DingTalk')));
      expect(settings.userAgent, isNot(contains('DingTalk')));
      expect(settings.javaScriptEnabled, isTrue);
      expect(settings.domStorageEnabled, isTrue);
      expect(settings.useShouldOverrideUrlLoading, isNot(true));
    });
  });

  group('未登录直接失败', () {
    test('未登录时 call 立即抛会话不可用，不启动 WebView 会话', () async {
      await expectLater(
        Epay100Gateway.instance.call('app.yktservice.getSetting', const {}),
        throwsA(isA<EpaySessionUnavailableException>()),
      );
    });
  });

  group('兼容别名（dorm_electricity 旧调用方）', () {
    test('旧名 typedef 指向共享网关同一实例', () {
      expect(EpayElectricityGateway.instance, same(Epay100Gateway.instance));
      expect(
        EpayElectricityGateway.instance,
        isA<HeadlessEpayElectricityGateway>(),
      );
      expect(EpayElectricityGateway.instance, isA<HeadlessEpay100Gateway>());
    });
  });
}
