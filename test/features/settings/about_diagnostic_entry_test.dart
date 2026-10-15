import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/perf/frame_timing_collector.dart';
import 'package:jxu_campus_hub/features/settings/about_page.dart';

import '../../helpers/pump_app.dart';
import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

  testWidgets('性能诊断入口的出现与编译期开关一致', (tester) async {
    await pumpPage(tester, const AboutPage());

    if (kPerfDiagnosticsEnabled) {
      // 启用构建里入口在页面下方，滚动到它再断言。
      await tester.scrollUntilVisible(find.text('性能诊断'), 200);
    }
    // 默认构建（未传 --dart-define）入口不出现；传了才出现。
    expect(
      find.text('性能诊断'),
      kPerfDiagnosticsEnabled ? findsOneWidget : findsNothing,
    );
    // 原有诊断入口不受影响。
    expect(find.text('复制登录诊断日志'), findsOneWidget);
  });

  testWidgets('未启用时关于页不出现性能诊断入口', (tester) async {
    if (kPerfDiagnosticsEnabled) {
      markTestSkipped('该断言只针对默认（未启用）构建');
      return;
    }
    await pumpPage(tester, const AboutPage());
    expect(find.text('性能诊断'), findsNothing);
    expect(find.text('内部工具，离线采集帧时'), findsNothing);
  });

  test('入口接线到命名路由，且由编译期开关把守', () {
    final src = File('lib/features/settings/about_page.dart')
        .readAsStringSync();
    expect(src.contains("pushNamed('performance-diagnostics')"), isTrue);
    expect(src.contains('kPerfDiagnosticsEnabled'), isTrue);
  });

  test('采集器单例默认开关与编译期开关一致', () {
    expect(FrameTimingCollector.instance.enabled, kPerfDiagnosticsEnabled);
  });
}
