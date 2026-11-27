import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/app/routes.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_builder.dart';
import 'package:jxu_campus_hub/features/physical_test/physical_test_page.dart';
import 'package:jxu_campus_hub/shared/widgets/auth_required_view.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_setup.dart';

Finder _fieldByKey(Key key) => find.byKey(key);

Future<void> _tap(WidgetTester tester, String label) async {
  final target = find.text(label);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, Key key, String value) async {
  final field = _fieldByKey(key);
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

void main() {
  setUp(resetTestEnvironment);

  testWidgets(
    'switches to calculator mode offline and calculates live scores',
    (tester) async {
      appRouter.go('/physical-test');
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: appRouter,
          theme: AppThemeBuilder.light(const Color(0xFF8B1A2D)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PhysicalTestPage), findsOneWidget);
      expect(find.byType(AuthRequiredView), findsOneWidget);

      await _tap(tester, '成绩计算');
      expect(find.byType(AuthRequiredView), findsNothing);
      expect(
        find.byKey(const Key('physical_test_calculator_readout')),
        findsOneWidget,
      );
      expect(find.text('--'), findsOneWidget);
      expect(find.text('待完善'), findsOneWidget);

      await _tap(tester, '请选择年级');
      await _tap(tester, '大一');
      await _tap(tester, '请选择性别');
      await _tap(tester, '男生');

      await _enter(tester, const Key('physical_test_input_height'), '200');
      await _enter(tester, const Key('physical_test_input_weight'), '80');
      await _enter(tester, const Key('physical_test_input_lung'), '4545');
      // 尚未填满所有项目时，已填单项仍实时显示得分，总分仍为待完善。
      expect(find.text('100 分'), findsOneWidget);
      expect(find.text('80 分'), findsOneWidget);
      expect(find.text('--'), findsOneWidget);

      await _enter(tester, const Key('physical_test_input_sprint'), '7.2');
      await _enter(tester, const Key('physical_test_input_reach'), '3.7');
      await _enter(tester, const Key('physical_test_input_jump'), '208');
      await _enter(tester, const Key('physical_test_input_strength'), '10');
      await _enter(tester, const Key('physical_test_input_endurance'), '270');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('请输入两位秒数'), findsOneWidget);

      await _enter(tester, const Key('physical_test_input_endurance'), '4.30');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('72.60'), findsOneWidget);
      expect(find.text('及格'), findsOneWidget);

      // 重置清空所有输入并恢复待完善。
      await _tap(tester, '重置');
      expect(find.text('72.60'), findsNothing);
      expect(find.text('--'), findsOneWidget);
      expect(find.text('待完善'), findsOneWidget);

      // 切回「我的成绩」恢复登录引导。
      await _tap(tester, '我的成绩');
      expect(find.byType(AuthRequiredView), findsOneWidget);
    },
  );

  testWidgets('legacy /physical-test/calculator route opens calculator mode', (
    tester,
  ) async {
    appRouter.go('/physical-test/calculator');
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: appRouter,
        theme: AppThemeBuilder.light(const Color(0xFF8B1A2D)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PhysicalTestPage), findsOneWidget);
    expect(
      find.byKey(const Key('physical_test_calculator_readout')),
      findsOneWidget,
    );
    expect(find.text('重置'), findsOneWidget);
  });

  testWidgets('compacts on narrow screens and resets the sex-specific fields', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 660);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeBuilder.dark(const Color(0xFF8B1A2D)),
        home: const PhysicalTestPage(
          initialMode: PhysicalTestPageMode.calculator,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tap(tester, '请选择年级');
    await _tap(tester, '大三');
    await _tap(tester, '请选择性别');
    await _tap(tester, '男生');
    await _enter(tester, const Key('physical_test_input_strength'), '10');
    await _enter(tester, const Key('physical_test_input_endurance'), '4.30');
    await _tap(tester, '男生');
    await _tap(tester, '女生');

    expect(find.text('引体向上'), findsNothing);
    expect(find.text('1000 米跑'), findsNothing);
    expect(find.text('1 分钟仰卧起坐'), findsOneWidget);
    expect(find.text('800 米跑'), findsOneWidget);
    expect(find.text('4.30'), findsNothing);

    await _enter(tester, const Key('physical_test_input_height'), '200');
    await _enter(tester, const Key('physical_test_input_weight'), '80');
    await _enter(tester, const Key('physical_test_input_lung'), '3350');
    await _enter(tester, const Key('physical_test_input_sprint'), '8.25');
    await _enter(tester, const Key('physical_test_input_reach'), '6.4');
    await _enter(tester, const Key('physical_test_input_jump'), '151');
    await _enter(tester, const Key('physical_test_input_strength'), '27');
    await _enter(tester, const Key('physical_test_input_endurance'), '273');
    expect(find.text('70.10'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
