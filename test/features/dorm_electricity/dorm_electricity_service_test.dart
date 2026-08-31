import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';

import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

  test('restores cached electricity and timestamp from preferences', () async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime(2026, 4, 8, 10).millisecondsSinceEpoch;
    await prefs.setDouble('dorm_cached_electricity', 123.45);
    await prefs.setInt('dorm_cached_electricity_updated_at', now);

    await DormElectricityService.instance.restoreCache(force: true);

    expect(DormElectricityService.instance.cachedElectricity, 123.45);
    expect(
      DormElectricityService.instance.lastUpdated,
      DateTime.fromMillisecondsSinceEpoch(now),
    );
  });

  test('saves and restores the epay100 four-level room config', () async {
    const config = DormRoomConfig(
      areaId: '3',
      buildingId: '114',
      floorId: 'F00000',
      roomId: '10720',
    );

    await DormElectricityService.instance.saveRoomConfig(config);
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
  });

  test('saving a new room config clears the previous balance cache', () async {
    final prefs = await SharedPreferences.getInstance();
    final oldUpdatedAt = DateTime.now()
        .subtract(const Duration(minutes: 5))
        .millisecondsSinceEpoch;
    await prefs.setDouble('dorm_cached_electricity', 88.8);
    await prefs.setInt('dorm_cached_electricity_updated_at', oldUpdatedAt);
    await DormElectricityService.instance.restoreCache(force: true);

    await DormElectricityService.instance.saveRoomConfig(
      const DormRoomConfig(
        areaId: '5',
        buildingId: '220',
        floorId: 'F2',
        roomId: '22018',
      ),
    );

    expect(prefs.containsKey('dorm_cached_electricity'), isFalse);
    expect(prefs.containsKey('dorm_cached_electricity_updated_at'), isFalse);
    expect(DormElectricityService.instance.cachedElectricity, isNull);
    expect(DormElectricityService.instance.lastUpdated, isNull);
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
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    await prefs.setDouble('dorm_cached_electricity', 88.8);
    await prefs.setInt('dorm_cached_electricity_updated_at', now);

    await DormElectricityService.instance.restoreCache(force: true);
    final value = await DormElectricityService.instance.fetchElectricity();

    expect(value, 88.8);
    expect(DormElectricityService.instance.lastError, isNull);
  });
}
