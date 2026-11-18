import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/update/apk_download_route.dart';
import 'package:jxu_campus_hub/core/update/apk_update_controller.dart';
import 'package:jxu_campus_hub/core/update/update_model.dart';
import 'package:jxu_campus_hub/shared/widgets/update_dialog.dart';

import '../helpers/fake_apk_update_transport.dart';
import '../helpers/preview_support.dart';

/// 应用内更新弹窗的视觉预览（独立于 preview_render_test.dart）。
///
/// `flutter test` 默认全部 skip（零副作用）；渲染时设 `JXU_PREVIEW_RENDER=1`
/// 并配合 `--update-goldens` 把每个状态写成 `preview/render/*.png`：
///
///   $env:JXU_PREVIEW_RENDER = "1"
///   flutter test test/preview/update_dialog_preview_test.dart --update-goldens
///
/// 覆盖：可更新 / 下载中（已知 / 未知总量）/ 待安装 / 需授权 / 失败 / 换源中 / 确认归属中 / 降级，
/// 以及深色、360 宽、2 倍字号与超长更新说明的可滚动形态。
void main() {
  final bool renderEnabled = Platform.environment['JXU_PREVIEW_RENDER'] == '1';

  setUpAll(() async {
    if (!renderEnabled) return;
    await setUpPreviewEnvironment();
  });

  void previewTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets('preview: $name', (tester) async {
      if (!renderEnabled) return;
      await body(tester);
    }, skip: !renderEnabled);
  }

  Future<void> renderDialog(
    WidgetTester tester,
    String name, {
    required FakeApkUpdateTransport transport,
    AppRelease? release,
    Brightness brightness = Brightness.light,
    Size? logicalSize,
    double textScale = 1.0,
  }) async {
    if (textScale != 1.0) {
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }
    await pumpPreviewScene(
      tester,
      (_) => _DialogLauncher(
        release: release ?? managedTestRelease(),
        controller: fakeApkUpdateController(transport),
      ),
      brightness: brightness,
      logicalSize: logicalSize,
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pump();
    await expectPreviewGolden(tester, name);
  }

  const downloading = ApkUpdateState(
    phase: ApkUpdatePhase.downloading,
    bytesDownloaded: 18 * 1024 * 1024,
    totalBytes: 45 * 1024 * 1024,
    requestKey: 'k',
  );

  previewTest('update_dialog_idle_light', (tester) async {
    await renderDialog(
      tester,
      'update_dialog_idle_light',
      transport: FakeApkUpdateTransport(),
    );
  });

  previewTest('update_dialog_idle_dark', (tester) async {
    await renderDialog(
      tester,
      'update_dialog_idle_dark',
      transport: FakeApkUpdateTransport(),
      brightness: Brightness.dark,
    );
  });

  previewTest('update_dialog_downloading_light', (tester) async {
    await renderDialog(
      tester,
      'update_dialog_downloading_light',
      transport: FakeApkUpdateTransport(active: downloading),
    );
  });

  previewTest('update_dialog_downloading_unknown_light', (tester) async {
    await renderDialog(
      tester,
      'update_dialog_downloading_unknown_light',
      transport: FakeApkUpdateTransport(
        active: const ApkUpdateState(
          phase: ApkUpdatePhase.downloading,
          bytesDownloaded: 5 * 1024 * 1024,
          requestKey: 'k',
        ),
      ),
    );
  });

  previewTest('update_dialog_ready_light', (tester) async {
    await renderDialog(
      tester,
      'update_dialog_ready_light',
      transport: FakeApkUpdateTransport(
        active: const ApkUpdateState(
          phase: ApkUpdatePhase.readyToInstall,
          requestKey: 'k',
        ),
      ),
    );
  });

  previewTest('update_dialog_permission_light', (tester) async {
    await renderDialog(
      tester,
      'update_dialog_permission_light',
      transport: FakeApkUpdateTransport(
        active: const ApkUpdateState(
          phase: ApkUpdatePhase.permissionRequired,
          requestKey: 'k',
        ),
      ),
    );
  });

  previewTest('update_dialog_failed_light', (tester) async {
    await renderDialog(
      tester,
      'update_dialog_failed_light',
      transport: FakeApkUpdateTransport(
        active: const ApkUpdateState(
          phase: ApkUpdatePhase.failed,
          reason: ApkUpdateFailureReason.network,
          requestKey: 'k',
        ),
      ),
    );
  });

  previewTest('update_dialog_switching_light', (tester) async {
    await renderDialog(
      tester,
      'update_dialog_switching_light',
      transport: FakeApkUpdateTransport(
        active: const ApkUpdateState(
          phase: ApkUpdatePhase.cleanupPending,
          requestKey: 'k',
          source: ApkDownloadSource.r2,
          triedSources: [ApkDownloadSource.r2],
          switching: true,
          switchReason: ApkFallbackReason.connectTimeout,
          fellBackFrom: ApkDownloadSource.r2,
        ),
      ),
    );
  });

  previewTest('update_dialog_reconcile_light', (tester) async {
    await renderDialog(
      tester,
      'update_dialog_reconcile_light',
      transport: FakeApkUpdateTransport(
        active: const ApkUpdateState(
          phase: ApkUpdatePhase.reconcileRequired,
          requestKey: 'k',
        ),
      ),
    );
  });

  previewTest('update_dialog_unsupported_light', (tester) async {
    await renderDialog(
      tester,
      'update_dialog_unsupported_light',
      transport: FakeApkUpdateTransport(supported: false),
    );
  });

  previewTest('update_dialog_downloading_360_textscale2', (tester) async {
    await renderDialog(
      tester,
      'update_dialog_downloading_360_textscale2',
      transport: FakeApkUpdateTransport(active: downloading),
      logicalSize: const Size(360, 740),
      textScale: 2.0,
    );
  });

  previewTest('update_dialog_long_changelog_light', (tester) async {
    await renderDialog(
      tester,
      'update_dialog_long_changelog_light',
      transport: FakeApkUpdateTransport(),
      release: managedTestRelease(
        changelog: List.generate(
          14,
          (i) => '· 第 ${i + 1} 项更新说明：优化课表加载与若干细节体验。',
        ).join('\n'),
      ),
      logicalSize: const Size(360, 640),
    );
  });
}

/// 打开弹窗的宿主：一个按钮 + 注入的控制器。
class _DialogLauncher extends StatelessWidget {
  const _DialogLauncher({required this.release, required this.controller});

  final AppRelease release;
  final ApkUpdateController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () =>
              showUpdateDialog(context, release, controller: controller),
          child: const Text('open'),
        ),
      ),
    );
  }
}
