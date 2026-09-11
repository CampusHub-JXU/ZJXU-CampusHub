import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/home/home_surface_scene.dart';
import 'package:jxu_campus_hub/features/home/models/example_campus_snapshot.dart';

void main() {
  Widget wrap(Widget child, {double width = 390, double height = 900}) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(width: width, height: height, child: child),
      ),
    );
  }

  testWidgets('真实 Home 组件渲染示例数据', (tester) async {
    await tester.pumpWidget(
      wrap(
        const HomeSurfaceScene(
          presentation: ExampleCampusSnapshot.presentation,
          scaleToFit: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('42 分钟后上课'), findsOneWidget);
    expect(find.text('高等数学 C2'), findsWidgets);
    expect(find.text('微观经济学'), findsOneWidget);
    expect(find.text('大学英语'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('预览缩放模式在小框内不溢出', (tester) async {
    await tester.pumpWidget(
      wrap(
        const HomeSurfaceScene(
          presentation: ExampleCampusSnapshot.presentation,
        ),
        width: 220,
        height: 420,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
