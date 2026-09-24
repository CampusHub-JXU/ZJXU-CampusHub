import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';

import '../../helpers/test_setup.dart';

/// 私有变更队列的 **zone 安全** 回归 + 归属守卫（clear / checkAndAlert）。
///
/// 这些用例必须用 `testWidgets`：只有 widget 测试体跑在 `FakeAsync` 区里，
/// 而 `setUp` 在区外执行。若队列种子是「在 setUp 里创建的已完成 Future」，
/// widget 测试里的 `.then` 会回到该 Future 自己的 zone 调度 microtask，
/// FakeAsync 永远泵不到 → `restoreCache(force:true)` / `saveRoomConfig` 死锁。
/// `--timeout` 打断不了 FakeAsync 死锁，必须用 OS 级进程树超时兜底运行。
const _configA = DormRoomConfig(
  areaId: '3',
  buildingId: '114',
  floorId: 'F00000',
  roomId: '10720',
);

const _configB = DormRoomConfig(
  areaId: '5',
  buildingId: '220',
  floorId: 'F2',
  roomId: '22018',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // setUp 在 FakeAsync 区之外运行：完整重置环境，复现 home / dorm page
  // widget 测试的真实测试序（队列在区外被重置）。
  setUp(() async {
    await resetTestEnvironment();
  });

  void loginAs(String account) {
    UnifiedAuthService.instance.debugSetSession(active: true, account: account);
  }

  String today() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  testWidgets('saveRoomConfig 在 FakeAsync 区内可完成并落盘', (tester) async {
    loginAs('A');

    await DormElectricityService.instance.saveRoomConfig(_configA);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(DormElectricityService.roomOwnerKey), 'A');
    expect(prefs.getString('dorm_epay_room_id'), '10720');
    final restored = await DormElectricityService.instance.loadRoomConfig();
    expect(restored, isNotNull);
    expect(restored!.roomId, '10720');
  });

  testWidgets('restoreCache(force: true) 在 FakeAsync 区内可完成并采纳 owner 缓存', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(DormElectricityService.roomOwnerKey, 'A');
    await prefs.setDouble('dorm_cached_electricity', 42.5);
    await prefs.setInt(
      'dorm_cached_electricity_updated_at',
      DateTime.now().millisecondsSinceEpoch,
    );
    loginAs('A');

    await DormElectricityService.instance.restoreCache(force: true);

    expect(DormElectricityService.instance.cachedElectricity, 42.5);
    expect(DormElectricityService.instance.lastUpdated, isNotNull);
  });

  testWidgets('并发两次 checkAndAlert：同日只回调一次、只落一次当日状态', (tester) async {
    final service = DormElectricityService.instance;
    final prefs = await SharedPreferences.getInstance();
    loginAs('A');
    await service.saveRoomConfig(_configA);
    await service.setAlertEnabled(true);
    await service.setAlertThreshold(20);
    service.debugSetCachedElectricity(5, updatedAt: DateTime.now());

    var alerts = 0;
    void onAlert({required double value, required double threshold}) {
      expect(value, 5);
      expect(threshold, 20);
      alerts++;
    }

    // 两个并发同身份检查：判定 + 回调 + 落盘必须整体串行，否则两边都读到
    // 空标记、各自回调（重复通知）。
    final first = service.checkAndAlert(onAlert: onAlert);
    final second = service.checkAndAlert(onAlert: onAlert);
    await Future.wait([first, second]);

    expect(alerts, 1);
    expect(prefs.getString('dorm_alert_last_notified_date'), today());

    // 当日再次检查不重复通知。
    await service.checkAndAlert(onAlert: onAlert);
    expect(alerts, 1);
  });

  testWidgets('A 登出后残留的清除不得删除 B 已保存的配置', (tester) async {
    final service = DormElectricityService.instance;
    final prefs = await SharedPreferences.getInstance();
    loginAs('A');
    await service.saveRoomConfig(_configA);
    loginAs('B');
    await service.saveRoomConfig(_configB);
    expect(prefs.getString(DormElectricityService.roomOwnerKey), 'B');

    // 登出（owner 捕获为 null）后的迟到清除：B 的最新保存已在磁盘上，
    // 绝不能因为「清除自己没带 owner」就把它当作无主遗留数据删掉。
    UnifiedAuthService.instance.debugSetSession(active: false);
    await service.clearRoomConfig();

    expect(prefs.getString(DormElectricityService.roomOwnerKey), 'B');
    expect(prefs.getString('dorm_epay_room_id'), '22018');
    loginAs('B');
    final restored = await service.loadRoomConfig();
    expect(restored, isNotNull);
    expect(restored!.roomId, '22018');
  });

  testWidgets('登出状态仍可清除真正无主（无 owner 标记）的遗留配置', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('dorm_epay_area_id', '3');
    await prefs.setString('dorm_epay_building_id', '114');
    await prefs.setString('dorm_epay_floor_id', 'F00000');
    await prefs.setString('dorm_epay_room_id', '10720');

    await DormElectricityService.instance.clearRoomConfig();

    expect(prefs.containsKey('dorm_epay_area_id'), isFalse);
    expect(prefs.containsKey('dorm_epay_room_id'), isFalse);
    expect(prefs.containsKey(DormElectricityService.roomOwnerKey), isFalse);
  });

  testWidgets('runAsync 写入之后的 fake zone 排队动作不被外部 zone 的 microtask 卡住', (
    tester,
  ) async {
    final service = DormElectricityService.instance;
    loginAs('A');
    // A：runAsync（真实 zone）写入完成——旧实现把队列尾留在这个外部 zone，
    // B 再 await 它时，迟到监听的 microtask 被调度回外部 zone，FakeAsync
    // 泵不到 → 死锁。
    await tester.runAsync(() => service.saveRoomConfig(_configA));

    // B：fake zone 的排队动作必须真的执行（旧实现会卡在这里）。
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('dorm_cached_electricity', 42.5);
    await prefs.setInt(
      'dorm_cached_electricity_updated_at',
      DateTime.now().millisecondsSinceEpoch,
    );
    await service.restoreCache(force: true);

    expect(service.cachedElectricity, 42.5);
    expect(service.lastUpdated, isNotNull);
  });

  testWidgets('混合 zone：runAsync 忙碌期内入队的 fake 动作随本轮 real zone 执行', (
    tester,
  ) async {
    final service = DormElectricityService.instance;
    loginAs('A');
    await service.saveRoomConfig(_configA); // 预热 prefs / 队列（fake zone）

    final fakeZone = Zone.current;
    final ranInFakeZone = <String, bool>{};
    service.debugPrivateWriteHook = (operation, key, write) async {
      ranInFakeZone['$operation:$key'] = identical(Zone.current, fakeZone);
      await write();
    };

    final prefs = await SharedPreferences.getInstance();

    await tester.runAsync(() async {
      // A：real（runAsync）zone 的写入，开启本轮忙碌期（drain 在 real zone）。
      final a = service.setAlertEnabled(true);
      // B：fake zone 入队的动作——同 hydrate / notifyListeners 里的
      // `unawaited(restoreCache())`：调用方不等待它自己的 Future（该 Future
      // 需要 fake zone 被泵到才能完成，是 FakeAsync 的固有边界，见类文档）。
      fakeZone.run(() {
        unawaited(service.setAlertThreshold(5.5));
      });
      // C：real zone 的写入排在 B 之后。旧实现里 C 要等 B，而 B 在 fake zone
      // 执行、写入挂在无法 flush 的 fake microtask 上（测试体正阻塞在
      // runAsync）→ 三者互等死锁。
      final c = service.setAlertThreshold(9);

      await Future.wait([a, c]);
    });

    // 整轮忙碌期由 real zone 的 drain 驱动：fake 入队的 B 也在 real zone 执行，
    // 不需要 fake zone 的 microtask；real zone 的 C 能越过 B 正常完成。
    expect(ranInFakeZone['setAlertEnabled:dorm_alert_enabled'], isFalse);
    expect(ranInFakeZone['setAlertThreshold:dorm_alert_threshold'], isFalse);
    // FIFO 保持：C（9）在 B（5.5）之后落盘。
    expect(prefs.getBool('dorm_alert_enabled'), isTrue);
    expect(prefs.getDouble('dorm_alert_threshold'), 9);
  });
}
