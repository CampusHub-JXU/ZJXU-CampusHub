import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/update/apk_update_controller.dart';
import 'package:jxu_campus_hub/core/update/update_checker.dart';
import 'package:jxu_campus_hub/core/update/update_model.dart';
import 'package:jxu_campus_hub/core/update/update_service.dart';
import 'package:jxu_campus_hub/features/settings/settings_page.dart';

import '../../helpers/fake_apk_update_transport.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_setup.dart';

/// 设置页「检查更新」入口与新的应用内更新弹窗的衔接：
/// 有受管下载在途时直接重开弹窗（查询原生状态），不发多余的网络检查。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(ApkUpdateProtocol.channelName);
  Map<String, Object?>? nativeState;

  setUp(() async {
    await resetTestEnvironment();
    ApkUpdateController.instance.debugReset();
    nativeState = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case ApkUpdateProtocol.methodIsSupported:
              return true;
            case ApkUpdateProtocol.methodQueryActiveUpdate:
              return nativeState;
            case ApkUpdateProtocol.methodStartDownload:
              return <String, Object?>{
                'phase': 'downloading',
                'bytesDownloaded': 1024 * 1024,
                'totalBytes': 2 * 1024 * 1024,
                'version': '0.3.0',
                'releaseTag': 'v0.3.0',
                'requestKey': 'k',
              };
            case ApkUpdateProtocol.methodCancelActiveUpdate:
              return <String, Object?>{'phase': 'canceled', 'requestKey': 'k'};
            case ApkUpdateProtocol.methodRequestInstall:
            case ApkUpdateProtocol.methodOpenInstallPermissionSettings:
              return true;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    ApkUpdateController.instance.debugReset();
  });

  testWidgets('有受管下载在途时直接重开弹窗并显示原生进度，不发版本检查请求', (tester) async {
    var networkCalled = false;
    UpdateService.instance.debugReleaseProvider = () async {
      networkCalled = true;
      return managedTestRelease();
    };
    UpdateChecker.instance.availableRelease.value = managedTestRelease();
    nativeState = <String, Object?>{
      'phase': 'downloading',
      'version': '0.3.0',
      'releaseTag': 'v0.3.0',
      'bytesDownloaded': 1024 * 1024,
      'totalBytes': 2 * 1024 * 1024,
      'requestKey': 'k',
    };
    ApkUpdateController.instance.state.value = const ApkUpdateState(
      phase: ApkUpdatePhase.downloading,
      bytesDownloaded: 1024 * 1024,
      totalBytes: 2 * 1024 * 1024,
      requestKey: 'k',
    );

    await pumpPage(tester, const SettingsPage());
    await tester.scrollUntilVisible(find.text('检查更新'), 300);
    // 只露出半行时 tap 会落在屏幕外：再把整行滚进视口。
    await tester.ensureVisible(find.text('检查更新'));
    await tester.pump();
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(networkCalled, isFalse, reason: '有在途下载时不应重新发起版本检查');
    expect(find.text('发现新版本 v0.3.0'), findsOneWidget);
    expect(find.text('正在下载安装包…'), findsOneWidget);
    expect(find.text('1.0 MB / 2.0 MB'), findsOneWidget);

    // 销毁弹窗以取消轮询定时器。
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('冷启动未缓存 Release 且离线时直接恢复原生已有更新', (tester) async {
    var networkCalled = false;
    UpdateService.instance.debugReleaseProvider = () async {
      networkCalled = true;
      throw StateError('offline');
    };
    nativeState = <String, Object?>{
      'phase': 'readyToInstall',
      'version': '0.2.9',
      'releaseTag': 'v0.2.9',
      'requestKey': 'old',
    };
    expect(ApkUpdateController.instance.state.value.phase, ApkUpdatePhase.idle);
    expect(UpdateChecker.instance.availableRelease.value, isNull);

    await pumpPage(tester, const SettingsPage());
    await tester.scrollUntilVisible(find.text('检查更新'), 300);
    // 只露出半行时 tap 会落在屏幕外：再把整行滚进视口。
    await tester.ensureVisible(find.text('检查更新'));
    await tester.pump();
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(networkCalled, isFalse);
    expect(find.text('已有更新 v0.2.9'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '安装更新'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('无在途下载时仍走版本检查，返回最新则提示已是最新', (tester) async {
    var networkCalled = false;
    UpdateService.instance.debugReleaseProvider = () async {
      networkCalled = true;
      return AppRelease(
        version: '0.0.1',
        changelog: '',
        downloadUrl: '',
        releaseUrl: 'https://example.com/release',
        publishedAt: DateTime(2026, 1, 1),
      );
    };

    await pumpPage(tester, const SettingsPage());
    await tester.scrollUntilVisible(find.text('检查更新'), 300);
    // 只露出半行时 tap 会落在屏幕外：再把整行滚进视口。
    await tester.ensureVisible(find.text('检查更新'));
    await tester.pump();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();

    expect(networkCalled, isTrue);
    expect(find.text('当前已是最新版本'), findsOneWidget);
  });
}
