import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/shared/widgets/app_error_view.dart';

import '../../helpers/pump_app.dart';

void main() {
  testWidgets('renders title, message and retry button, wires onRetry', (
    tester,
  ) async {
    var retried = 0;

    await pumpApp(
      tester,
      AppErrorView(title: '加载失败', message: '网络连接超时', onRetry: () => retried++),
    );

    expect(find.text('加载失败'), findsOneWidget);
    expect(find.text('网络连接超时'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pump();

    expect(retried, 1);
  });

  testWidgets('hides retry button when onRetry is absent', (tester) async {
    await pumpApp(tester, const AppErrorView(title: '登录状态已失效'));

    expect(find.text('登录状态已失效'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('supports custom retry label and icon', (tester) async {
    await pumpApp(
      tester,
      const AppErrorView(
        title: '加载失败',
        retryLabel: '重新加载',
        icon: Icons.wifi_off_outlined,
        onRetry: _noop,
      ),
    );

    expect(find.text('重新加载'), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off_outlined), findsOneWidget);
  });
}

void _noop() {}
