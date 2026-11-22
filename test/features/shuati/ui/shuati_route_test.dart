// `/shuati-practice` 及其全部入口已切换为原生刷题助手；`/shuati-legacy` 保留旧版
// WebView 入口供用户导出旧数据。
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:jxu_campus_hub/app/routes.dart';
import 'package:jxu_campus_hub/core/actions/campus_action.dart';
import 'package:jxu_campus_hub/core/actions/campus_action_ids.dart';
import 'package:jxu_campus_hub/core/actions/campus_action_registry.dart';
import 'package:jxu_campus_hub/features/shuati/domain/shuati_models.dart';
import 'package:jxu_campus_hub/features/shuati/shuati_webview_page.dart';
import 'package:jxu_campus_hub/features/shuati/ui/shuati_native_home_page.dart';
import 'package:jxu_campus_hub/features/shuati/ui/shuati_native_import_page.dart';
import 'package:jxu_campus_hub/features/shuati/ui/shuati_native_practice_page.dart';
import 'package:jxu_campus_hub/features/shuati/ui/shuati_native_settings_page.dart';
import 'package:jxu_campus_hub/features/shuati/ui/shuati_native_wrong_page.dart';
import 'package:jxu_campus_hub/features/shuati/ui/shuati_services.dart';

import '../../../helpers/fake_inappwebview.dart';
import '../../../helpers/shuati_test_support.dart';
import '../../../helpers/test_setup.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    InAppWebViewPlatform.instance = FakeInAppWebViewPlatform();
  });

  setUp(() async {
    await resetTestEnvironment();
  });

  tearDown(ShuatiServices.instance.debugReset);

  testWidgets('/shuati-practice opens the native home page', (tester) async {
    final store = (await tester.runAsync(openTestStore))!;
    ShuatiServices.instance.debugUse(store);

    await tester.pumpWidget(MaterialApp.router(routerConfig: appRouter));
    await tester.pump();
    appRouter.go('/shuati-practice');
    await _settle(tester);

    expect(find.byType(ShuatiNativeHomePage), findsOneWidget);
    expect(find.byType(ShuatiWebViewPage), findsNothing);
  });

  testWidgets('/shuati-legacy keeps the WebView fallback page', (tester) async {
    await tester.pumpWidget(MaterialApp.router(routerConfig: appRouter));
    await tester.pump();
    appRouter.go('/shuati-legacy');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(ShuatiWebViewPage), findsOneWidget);
    expect(find.byType(ShuatiNativeHomePage), findsNothing);
  });

  testWidgets('native child routes resolve and forward query parameters', (
    tester,
  ) async {
    final store = (await tester.runAsync(openTestStore))!;
    ShuatiServices.instance.debugUse(store);

    await tester.pumpWidget(MaterialApp.router(routerConfig: appRouter));
    await tester.pump();

    appRouter.go('/shuati-practice/import');
    await _settle(tester);
    expect(find.byType(ShuatiNativeImportPage), findsOneWidget);

    appRouter.go('/shuati-practice/settings');
    await _settle(tester);
    expect(find.byType(ShuatiNativeSettingsPage), findsOneWidget);

    appRouter.go('/shuati-practice/wrong/b1');
    await _settle(tester);
    final wrongPage = tester.widget<ShuatiNativeWrongPage>(
      find.byType(ShuatiNativeWrongPage),
    );
    expect(wrongPage.bankId, 'b1');

    appRouter.go(
      '/shuati-practice/practice/b1/exam?type=single&examCount=20&randomCount=10&resume=1',
    );
    await _settle(tester);
    final practicePage = tester.widget<ShuatiNativePracticePage>(
      find.byType(ShuatiNativePracticePage),
    );
    expect(practicePage.bankId, 'b1');
    expect(practicePage.mode, PracticeMode.exam);
    expect(practicePage.typeFilter, QuestionType.single);
    expect(practicePage.examCount, 20);
    expect(practicePage.randomCount, 10);
    expect(practicePage.resume, isTrue);
  });

  test('shuati.open action targets the shuati-practice route', () {
    final action = CampusActionRegistry.instance.findById(
      CampusActionIds.shuatiOpen,
    );
    final target = action?.target;
    expect(target, isA<RouteActionTarget>());
    expect((target! as RouteActionTarget).routeName, 'shuati-practice');
  });
}
