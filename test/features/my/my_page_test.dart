import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/features/my/my_page.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';
import 'package:jxu_campus_hub/shared/widgets/app_dropdown.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    UnifiedAuthService.instance.debugReset();
    ZhengfangAuth.instance.debugReset();
    await ScheduleService.instance.debugClearCache();
  });

  tearDown(() {
    UnifiedAuthService.instance.debugReset();
    ZhengfangAuth.instance.debugReset();
  });

  testWidgets(
    'shows logged out when restored unified auth session is invalid',
    (tester) async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '2025001',
      );
      UnifiedAuthService.instance.debugSessionValidator = (_) async => false;

      await tester.pumpWidget(const MaterialApp(home: MyPage()));
      await tester.pump();
      await tester.pump();

      expect(find.text('统一认证（含一卡通）'), findsOneWidget);
      expect(find.text('已登录'), findsNothing);
      // 副标题呈现「未登录」，已去除行尾状态灯及右侧独立状态文案。
      expect(find.text('未登录'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('my_campus_status'))).data,
        '未登录',
      );
    },
  );

  testWidgets('keeps logged in state when unified auth session validates', (
    tester,
  ) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2025001',
    );
    UnifiedAuthService.instance.debugSessionValidator = (_) async => true;

    await tester.pumpWidget(const MaterialApp(home: MyPage()));
    await tester.pump();
    await tester.pump();

    expect(find.text('统一认证（含一卡通）'), findsOneWidget);
    // 副标题呈现「已登录」，已去除行尾状态灯及右侧独立状态文案。
    expect(find.text('已登录'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('my_campus_status'))).data,
      '已登录',
    );
  });

  testWidgets(
    'shows unknown state when liveness check fails with network error',
    (tester) async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '2025001',
      );
      // 校验请求本身失败（返回 null = 网络异常）：不能沿用「已登录」。
      UnifiedAuthService.instance.debugSessionValidator = (_) async => null;

      await tester.pumpWidget(const MaterialApp(home: MyPage()));
      await tester.pump();
      await tester.pump();

      expect(find.text('已登录'), findsNothing);
      expect(find.textContaining('登录状态未知'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('my_campus_status'))).data,
        '登录状态未知 · 点按重新校验',
      );
    },
  );

  testWidgets('grade dropdown switches between auto follow and manual year', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: MyPage()));
    await tester.pump();
    await tester.pump();

    // 默认「自动」紧凑档（行尾小矩形）；说明文案收进问号 tooltip，
    // 不再常驻行下。
    expect(find.text('自动'), findsOneWidget);
    expect(find.text('默认跟随学号自动识别，仅用于过滤与你无关的教务处公告，可能误判。'), findsNothing);
    expect(find.byTooltip('默认跟随学号自动识别，仅用于过滤与你无关的教务处公告，可能误判。'), findsOneWidget);

    // 选择手动年级：写入持久化，按钮文案随选中项切换。
    await tester.tap(find.byType(AppDropdown<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2024级'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('profile_enrollment_year'), 2024);

    // 恢复「自动」：手动值清除。菜单项用弹出层 key 定位，与按钮上的
    // 同名回显文案区分开。
    await tester.tap(find.byType(AppDropdown<int>));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('app-dropdown-menu')),
        matching: find.text('自动'),
      ),
    );
    await tester.pumpAndSettle();

    final prefsAfter = await SharedPreferences.getInstance();
    expect(prefsAfter.getInt('profile_enrollment_year'), isNull);
    expect(find.text('自动'), findsOneWidget);
  });

  testWidgets('renders on small screen (360x640) without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: MyPage()));
    await tester.pumpAndSettle();

    expect(find.text('我的'), findsOneWidget);
    expect(find.text('统一认证（含一卡通）'), findsOneWidget);
    expect(find.text('教务系统'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders with large text scale (1.5x) without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: MyPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('我的'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders in dark mode with unified icon colors', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: const MyPage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('我的'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
