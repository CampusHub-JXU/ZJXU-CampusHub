import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:jxu_campus_hub/core/actions/campus_action_ids.dart';
import 'package:jxu_campus_hub/core/system_surface/campus_widget_bridge.dart';
import 'package:jxu_campus_hub/core/system_surface/widget_refresh_state.dart';
import 'package:jxu_campus_hub/features/settings/desktop_background_page.dart';
import 'package:jxu_campus_hub/shared/widgets/plain_list.dart';

import '../../helpers/pump_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shortcutChannel = MethodChannel('edu.zjxu.jxucampushub/shortcut');

  late _FakeCampusWidgetGateway widgetGateway;
  late List<MethodCall> shortcutCalls;
  WidgetRefreshRecord? refreshRecord;

  /// 1×1 透明 PNG：足够通过 Image.memory 解码路径。
  final previewPng = Uint8List.fromList(const [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0x9C,
    0x62,
    0x00,
    0x01,
    0x00,
    0x00,
    0x05,
    0x00,
    0x01,
    0x0D,
    0x0A,
    0x2D,
    0xB4,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82,
  ]);

  setUp(() {
    refreshRecord = null;
    shortcutCalls = <MethodCall>[];
    widgetGateway = _FakeCampusWidgetGateway();
    widgetGateway.status = CampusWidgetStatus.fromPlatformValue(
      <String, Object?>{
        'pinSupported': true,
        'installed': <String, Object?>{'small': 0, 'medium': 2, 'large': 0},
        'lastSnapshotAtMs': DateTime(
          2026,
          10,
          16,
          9,
          55,
        ).millisecondsSinceEpoch,
      },
    );
    CampusWidgetBridge.instance.setGatewayForTesting(widgetGateway);

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(shortcutChannel, (call) async {
      shortcutCalls.add(call);
      if (call.method == 'openShortcutPermissionSettings') return true;
      if (call.method == 'requestPinnedShortcut') return 'requested';
      return null;
    });
  });

  tearDown(() {
    CampusWidgetBridge.instance.setGatewayForTesting(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shortcutChannel, null);
  });

  Future<void> pumpDesktopBackgroundPage(WidgetTester tester) async {
    await pumpPage(
      tester,
      DesktopBackgroundPage(
        now: () => DateTime(2026, 10, 16, 10, 20),
        refreshRecordLoader: () async => refreshRecord,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> revealRow(WidgetTester tester, String title) async {
    final row = find.text(title);
    await tester.scrollUntilVisible(row, 200);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
  }

  Future<void> tapRow(WidgetTester tester, String title) async {
    final row = find.text(title);
    await revealRow(tester, title);
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  Future<void> sendLifecycleState(WidgetTester tester, String state) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          SystemChannels.lifecycle.name,
          const StringCodec().encodeMessage(state),
          (_) {},
        );
    await tester.pumpAndSettle();
  }

  testWidgets('只展示桌面组件与快捷方式两个区块，不包含权限与后台项', (tester) async {
    await pumpDesktopBackgroundPage(tester);

    expect(find.text('桌面组件'), findsWidgets);
    expect(find.text('快捷方式'), findsOneWidget);
    expect(find.text('今日课表快捷方式'), findsOneWidget);

    expect(find.text('桌面与后台'), findsNothing);
    expect(find.text('后台运行'), findsNothing);
    expect(find.text('桌面快捷方式权限'), findsNothing);
    expect(find.text('通知'), findsNothing);
    expect(find.text('通知权限'), findsNothing);
    expect(find.text('精确闹钟'), findsNothing);
    expect(find.text('电池优化'), findsNothing);
    expect(find.text('自启动'), findsNothing);
    expect(find.text('系统应用信息'), findsNothing);
  });

  testWidgets('桌面组件三行分别以 small / medium / large 请求固定', (tester) async {
    await pumpDesktopBackgroundPage(tester);

    expect(find.text('小 · 2×2 下一节课'), findsOneWidget);
    expect(find.text('中 · 4×2 今日课表'), findsOneWidget);
    expect(find.text('大 · 4×4 校园总览'), findsOneWidget);

    for (final (title, size) in const [
      ('小 · 2×2 下一节课', CampusWidgetSize.small),
      ('中 · 4×2 今日课表', CampusWidgetSize.medium),
      ('大 · 4×4 校园总览', CampusWidgetSize.large),
    ]) {
      await tapRow(tester, title);
      expect(widgetGateway.pinRequests.last, size);
      expect(find.text('已请求添加，请在桌面确认'), findsOneWidget);
    }
    expect(widgetGateway.pinRequests, hasLength(3));
  });

  testWidgets('桌面不支持一键添加时提示手动添加路径', (tester) async {
    widgetGateway.pinResult = CampusWidgetPinResult.unsupported;
    await pumpDesktopBackgroundPage(tester);

    await tapRow(tester, '小 · 2×2 下一节课');

    expect(find.textContaining('当前桌面不支持一键添加'), findsOneWidget);
    expect(find.textContaining('小组件 → 嘉兴大学'), findsOneWidget);
  });

  testWidgets('固定被拒绝时提示并可跳转快捷方式权限设置', (tester) async {
    widgetGateway.pinResult = CampusWidgetPinResult.rejected;
    await pumpDesktopBackgroundPage(tester);

    await tapRow(tester, '中 · 4×2 今日课表');

    expect(find.textContaining('桌面拒绝了添加请求'), findsOneWidget);
    expect(find.textContaining('允许「桌面快捷方式」'), findsOneWidget);
    await tester.tap(find.text('去设置'));
    await tester.pumpAndSettle();
    expect(
      shortcutCalls.map((c) => c.method),
      contains('openShortcutPermissionSettings'),
    );
  });

  testWidgets('原生异常时提示添加失败，不抛出', (tester) async {
    widgetGateway.pinResult = CampusWidgetPinResult.error;
    await pumpDesktopBackgroundPage(tester);

    await tapRow(tester, '大 · 4×4 校园总览');

    expect(find.textContaining('添加失败'), findsOneWidget);
  });

  testWidgets('点击今日课表快捷方式发起固定请求', (tester) async {
    await pumpDesktopBackgroundPage(tester);

    await tapRow(tester, '今日课表快捷方式');

    final call = shortcutCalls.singleWhere(
      (c) => c.method == 'requestPinnedShortcut',
    );
    expect(call.arguments, {
      'actionId': CampusActionIds.scheduleToday,
      'title': '今日课表',
    });
    expect(find.text('已发起添加请求，请在系统提示中确认'), findsOneWidget);
  });

  testWidgets('桌面组件行显示真实放置数量与上次同步时间', (tester) async {
    await pumpDesktopBackgroundPage(tester);

    expect(_valueOf(tester, '小 · 2×2 下一节课'), '未放置');
    expect(_valueOf(tester, '中 · 4×2 今日课表'), '已放置 2 个');
    expect(_valueOf(tester, '上次同步'), '25 分钟前');
    // 后台刷新尚未运行过：不显示该行，不编造时间。
    expect(find.text('上次后台刷新'), findsNothing);
  });

  testWidgets('返回前台时重新查询桌面组件放置数量', (tester) async {
    await pumpDesktopBackgroundPage(tester);
    expect(_valueOf(tester, '小 · 2×2 下一节课'), '未放置');

    widgetGateway.status = CampusWidgetStatus.fromPlatformValue(
      <String, Object?>{
        'pinSupported': true,
        'installed': <String, Object?>{'small': 1, 'medium': 2, 'large': 0},
        'lastSnapshotAtMs': DateTime(
          2026,
          10,
          16,
          10,
          19,
        ).millisecondsSinceEpoch,
      },
    );
    await sendLifecycleState(tester, 'AppLifecycleState.resumed');

    expect(_valueOf(tester, '小 · 2×2 下一节课'), '已放置 1 个');
    expect(_valueOf(tester, '上次同步'), '1 分钟前');
  });

  testWidgets('组件状态读不到时不显示「未放置」，同步显示尚未同步', (tester) async {
    widgetGateway.status = CampusWidgetStatus.unknown;
    await pumpDesktopBackgroundPage(tester);

    expect(find.text('未放置'), findsNothing);
    expect(_valueOf(tester, '上次同步'), '尚未同步');
  });

  testWidgets('后台记录展示真实结果', (tester) async {
    refreshRecord = WidgetRefreshRecord(
      lastAttemptAt: DateTime(2026, 10, 16, 10, 15),
      lastOutcome: WidgetRefreshOutcome.partial,
    );
    await pumpDesktopBackgroundPage(tester);
    expect(find.text('上次后台刷新'), findsOneWidget);
    expect(find.textContaining('部分成功'), findsOneWidget);
  });

  testWidgets('原生预览位图按尺寸渲染，缺失时整块隐藏', (tester) async {
    widgetGateway.previews[CampusWidgetSize.medium] = previewPng;
    widgetGateway.previews[CampusWidgetSize.large] = previewPng;
    await pumpDesktopBackgroundPage(tester);
    expect(
      find.byKey(const Key('desktop_widget_preview_medium')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('desktop_widget_preview_large')),
      findsOneWidget,
    );
    // small 未返回位图：预览区整块隐藏，不留占位。
    expect(find.byKey(const Key('desktop_widget_preview_small')), findsNothing);
  });
}

PlainListRow _rowOf(WidgetTester tester, String title) => tester.widget(
  find.ancestor(of: find.text(title), matching: find.byType(PlainListRow)),
);

String? _valueOf(WidgetTester tester, String title) =>
    _rowOf(tester, title).value;

/// 记录式 CampusWidgetGateway 替身：记录固定请求，返回可配置状态 / 预览。
class _FakeCampusWidgetGateway implements CampusWidgetGateway {
  final pinRequests = <CampusWidgetSize>[];
  final previews = <CampusWidgetSize, Uint8List>{};

  CampusWidgetPinResult pinResult = CampusWidgetPinResult.requested;
  CampusWidgetStatus status = CampusWidgetStatus.unknown;
  bool supported = true;

  @override
  Future<void> pushSnapshot(Map<String, Object?> projection) async {}

  @override
  Future<CampusWidgetPinResult> requestPin(CampusWidgetSize size) async {
    pinRequests.add(size);
    return pinResult;
  }

  @override
  Future<CampusWidgetStatus> getStatus() async => status;

  @override
  Future<Uint8List?> getPreview(
    CampusWidgetSize size, {
    required int widthPx,
  }) async => previews[size];

  @override
  Future<bool> isSupported() async => supported;
}
