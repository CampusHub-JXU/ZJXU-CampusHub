import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/shared/widgets/app_app_bar.dart';

import '../../helpers/test_setup.dart';

void main() {
  setUp(() async {
    await resetTestEnvironment();
  });

  Future<void> pumpBar(WidgetTester tester, {PreferredSizeWidget? bar}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: bar ?? const AppAppBar(title: Text('标题')),
          body: const Center(child: Text('内容')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('玻璃开启时渲染模糊层与标题', (tester) async {
    await pumpBar(tester);

    expect(find.text('标题'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
    final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
    expect(filter.filter, isA<ImageFilter>());
  });

  testWidgets('玻璃关闭时回退实色且不创建 BackdropFilter', (tester) async {
    await GlassStyleController.instance.setEnabled(false);
    await pumpBar(tester);

    expect(find.text('标题'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('显式 backgroundColor 跳过玻璃层', (tester) async {
    await pumpBar(
      tester,
      bar: AppAppBar(title: const Text('扫码'), backgroundColor: Colors.black),
    );

    expect(find.text('扫码'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('preferredSize 计入 bottom 高度', (tester) async {
    final bar = AppAppBar(
      title: const Text('标题'),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Container(),
      ),
    );
    expect(bar.preferredSize.height, kToolbarHeight + 48);
  });
}
