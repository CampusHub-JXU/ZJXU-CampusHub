import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/update/apk_update_controller.dart';
import 'package:jxu_campus_hub/core/update/update_model.dart';
import 'package:jxu_campus_hub/shared/widgets/update_dialog.dart';

import '../../helpers/fake_apk_update_transport.dart';

void main() {
  testWidgets('renders release metadata and fallback changelog text', (
    tester,
  ) async {
    final release = AppRelease(
      version: '0.2.3',
      changelog: '',
      downloadUrl: '',
      releaseUrl: 'https://example.com/release',
      publishedAt: DateTime(2026, 4, 11, 9, 30),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showUpdateDialog(context, release),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本 v0.2.3'), findsOneWidget);
    expect(find.text('发布时间：2026-04-11 09:30'), findsOneWidget);
    expect(find.text('暂无更新说明'), findsOneWidget);
    expect(find.text('查看版本'), findsOneWidget);
  });

  group('受管更新流程', () {
    late FakeApkUpdateTransport transport;
    late ApkUpdateController controller;

    setUp(() {
      transport = FakeApkUpdateTransport();
      controller = fakeApkUpdateController(transport);
    });

    Future<void> open(WidgetTester tester, AppRelease release) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showUpdateDialog(context, release, controller: controller),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump(); // 打开弹窗路由
      await tester.pump(); // 能力探测
      await tester.pump(); // 初始原生状态查询
    }

    // 活动状态会启动 ~1s 轮询与不定进度动画：收尾时销毁弹窗以取消定时器，
    // 避免遗留 pending timer。
    Future<void> disposeDialog(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }

    testWidgets('受支持且资产可信时提供「更新」入口', (tester) async {
      await open(tester, managedTestRelease());

      expect(find.widgetWithText(FilledButton, '更新'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '稍后再说'), findsOneWidget);
      expect(find.text('下载 APK'), findsNothing);
      expect(find.text('查看版本'), findsNothing);
      await disposeDialog(tester);
    });

    testWidgets('点「更新」调用一次原生下载并入队', (tester) async {
      transport.startResult = const ApkUpdateState(
        phase: ApkUpdatePhase.enqueued,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await open(tester, managedTestRelease());

      await tester.tap(find.widgetWithText(FilledButton, '更新'));
      await tester.pump();
      await tester.pump();

      expect(transport.startCalls, 1);
      expect(transport.lastRequest?.assetUrl, kTestCanonicalAssetUrl);
      expect(find.text('正在加入下载队列…'), findsOneWidget);
      await disposeDialog(tester);
    });

    testWidgets('下载中显示真实进度（已知总量）', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.downloading,
        bytesDownloaded: 1024 * 1024,
        totalBytes: 2 * 1024 * 1024,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await open(tester, managedTestRelease());

      expect(find.text('正在下载安装包…'), findsOneWidget);
      expect(find.text('1.0 MB / 2.0 MB'), findsOneWidget);
      final indicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(indicator.value, 0.5);
      await disposeDialog(tester);
    });

    testWidgets('总量未知时不合成百分比，只显示已下载字节', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.downloading,
        bytesDownloaded: 512 * 1024,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await open(tester, managedTestRelease());

      expect(find.text('正在下载安装包…'), findsOneWidget);
      expect(find.text('已下载 512 KB'), findsOneWidget);
      expect(find.textContaining(' / '), findsNothing);
      final indicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(indicator.value, isNull);
      await disposeDialog(tester);
    });

    testWidgets('就绪后手动「安装更新」，成功只表示已发起', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.readyToInstall,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await open(tester, managedTestRelease());

      expect(find.text('下载完成，可安装更新'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '安装更新'));
      await tester.pump();
      await tester.pump();

      expect(transport.installCalls, 1);
      expect(transport.lastExpectedReleaseTag, 'v0.3.0');
      expect(find.text('已打开系统安装确认'), findsOneWidget);
      expect(find.textContaining('已安装'), findsNothing);
      expect(find.textContaining('更新成功'), findsNothing);
      await disposeDialog(tester);
    });

    testWidgets('旧受管版本与新 Release 不同则禁止安装并可重新下载', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.readyToInstall,
        version: '0.2.9',
        releaseTag: 'v0.2.9',
        requestKey: 'old',
      );
      await open(tester, managedTestRelease(changelog: '新版本专属日志'));

      expect(find.text('已有更新 v0.2.9'), findsOneWidget);
      expect(find.text('新版本专属日志'), findsNothing);
      expect(find.widgetWithText(FilledButton, '安装更新'), findsNothing);
      expect(transport.installCalls, 0);
      await tester.tap(find.widgetWithText(FilledButton, '重新下载 v0.3.0'));
      await tester.pump();
      expect(transport.startCalls, 1);
      expect(transport.lastRequest?.version, '0.3.0');
      await disposeDialog(tester);
    });

    testWidgets('同版本但 Release tag 不同也不提供安装入口', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.readyToInstall,
        version: '0.3.0',
        releaseTag: 'v0.3.0-old',
        requestKey: 'old',
      );
      await open(tester, managedTestRelease());

      expect(find.widgetWithText(FilledButton, '安装更新'), findsNothing);
      expect(find.widgetWithText(FilledButton, '重新下载 v0.3.0'), findsOneWidget);
      await disposeDialog(tester);
    });

    testWidgets('未获取 Release 时仍可恢复已有安装包并安装', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.readyToInstall,
        version: '0.2.9',
        releaseTag: 'v0.2.9',
        requestKey: 'old',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showManagedUpdateDialog(context, controller: controller),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.text('已有更新 v0.2.9'), findsOneWidget);
      expect(find.text('发布时间：'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, '安装更新'));
      await tester.pump();
      expect(transport.installCalls, 1);
      expect(transport.lastExpectedReleaseTag, 'v0.2.9');
      expect(transport.startCalls, 0);
      await disposeDialog(tester);
    });

    testWidgets('需要安装权限时给出明确原因与授权入口', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.permissionRequired,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await open(tester, managedTestRelease());

      expect(find.text('需要允许安装应用'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '允许安装应用'));
      await tester.pump();
      await tester.pump();

      expect(transport.permissionSettingsCalls, 1);
      await disposeDialog(tester);
    });

    testWidgets('installerOpened 只说明已打开系统确认，不谎称安装成功', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.installerOpened,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await open(tester, managedTestRelease());

      expect(find.text('已打开系统安装确认'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '安装更新'), findsNothing);
      expect(find.textContaining('已安装'), findsNothing);
      await disposeDialog(tester);
    });

    testWidgets('失败时给出接地气的中文原因与重试', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.failed,
        reason: ApkUpdateFailureReason.network,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await open(tester, managedTestRelease());

      expect(find.text('网络连接失败，请检查网络后重试'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);
      await disposeDialog(tester);
    });

    for (final previous in [
      ApkUpdatePhase.permissionRequired,
      ApkUpdatePhase.installerOpened,
    ]) {
      testWidgets('从 ${previous.name} 返回前台可安装且不重新下载', (tester) async {
        transport.active = ApkUpdateState(
          phase: previous,
          version: '0.3.0',
          releaseTag: 'v0.3.0',
          requestKey: 'k',
        );
        await open(tester, managedTestRelease());
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        // Native reconciles real permission / installer return on resume.
        transport.active = const ApkUpdateState(
          phase: ApkUpdatePhase.readyToInstall,
          version: '0.3.0',
          releaseTag: 'v0.3.0',
          requestKey: 'k',
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await tester.pump();
        expect(find.widgetWithText(FilledButton, '安装更新'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, '安装更新'));
        await tester.pump();
        expect(transport.installCalls, 1);
        expect(transport.startCalls, 0);
        await disposeDialog(tester);
      });
    }

    testWidgets('取消后显示已取消并可手动重试', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.canceled,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await open(tester, managedTestRelease());

      expect(find.text('已取消下载'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '重试'));
      await tester.pump();
      await tester.pump();
      expect(transport.startCalls, 1);
      await disposeDialog(tester);
    });

    testWidgets('关闭弹窗只关闭，不取消原生下载', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.downloading,
        bytesDownloaded: 1024,
        totalBytes: 2048,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await open(tester, managedTestRelease());

      await tester.tap(find.widgetWithText(TextButton, '关闭'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('正在下载安装包…'), findsNothing);
      expect(transport.cancelCalls, 0);
      await disposeDialog(tester);
    });

    testWidgets('「取消下载」只调用一次原生取消', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.downloading,
        bytesDownloaded: 1024,
        totalBytes: 2048,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await open(tester, managedTestRelease());

      await tester.tap(find.widgetWithText(TextButton, '取消下载'));
      await tester.pump();
      await tester.pump();

      expect(transport.cancelCalls, 1);
      expect(find.text('已取消下载'), findsOneWidget);
      await disposeDialog(tester);
    });

    testWidgets('切到后台停止轮询，回前台再查询一次', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.downloading,
        bytesDownloaded: 1024,
        totalBytes: 2048,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await open(tester, managedTestRelease());
      final afterOpen = transport.queryCalls;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 3));
      expect(transport.queryCalls, afterOpen, reason: '非前台不应继续轮询');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(
        transport.queryCalls,
        greaterThan(afterOpen),
        reason: '回前台应查询一次原生状态',
      );
      await disposeDialog(tester);
    });

    testWidgets('不支持应用内更新时降级为外部浏览器链接', (tester) async {
      transport = FakeApkUpdateTransport(supported: false);
      controller = fakeApkUpdateController(transport);
      await open(tester, managedTestRelease());

      expect(find.textContaining('当前平台不支持应用内更新'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '下载 APK'), findsOneWidget);
      await disposeDialog(tester);
    });

    testWidgets('版本未提供可信安装包时降级并说明原因', (tester) async {
      await open(tester, managedTestRelease(canonicalAssetUrl: null));

      expect(find.textContaining('该版本未提供可校验的安装包'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '下载 APK'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '更新'), findsNothing);
      await disposeDialog(tester);
    });

    testWidgets('非可信仓库的资产 URL 一律按不可用处理', (tester) async {
      await open(
        tester,
        managedTestRelease(
          canonicalAssetUrl: 'https://evil.example.com/app.apk',
        ),
      );

      expect(find.textContaining('该版本未提供可校验的安装包'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '更新'), findsNothing);
      await disposeDialog(tester);
    });
  });
}
