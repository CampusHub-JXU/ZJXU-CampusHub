import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/app/theme.dart';
import 'package:jxu_campus_hub/core/theme/app_colors.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_bill_page.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_consumption.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';
import 'package:jxu_campus_hub/shared/widgets/skeleton_box.dart';

import '../../helpers/credential_store_test_ext.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  CampusCardConsumptionSummary buildSampleSummary() {
    return CampusCardConsumptionSummary(
      todaySpend: 14.6,
      cardBalance: 48.2,
      weekSpend: 68.5,
      monthSpend: 215.0,
      recent: [
        CampusCardConsumptionEntry(
          date: DateTime(2026, 11, 16),
          location: '梅园餐厅二楼',
          amount: 11.0,
        ),
        CampusCardConsumptionEntry(
          date: DateTime(2026, 11, 16),
          location: '梅园餐厅一楼',
          amount: 3.6,
        ),
      ],
      meals: const [
        CampusCardMealSpend(label: '早餐', amount: 3.6),
        CampusCardMealSpend(label: '午餐', amount: 15.0),
        CampusCardMealSpend(label: '晚餐', amount: 64.5),
      ],
      dailyTrend: const [
        CampusCardDaySpend(label: '11-10', amount: 12.0, count: 2),
        CampusCardDaySpend(label: '11-12', amount: 18.5, count: 3),
        CampusCardDaySpend(label: '11-14', amount: 9.0, count: 1),
        CampusCardDaySpend(label: '11-16', amount: 14.6, count: 2),
      ],
      fetchedAt: DateTime(2026, 11, 19, 10, 0),
    );
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    AuthSessionPersistence.instance
      ..debugReset()
      ..debugDisableFileLock = true;
    UnifiedAuthService.instance.debugReset();
    CampusCardService.instance.debugReset();

    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'casuser',
    );
    await CredentialStore.instance.saveUnifiedAuthSession('casuser');
    AuthSessionPersistence.instance
      ..debugReset()
      ..debugDisableFileLock = true;
  });

  tearDown(() {
    AuthSessionPersistence.instance
      ..debugReset()
      ..debugDisableFileLock = true;
  });

  testWidgets('renders stats, recent consumption, meals, and daily trend', (
    tester,
  ) async {
    CampusCardService.instance.debugConsumptionFetcher = () async =>
        buildSampleSummary();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightThemeFor(AppColors.primary),
        home: const CampusCardBillPage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('校园卡账单'), findsOneWidget);
    expect(find.text('48.20'), findsOneWidget);
    expect(find.text('今日消费'), findsOneWidget);
    expect(find.text('14.60'), findsWidgets);
    expect(find.text('本周消费'), findsOneWidget);
    expect(find.text('68.50'), findsOneWidget);
    expect(find.text('本月消费'), findsOneWidget);
    expect(find.text('215.00'), findsOneWidget);

    expect(find.text('梅园餐厅二楼'), findsOneWidget);
    expect(find.text('11.00'), findsWidgets);
    expect(find.text('早餐'), findsOneWidget);
    expect(find.text('午餐'), findsOneWidget);
    expect(find.text('晚餐'), findsOneWidget);
    expect(find.text('11-16 · 2笔'), findsOneWidget);
  });

  testWidgets('loading shows skeleton boxes and resolves cleanly', (
    tester,
  ) async {
    final pending = Completer<CampusCardConsumptionSummary?>();
    CampusCardService.instance.debugConsumptionFetcher = () => pending.future;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightThemeFor(AppColors.primary),
        home: const CampusCardBillPage(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(SkeletonBox), findsWidgets);

    pending.complete(buildSampleSummary());
    await tester.pumpAndSettle();

    expect(find.byType(SkeletonBox), findsNothing);
    expect(find.text('梅园餐厅二楼'), findsOneWidget);
  });

  testWidgets('failure without cache shows error view and H5 fallback works', (
    tester,
  ) async {
    var h5Tapped = 0;
    CampusCardService.instance.debugConsumptionFetcher = () async => null;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightThemeFor(AppColors.primary),
        home: CampusCardBillPage(onOpenH5: () => h5Tapped++),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('去官方页面查看'), findsOneWidget);
    await tester.tap(find.text('去官方页面查看'));
    await tester.pumpAndSettle();
    expect(h5Tapped, 1);
  });

  testWidgets('360px narrow screen with 1.5x text scale does not overflow', (
    tester,
  ) async {
    CampusCardService.instance.debugConsumptionFetcher = () async =>
        buildSampleSummary();

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 740),
          textScaler: TextScaler.linear(1.5),
        ),
        child: MaterialApp(
          theme: AppTheme.darkThemeFor(AppColors.primary),
          home: const CampusCardBillPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('梅园餐厅二楼'), findsOneWidget);
  });
}
