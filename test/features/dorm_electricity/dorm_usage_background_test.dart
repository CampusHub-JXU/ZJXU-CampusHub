import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jxu_campus_hub/core/auth/background_session_gate.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_usage_background.dart';

import '../../helpers/credential_store_test_ext.dart';
import '../../helpers/test_setup.dart';

void main() {
  final tempDirs = <Directory>[];

  setUp(() async {
    await resetTestEnvironment();
  });

  tearDown(() async {
    DormUsageBackground.instance.debugReset();
    for (final dir in tempDirs) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    tempDirs.clear();
  });

  test('background schedule respects Android periodic minimum', () {
    expect(DormUsageBackground.interval, const Duration(minutes: 15));
    expect(DormUsageBackground.minAttemptInterval, const Duration(minutes: 10));
  });
  test('parse only matching room balance', () {
    const body =
        '{"code":200,"data":{"balance_list":[{"id":"other","balance":"123"},{"id":"mine","balance":"409.38"}]}}';
    expect(DormUsageBackground.parseBalance(body, 'mine'), 409.38);
    expect(DormUsageBackground.parseBalance(body, 'missing'), isNull);
  });
  test('reject malformed and unsupported responses', () {
    expect(
      DormUsageBackground.parseBalance('{"code":"M004001"}', 'mine'),
      isNull,
    );
    expect(DormUsageBackground.parseBalance('not JSON', 'mine'), isNull);
    expect(
      DormUsageBackground.parseBalance(
        '{"code":200,"data":{"balance_list":[{"id":"mine","balance":"NaN"}]}}',
        'mine',
      ),
      isNull,
    );
  });
  test('reject negative balances as invalid for usage analysis', () {
    expect(
      DormUsageBackground.parseBalance(
        '{"code":200,"data":{"balance_list":[{"id":"mine","balance":"-1"}]}}',
        'mine',
      ),
      isNull,
    );
  });

  test('background records the direct RPC result, not the old balance cache', () async {
    final dir = await Directory.systemTemp.createTemp('dorm-usage-r3-');
    tempDirs.add(dir);
    final background = DormUsageBackground.instance
      ..debugAvailableOverride = true
      ..debugDirectoryProvider = () async => dir;
    final auth = UnifiedAuthService.instance;
    auth.debugSetSession(active: true, account: 'account-A');
    await CredentialStore.instance.saveUnifiedAuthSession('account-A');

    const area = '3';
    const building = '114';
    const floor = 'F00000';
    const room = '10720';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(DormElectricityService.roomOwnerKey, 'account-A');
    await prefs.setString(DormElectricityService.keyAreaId, area);
    await prefs.setString(DormElectricityService.keyBuildingId, building);
    await prefs.setString(DormElectricityService.keyFloorId, floor);
    await prefs.setString(DormElectricityService.keyRoomId, room);
    await prefs.setDouble(DormElectricityService.keyElectricity, 17.25);
    final epoch = await CredentialStore.instance.readSessionEnvelope(
      CredentialSessionDomain.unified,
    );
    final scope = jsonEncode([
      'account-A',
      epoch.epoch,
      area,
      building,
      floor,
      room,
    ]);
    await File(
      '${dir.path}${Platform.pathSeparator}dorm_usage_background_v3.json',
    ).writeAsString(
      jsonEncode({
        'scope': scope,
        'enabled': true,
        'token': 71,
        'samples': <Object?>[],
      }),
    );

    var fetchCount = 0;
    Map<String, String>? requested;
    var released = 0;
    background.debugTryClaim = () async => BackgroundLoginClaim(
      token: 'test-claim',
      until: DateTime.now().add(const Duration(minutes: 2)),
    );
    background.debugShouldYield = (_) async => false;
    background.debugRelease = (_) async {
      released++;
    };
    background.debugFetchBalance = (arguments) async {
      fetchCount++;
      requested = arguments;
      return '{"code":200,"data":{"balance_list":[{"id":"$room","balance":"409.38"}]}}';
    };

    expect(await background.run(), isTrue);

    expect(fetchCount, 1);
    expect(requested?['L4_room_id'], room);
    expect(released, 1);
    await prefs.reload();
    expect(prefs.getDouble(DormElectricityService.keyElectricity), 17.25);
    final samples = await background.samplesFor(
      owner: 'account-A',
      area: area,
      building: building,
      floor: floor,
      room: room,
    );
    expect(samples, hasLength(1));
    expect(samples.single.kwh, 409.38);
    expect(
      await background.samplesFor(
        owner: 'account-B',
        area: area,
        building: building,
        floor: floor,
        room: room,
      ),
      isEmpty,
    );
    expect(
      await background.samplesFor(
        owner: 'account-A',
        area: area,
        building: building,
        floor: floor,
        room: 'other-room',
      ),
      isEmpty,
    );
  });

  test('worker cancels a leftover periodic task when compiled out', () async {
    final dir = await Directory.systemTemp.createTemp('dorm-usage-off-');
    tempDirs.add(dir);
    final background = DormUsageBackground.instance
      ..debugAvailableOverride = false
      ..debugDirectoryProvider = () async => dir;
    var canceled = 0;
    background.debugCancelTask = () async {
      canceled++;
    };

    expect(await background.run(), isTrue);
    expect(canceled, 1);
  });

  test(
    'foreground and background auto requests share ten-minute spacing',
    () async {
      final dir = await Directory.systemTemp.createTemp('dorm-usage-throttle-');
      tempDirs.add(dir);
      var now = DateTime(2026, 11, 26, 10);
      final background = DormUsageBackground.instance;
      background.debugDirectoryProvider = () async => dir;
      background.debugNow = () => now;
      final auth = UnifiedAuthService.instance;
      auth.debugSetSession(active: true, account: 'account-A');
      await CredentialStore.instance.saveUnifiedAuthSession('account-A');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(DormElectricityService.roomOwnerKey, 'account-A');
      await prefs.setString(DormElectricityService.keyAreaId, '3');
      await prefs.setString(DormElectricityService.keyBuildingId, '114');
      await prefs.setString(DormElectricityService.keyFloorId, 'F00000');
      await prefs.setString(DormElectricityService.keyRoomId, '10720');
      background.debugCancelTask = () async {};

      expect(await background.tryAcquireAutoSamplingSlot(), isTrue);
      expect(await background.tryAcquireAutoSamplingSlot(), isFalse);
      now = now.add(const Duration(minutes: 10));
      expect(await background.tryAcquireAutoSamplingSlot(), isTrue);
    },
  );

  test('logout clears the opt-in samples and cancels periodic work', () async {
    final dir = await Directory.systemTemp.createTemp('dorm-usage-logout-');
    tempDirs.add(dir);
    final background = DormUsageBackground.instance
      ..debugAvailableOverride = true
      ..debugDirectoryProvider = () async => dir;
    final auth = UnifiedAuthService.instance;
    auth.debugSetSession(active: true, account: 'account-A');
    await CredentialStore.instance.saveUnifiedAuthSession('account-A');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(DormElectricityService.roomOwnerKey, 'account-A');
    await prefs.setString(DormElectricityService.keyAreaId, '3');
    await prefs.setString(DormElectricityService.keyBuildingId, '114');
    await prefs.setString(DormElectricityService.keyFloorId, 'F00000');
    await prefs.setString(DormElectricityService.keyRoomId, '10720');

    var registered = 0;
    var canceled = 0;
    background
      ..debugRegisterTask = () async {
        registered++;
      }
      ..debugCancelTask = () async {
        canceled++;
      };
    expect(await background.setEnabled(true), isTrue);
    expect(registered, 1);

    await auth.markLoggedOut();
    for (var i = 0; i < 100 && canceled == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(canceled, 1);
    final raw = await File(
      '${dir.path}${Platform.pathSeparator}dorm_usage_background_v3.json',
    ).readAsString();
    expect(jsonDecode(raw), isEmpty);
  });
}
