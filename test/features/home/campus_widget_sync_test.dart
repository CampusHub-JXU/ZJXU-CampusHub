import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/system_surface/campus_data_change_bus.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/features/home/widget/campus_widget_sync.dart';

import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('edu.zjxu.jxucampushub/widget');
  final pushes = <Map<Object?, Object?>>[];

  setUp(() async {
    pushes.clear();
    await resetTestEnvironment();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'pushSnapshot') {
            pushes.add(call.arguments as Map<Object?, Object?>);
          }
          return null;
        });
    CampusWidgetSync.instance.start();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    CampusWidgetSync.instance.debugReset();
    CampusDataChangeBus.instance.debugReset();
  });

  test('校园数据变化会触发一次去凭据的桌面投影推送', () async {
    CampusDataChangeBus.instance.notifyChanged();
    await pumpEventQueue();

    expect(pushes, hasLength(1));
    final snapshot =
        pushes.single['snapshot'] as Map<Object?, Object?>? ?? const {};
    expect(snapshot.keys, contains('generatedAt'));
    expect(snapshot.keys, isNot(contains('cookie')));
    expect(snapshot.keys, isNot(contains('token')));
  });

  test('统一认证身份变化会重推桌面投影并清掉上一账号电费', () async {
    // A 的房间配置 / 余额缓存都带 A 的 owner 标记：无论 restoreCache 何时
    // 完成，投影都只会看到 A 自己的 3.2 度。
    SharedPreferences.setMockInitialValues({
      'dorm_epay_area_id': 'area',
      'dorm_epay_building_id': 'building',
      'dorm_epay_floor_id': 'floor',
      'dorm_epay_room_id': 'room',
      DormElectricityService.roomOwnerKey: 'casuserA',
      'dorm_cached_electricity': 3.2,
      'dorm_cached_electricity_updated_at':
          DateTime.now().millisecondsSinceEpoch,
    });
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'casuserA',
    );
    UnifiedAuthService.instance.notifyListeners();
    await pumpEventQueue();
    pushes.clear();

    // A 的电费内存缓存归属 A，投影可见（格式化保留两位小数）。
    DormElectricityService.instance.debugSetCachedElectricity(
      3.2,
      updatedAt: DateTime.now(),
    );
    await CampusWidgetSync.instance.syncNow();
    expect(pushes, hasLength(1));
    var snapshot = pushes.last['snapshot'] as Map<Object?, Object?>;
    expect(snapshot['dormElectricity'], '3.20');
    expect(snapshot['hasElectricityData'], isTrue);

    // 换号到 B：身份变化必须触发重推，且投影只读 owner 归属校验后的缓存，
    // 不得残留上一账号的低电量。
    pushes.clear();
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'casuserB',
    );
    UnifiedAuthService.instance.notifyListeners();
    await pumpEventQueue();

    expect(pushes, isNotEmpty);
    snapshot = pushes.last['snapshot'] as Map<Object?, Object?>;
    expect(snapshot['dormElectricity'], '--');
    expect(snapshot['hasElectricityData'], isFalse);
  });
}
