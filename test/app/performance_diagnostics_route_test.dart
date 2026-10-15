import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jxu_campus_hub/app/routes.dart';
import 'package:jxu_campus_hub/core/perf/frame_timing_collector.dart';
import 'package:jxu_campus_hub/features/settings/performance_diagnostics_page.dart';

import '../helpers/pump_app.dart';
import '../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

  test('性能诊断路由已注册且走 _appRoute（MaterialPage 全局转场）', () {
    final routes = appRouter.configuration.routes.whereType<GoRoute>();
    final route = routes.firstWhere(
      (r) => r.name == 'performance-diagnostics',
      orElse: () => throw StateError('未注册 performance-diagnostics 路由'),
    );

    expect(route.path, '/performance-diagnostics');
    // `_appRoute` 用 pageBuilder 显式包 MaterialPage；shell 根路由才用 builder。
    expect(route.pageBuilder, isNotNull);
    expect(route.builder, isNull);
  });

  testWidgets('默认构建下路由目标页 fail closed（不提供开启采样的开关）', (tester) async {
    if (kPerfDiagnosticsEnabled) {
      markTestSkipped('该断言只针对默认（未启用）构建');
      return;
    }

    await pumpPage(tester, const PerformanceDiagnosticsPage());

    expect(find.text('性能诊断未启用'), findsOneWidget);
    expect(find.text('开始采样'), findsNothing);
  });
}
