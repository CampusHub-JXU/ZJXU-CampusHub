import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/app_design_tokens.dart';
import 'package:jxu_campus_hub/features/library/library_login_help.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_dialog_route.dart';

import '../helpers/preview_support.dart';

/// 图书馆登录说明弹层预览（Issue 54）。
///
/// 仅在 `JXU_PREVIEW_RENDER=1`（`tools/render_previews.ps1` +
/// `flutter test --update-goldens test/preview/`）下渲染为
/// `preview/render/library_login_help_<brightness>.png`；普通 `flutter test`
/// 整体 skip，零副作用。
void main() {
  final renderEnabled = Platform.environment['JXU_PREVIEW_RENDER'] == '1';

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

  for (final brightness in Brightness.values) {
    previewTest('library_login_help_${brightness.name}', (tester) async {
      await pumpPreviewScene(
        tester,
        (_) => const _HelpSheetScene(),
        brightness: brightness,
      );
      await expectPreviewGolden(
        tester,
        'library_login_help_${brightness.name}',
      );
    });
  }
}

/// 按弹层真实观感摆放：底部贴边 + 顶部 squircle 圆角 + overlay 档玻璃面。
class _HelpSheetScene extends StatelessWidget {
  const _HelpSheetScene();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      body: Align(
        alignment: Alignment.bottomCenter,
        child: GlassOverlaySurface(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.sheet),
          ),
          child: const SafeArea(top: false, child: LibraryLoginHelpSheet()),
        ),
      ),
    );
  }
}
