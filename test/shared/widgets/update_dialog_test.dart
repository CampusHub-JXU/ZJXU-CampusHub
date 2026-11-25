import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/update/apk_download_route.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
    late bool foreground;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      transport = FakeApkUpdateTransport();
      foreground = true;
      // 弹窗本身不再持有轮询：由控制器统一做前台轮询与停滞观察。本组打开
      // 控制器轮询以验证端到端行为（前台状态经注入切换，与真实生命周期等价）。
      controller = fakeApkUpdateController(
        transport,
        enablePolling: true,
        foregroundProvider: () => foreground,
      );
      // 本组用例聚焦弹窗的状态投影，需要弹窗在发起下载后保持打开；
      // 自动关闭转后台的行为在独立分组里验证。
      kUpdateDialogAutoCloseAfterStart = false;
    });

    tearDown(() {
      kUpdateDialogAutoCloseAfterStart = true;
      foreground = true;
      // 控制器持有跨弹窗的轮询定时器：用例收尾必须复位，避免 pending timer
      // 泄漏到下一个用例。
      controller.debugReset();
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

    // 活动状态会启动控制器的 ~1s 前台轮询与不定进度动画：收尾时销毁弹窗并复位
    // 控制器（轮询归控制器持有，弹窗销毁不再停表），避免遗留 pending timer。
    // postTest 的不变量校验先于本组 tearDown 执行，因此必须在用例体内复位。
    Future<void> disposeDialog(WidgetTester tester) async {
      controller.debugReset();
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
      // 默认「自动」且该版本无 R2 镜像标记：只有 EdgeOne 线路，URL 为镜像形态。
      expect(transport.lastRequest?.sources, hasLength(1));
      expect(
        transport.lastRequest?.sources.single.url,
        '${ApkUpdateProtocol.trustedMirrorPrefix}$kTestCanonicalAssetUrl',
      );
      expect(
        transport.lastRequest?.sources.single.source,
        ApkDownloadSource.edgeone,
      );
      expect(transport.lastRequest?.mode, ApkDownloadMode.auto);
      expect(find.text('正在加入下载队列…'), findsOneWidget);
      await disposeDialog(tester);
    });

    testWidgets('有 R2 镜像时默认自动先入队 R2，弹窗本身不提供选线', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      transport.startResult = const ApkUpdateState(
        phase: ApkUpdatePhase.enqueued,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await open(tester, managedTestRelease(r2MirrorAvailable: true));

      expect(find.byType(SegmentedButton<ApkDownloadRoute>), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, '更新'));
      await tester.pump();
      await tester.pump();

      expect(
        [for (final c in transport.lastRequest!.sources) c.source],
        [ApkDownloadSource.r2, ApkDownloadSource.edgeone],
      );
      expect(
        transport.lastRequest?.sources.first.url,
        startsWith('https://download.fhfanshu.xyz/'),
      );
      await disposeDialog(tester);
    });

    testWidgets('设置里选了 EdgeOne：即使有 R2 也只走 EdgeOne', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ApkDownloadRoutePreference.storageKey: 'edgeone',
      });
      transport.startResult = const ApkUpdateState(
        phase: ApkUpdatePhase.enqueued,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await open(tester, managedTestRelease(r2MirrorAvailable: true));

      await tester.tap(find.widgetWithText(FilledButton, '更新'));
      await tester.pump();
      await tester.pump();

      expect(
        [for (final c in transport.lastRequest!.sources) c.source],
        [ApkDownloadSource.edgeone],
      );
      expect(transport.lastRequest?.mode, ApkDownloadMode.manual);
      await disposeDialog(tester);
    });

    testWidgets('设置里选了 R2 但该版本无 R2 镜像：改用 EdgeOne 并提示', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ApkDownloadRoutePreference.storageKey: 'r2',
      });
      // 原生按 unavailablePreferred 把首选线路记入 fellBackFrom。
      transport.startResult = const ApkUpdateState(
        phase: ApkUpdatePhase.enqueued,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
        source: ApkDownloadSource.edgeone,
        mode: ApkDownloadMode.manual,
        fellBackFrom: ApkDownloadSource.r2,
      );
      await open(tester, managedTestRelease());
      await tester.tap(find.widgetWithText(FilledButton, '更新'));
      await tester.pump();
      await tester.pump();

      expect(
        [for (final c in transport.lastRequest!.sources) c.source],
        [ApkDownloadSource.edgeone],
      );
      expect(transport.lastRequest?.unavailablePreferred, ApkDownloadSource.r2);
      expect(find.textContaining('暂无 Cloudflare R2 线路'), findsOneWidget);
      expect(find.textContaining('已改用 EdgeOne'), findsOneWidget);
      await disposeDialog(tester);
    });

    testWidgets('别的版本遗留的失败记录不当作本版本的失败展示', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.failed,
        reason: ApkUpdateFailureReason.versionNotNewer,
        version: '0.2.9',
        releaseTag: 'v0.2.9',
        requestKey: 'old',
      );
      await open(tester, managedTestRelease());

      expect(find.text('该版本不新于当前版本'), findsNothing);
      expect(find.widgetWithText(FilledButton, '更新'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await disposeDialog(tester);
    });

    testWidgets('别的版本遗留的已取消记录同样按 idle 展示', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.canceled,
        version: '0.2.9',
        releaseTag: 'v0.2.9',
        requestKey: 'old',
      );
      await open(tester, managedTestRelease());

      expect(find.text('已取消下载'), findsNothing);
      expect(find.widgetWithText(FilledButton, '更新'), findsOneWidget);
      await disposeDialog(tester);
    });

    testWidgets('清理中（非换源）显示清理文案，按钮为取消下载 + 关闭', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.cleanupPending,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
        source: ApkDownloadSource.edgeone,
        attempt: 1,
      );
      await open(tester, managedTestRelease());

      expect(find.text('正在清理上一次下载…'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '取消下载'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '关闭'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '更新'), findsNothing);
      expect(find.widgetWithText(FilledButton, '重试'), findsNothing);
      await disposeDialog(tester);
    });

    testWidgets('换源中显示正在切换到下一条线路，并说明原因', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.cleanupPending,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
        source: ApkDownloadSource.r2,
        mode: ApkDownloadMode.auto,
        attempt: 1,
        triedSources: [ApkDownloadSource.r2],
        switching: true,
        switchReason: ApkFallbackReason.connectTimeout,
        fellBackFrom: ApkDownloadSource.r2,
      );
      await open(tester, managedTestRelease(r2MirrorAvailable: true));

      expect(find.text('正在切换到 EdgeOne…'), findsOneWidget);
      expect(find.text('Cloudflare R2 连接超时。'), findsOneWidget);
      expect(find.text('正在清理上一次下载…'), findsNothing);
      expect(find.widgetWithText(TextButton, '取消下载'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '关闭'), findsOneWidget);
      await disposeDialog(tester);
    });

    testWidgets('归属待确认显示确认文案，按钮为取消下载 + 关闭', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.reconcileRequired,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await open(tester, managedTestRelease());

      expect(find.text('正在确认上一次下载的状态…'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '取消下载'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '关闭'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '更新'), findsNothing);
      await disposeDialog(tester);
    });

    testWidgets('取消时退役未确认：弹窗留在清理中，不显示成已取消', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.downloading,
        bytesDownloaded: 1024,
        totalBytes: 2048,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await open(tester, managedTestRelease());
      // 原生 remove 未确认：取消返回 cleanupPending，retired=false。
      transport.cancelOverride = const ApkUpdateState(
        phase: ApkUpdatePhase.cleanupPending,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );

      await tester.tap(find.widgetWithText(TextButton, '取消下载'));
      await tester.pump();
      await tester.pump();

      expect(transport.cancelCalls, 1);
      expect(find.text('已取消下载'), findsNothing);
      expect(find.text('正在清理上一次下载…'), findsOneWidget);
      await disposeDialog(tester);
    });

    testWidgets('线路说明只取自原生状态：当前线路 / 已切换 / 全部失败 / 手动提示', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.downloading,
        bytesDownloaded: 1024,
        totalBytes: 2048,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
        source: ApkDownloadSource.r2,
      );
      await open(tester, managedTestRelease(r2MirrorAvailable: true));
      expect(find.text('下载线路：Cloudflare R2'), findsOneWidget);

      // 原生换源后：说明离开的线路、原因与当前线路。
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.downloading,
        bytesDownloaded: 0,
        totalBytes: 2048,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
        source: ApkDownloadSource.edgeone,
        attempt: 2,
        triedSources: [ApkDownloadSource.r2, ApkDownloadSource.edgeone],
        switchReason: ApkFallbackReason.stalled,
        fellBackFrom: ApkDownloadSource.r2,
      );
      await controller.refreshActiveUpdate();
      await tester.pump();
      expect(find.text('Cloudflare R2 长时间无数据，已切换到 EdgeOne。'), findsOneWidget);

      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.failed,
        reason: ApkUpdateFailureReason.network,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
        mode: ApkDownloadMode.auto,
        exhausted: true,
      );
      await controller.refreshActiveUpdate();
      await tester.pump();
      expect(find.text('所有线路均未成功下载，可稍后重试或改用浏览器下载。'), findsOneWidget);

      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.failed,
        reason: ApkUpdateFailureReason.network,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
        mode: ApkDownloadMode.manual,
      );
      await controller.refreshActiveUpdate();
      await tester.pump();
      expect(find.textContaining('更新下载线路'), findsOneWidget);
      await disposeDialog(tester);
    });

    testWidgets('同版本的失败记录仍如实展示并可重试', (tester) async {
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

    testWidgets('原生未发起安装器时如实提示，不让按钮看起来点了没反应', (tester) async {
      // v0.11.1 的真实故障：FileProvider 白名单与受管目录不匹配，原生
      // requestInstall 永远返回 false 且状态仍停在 readyToInstall，用户连点
      // 「安装更新」毫无反馈。Dart 不得伪造 failed，但必须给出可见原因。
      transport.installResult = false;
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.readyToInstall,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await open(tester, managedTestRelease());

      await tester.tap(find.widgetWithText(FilledButton, '安装更新'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(transport.installCalls, 1);
      expect(find.text('下载完成，可安装更新'), findsOneWidget);
      expect(find.text('无法打开系统安装程序'), findsOneWidget);
      expect(find.textContaining('已安装'), findsNothing);

      await tester.pump(const Duration(seconds: 5)); // 让提示计时器走完
      await disposeDialog(tester);
    });

    testWidgets('原生返回 false 但状态已推进为需要授权时，不叠加「无法打开」提示', (tester) async {
      // 相位守卫的否定分支：原生确实没发起安装器，但它同时把受管状态推进为
      // permissionRequired（状态区已有授权引导）。此时再弹「无法打开系统安装
      // 程序」既是错误归因，也会与权限横幅重复。
      transport.installResult = false;
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.readyToInstall,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      transport.onInstall = () {
        transport.active = const ApkUpdateState(
          phase: ApkUpdatePhase.permissionRequired,
          version: '0.3.0',
          releaseTag: 'v0.3.0',
          requestKey: 'k',
        );
      };
      await open(tester, managedTestRelease());

      await tester.tap(find.widgetWithText(FilledButton, '安装更新'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(transport.installCalls, 1);
      expect(find.text('需要允许安装应用'), findsOneWidget);
      expect(find.text('无法打开系统安装程序'), findsNothing);
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

    testWidgets('切到后台停止轮询，回前台再查询一次（轮询归控制器，弹窗无关）', (tester) async {
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

      foreground = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 3));
      expect(transport.queryCalls, afterOpen, reason: '非前台不应继续轮询');

      foreground = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(
        transport.queryCalls,
        greaterThan(afterOpen),
        reason: '回前台应查询一次原生状态',
      );
      foreground = true;
      await disposeDialog(tester);
    });

    testWidgets('关闭弹窗不停止控制器轮询：后台下载的进度仍在更新', (tester) async {
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

      // 弹窗已关闭，但控制器仍在前台轮询原生状态（下载转入后台的前提）。
      final beforeBackground = transport.queryCalls;
      await tester.pump(const Duration(seconds: 2, milliseconds: 100));
      expect(
        transport.queryCalls,
        greaterThan(beforeBackground),
        reason: '关闭弹窗后控制器应继续前台轮询',
      );

      // 下载完成（终态）后轮询停止，不留下 pending timer。
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.canceled,
        retired: true,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await tester.pump(const Duration(seconds: 2));
      final atTerminal = transport.queryCalls;
      await tester.pump(const Duration(seconds: 2));
      expect(transport.queryCalls, atTerminal, reason: '非活动阶段轮询应停止');
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

  group('点「更新」后自动转入后台（生产默认行为）', () {
    late FakeApkUpdateTransport transport;
    late ApkUpdateController controller;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      transport = FakeApkUpdateTransport();
      controller = fakeApkUpdateController(transport);
      kUpdateDialogAutoCloseAfterStart = true;
    });

    tearDown(() {
      controller.debugReset();
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
      await tester.pump();
      await tester.pump();
      await tester.pump();
    }

    testWidgets('发起下载成功后弹窗自动关闭并提示已转入后台', (tester) async {
      transport.startResult = const ApkUpdateState(
        phase: ApkUpdatePhase.enqueued,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await open(tester, managedTestRelease());
      expect(find.widgetWithText(FilledButton, '更新'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '更新'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(transport.startCalls, 1);
      expect(
        find.text('已转入后台下载，完成后将提示安装'),
        findsOneWidget,
        reason: '应提示已转入后台下载',
      );
      expect(find.text('发现新版本 v0.3.0'), findsNothing, reason: '弹窗应已关闭');
      expect(find.text('正在加入下载队列…'), findsNothing, reason: '用户不再被卡在前台模态里看进度');

      await tester.pump(const Duration(seconds: 5)); // 让 toast 计时器与退出动画走完
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('「重试」成功发起后同样自动关闭弹窗', (tester) async {
      transport.active = const ApkUpdateState(
        phase: ApkUpdatePhase.failed,
        reason: ApkUpdateFailureReason.network,
        version: '0.3.0',
        releaseTag: 'v0.3.0',
        requestKey: 'k',
      );
      await open(tester, managedTestRelease());
      expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '重试'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(transport.startCalls, 1);
      expect(find.text('发现新版本 v0.3.0'), findsNothing);
      expect(find.text('网络连接失败，请检查网络后重试'), findsNothing);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('资产不可信（发起失败）时弹窗保持打开', (tester) async {
      await open(tester, managedTestRelease(canonicalAssetUrl: null));
      // 无「更新」按钮可点（降级路径）：直接验证发起失败语义已在其它用例覆盖，
      // 这里只确认降级弹窗本身不会因自动关闭逻辑意外消失。
      expect(find.textContaining('该版本未提供可校验的安装包'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}
