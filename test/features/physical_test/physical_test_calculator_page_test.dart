import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/app/routes.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_builder.dart';
import 'package:jxu_campus_hub/features/physical_test/physical_test_calculator_page.dart';
import 'package:jxu_campus_hub/features/physical_test/physical_test_page.dart';
import 'package:jxu_campus_hub/shared/widgets/auth_required_view.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_setup.dart';

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> _tap(WidgetTester tester, String label) async {
  final target = find.text(label);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String label, String value) async {
  final field = _field(label);
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

void main() {
  setUp(resetTestEnvironment);

  testWidgets(
    'opens the calculator from the scores page and shows all scores',
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
      await _tap(tester, '体测计算器');
      expect(find.byType(PhysicalTestCalculatorPage), findsOneWidget);
      await _tap(tester, '请选择年级');
      await _tap(tester, '大一');
      await _tap(tester, '请选择性别');
      await _tap(tester, '男生');

      await _enter(tester, '身高（厘米）', '200');
      await _enter(tester, '体重（千克）', '80');
      await _enter(tester, '肺活量（毫升）', '4545');
      await _enter(tester, '50 米跑（秒）', '7.2');
      await _enter(tester, '坐位体前屈（厘米）', '3.7');
      await _enter(tester, '立定跳远（厘米）', '208');
      await _enter(tester, '引体向上（次）', '10');
      await _enter(tester, '1000 米跑', '270');
      await _tap(tester, '计算成绩');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('请输入两位秒数'), findsOneWidget);

      await _enter(tester, '1000 米跑', '4.30');
      await _tap(tester, '计算成绩');
      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      expect(find.text('72.60 / 100'), findsOneWidget);
      for (final event in [
        '体重指数（BMI）',
        '肺活量',
        '50 米跑',
        '坐位体前屈',
        '立定跳远',
        '引体向上',
        '1000 米跑',
      ]) {
        expect(
          find.descendant(of: dialog, matching: find.text(event)),
          findsOneWidget,
        );
      }
      await _tap(tester, '完成');
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(PhysicalTestPage), findsOneWidget);
    },
  );

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
        home: const PhysicalTestCalculatorPage(),
      ),
    );
    await tester.pumpAndSettle();
    await _tap(tester, '请选择年级');
    await _tap(tester, '大三');
    await _tap(tester, '请选择性别');
    await _tap(tester, '男生');
    await _enter(tester, '引体向上（次）', '10');
    await _enter(tester, '1000 米跑', '4.30');
    await _tap(tester, '男生');
    await _tap(tester, '女生');

    expect(_field('引体向上（次）'), findsNothing);
    expect(_field('1000 米跑'), findsNothing);
    expect(_field('1 分钟仰卧起坐（次）'), findsOneWidget);
    expect(_field('800 米跑'), findsOneWidget);
    expect(find.text('4.30'), findsNothing);

    await _enter(tester, '身高（厘米）', '200');
    await _enter(tester, '体重（千克）', '80');
    await _enter(tester, '肺活量（毫升）', '3350');
    await _enter(tester, '50 米跑（秒）', '8.25');
    await _enter(tester, '坐位体前屈（厘米）', '6.4');
    await _enter(tester, '立定跳远（厘米）', '151');
    await _enter(tester, '1 分钟仰卧起坐（次）', '27');
    await _enter(tester, '800 米跑', '273');
    await _tap(tester, '计算成绩');
    expect(find.text('70.10 / 100'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('800 米跑'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await _tap(tester, '完成');
    expect(find.byType(AlertDialog), findsNothing);
  });
}
