import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/epay_electricity_gateway.dart';

import '../../helpers/test_setup.dart';

/// 断言「未登录 / 无归属时绝不触网」：任何 call 都视为测试失败。
class _ThrowingGateway implements EpayElectricityGateway {
  int calls = 0;

  @override
  Future<String> call(String method, Map<String, String> data) async {
    calls++;
    throw StateError('unexpected gateway call: $method');
  }

  @override
  void debugReset() {
    calls = 0;
  }

  @override
  Future<void> invalidate() async {}
}

/// 只回答余额查询的网关替身（供串行写入测试驱动一次成功查询）。
class _BalanceGateway implements EpayElectricityGateway {
  _BalanceGateway(this.balance);

  final String balance;

  @override
  Future<String> call(String method, Map<String, String> data) async {
    if (method != 'app.electric.getRoomBalance') {
      throw StateError('unexpected gateway call: $method');
    }
    return jsonEncode({
      'code': '200',
      'msg': 'SUC0000',
      'data': {
        'balance_list': [
          {'id': data['L4_room_id'], 'name': 'room', 'balance': balance},
        ],
      },
    });
  }

  @override
  void debugReset() {}

  @override
  Future<void> invalidate() async {}
}

/// 轮询等待异步链路推进（测试无 FakeAsync，用真实微任务 + 极短延迟）。
Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 400 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue, reason: '等待条件超时');
}

const _configA = DormRoomConfig(
  areaId: '3',
  buildingId: '114',
  floorId: 'F00000',
  roomId: '10720',
);

const _configA2 = DormRoomConfig(
  areaId: '3',
  buildingId: '114',
  floorId: 'F00000',
  roomId: '10721',
);

const _configB = DormRoomConfig(
  areaId: '5',
  buildingId: '220',
  floorId: 'F2',
  roomId: '22018',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

  void loginAs(String account) {
    UnifiedAuthService.instance.debugSetSession(active: true, account: account);
  }

  Future<SharedPreferences> seedOwnedCache(
    String owner,
    double value, {
    DateTime? updatedAt,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(DormElectricityService.roomOwnerKey, owner);
    await prefs.setDouble('dorm_cached_electricity', value);
    await prefs.setInt(
      'dorm_cached_electricity_updated_at',
      (updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
    );
    return prefs;
  }

  test(
    'restores cached electricity and timestamp for the saved owner',
    () async {
      final now = DateTime(2026, 4, 8, 10);
      await seedOwnedCache('20260001', 123.45, updatedAt: now);
      loginAs('20260001');

      await DormElectricityService.instance.restoreCache(force: true);

      expect(DormElectricityService.instance.cachedElectricity, 123.45);
      expect(DormElectricityService.instance.lastUpdated, now);
      expect(DormElectricityService.instance.hasFreshCache, isFalse); // 4 月的时间戳
    },
  );

  test('legacy unowned room config and cache stay ignored until an explicit reselect', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('dorm_epay_area_id', '3');
    await prefs.setString('dorm_epay_building_id', '114');
    await prefs.setString('dorm_epay_floor_id', 'F00000');
    await prefs.setString('dorm_epay_room_id', '10720');
    await prefs.setDouble('dorm_cached_electricity', 88.8);
    await prefs.setInt(
      'dorm_cached_electricity_updated_at',
      DateTime.now().millisecondsSinceEpoch,
    );
    await prefs.setBool('dorm_alert_enabled', true);
    await prefs.setDouble('dorm_alert_threshold', 5);
    loginAs('20260001');

    await DormElectricityService.instance.restoreCache(force: true);

    // 无 owner 标记 = 无主数据：不展示、不查询、不预警，也绝不静默归属。
    expect(DormElectricityService.instance.cachedElectricity, isNull);
    expect(DormElectricityService.instance.lastUpdated, isNull);
    expect(DormElectricityService.instance.hasFreshCache, isFalse);
    expect(await DormElectricityService.instance.loadRoomConfig(), isNull);
    expect(await DormElectricityService.instance.hasRoomConfig(), isFalse);
    expect(await DormElectricityService.instance.getAlertEnabled(), isFalse);
    expect(
      await DormElectricityService.instance.getAlertThreshold(),
      DormElectricityService.defaultAlertThreshold,
    );
    // 磁盘数据保留但被忽略；owner 标记仍为空。
    expect(prefs.getDouble('dorm_cached_electricity'), 88.8);
    expect(prefs.getString(DormElectricityService.roomOwnerKey), isNull);
  });

  test('unowned config is never queried even when logged in', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('dorm_epay_area_id', '3');
    await prefs.setString('dorm_epay_building_id', '114');
    await prefs.setString('dorm_epay_floor_id', 'F00000');
    await prefs.setString('dorm_epay_room_id', '10720');
    loginAs('20260001');
    final gateway = _ThrowingGateway();
    DormElectricityService.instance.debugSetGateway(gateway);

    final value = await DormElectricityService.instance.fetchElectricity(
      forceRefresh: true,
    );

    expect(value, isNull);
    expect(gateway.calls, 0);
    expect(DormElectricityService.instance.lastError, isNull);
  });

  test('saves and restores the epay100 four-level room config', () async {
    loginAs('20260001');

    await DormElectricityService.instance.saveRoomConfig(_configA);
    final restored = await DormElectricityService.instance.loadRoomConfig();
    final prefs = await SharedPreferences.getInstance();

    expect(restored, isNotNull);
    expect(restored!.areaId, '3');
    expect(restored.buildingId, '114');
    expect(restored.floorId, 'F00000');
    expect(restored.roomId, '10720');
    expect(prefs.getString('dorm_epay_area_id'), '3');
    expect(prefs.getString('dorm_epay_building_id'), '114');
    expect(prefs.getString('dorm_epay_floor_id'), 'F00000');
    expect(prefs.getString('dorm_epay_room_id'), '10720');
    // owner 标记最后落盘。
    expect(prefs.getString(DormElectricityService.roomOwnerKey), '20260001');
  });

  test(
    'saveRoomConfig fails closed without a verified unified auth account',
    () async {
      await expectLater(
        DormElectricityService.instance.saveRoomConfig(_configA),
        throwsA(isA<DormServiceException>()),
      );
      // 空白账号同样不算已验证身份。
      UnifiedAuthService.instance.debugSetSession(active: true, account: '   ');
      await expectLater(
        DormElectricityService.instance.saveRoomConfig(_configA),
        throwsA(isA<DormServiceException>()),
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dorm_epay_area_id'), isNull);
      expect(prefs.getString(DormElectricityService.roomOwnerKey), isNull);
    },
  );

  test('saving a new room config clears the previous balance cache', () async {
    final prefs = await SharedPreferences.getInstance();
    final oldUpdatedAt = DateTime.now()
        .subtract(const Duration(minutes: 5))
        .millisecondsSinceEpoch;
    await prefs.setDouble('dorm_cached_electricity', 88.8);
    await prefs.setInt('dorm_cached_electricity_updated_at', oldUpdatedAt);
    loginAs('20260001');
    await DormElectricityService.instance.restoreCache(force: true);

    await DormElectricityService.instance.saveRoomConfig(_configB);

    expect(prefs.containsKey('dorm_cached_electricity'), isFalse);
    expect(prefs.containsKey('dorm_cached_electricity_updated_at'), isFalse);
    expect(DormElectricityService.instance.cachedElectricity, isNull);
    expect(DormElectricityService.instance.lastUpdated, isNull);
  });

  test(
    'another account cannot read the saved config, cache or alert settings',
    () async {
      loginAs('A');
      await DormElectricityService.instance.saveRoomConfig(_configA);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('dorm_cached_electricity', 42.5);
      await prefs.setInt(
        'dorm_cached_electricity_updated_at',
        DateTime.now().millisecondsSinceEpoch,
      );
      await prefs.setBool('dorm_alert_enabled', true);
      await prefs.setDouble('dorm_alert_threshold', 5);

      loginAs('B');
      await DormElectricityService.instance.restoreCache(force: true);

      expect(DormElectricityService.instance.cachedElectricity, isNull);
      expect(DormElectricityService.instance.lastUpdated, isNull);
      expect(DormElectricityService.instance.hasFreshCache, isFalse);
      expect(await DormElectricityService.instance.loadRoomConfig(), isNull);
      expect(await DormElectricityService.instance.hasRoomConfig(), isFalse);
      expect(await DormElectricityService.instance.getAlertEnabled(), isFalse);
      expect(
        await DormElectricityService.instance.getAlertThreshold(),
        DormElectricityService.defaultAlertThreshold,
      );
      // B 未显式重选前，A 的标记与数据保持原样、不被改写。
      expect(prefs.getString(DormElectricityService.roomOwnerKey), 'A');
    },
  );

  test(
    'B explicit save resets A cache, alert opt-in and last notification',
    () async {
      loginAs('A');
      await DormElectricityService.instance.saveRoomConfig(_configA);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('dorm_cached_electricity', 42.5);
      await prefs.setInt(
        'dorm_cached_electricity_updated_at',
        DateTime.now().millisecondsSinceEpoch,
      );
      await prefs.setBool('dorm_alert_enabled', true);
      await prefs.setDouble('dorm_alert_threshold', 5);
      await prefs.setString('dorm_alert_last_notified_date', '2026-09-24');

      loginAs('B');
      await DormElectricityService.instance.saveRoomConfig(_configB);

      expect(prefs.getString(DormElectricityService.roomOwnerKey), 'B');
      expect(prefs.containsKey('dorm_cached_electricity'), isFalse);
      expect(prefs.containsKey('dorm_cached_electricity_updated_at'), isFalse);
      expect(prefs.getBool('dorm_alert_enabled'), isFalse);
      expect(prefs.containsKey('dorm_alert_threshold'), isFalse);
      expect(prefs.containsKey('dorm_alert_last_notified_date'), isFalse);
      expect(await DormElectricityService.instance.getAlertEnabled(), isFalse);
      final restored = await DormElectricityService.instance.loadRoomConfig();
      expect(restored!.roomId, '22018');
    },
  );

  test('same-owner save keeps the alert opt-in', () async {
    loginAs('A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    await DormElectricityService.instance.setAlertEnabled(true);
    await DormElectricityService.instance.setAlertThreshold(5);

    await DormElectricityService.instance.saveRoomConfig(_configA2);

    expect(await DormElectricityService.instance.getAlertEnabled(), isTrue);
    expect(await DormElectricityService.instance.getAlertThreshold(), 5);
  });

  test('restoreCache removes incompatible legacy jdhq room ids', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('dorm_community_id', 'legacy-area');
    await prefs.setString('dorm_building_id', 'legacy-building');
    await prefs.setString('dorm_floor_id', 'legacy-floor');
    await prefs.setString('dorm_room_id', 'legacy-room');
    await prefs.setDouble('dorm_cached_electricity', 66.6);
    await prefs.setInt(
      'dorm_cached_electricity_updated_at',
      DateTime.now().millisecondsSinceEpoch,
    );
    loginAs('20260001');

    await DormElectricityService.instance.restoreCache(force: true);

    expect(prefs.containsKey('dorm_community_id'), isFalse);
    expect(prefs.containsKey('dorm_building_id'), isFalse);
    expect(prefs.containsKey('dorm_floor_id'), isFalse);
    expect(prefs.containsKey('dorm_room_id'), isFalse);
    expect(prefs.containsKey('dorm_cached_electricity'), isFalse);
    expect(prefs.containsKey('dorm_cached_electricity_updated_at'), isFalse);
    expect(DormElectricityService.instance.cachedElectricity, isNull);
    expect(DormElectricityService.instance.lastUpdated, isNull);
    expect(await DormElectricityService.instance.hasRoomConfig(), isFalse);
  });

  test('uses fresh cache without requesting remote electricity', () async {
    await seedOwnedCache('20260001', 88.8);
    loginAs('20260001');
    final gateway = _ThrowingGateway();
    DormElectricityService.instance.debugSetGateway(gateway);

    await DormElectricityService.instance.restoreCache(force: true);
    final value = await DormElectricityService.instance.fetchElectricity();

    expect(value, 88.8);
    expect(gateway.calls, 0);
    expect(DormElectricityService.instance.lastError, isNull);
  });

  test(
    'logged-out account cannot display, query or fall back to the cache',
    () async {
      await seedOwnedCache('A', 123.45);
      loginAs('A');
      await DormElectricityService.instance.restoreCache(force: true);
      expect(DormElectricityService.instance.cachedElectricity, 123.45);

      UnifiedAuthService.instance.debugSetSession(active: false);
      final gateway = _ThrowingGateway();
      DormElectricityService.instance.debugSetGateway(gateway);

      expect(DormElectricityService.instance.cachedElectricity, isNull);
      expect(DormElectricityService.instance.lastUpdated, isNull);
      expect(DormElectricityService.instance.hasFreshCache, isFalse);
      expect(await DormElectricityService.instance.getAlertEnabled(), isFalse);
      expect(await DormElectricityService.instance.loadRoomConfig(), isNull);
      expect(
        await DormElectricityService.instance.fetchElectricity(
          forceRefresh: true,
        ),
        isNull,
      );
      expect(gateway.calls, 0);
    },
  );

  test('same-account re-login can read the existing owner cache', () async {
    await seedOwnedCache('A', 123.45);
    loginAs('A');
    await DormElectricityService.instance.restoreCache(force: true);
    expect(DormElectricityService.instance.cachedElectricity, 123.45);

    UnifiedAuthService.instance.debugSetSession(active: false);
    expect(DormElectricityService.instance.cachedElectricity, isNull);

    loginAs('A');
    await DormElectricityService.instance.restoreCache();
    expect(DormElectricityService.instance.cachedElectricity, 123.45);
  });

  test('auth identity notification adopts the owner cache', () async {
    await seedOwnedCache('A', 123.45);
    loginAs('A');

    // 真实身份变化会 notifyListeners（debugSetSession 不会），监听路径应
    // 自动按 owner 采纳持久缓存，无需调用方显式 restoreCache。
    UnifiedAuthService.instance.notifyListeners();
    await pumpEventQueue();

    expect(DormElectricityService.instance.cachedElectricity, 123.45);
    expect(DormElectricityService.instance.lastUpdated, isNotNull);
  });

  test('a restore started earlier never clobbers a fresher value', () async {
    // 身份出现时触发的 restoreCache 还在读磁盘，网络结果先写入内存：
    // 旧磁盘值（11.1）绝不能覆盖新值（99.9）。
    await seedOwnedCache('A', 11.1);
    final gate = Completer<void>();
    var blocked = false;
    DormElectricityService.instance.debugBeforeCacheAdopt = () async {
      if (blocked) return;
      blocked = true;
      await gate.future;
    };

    loginAs('A');
    // debugSetSession 不触发 notifyListeners；真实身份变化（restoreSession /
    // 登录成功 / 登出）会通知，这里按真实契约显式触发。
    UnifiedAuthService.instance.notifyListeners();
    for (var i = 0; i < 200 && !blocked; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(blocked, isTrue, reason: '等待 restoreCache 采纳屏障超时');
    DormElectricityService.instance.debugSetCachedElectricity(
      99.9,
      updatedAt: DateTime.now(),
    );

    gate.complete();
    await pumpEventQueue();

    expect(DormElectricityService.instance.cachedElectricity, 99.9);
  });

  test('同账号重登推进 revision（无 notify）后，挂起的 restoreCache 不得采纳旧磁盘值', () async {
    await seedOwnedCache('A', 11.1);
    final gate = Completer<void>();
    var blocked = false;
    DormElectricityService.instance.debugBeforeCacheAdopt = () async {
      if (blocked) return;
      blocked = true;
      await gate.future;
    };

    loginAs('A');
    final restore = DormElectricityService.instance.restoreCache(force: true);
    await _waitUntil(() => blocked);

    // 同账号重登：debugSetSession 不 notify（不触发 _onAuthChanged、内存缓存
    // 代际不动），只有 sessionRevision 推进。
    final revisionBefore = UnifiedAuthService.instance.sessionRevision;
    UnifiedAuthService.instance.debugSetSession(active: false);
    loginAs('A');
    expect(
      UnifiedAuthService.instance.sessionRevision,
      greaterThan(revisionBefore),
      reason: '同账号重登必须推进 sessionRevision',
    );

    gate.complete();
    await restore;

    expect(DormElectricityService.instance.cachedElectricity, isNull);
    expect(DormElectricityService.instance.lastUpdated, isNull);
  });

  test('同账号重登推进 revision（无 notify）后，挂起的 loadRoomConfig 不得返回旧配置', () async {
    loginAs('A');
    await DormElectricityService.instance.saveRoomConfig(_configA);

    final gate = Completer<void>();
    var blocked = false;
    DormElectricityService.instance.debugBeforeRoomConfigExpose = () async {
      if (blocked) return;
      blocked = true;
      await gate.future;
    };

    final load = DormElectricityService.instance.loadRoomConfig();
    await _waitUntil(() => blocked);

    // 最后一个 await 边界内身份推进：旧 epoch 的配置快照必须 fail closed。
    UnifiedAuthService.instance.debugSetSession(active: false);
    loginAs('A');

    gate.complete();

    expect(await load, isNull);
  });

  test('checkAndAlert never notifies for a foreign owner config', () async {
    loginAs('A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    await DormElectricityService.instance.setAlertEnabled(true);
    await DormElectricityService.instance.setAlertThreshold(20);
    await seedOwnedCache('A', 5);
    final prefs = await SharedPreferences.getInstance();

    loginAs('B');
    var alerts = 0;
    await DormElectricityService.instance.checkAndAlert(
      onAlert: ({required value, required threshold}) => alerts++,
    );

    expect(alerts, 0);
    expect(prefs.containsKey('dorm_alert_last_notified_date'), isFalse);
  });

  test('checkAndAlert notifies the owning account and records the day', () async {
    loginAs('A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    await DormElectricityService.instance.setAlertEnabled(true);
    await DormElectricityService.instance.setAlertThreshold(20);
    await seedOwnedCache('A', 5);
    final prefs = await SharedPreferences.getInstance();
    await DormElectricityService.instance.restoreCache(force: true);

    var alerts = 0;
    await DormElectricityService.instance.checkAndAlert(
      onAlert: ({required value, required threshold}) {
        expect(value, 5);
        expect(threshold, 20);
        alerts++;
      },
    );

    expect(alerts, 1);
    final now = DateTime.now();
    final today =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    expect(prefs.getString('dorm_alert_last_notified_date'), today);
  });

  test('logged-out checkAndAlert does nothing', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(DormElectricityService.roomOwnerKey, 'A');
    await prefs.setBool('dorm_alert_enabled', true);
    await prefs.setDouble('dorm_alert_threshold', 20);

    var alerts = 0;
    await DormElectricityService.instance.checkAndAlert(
      onAlert: ({required value, required threshold}) => alerts++,
    );

    expect(alerts, 0);
    expect(prefs.containsKey('dorm_alert_last_notified_date'), isFalse);
  });

  // ── 同 isolate 串行：确定性交错 ──────────────────────────────────────────
  //
  // 这些用例用 [DormElectricityService.debugPrivateWriteHook] 把某一次私有
  // 写入精确挂起，在挂起期间切换身份并排队 B 的显式保存，验证服务层的
  // 「写入后复核 + 回滚」：没有串行队列与写入后复核时，A 的迟到写入会落到
  // B 的 owner 名下（B 的配置字段被 A 覆盖 / B 读到 A 的余额或 opt-in）。

  test('A 的 owner 落盘被挂起、B 的保存排队：B 必须拥有匹配的 B 配置', () async {
    final prefs = await SharedPreferences.getInstance();
    loginAs('A');
    await DormElectricityService.instance.saveRoomConfig(_configA);

    final hold = Completer<void>();
    var ownerWrites = 0;
    DormElectricityService.instance.debugPrivateWriteHook =
        (operation, key, write) async {
          if (operation == 'saveRoomConfig' &&
              key == DormElectricityService.roomOwnerKey) {
            ownerWrites++;
            // 第 1 次是保存开始时的标记失效，第 2 次才是最后的 owner 落盘。
            if (ownerWrites == 2) await hold.future;
          }
          await write();
        };

    // A 重新保存：写入 owner 标记后、服务层写入后复核前挂起。
    final aFuture = DormElectricityService.instance.saveRoomConfig(_configA2);
    await _waitUntil(() => ownerWrites >= 2);

    // B 登录并显式保存：动作排在 A 之后（A 仍占着队列）。
    loginAs('B');
    final bFuture = DormElectricityService.instance.saveRoomConfig(_configB);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // 半写入期间 owner 标记保持失效（fail closed），B 尚未执行。
    expect(prefs.getString(DormElectricityService.roomOwnerKey), isNull);

    final aRejects = expectLater(aFuture, throwsA(isA<DormServiceException>()));
    hold.complete();
    await aRejects;
    await bFuture;

    // A 的落盘后复核失败 → 回滚标记；B 的保存随后完整落盘。
    expect(prefs.getString(DormElectricityService.roomOwnerKey), 'B');
    final restored = await DormElectricityService.instance.loadRoomConfig();
    expect(restored, isNotNull);
    expect(restored!.areaId, '5');
    expect(restored.roomId, '22018');
    expect(prefs.getString('dorm_epay_room_id'), '22018');
  });

  test('A 的余额缓存写入被挂起、身份在写入后变化：回滚，不留 A 的值', () async {
    final prefs = await SharedPreferences.getInstance();
    loginAs('A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    DormElectricityService.instance.debugSetGateway(_BalanceGateway('77.70'));

    final hold = Completer<void>();
    var held = false;
    DormElectricityService.instance.debugPrivateWriteHook =
        (operation, key, write) async {
          if (!held &&
              operation == 'persistCache' &&
              key == 'dorm_cached_electricity') {
            held = true;
            await hold.future;
          }
          await write();
        };

    final aFuture = DormElectricityService.instance.fetchElectricity(
      forceRefresh: true,
    );
    await _waitUntil(() => held);

    // 身份在写入前复核之后、写入完成之前变化：没有写入后复核 + 回滚时，
    // A 的余额会留在磁盘上（无时间戳），被后续身份读到。
    loginAs('B');
    hold.complete();

    expect(await aFuture, isNull);
    expect(prefs.containsKey('dorm_cached_electricity'), isFalse);
    expect(prefs.containsKey('dorm_cached_electricity_updated_at'), isFalse);
    expect(DormElectricityService.instance.cachedElectricity, isNull);
  });

  test('A 的余额缓存写入被挂起、B 的保存排队：B 名下绝不出现 A 的值', () async {
    final prefs = await SharedPreferences.getInstance();
    loginAs('A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    DormElectricityService.instance.debugSetGateway(_BalanceGateway('77.70'));

    final hold = Completer<void>();
    var held = false;
    DormElectricityService.instance.debugPrivateWriteHook =
        (operation, key, write) async {
          if (!held &&
              operation == 'persistCache' &&
              key == 'dorm_cached_electricity') {
            held = true;
            await hold.future;
          }
          await write();
        };

    final aFuture = DormElectricityService.instance.fetchElectricity(
      forceRefresh: true,
    );
    await _waitUntil(() => held);

    loginAs('B');
    final bFuture = DormElectricityService.instance.saveRoomConfig(_configB);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    hold.complete();
    expect(await aFuture, isNull); // A 的迟到结果被丢弃
    await bFuture;

    expect(prefs.getString(DormElectricityService.roomOwnerKey), 'B');
    expect(prefs.containsKey('dorm_cached_electricity'), isFalse);
    expect(prefs.containsKey('dorm_cached_electricity_updated_at'), isFalse);
    expect(DormElectricityService.instance.cachedElectricity, isNull);
    final restored = await DormElectricityService.instance.loadRoomConfig();
    expect(restored!.roomId, '22018');
  });

  test('A 的预警开关写入被挂起、身份切到 B 且没有 B 保存：回滚，不留 A 的 opt-in', () async {
    final prefs = await SharedPreferences.getInstance();
    loginAs('A');
    await DormElectricityService.instance.saveRoomConfig(_configA);

    final hold = Completer<void>();
    var held = false;
    DormElectricityService.instance.debugPrivateWriteHook =
        (operation, key, write) async {
          if (!held &&
              operation == 'setAlertEnabled' &&
              key == 'dorm_alert_enabled') {
            held = true;
            await hold.future;
          }
          await write();
        };

    final aFuture = DormElectricityService.instance.setAlertEnabled(true);
    await _waitUntil(() => held);

    loginAs('B');
    hold.complete();
    await aFuture;

    // 没有写入后复核 + 回滚时，这里会留下 true。
    expect(prefs.getBool('dorm_alert_enabled'), isFalse);
    expect(await DormElectricityService.instance.getAlertEnabled(), isFalse);
  });

  test('A 的预警开关写入被挂起、B 的保存排队：回滚，绝不为 B 打开预警', () async {
    final prefs = await SharedPreferences.getInstance();
    loginAs('A');
    await DormElectricityService.instance.saveRoomConfig(_configA);

    final hold = Completer<void>();
    var held = false;
    DormElectricityService.instance.debugPrivateWriteHook =
        (operation, key, write) async {
          if (!held &&
              operation == 'setAlertEnabled' &&
              key == 'dorm_alert_enabled') {
            held = true;
            await hold.future;
          }
          await write();
        };

    final aFuture = DormElectricityService.instance.setAlertEnabled(true);
    await _waitUntil(() => held);
    // A 的 opt-in 尚未落盘（保存时被重置为 false）。
    expect(prefs.getBool('dorm_alert_enabled'), isFalse);

    loginAs('B');
    final bFuture = DormElectricityService.instance.saveRoomConfig(_configB);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    hold.complete();
    await aFuture;
    await bFuture;

    expect(prefs.getString(DormElectricityService.roomOwnerKey), 'B');
    expect(prefs.getBool('dorm_alert_enabled'), isFalse);
    expect(await DormElectricityService.instance.getAlertEnabled(), isFalse);
  });

  test('A 的当日通知状态写入被挂起、身份切到 B：回滚，不写当日状态', () async {
    final prefs = await SharedPreferences.getInstance();
    loginAs('A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    await DormElectricityService.instance.setAlertEnabled(true);
    await DormElectricityService.instance.setAlertThreshold(20);
    await seedOwnedCache('A', 5);
    await DormElectricityService.instance.restoreCache(force: true);

    final hold = Completer<void>();
    var held = false;
    DormElectricityService.instance.debugPrivateWriteHook =
        (operation, key, write) async {
          if (!held &&
              operation == 'checkAndAlert' &&
              key == 'dorm_alert_last_notified_date') {
            held = true;
            await hold.future;
          }
          await write();
        };

    var alerts = 0;
    final checkFuture = DormElectricityService.instance.checkAndAlert(
      onAlert: ({required value, required threshold}) => alerts++,
    );
    await _waitUntil(() => held);
    expect(alerts, 1); // 通知回调在写入前触发，无法撤回；状态写入必须被放弃

    loginAs('B');
    hold.complete();
    await checkFuture;

    expect(prefs.containsKey('dorm_alert_last_notified_date'), isFalse);
  });

  test('owner 自己调用 clearRoomConfig 会清除全部私有键与 owner 标记', () async {
    final prefs = await SharedPreferences.getInstance();
    loginAs('A');
    await DormElectricityService.instance.saveRoomConfig(_configA);
    await DormElectricityService.instance.setAlertEnabled(true);
    await DormElectricityService.instance.setAlertThreshold(5);
    await seedOwnedCache('A', 42.5);

    await DormElectricityService.instance.clearRoomConfig();

    for (final key in [
      'dorm_epay_area_id',
      'dorm_epay_building_id',
      'dorm_epay_floor_id',
      'dorm_epay_room_id',
      DormElectricityService.roomOwnerKey,
      'dorm_cached_electricity',
      'dorm_cached_electricity_updated_at',
      'dorm_alert_enabled',
      'dorm_alert_threshold',
    ]) {
      expect(prefs.containsKey(key), isFalse, reason: key);
    }
  });

  test('归属他人时 clearRoomConfig 不动磁盘数据（fail closed）', () async {
    final prefs = await SharedPreferences.getInstance();
    loginAs('A');
    await DormElectricityService.instance.saveRoomConfig(_configA);

    // B 的迟到清除（例如切换账号后旧界面触发）不得删掉 A 的数据。
    loginAs('B');
    await DormElectricityService.instance.clearRoomConfig();

    expect(prefs.getString(DormElectricityService.roomOwnerKey), 'A');
    expect(prefs.getString('dorm_epay_area_id'), '3');
    expect(prefs.getString('dorm_epay_room_id'), '10720');
  });
}
