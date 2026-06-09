import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/app/app_bootstrap_controller.dart';
import 'package:jxu_campus_hub/core/shortcut/app_shortcut_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shortcutChannel = MethodChannel('edu.zjxu.jxucampushub/shortcut');

  setUp(() {
    AppBootstrapController.instance.debugReset(
      phaseValue: AppBootstrapPhase.localStateReady,
    );
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
    expect(result.message, contains('创建桌面快捷方式权限'));
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
      navigateToNamedRoute: (routeName) async {
        routes.add(routeName);
      },
    );
    await tester.pump();

    expect(routes, ['shuati-practice']);
  });
}
