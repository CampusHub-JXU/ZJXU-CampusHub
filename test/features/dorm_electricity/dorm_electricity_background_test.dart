import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_background.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/core/epay100/epay100_gateway.dart';

import '../../helpers/test_setup.dart';

/// 后台调度替身：记录原生副作用调用，避免单测依赖 WorkManager / 通知通道。
class _FakeScheduler implements DormBackgroundScheduler {
  int registerCalls = 0;
  int cancelPeriodicCalls = 0;
  int scheduleAlarmCalls = 0;
  int cancelAlarmCalls = 0;
  final List<({int id, double value, double threshold})> notifications = [];

  /// 原生副作用顺序（验证「取消不早于在途调度」「迟到调度之后必有取消」）。
  final List<String> ops = [];

  /// 非 null 时挂起每日提醒调度（模拟原生调用在途）。
  Completer<void>? scheduleAlarmGate;

  /// 非 null 时挂起每日提醒取消（模拟取消在途）。
  Completer<void>? cancelAlarmGate;

  /// 非 null 时挂起周期任务注册（模拟原生调用在途）。
  Completer<void>? registerGate;

  /// 非 null 时在展示即时通知时执行（模拟通知发出瞬间身份变化）。
  Future<void> Function()? onShow;

  @override
  Future<void> registerPeriodicTask() async {
    registerCalls++;
    ops.add('registerPeriodic');
    final gate = registerGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> cancelPeriodicTask() async {
    cancelPeriodicCalls++;
    ops.add('cancelPeriodic');
  }

  @override
  Future<void> scheduleDailyAlarm() async {
    scheduleAlarmCalls++;
    ops.add('scheduleAlarm');
    final gate = scheduleAlarmGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> cancelDailyAlarm() async {
    cancelAlarmCalls++;
    ops.add('cancelAlarm');
    final gate = cancelAlarmGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> showLowElectricityNotification({
    required int id,
    required double value,
    required double threshold,
  }) async {
    notifications.add((id: id, value: value, threshold: threshold));
    ops.add('notify');
    await onShow?.call();
  }
}

/// 断言后台链路绝不触网：任何 call 都视为测试失败。
class _ThrowingGateway implements Epay100Gateway {
  int calls = 0;

  @override
  Future<String> call(String method, Map<String, String> data) async {
    calls++;
    throw StateError('background check must not touch the gateway: $method');
  }

  @override
  void debugReset() {
    calls = 0;
  }

  @override
  Future<void> invalidate() async {}
}

class _BalanceGateway implements Epay100Gateway {
  _BalanceGateway(this.balance);

  final double balance;

  @override
  Future<String> call(String method, Map<String, String> data) async {
    expect(method, 'app.electric.getRoomBalance');
    return '{"code":"200","msg":"SUC0000","data":{"balance_list":['
        '{"id":"${data['L4_room_id']}","name":"HX4-111","balance":"$balance"}]}}';
  }

  @override
  void debugReset() {}

  @override
  Future<void> invalidate() async {}
}

String _today() {
  final now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}

Future<SharedPreferences> _seedPrefs({
  String? owner,
  bool alertEnabled = false,
  double? cachedValue,
  Duration cacheAge = Duration.zero,
  double threshold = 20,
}) async {
  final prefs = await SharedPreferences.getInstance();
  if (owner != null) {
    await prefs.setString(DormElectricityService.roomOwnerKey, owner);
  }
  await prefs.setString('dorm_epay_area_id', '3');
  await prefs.setString('dorm_epay_building_id', '114');
  await prefs.setString('dorm_epay_floor_id', 'F00000');
  await prefs.setString('dorm_epay_room_id', '10720');
  await prefs.setBool('dorm_alert_enabled', alertEnabled);
  await prefs.setDouble('dorm_alert_threshold', threshold);
  if (cachedValue != null) {
    await prefs.setDouble('dorm_cached_electricity', cachedValue);
    await prefs.setInt(
      'dorm_cached_electricity_updated_at',
      DateTime.now().subtract(cacheAge).millisecondsSinceEpoch,
    );
  }
  return prefs;
}

/// 有界轮询等待真实异步推进（不使用固定长延时，避免用例抖动）。
Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeScheduler scheduler;

  setUp(() async {
    await resetTestEnvironment();
    DormElectricityBackground.instance.debugReset();
    scheduler = _FakeScheduler();
    DormElectricityBackground.instance.scheduler = scheduler;
  });

  void loginAs(String account) {
    UnifiedAuthService.instance.debugSetSession(active: true, account: account);
  }

  test('disabled alert never notifies or registers on cold start', () async {
    final prefs = await _seedPrefs(cachedValue: 5);
    loginAs('A');
    final gateway = _ThrowingGateway();
    DormElectricityService.instance.debugSetGateway(gateway);

    expect(
      await DormElectricityBackground.instance.executeBackgroundCheck(),
      isTrue,
    );
    await DormElectricityBackground.instance.ensureScheduled();

    expect(scheduler.notifications, isEmpty);
    expect(scheduler.registerCalls, 0);
    expect(scheduler.scheduleAlarmCalls, 0);
    // 未启用时必须撤掉可能残留的旧任务 / 闹钟。
    expect(scheduler.cancelAlarmCalls, 1);
    expect(scheduler.cancelPeriodicCalls, 1);
    expect(gateway.calls, 0);
    expect(prefs.containsKey('dorm_alert_last_notified_date'), isFalse);
  });

  test('legacy unowned config never notifies or registers', () async {
    final prefs = await _seedPrefs(
      alertEnabled: true,
      cachedValue: 5,
    ); // 无 owner 标记
    loginAs('A');
    final gateway = _ThrowingGateway();
    DormElectricityService.instance.debugSetGateway(gateway);

    expect(
      await DormElectricityBackground.instance.executeBackgroundCheck(),
      isTrue,
    );
    await DormElectricityBackground.instance.ensureScheduled();

    expect(scheduler.notifications, isEmpty);
    expect(scheduler.registerCalls, 0);
    expect(scheduler.scheduleAlarmCalls, 0);
    expect(scheduler.cancelAlarmCalls, 1);
    expect(scheduler.cancelPeriodicCalls, 1);
    expect(prefs.containsKey('dorm_alert_last_notified_date'), isFalse);
    expect(gateway.calls, 0);
  });

  test('foreign owner config never notifies or registers', () async {
    final prefs = await _seedPrefs(
      owner: 'A',
      alertEnabled: true,
      cachedValue: 5,
    );
    loginAs('B');
    final gateway = _ThrowingGateway();
    DormElectricityService.instance.debugSetGateway(gateway);

    expect(
      await DormElectricityBackground.instance.executeBackgroundCheck(),
      isTrue,
    );
    await DormElectricityBackground.instance.ensureScheduled();

    expect(scheduler.notifications, isEmpty);
    expect(scheduler.registerCalls, 0);
    expect(scheduler.scheduleAlarmCalls, 0);
    expect(prefs.containsKey('dorm_alert_last_notified_date'), isFalse);
    expect(gateway.calls, 0);
  });

  test('stale cache beyond 24h never notifies', () async {
    await _seedPrefs(
      owner: 'A',
      alertEnabled: true,
      cachedValue: 5,
      cacheAge: const Duration(hours: 25),
    );
    loginAs('A');

    expect(
      await DormElectricityBackground.instance.executeBackgroundCheck(),
      isTrue,
    );

    expect(scheduler.notifications, isEmpty);
  });

  test('owner-matched fresh low cache notifies once per day', () async {
    final prefs = await _seedPrefs(
      owner: 'A',
      alertEnabled: true,
      cachedValue: 5,
    );
    loginAs('A');
    final gateway = _ThrowingGateway();
    DormElectricityService.instance.debugSetGateway(gateway);

    expect(
      await DormElectricityBackground.instance.executeBackgroundCheck(),
      isTrue,
    );
    expect(scheduler.notifications, hasLength(1));
    expect(scheduler.notifications.single.value, 5);
    expect(scheduler.notifications.single.threshold, 20);
    expect(prefs.getString('dorm_alert_last_notified_date'), _today());

    // 当天第二次检查不重复通知。
    await DormElectricityBackground.instance.executeBackgroundCheck();
    expect(scheduler.notifications, hasLength(1));
    expect(gateway.calls, 0);
  });

  test('owner flip before the notification recheck fails closed', () async {
    final prefs = await _seedPrefs(
      owner: 'A',
      alertEnabled: true,
      cachedValue: 5,
    );
    loginAs('A');
    DormElectricityBackground
        .instance
        .debugBeforeNotificationBarrier = () async {
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
    };

    expect(
      await DormElectricityBackground.instance.executeBackgroundCheck(),
      isTrue,
    );

    expect(scheduler.notifications, isEmpty);
    expect(prefs.containsKey('dorm_alert_last_notified_date'), isFalse);
  });

  test('alert disabled before the notification recheck fails closed', () async {
    final prefs = await _seedPrefs(
      owner: 'A',
      alertEnabled: true,
      cachedValue: 5,
    );
    loginAs('A');
    DormElectricityBackground.instance.debugBeforeNotificationBarrier =
        () async {
          // 模拟主 isolate 在后台检查途中关闭预警：重载后必须放弃。
          await prefs.setBool('dorm_alert_enabled', false);
        };

    expect(
      await DormElectricityBackground.instance.executeBackgroundCheck(),
      isTrue,
    );

    expect(scheduler.notifications, isEmpty);
    expect(prefs.containsKey('dorm_alert_last_notified_date'), isFalse);
  });

  test(
    'notification state is not written when the owner changes on show',
    () async {
      final prefs = await _seedPrefs(
        owner: 'A',
        alertEnabled: true,
        cachedValue: 5,
      );
      loginAs('A');
      scheduler.onShow = () async {
        UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
      };

      expect(
        await DormElectricityBackground.instance.executeBackgroundCheck(),
        isTrue,
      );

      // 通知已发出无法撤回，但通知状态绝不写到已不可信的 owner 上。
      expect(scheduler.notifications, hasLength(1));
      expect(prefs.containsKey('dorm_alert_last_notified_date'), isFalse);
    },
  );

  test(
    'foreground ensureScheduled fails closed when the session is not hydrated',
    () async {
      final prefs = await _seedPrefs(
        owner: 'A',
        alertEnabled: true,
        cachedValue: 5,
      );
      var loaderCalls = 0;
      UnifiedAuthService.instance.debugSessionMetadataLoader = () async {
        loaderCalls++;
        return 'A';
      };
      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);

      await DormElectricityBackground.instance.ensureScheduled();

      // 前台调度路径绝不读持久会话：登出持久撤销竞态下不得复活旧身份，
      // 未水合一律取消残留（fail closed）。
      expect(loaderCalls, 0);
      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
      expect(UnifiedAuthService.instance.debugWebViewCookieSyncCalls, 0);
      expect(scheduler.scheduleAlarmCalls, 0);
      expect(scheduler.registerCalls, 0);
      expect(scheduler.cancelAlarmCalls, 1);
      expect(scheduler.cancelPeriodicCalls, 1);
      // prefs 仍保留 A 的 owner 标记与 opt-in，等待真实身份恢复后再注册。
      expect(prefs.getString(DormElectricityService.roomOwnerKey), 'A');

      // start 的首次对账读到同一未水合身份：幂等，不重复取消。
      DormElectricityBackground.instance.start();
      await DormElectricityBackground.instance.debugWaitForIdle();
      expect(scheduler.cancelAlarmCalls, 1);
      expect(scheduler.cancelPeriodicCalls, 1);

      // 真实登录通知（内存身份 + revision 推进）后由监听器只注册一次。
      loginAs('A');
      UnifiedAuthService.instance.notifyListeners();
      await DormElectricityBackground.instance.debugWaitForIdle();
      expect(scheduler.scheduleAlarmCalls, 1);
      expect(scheduler.registerCalls, 1);
      expect(scheduler.cancelAlarmCalls, 1);
      expect(loaderCalls, 0);
    },
  );

  test(
    'background check restores metadata only and notifies owner-matched cache',
    () async {
      final prefs = await _seedPrefs(
        owner: 'A',
        alertEnabled: true,
        cachedValue: 5,
      );
      UnifiedAuthService.instance.debugSessionMetadataLoader = () async => 'A';

      expect(
        await DormElectricityBackground.instance.executeBackgroundCheck(),
        isTrue,
      );

      expect(UnifiedAuthService.instance.debugWebViewCookieSyncCalls, 0);
      expect(scheduler.notifications, hasLength(1));
      expect(prefs.getString('dorm_alert_last_notified_date'), _today());
    },
  );

  test('reRegisterIfNeeded cancels when disabled or unowned', () async {
    await _seedPrefs(owner: 'A', alertEnabled: false, cachedValue: 5);
    await DormElectricityBackground.instance.reRegisterIfNeeded();
    expect(scheduler.registerCalls, 0);
    expect(scheduler.cancelAlarmCalls, 1);
    expect(scheduler.cancelPeriodicCalls, 1);

    await _seedPrefs(owner: 'A', alertEnabled: true, cachedValue: 5);
    loginAs('B');
    await DormElectricityBackground.instance.reRegisterIfNeeded();
    expect(scheduler.registerCalls, 0);
    expect(scheduler.cancelAlarmCalls, 2);
    expect(scheduler.cancelPeriodicCalls, 2);

    loginAs('A');
    await DormElectricityBackground.instance.reRegisterIfNeeded();
    expect(scheduler.registerCalls, 1);
    expect(scheduler.scheduleAlarmCalls, 1);
    expect(scheduler.cancelAlarmCalls, 2);
  });

  test('foregroundCheck does nothing for a foreign owner', () async {
    final prefs = await _seedPrefs(
      owner: 'A',
      alertEnabled: true,
      cachedValue: 5,
    );
    loginAs('B');
    final gateway = _ThrowingGateway();
    DormElectricityService.instance.debugSetGateway(gateway);

    await DormElectricityBackground.instance.foregroundCheck();

    expect(scheduler.notifications, isEmpty);
    expect(gateway.calls, 0);
    expect(prefs.containsKey('dorm_alert_last_notified_date'), isFalse);
  });

  test('foregroundCheck notifies the owner-matched low cache', () async {
    final prefs = await _seedPrefs(owner: 'A', alertEnabled: true);
    loginAs('A');
    DormElectricityService.instance.debugSetGateway(_BalanceGateway(5));

    await DormElectricityBackground.instance.foregroundCheck();

    expect(scheduler.notifications, hasLength(1));
    expect(scheduler.notifications.single.value, 5);
    expect(prefs.getString('dorm_alert_last_notified_date'), _today());
  });

  group('主引擎前台身份对账（登出 / 换号 / 同号重登）', () {
    test(
      'logout reconciliation cancels the scheduled alarm and periodic task',
      () async {
        await _seedPrefs(owner: 'A', alertEnabled: true);
        loginAs('A');
        await DormElectricityBackground.instance.ensureScheduled();
        expect(scheduler.scheduleAlarmCalls, 1);
        expect(scheduler.registerCalls, 1);

        UnifiedAuthService.instance.debugSetSession(active: false);
        await DormElectricityBackground.instance.onAuthIdentityChanged();

        expect(scheduler.cancelAlarmCalls, 1);
        expect(scheduler.cancelPeriodicCalls, 1);
        // 取消后不再重注册任何旧身份任务。
        expect(scheduler.scheduleAlarmCalls, 1);
        expect(scheduler.registerCalls, 1);
        expect(scheduler.ops.last, 'cancelPeriodic');
      },
    );

    test('A→B switch cancels stale artifacts and does not re-arm', () async {
      final prefs = await _seedPrefs(owner: 'A', alertEnabled: true);
      loginAs('A');
      await DormElectricityBackground.instance.ensureScheduled();
      expect(scheduler.scheduleAlarmCalls, 1);

      loginAs('B');
      await DormElectricityBackground.instance.onAuthIdentityChanged();

      expect(scheduler.cancelAlarmCalls, 1);
      expect(scheduler.cancelPeriodicCalls, 1);
      expect(scheduler.scheduleAlarmCalls, 1);
      expect(scheduler.registerCalls, 1);
      // A 的 owner 标记与 opt-in 原样保留，B 不得接管。
      expect(prefs.getString(DormElectricityService.roomOwnerKey), 'A');
      expect(scheduler.ops.last, 'cancelPeriodic');
    });

    test('a late A schedule can never land after B cancellation', () async {
      await _seedPrefs(owner: 'A', alertEnabled: true);
      loginAs('A');

      final gate = Completer<void>();
      scheduler.scheduleAlarmGate = gate;
      final firstRound = DormElectricityBackground.instance
          .onAuthIdentityChanged();
      await _waitFor(() => scheduler.scheduleAlarmCalls == 1);

      // A 的调度在途，切到 B（marker 仍是 A，不可注册）。
      loginAs('B');
      final secondRound = DormElectricityBackground.instance
          .onAuthIdentityChanged();
      // 串行队列：B 的取消必须等 A 的在途调度结束后才开始。
      expect(scheduler.cancelAlarmCalls, 0);

      gate.complete();
      await firstRound;
      await secondRound;

      expect(scheduler.scheduleAlarmCalls, 1);
      // 迟到的 A 轮次不再追加周期任务；最终状态由 B 轮次取消收口。
      expect(scheduler.registerCalls, 0);
      expect(scheduler.cancelAlarmCalls, 1);
      expect(scheduler.cancelPeriodicCalls, 1);
      expect(scheduler.ops.last, 'cancelPeriodic');
    });

    test(
      'repeated same-identity reconciliation does not register twice',
      () async {
        await _seedPrefs(owner: 'A', alertEnabled: true);
        loginAs('A');

        await DormElectricityBackground.instance.onAuthIdentityChanged();
        expect(scheduler.scheduleAlarmCalls, 1);
        expect(scheduler.registerCalls, 1);

        await DormElectricityBackground.instance.onAuthIdentityChanged();
        await DormElectricityBackground.instance.onAuthIdentityChanged();

        expect(scheduler.scheduleAlarmCalls, 1);
        expect(scheduler.registerCalls, 1);
        expect(
          scheduler.ops.where((op) => op == 'scheduleAlarm'),
          hasLength(1),
        );
      },
    );

    test(
      'start installs the auth listener and logout notification cancels',
      () async {
        await _seedPrefs(owner: 'A', alertEnabled: true);
        loginAs('A');

        DormElectricityBackground.instance.start();
        DormElectricityBackground.instance.start(); // 幂等：不重复安装监听。
        await DormElectricityBackground.instance.debugWaitForIdle();
        expect(scheduler.scheduleAlarmCalls, 1);
        expect(scheduler.registerCalls, 1);

        // 生产登出路径：`markLoggedOut` 会 notifyListeners，监听器随即排队取消。
        UnifiedAuthService.instance.debugSetSession(active: false);
        UnifiedAuthService.instance.notifyListeners();
        await DormElectricityBackground.instance.debugWaitForIdle();

        expect(scheduler.cancelAlarmCalls, 1);
        expect(scheduler.cancelPeriodicCalls, 1);
        expect(scheduler.scheduleAlarmCalls, 1);
        expect(scheduler.registerCalls, 1);
      },
    );

    test(
      'same-account re-login re-arms only after the verified owner returns',
      () async {
        await _seedPrefs(owner: 'A', alertEnabled: true);
        loginAs('A');
        await DormElectricityBackground.instance.ensureScheduled();
        expect(scheduler.scheduleAlarmCalls, 1);

        // 登出：同账号重登前的窗口必须先取消，绝不把 A 的提醒留给未验证窗口。
        UnifiedAuthService.instance.debugSetSession(active: false);
        await DormElectricityBackground.instance.onAuthIdentityChanged();
        expect(scheduler.cancelAlarmCalls, 1);
        expect(scheduler.cancelPeriodicCalls, 1);

        // 同账号重登（revision 已推进）→ 新的已验证 owner 重排。
        loginAs('A');
        await DormElectricityBackground.instance.onAuthIdentityChanged();
        expect(scheduler.scheduleAlarmCalls, 2);
        expect(scheduler.registerCalls, 2);
        expect(scheduler.cancelAlarmCalls, 1);
      },
    );

    test('cold start with alert disabled stays cancelled', () async {
      await _seedPrefs(alertEnabled: false);
      loginAs('A');

      DormElectricityBackground.instance.start();
      await DormElectricityBackground.instance.debugWaitForIdle();

      expect(scheduler.scheduleAlarmCalls, 0);
      expect(scheduler.registerCalls, 0);
      expect(scheduler.cancelAlarmCalls, 1);
      expect(scheduler.cancelPeriodicCalls, 1);
    });

    test('cold start with unowned config stays cancelled', () async {
      await _seedPrefs(alertEnabled: true); // 无 owner 标记（legacy 残留）
      loginAs('A');

      DormElectricityBackground.instance.start();
      await DormElectricityBackground.instance.debugWaitForIdle();

      expect(scheduler.scheduleAlarmCalls, 0);
      expect(scheduler.registerCalls, 0);
      expect(scheduler.cancelAlarmCalls, 1);
      expect(scheduler.cancelPeriodicCalls, 1);
    });

    test('debugReset removes the auth listener', () async {
      await _seedPrefs(owner: 'A', alertEnabled: true);
      loginAs('A');
      DormElectricityBackground.instance.start();
      await DormElectricityBackground.instance.debugWaitForIdle();
      expect(scheduler.scheduleAlarmCalls, 1);

      DormElectricityBackground.instance.debugReset();
      DormElectricityBackground.instance.scheduler = scheduler;

      // 监听器已卸载：身份通知不得再触发任何原生副作用。
      UnifiedAuthService.instance.debugSetSession(active: false);
      UnifiedAuthService.instance.notifyListeners();
      await Future<void>.delayed(Duration.zero);

      expect(scheduler.cancelAlarmCalls, 0);
      expect(scheduler.cancelPeriodicCalls, 0);
      expect(scheduler.scheduleAlarmCalls, 1);
    });

    test('identity flip during in-flight alarm scheduling cancels in the same action', () async {
      await _seedPrefs(owner: 'A', alertEnabled: true);
      loginAs('A');

      final gate = Completer<void>();
      scheduler.scheduleAlarmGate = gate;
      final round = DormElectricityBackground.instance.onAuthIdentityChanged();
      await _waitFor(() => scheduler.scheduleAlarmCalls == 1);

      // 无通知的身份翻转：不能只依赖后续监听器，本动作内必须回撤。
      UnifiedAuthService.instance.debugSetSession(active: false);
      gate.complete();
      await round;

      expect(scheduler.scheduleAlarmCalls, 1);
      expect(scheduler.registerCalls, 0);
      expect(scheduler.cancelAlarmCalls, 1);
      expect(scheduler.cancelPeriodicCalls, 1);
      expect(scheduler.ops.last, 'cancelPeriodic');

      // 迟到的同身份对账保持幂等：不重复取消 / 注册。
      await DormElectricityBackground.instance.onAuthIdentityChanged();
      expect(scheduler.cancelAlarmCalls, 1);
      expect(scheduler.cancelPeriodicCalls, 1);
      expect(scheduler.scheduleAlarmCalls, 1);
    });

    test('identity flip during in-flight periodic registration cancels in the same action', () async {
      await _seedPrefs(owner: 'A', alertEnabled: true);
      loginAs('A');

      final gate = Completer<void>();
      scheduler.registerGate = gate;
      final round = DormElectricityBackground.instance.onAuthIdentityChanged();
      await _waitFor(() => scheduler.registerCalls == 1);

      // 无通知的身份翻转：注册在途期间翻转也必须在本动作内回撤。
      UnifiedAuthService.instance.debugSetSession(active: false);
      gate.complete();
      await round;

      expect(scheduler.scheduleAlarmCalls, 1);
      expect(scheduler.registerCalls, 1);
      expect(scheduler.cancelAlarmCalls, 1);
      expect(scheduler.cancelPeriodicCalls, 1);
      expect(scheduler.ops.last, 'cancelPeriodic');
    });

    test('explicit ensureScheduled cancels its in-flight stale schedule without a notification', () async {
      await _seedPrefs(owner: 'A', alertEnabled: true);
      loginAs('A');

      final gate = Completer<void>();
      scheduler.scheduleAlarmGate = gate;
      final round = DormElectricityBackground.instance.ensureScheduled();
      await _waitFor(() => scheduler.scheduleAlarmCalls == 1);

      UnifiedAuthService.instance.debugSetSession(active: false);
      gate.complete();
      await round;

      expect(scheduler.registerCalls, 0);
      expect(scheduler.cancelAlarmCalls, 1);
      expect(scheduler.cancelPeriodicCalls, 1);
      expect(scheduler.ops.last, 'cancelPeriodic');
    });

    test('foreground reschedule cancels its in-flight stale alarm without a notification', () async {
      await _seedPrefs(owner: 'A', alertEnabled: true, cachedValue: 5);
      loginAs('A');
      DormElectricityService.instance.debugSetGateway(_BalanceGateway(25));

      final gate = Completer<void>();
      scheduler.scheduleAlarmGate = gate;
      final round = DormElectricityBackground.instance.foregroundCheck();
      await _waitFor(() => scheduler.scheduleAlarmCalls == 1);

      UnifiedAuthService.instance.debugSetSession(active: false);
      gate.complete();
      await round;

      expect(scheduler.notifications, isEmpty);
      expect(scheduler.scheduleAlarmCalls, 1);
      expect(scheduler.cancelAlarmCalls, 1);
      expect(scheduler.cancelPeriodicCalls, 1);
      expect(scheduler.ops.last, 'cancelPeriodic');
    });
  });
}
