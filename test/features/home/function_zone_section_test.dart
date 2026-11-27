import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/config/feature_entry_catalog.dart';
import 'package:jxu_campus_hub/features/home/function_zone/function_zone_section.dart';
import 'package:jxu_campus_hub/core/config/service_hub_usage_store.dart';
import 'package:jxu_campus_hub/shared/widgets/app_icon_badge.dart';
import 'package:jxu_campus_hub/shared/widgets/app_tile_surface.dart';

/// 默认（无使用记录）状态下的卡面数：全部入口各一块 + 「常用」快捷方式
/// （默认补位 5 个，入口本体仍留在分类里）+ 搜索框卡面 1 块。
const _defaultCommonCount = 5;
int get _defaultSurfaceCount =>
    AppFeaturesConfig.entries.length + _defaultCommonCount + 1;

/// 搜索框卡面的聚焦描边画在一个 [AnimatedContainer] 的
/// `foregroundDecoration`（[RoundedSuperellipseBorder]）上；本函数取出它的
/// `side` 以便断言聚焦视觉（返回 null 表示找不到该卡面）。
BorderSide? _searchRing(WidgetTester tester) {
  final matches = tester
      .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
      .where(
        (widget) =>
            widget.foregroundDecoration is ShapeDecoration &&
            (widget.foregroundDecoration! as ShapeDecoration).shape
                is RoundedSuperellipseBorder,
      )
      .toList();
  if (matches.isEmpty) return null;
  expect(matches, hasLength(1));
  final shape =
      (matches.single.foregroundDecoration! as ShapeDecoration).shape
          as RoundedSuperellipseBorder;
  return shape.side;
}

bool _ringVisible(BorderSide? side) =>
    side != null && side.width > 0 && side.style != BorderStyle.none;

/// 输入框本身（内部 `TextField` 的 [EditableText]）是否真正持有焦点。
bool _inputFocused(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;

Future<void> _pumpSection(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: FunctionZoneSection())),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ServiceHubUsageStore.instance.debugReset();
  });

  tearDown(() {
    ServiceHubUsageStore.instance.debugReset();
  });

  testWidgets(
    'renders hierarchical tiles: rank 0 as wide tile, others as small tiles',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FunctionZoneSection(
                campusCardBalance: '38.50',
                dormElectricity: '18.2',
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Section header
      expect(find.text('功能'), findsOneWidget);
      expect(find.text('长按置顶'), findsOneWidget);

      // All tiles (and the search field) are wrapped in AppTileSurface
      expect(find.byType(AppTileSurface), findsNWidgets(_defaultSurfaceCount));

      // Rank 0 (课表) is a wide tile without static subtitle; the entry
      // itself also stays in its category.
      expect(find.text('课表'), findsNWidgets(2));
      expect(find.text('查看本学期课程、周次与调课提醒'), findsNothing);

      // Standard entries are present (default 常用 shortcuts appear twice)
      expect(find.text('成绩'), findsNWidgets(2));
      expect(find.text('考试'), findsNWidgets(2));
      expect(find.text('付款码'), findsOneWidget);
      expect(find.text('图书馆'), findsOneWidget);
      expect(find.text('第二课堂'), findsOneWidget);
    },
  );

  testWidgets(
    'pinning an entry promotes it to wide tile at top with pin icon',
    (tester) async {
      // Pin library
      await ServiceHubUsageStore.instance.togglePinned('library');

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: FunctionZoneSection()),
          ),
        ),
      );
      await tester.pump();

      // Library should now have a pin icon and be at the top as a wide tile
      // without static subtitle, while its own tile stays in the category.
      expect(find.byIcon(Icons.push_pin_rounded), findsWidgets);
      expect(find.text('图书馆'), findsNWidgets(2));
      expect(find.text('馆藏检索、借阅与电子资源入口'), findsNothing);
    },
  );

  testWidgets('long press toggles pinned status and displays snackbar', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: FunctionZoneSection()),
        ),
      ),
    );
    await tester.pump();

    expect(ServiceHubUsageStore.instance.snapshot.isPinned('library'), isFalse);

    // Long press 图书馆
    await tester.longPress(find.text('图书馆'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('已置顶 图书馆'), findsOneWidget);
    expect(ServiceHubUsageStore.instance.snapshot.isPinned('library'), isTrue);

    // Long press again to unpin (now also shown as a 常用 shortcut)
    await tester.longPress(find.text('图书馆').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('已取消置顶 图书馆'), findsOneWidget);
    expect(ServiceHubUsageStore.instance.snapshot.isPinned('library'), isFalse);
  });

  testWidgets('unifies tile icons to theme primary color without badge', (
    tester,
  ) async {
    const testSeedColor = Color(0xFF8B1D2C); // JXU Wine Red
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: testSeedColor,
            brightness: Brightness.light,
          ),
        ),
        home: const Scaffold(
          body: SingleChildScrollView(child: FunctionZoneSection()),
        ),
      ),
    );
    await tester.pump();

    // 磁贴不再使用 AppIconBadge 底座，改为裸 Icon 并统一主题主色。
    expect(find.byType(AppIconBadge), findsNothing);

    final expectedPrimary = Theme.of(
      tester.element(find.byType(FunctionZoneSection)),
    ).colorScheme.primary;
    // 磁贴图标尺寸为 26（1×1 / 2×1）或 34（2×2）；搜索图标 20 除外。
    final tileIcons = tester
        .widgetList<Icon>(find.byType(Icon))
        .where((icon) => icon.size == 26 || icon.size == 34)
        .toList();
    expect(tileIcons.isNotEmpty, isTrue);
    for (final icon in tileIcons) {
      expect(icon.color, expectedPrimary);
    }
  });

  testWidgets('tapping a tile triggers navigation and records usage', (
    tester,
  ) async {
    var navigatedRoute = '';
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          name: 'home',
          builder: (context, state) => const Scaffold(
            body: SingleChildScrollView(child: FunctionZoneSection()),
          ),
        ),
        GoRoute(
          path: '/exam',
          name: 'exam',
          builder: (context, state) {
            navigatedRoute = 'exam';
            return const Scaffold(body: Text('考试页面'));
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();

    final visitsBefore =
        ServiceHubUsageStore.instance.snapshot.usageById['exam']?.visitCount ??
        0;
    expect(visitsBefore, 0);

    await tester.tap(find.text('考试').first);
    await tester.pumpAndSettle();

    expect(navigatedRoute, 'exam');
    expect(find.text('考试页面'), findsOneWidget);
    expect(
      ServiceHubUsageStore.instance.snapshot.usageById['exam']?.visitCount,
      1,
    );
  });

  testWidgets(
    'wide screen layout (>= 600px) organizes tiles into multi-column grid',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: FunctionZoneSection()),
          ),
        ),
      );
      await tester.pump();

      // All entries are rendered
      expect(find.byType(AppTileSurface), findsNWidgets(_defaultSurfaceCount));
      expect(find.text('课表'), findsNWidgets(2));
      expect(find.text('成绩'), findsNWidgets(2));
      expect(find.text('考试'), findsNWidgets(2));
    },
  );

  testWidgets('small screen (360x640) renders without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FunctionZoneSection(
              campusCardBalance: '¥38.50',
              dormElectricity: '18.2 度',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppTileSurface), findsNWidgets(_defaultSurfaceCount));
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text scale (1.5x) renders without overflow', (
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
          child: Scaffold(
            body: SingleChildScrollView(
              child: FunctionZoneSection(
                campusCardBalance: '¥38.50',
                dormElectricity: '18.2 度',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppTileSurface), findsNWidgets(_defaultSurfaceCount));
    expect(tester.takeException(), isNull);
  });

  testWidgets('library entry opens the in-app library route', (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          name: 'home',
          builder: (context, state) => const Scaffold(
            body: SingleChildScrollView(child: FunctionZoneSection()),
          ),
        ),
        GoRoute(
          path: '/library',
          name: 'library',
          builder: (context, state) => const Scaffold(body: Text('图书馆页面')),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();

    await tester.ensureVisible(find.text('图书馆'));
    await tester.pump();
    await tester.tap(find.text('图书馆'));
    await tester.pumpAndSettle();

    expect(find.text('图书馆页面'), findsOneWidget);
  });

  testWidgets('dark mode applies correct theme colors to surfaces and badges', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: const Scaffold(
          body: SingleChildScrollView(child: FunctionZoneSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppTileSurface), findsNWidgets(_defaultSurfaceCount));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tight zero-width constraints collapse and recover with tiles', (
    tester,
  ) async {
    var width = 0.0;
    late StateSetter setWidth;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setWidth = setState;
              return SizedBox(
                width: width,
                child: const SingleChildScrollView(
                  child: FunctionZoneSection(),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Zero-width phase: the section collapses without exceptions and no tile
    // is laid out with a negative width.
    expect(tester.takeException(), isNull);
    expect(find.byType(AppTileSurface), findsNothing);

    final zeroWidthElement = tester.element(find.byType(FunctionZoneSection));

    // Restore a normal phone width on the same mounted element.
    setWidth(() => width = 360);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      tester.element(find.byType(FunctionZoneSection)),
      same(zeroWidthElement),
    );
    expect(find.text('功能'), findsOneWidget);
    expect(find.text('长按置顶'), findsOneWidget);
    expect(find.byType(AppTileSurface), findsNWidgets(_defaultSurfaceCount));
  });

  testWidgets('常用 holds shortcuts while every entry stays in its category', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: FunctionZoneSection()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('常用'), findsOneWidget);
    for (final category in FeatureEntryCategory.values) {
      expect(find.text(category.label), findsOneWidget);
    }
    // 默认常用（课表/成绩/考试/一卡通/电费）是快捷方式，本体仍在分类里。
    expect(find.text('一卡通'), findsNWidgets(2));
    expect(find.text('宿舍电费'), findsNWidgets(2));
    expect(find.byType(AppTileSurface), findsNWidgets(_defaultSurfaceCount));
  });

  testWidgets('frequently visited entries move into 常用', (tester) async {
    await ServiceHubUsageStore.instance.recordVisit('physical-test');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: FunctionZoneSection()),
        ),
      ),
    );
    await tester.pump();

    // 访问过的体测成为常用首位宽磁贴（不再展示静态副标题），本体仍在分类里。
    expect(find.text('体质测试成绩与预约（WebVPN 访问）'), findsNothing);
    expect(find.text('体测成绩'), findsNWidgets(2));
  });

  testWidgets('search filters entries by title, subtitle and keywords', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: FunctionZoneSection()),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '校园卡');
    await tester.pump();

    expect(find.text('常用'), findsNothing);
    expect(find.text('搜索结果 · 2'), findsOneWidget);
    expect(find.text('一卡通'), findsOneWidget);
    expect(find.text('付款码'), findsOneWidget);
    // 结果磁贴 + 搜索框卡面。
    expect(find.byType(AppTileSurface), findsNWidgets(3));

    await tester.enterText(find.byType(TextField), 'gpa');
    await tester.pump();
    expect(find.text('成绩'), findsOneWidget);
    expect(find.byType(AppTileSurface), findsNWidgets(2));

    await tester.enterText(find.byType(TextField), '不存在的功能');
    await tester.pump();
    expect(find.text('没有找到相关功能'), findsOneWidget);
    expect(find.byType(AppTileSurface), findsOneWidget);

    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pump();
    expect(find.text('常用'), findsOneWidget);
    expect(find.byType(AppTileSurface), findsNWidgets(_defaultSurfaceCount));
  });

  // ── Issue #43: search tile focus ring must follow the real TextField focus ──
  //
  // The ring used to be driven by an ancestor `Focus(onFocusChange:)` boolean.
  // An ancestor's `hasFocus` is true if *any* descendant is focused, so when
  // focus moved off the input onto the trailing clear button (both live inside
  // that ancestor) the ring stayed painted even though the input had lost
  // focus. These tests pin the ring to the input's own FocusNode.
  group('search tile focus ring (Issue #43)', () {
    testWidgets('ring is off until the input is focused, then tracks gain/loss '
        'with and without text', (tester) async {
      await _pumpSection(tester);

      // Empty + unfocused.
      expect(_inputFocused(tester), isFalse);
      expect(_ringVisible(_searchRing(tester)), isFalse);

      // Empty + focused (tap to edit).
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(_inputFocused(tester), isTrue);
      expect(_ringVisible(_searchRing(tester)), isTrue);

      // Empty + real unfocus.
      tester.binding.focusManager.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(_inputFocused(tester), isFalse);
      expect(_ringVisible(_searchRing(tester)), isFalse);

      // Non-empty + focused.
      await tester.enterText(find.byType(TextField), '成绩');
      await tester.pumpAndSettle();
      expect(_inputFocused(tester), isTrue);
      expect(_ringVisible(_searchRing(tester)), isTrue);

      // Non-empty + real unfocus: the ring clears regardless of text.
      tester.binding.focusManager.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(_inputFocused(tester), isFalse);
      expect(_ringVisible(_searchRing(tester)), isFalse);
    });

    testWidgets('hiding the keyboard while the input stays focused keeps the '
        'ring (keyboard-hidden != focus-lost)', (tester) async {
      await _pumpSection(tester);
      await tester.enterText(find.byType(TextField), '成绩');
      await tester.pumpAndSettle();
      expect(_inputFocused(tester), isTrue);
      expect(_ringVisible(_searchRing(tester)), isTrue);

      // Dismiss the soft keyboard only; the input keeps focus.
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      expect(_inputFocused(tester), isTrue);
      expect(_ringVisible(_searchRing(tester)), isTrue);

      // A genuine unfocus is what clears the ring.
      tester.binding.focusManager.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(_ringVisible(_searchRing(tester)), isFalse);
    });

    testWidgets('focus moving off the input (onto the clear button) clears the '
        'ring even though the field stays inside the card', (tester) async {
      await _pumpSection(tester);
      await tester.enterText(find.byType(TextField), 'a');
      await tester.pumpAndSettle();
      expect(_inputFocused(tester), isTrue);
      expect(_ringVisible(_searchRing(tester)), isTrue);

      // Traverse focus to the trailing clear button: still inside the card,
      // but the input itself is no longer focused.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(_inputFocused(tester), isFalse);
      expect(_ringVisible(_searchRing(tester)), isFalse);
    });

    testWidgets('clearing text keeps the input focused, resets results, and '
        'keeps the ring in sync', (tester) async {
      await _pumpSection(tester);
      await tester.enterText(find.byType(TextField), '校园卡');
      await tester.pumpAndSettle();
      expect(find.text('搜索结果 · 2'), findsOneWidget);
      expect(_inputFocused(tester), isTrue);
      expect(_ringVisible(_searchRing(tester)), isTrue);

      await tester.tap(find.byTooltip('清除搜索'));
      await tester.pumpAndSettle();

      // Filtering resets; clearing text does not unfocus, so the ring stays.
      expect(find.text('常用'), findsOneWidget);
      expect(find.byType(AppTileSurface), findsNWidgets(_defaultSurfaceCount));
      expect(_inputFocused(tester), isTrue);
      expect(_ringVisible(_searchRing(tester)), isTrue);

      tester.binding.focusManager.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(_inputFocused(tester), isFalse);
      expect(_ringVisible(_searchRing(tester)), isFalse);
    });

    testWidgets('repeated focus/unfocus cycles stay in sync and end clear', (
      tester,
    ) async {
      await _pumpSection(tester);
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byType(TextField));
        await tester.pumpAndSettle();
        expect(_inputFocused(tester), isTrue, reason: 'cycle $i gain');
        expect(
          _ringVisible(_searchRing(tester)),
          isTrue,
          reason: 'cycle $i gain',
        );

        tester.binding.focusManager.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        expect(_inputFocused(tester), isFalse, reason: 'cycle $i loss');
        expect(
          _ringVisible(_searchRing(tester)),
          isFalse,
          reason: 'cycle $i loss',
        );
      }
    });

    testWidgets(
      'tapping a feature tile unfocuses the input before navigation',
      (tester) async {
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              name: 'home',
              builder: (context, state) => const Scaffold(
                body: SingleChildScrollView(child: FunctionZoneSection()),
              ),
            ),
            GoRoute(
              path: '/exam',
              name: 'exam',
              builder: (context, state) => const Scaffold(body: Text('考试页面')),
            ),
          ],
        );

        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pump();

        await tester.tap(find.byType(TextField));
        await tester.pumpAndSettle();
        expect(_ringVisible(_searchRing(tester)), isTrue);

        await tester.tap(find.text('考试').first);
        await tester.pumpAndSettle();

        expect(find.text('考试页面'), findsOneWidget);
        // The home route is offstage: the input must have been unfocused.
        final editable = tester.widget<EditableText>(
          find.byType(EditableText, skipOffstage: false),
        );
        expect(editable.focusNode.hasFocus, isFalse);
      },
    );

    testWidgets('disposing the section releases the owned focus node cleanly '
        'and a fresh mount still tracks focus', (tester) async {
      await _pumpSection(tester);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(_ringVisible(_searchRing(tester)), isTrue);

      // Replace the whole subtree while the input is focused: the tile state
      // (and its FocusNode) is disposed with focus held.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Re-mount: a fresh node starts unfocused and still tracks focus.
      await _pumpSection(tester);
      expect(_ringVisible(_searchRing(tester)), isFalse);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(_ringVisible(_searchRing(tester)), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a real touch (tapAt) on blank outside the card unfocuses the '
        'input and clears the ring', (tester) async {
      await _pumpSection(tester);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(_inputFocused(tester), isTrue);
      expect(_ringVisible(_searchRing(tester)), isTrue);

      // Real finger-style touch (touch pointer) on the section header, which
      // sits outside the search card. On Android the framework's default
      // `onTapOutside` intentionally does NOT unfocus on touch, so this is the
      // behaviour the card-local TapRegion must provide.
      await tester.tapAt(tester.getCenter(find.text('功能')));
      await tester.pumpAndSettle();

      expect(_inputFocused(tester), isFalse);
      expect(_ringVisible(_searchRing(tester)), isFalse);
    });

    testWidgets('touching the interior of the card (search glyph) keeps the '
        'input focused and the ring on', (tester) async {
      await _pumpSection(tester);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(_inputFocused(tester), isTrue);

      // The leading search glyph is inside the card but outside the editable
      // text; the card-local TapRegion treats the whole card as "inside".
      await tester.tapAt(
        tester.getCenter(find.byIcon(Icons.search_rounded).first),
      );
      await tester.pumpAndSettle();

      expect(_inputFocused(tester), isTrue);
      expect(_ringVisible(_searchRing(tester)), isTrue);
    });

    testWidgets('dragging / scrolling from blank is not treated as an outside '
        'tap: it still scrolls and keeps focus', (tester) async {
      await _pumpSection(tester);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(_inputFocused(tester), isTrue);

      final beforeY = tester.getTopLeft(find.text('功能')).dy;
      // Start the scroll gesture on the blank header area.
      await tester.drag(find.text('功能'), const Offset(0, -160));
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(find.text('功能')).dy, lessThan(beforeY));
      // A scroll drag exceeds touch slop, so it does not count as a tap.
      expect(_inputFocused(tester), isTrue);
      expect(_ringVisible(_searchRing(tester)), isTrue);
    });

    testWidgets('repeated real outside touches keep gain/loss and the ring in '
        'sync', (tester) async {
      await _pumpSection(tester);
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byType(TextField));
        await tester.pumpAndSettle();
        expect(_inputFocused(tester), isTrue, reason: 'cycle $i gain');
        expect(
          _ringVisible(_searchRing(tester)),
          isTrue,
          reason: 'cycle $i ring on',
        );

        await tester.tapAt(tester.getCenter(find.text('功能')));
        await tester.pumpAndSettle();
        expect(_inputFocused(tester), isFalse, reason: 'cycle $i loss');
        expect(
          _ringVisible(_searchRing(tester)),
          isFalse,
          reason: 'cycle $i ring off',
        );
      }
    });
  });
}
