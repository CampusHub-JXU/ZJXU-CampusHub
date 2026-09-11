import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/system_surface/campus_data_change_bus.dart';
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
    final snapshot = pushes.single;
    expect(snapshot.keys, contains('generatedAt'));
    expect(snapshot.keys, isNot(contains('cookie')));
    expect(snapshot.keys, isNot(contains('token')));
  });
}
