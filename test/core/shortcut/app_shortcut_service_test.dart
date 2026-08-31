import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/shortcut/app_shortcut_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shortcutChannel = MethodChannel('edu.zjxu.jxucampushub/shortcut');

  // 导航就绪信号改为注入式：由测试构造并模拟 bootstrap 派生状态，
  // 服务本身不再读取 AppBootstrapController.phase。
  final navigationReady = ValueNotifier<bool>(false);

  setUp(() {
    navigationReady.value = true;
    AppShortcutService.instance.debugReset();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shortcutChannel, null);
    AppShortcutService.instance.debugReset();
  });

  test('requestShuatiShortcut invokes platform shortcut request', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shortcutChannel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'consumeInitialShortcutAction' => null,
            'requestShuatiShortcut' => 'requested',
            _ => null,
          };
        });

    final created = await AppShortcutService.instance.requestShuatiShortcut();
    final result = await AppShortcutService.instance
        .requestShuatiShortcutResult();

    expect(created, isTrue);
    expect(result, AppShortcutRequestResult.requested);
    expect(
      calls.map((call) => call.method),
      containsAllInOrder([
        'consumeInitialShortcutAction',
        'requestShuatiShortcut',
      ]),
    );
  });

  test('maps launcher rejection to permission-oriented message', () {
    final result = AppShortcutRequestResult.fromPlatformValue('rejected');

    expect(result, AppShortcutRequestResult.rejected);
    expect(result.message, contains('去设置'));
    expect(result.canOpenPermissionSettings, isTrue);
  });

  test(
    'openShortcutPermissionSettings invokes platform settings entry',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(shortcutChannel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'consumeInitialShortcutAction' => null,
              'openShortcutPermissionSettings' => true,
              _ => null,
            };
          });

      final opened = await AppShortcutService.instance
          .openShortcutPermissionSettings();

      expect(opened, isTrue);
      expect(
        calls.map((call) => call.method),
        containsAllInOrder([
          'consumeInitialShortcutAction',
          'openShortcutPermissionSettings',
        ]),
      );
    },
  );

  testWidgets('shuati shortcut action navigates to practice route', (
    tester,
  ) async {
    final routes = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shortcutChannel, (call) async {
          if (call.method == 'consumeInitialShortcutAction') {
            return AppShortcutService.shuatiAction;
          }
          return null;
        });

    await AppShortcutService.instance.initialize(
      navigationReady: navigationReady,
      navigateToNamedRoute: (routeName) async {
        routes.add(routeName);
      },
    );
    await tester.pump();

    expect(routes, ['shuati-practice']);
  });

  testWidgets('pending shortcut action flushes once navigation becomes ready', (
    tester,
  ) async {
    final routes = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shortcutChannel, (call) async {
          if (call.method == 'consumeInitialShortcutAction') {
            return AppShortcutService.shuatiAction;
          }
          return null;
        });

    navigationReady.value = false;
    await AppShortcutService.instance.initialize(
      navigationReady: navigationReady,
      navigateToNamedRoute: (routeName) async {
        routes.add(routeName);
      },
    );
    await tester.pump();
    expect(routes, isEmpty);

    // 就绪信号翻转后，挂起动作应自动补发。
    navigationReady.value = true;
    await tester.pump();

    expect(routes, ['shuati-practice']);
  });
}
