import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/actions/campus_action.dart';
import 'package:jxu_campus_hub/core/actions/campus_action_executor.dart';
import 'package:jxu_campus_hub/core/actions/campus_action_ids.dart';
import 'package:jxu_campus_hub/core/actions/campus_action_registry.dart';
import 'package:jxu_campus_hub/core/actions/campus_deep_link.dart';
import 'package:jxu_campus_hub/core/config/feature_entry_catalog.dart';
import 'package:jxu_campus_hub/core/wechat/wechat_launcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CampusActionRegistry', () {
    test('action id 唯一且 Catalog 的 primaryActionId 均可解析', () {
      final all = CampusActionRegistry.instance.all.toList();
      final ids = all.map((action) => action.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'action id 必须唯一');

      for (final entry in AppFeaturesConfig.entries) {
        expect(
          CampusActionRegistry.instance.findById(entry.primaryActionId),
          isNotNull,
          reason: '${entry.id} -> ${entry.primaryActionId} 未注册',
        );
      }
    });

    test('首批 PRD action id 均已注册', () {
      const required = <String>{
        CampusActionIds.scheduleOpen,
        CampusActionIds.scheduleToday,
        CampusActionIds.gradesOpen,
        CampusActionIds.campusCardOpen,
        CampusActionIds.campusCardPayment,
        CampusActionIds.campusCardRecharge,
        CampusActionIds.campusCardResetPassword,
        CampusActionIds.electricityOpen,
        CampusActionIds.electricityRecharge,
        CampusActionIds.libraryOpen,
        CampusActionIds.noticeInbox,
        CampusActionIds.serviceHallOpen,
        CampusActionIds.oneStopServiceOpen,
        CampusActionIds.microLifeOpen,
        CampusActionIds.shuatiOpen,
      };
      for (final id in required) {
        expect(CampusActionRegistry.instance.contains(id), isTrue, reason: id);
      }
    });
  });

  group('CampusDeepLink', () {
    test('解析新格式 action 链接', () {
      expect(
        CampusDeepLink.parse('jxucampushub://action/schedule.today'),
        CampusActionIds.scheduleToday,
      );
      expect(
        CampusDeepLink.parse('jxucampushub://action/campus-card.payment'),
        CampusActionIds.campusCardPayment,
      );
    });

    test('兼容旧 shortcut 链接', () {
      expect(
        CampusDeepLink.parse('jxucampushub://shortcut/campus-card-payment'),
        CampusActionIds.campusCardPayment,
      );
      expect(
        CampusDeepLink.parse('jxucampushub://shortcut/shuati-practice'),
        CampusActionIds.shuatiOpen,
      );
    });

    test('拒绝未注册 action、未知 host 与非法 scheme', () {
      expect(
        CampusDeepLink.parse('jxucampushub://action/unknown.action'),
        isNull,
      );
      expect(CampusDeepLink.parse('jxucampushub://shortcut/unknown'), isNull);
      expect(CampusDeepLink.parse('https://action/schedule.today'), isNull);
      expect(CampusDeepLink.parse('jxucampushub://action/'), isNull);
      expect(CampusDeepLink.parse('not a uri'), isNull);
    });
  });

  testWidgets('未注册 action 返回 unsupported 且不导航', (tester) async {
    late CampusActionResult result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await CampusActionExecutor.instance.execute(
                  context,
                  'nope.missing',
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(result.status, CampusActionStatus.unsupported);
  });

  group('CampusActionExecutor.executeWechat', () {
    const testUrl = 'https://example.cn/dekt/wx/index?_WXFTL=0';

    /// 泵一个带 ScaffoldMessenger 的最小页面并触发一次 executeWechat。
    Future<CampusActionResult> runExecuteWechat(
      WidgetTester tester, {
      String url = testUrl,
      String title = '测试入口',
      bool autoCopyOnFailure = false,
    }) async {
      late CampusActionResult result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await CampusActionExecutor.instance.executeWechat(
                    context,
                    url: url,
                    title: title,
                    autoCopyOnFailure: autoCopyOnFailure,
                  );
                },
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      return result;
    }

    tearDown(() {
      WechatLauncher.instance.setGatewayForTesting(null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets('launched 状态返回 success 且文案不断言已打开', (tester) async {
      WechatLauncher.instance.setGatewayForTesting(
        _FakeWechatGateway(
          openUrlResult: const WechatLaunchResult(
            status: WechatLaunchStatus.launched,
            sanitizedUrl: '',
          ),
        ),
      );

      final result = await runExecuteWechat(tester);

      expect(result.status, CampusActionStatus.success);
      expect(result.message, isNotNull);
      expect(result.message, isNot(contains('已跳转到微信')));
      expect(result.message, isNot(contains('已打开微信')));
      expect(result.message, contains('已请求打开微信'));
      expect(find.text(result.message!), findsOneWidget);
    });

    testWidgets('no_handler 复制干净链接后拉起微信 App，仍按降级上报', (tester) async {
      final gateway = _FakeWechatGateway(
        openUrlResult: const WechatLaunchResult(
          status: WechatLaunchStatus.noHandler,
          sanitizedUrl: '',
        ),
        openAppResult: const WechatLaunchResult(
          status: WechatLaunchStatus.launched,
          sanitizedUrl: '',
        ),
      );
      WechatLauncher.instance.setGatewayForTesting(gateway);
      final clipboard = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard.add((call.arguments as Map)['text'] as String);
            }
            return null;
          });

      // 复制动作必须走清理后链接：一次性 ticket 不能进剪贴板。
      final result = await runExecuteWechat(
        tester,
        url: 'https://example.cn/pay?ticket=t-1&schoolCode=001',
      );

      // 先请求直达 → 复制 → 再拉起微信 App 本体。
      expect(gateway.urls, hasLength(1));
      expect(gateway.openAppCalls, 1);
      // 微信被拉起 ≠ 目标网页已打开：绝不能上报 success。
      expect(result.status, CampusActionStatus.fallbackAvailable);
      expect(clipboard, ['https://example.cn/pay?schoolCode=001']);
      expect(find.text('微信不支持外部直达该网页，已复制链接并打开微信，请在微信内粘贴打开'), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, '复制链接'), findsOneWidget);
    });

    testWidgets('no_handler + 微信 App 拉起但复制失败时如实提示', (tester) async {
      WechatLauncher.instance.setGatewayForTesting(
        _FakeWechatGateway(
          openUrlResult: const WechatLaunchResult(
            status: WechatLaunchStatus.noHandler,
            sanitizedUrl: '',
          ),
          openAppResult: const WechatLaunchResult(
            status: WechatLaunchStatus.launched,
            sanitizedUrl: '',
          ),
        ),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              throw PlatformException(code: 'unavailable');
            }
            return null;
          });

      final result = await runExecuteWechat(tester);

      expect(result.status, CampusActionStatus.fallbackAvailable);
      expect(find.text('微信不支持外部直达该网页，已打开微信；可点击复制链接后粘贴打开'), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, '复制链接'), findsOneWidget);
    });

    testWidgets('no_handler + 未安装微信时提示未检测到微信', (tester) async {
      WechatLauncher.instance.setGatewayForTesting(
        _FakeWechatGateway(
          openUrlResult: const WechatLaunchResult(
            status: WechatLaunchStatus.noHandler,
            sanitizedUrl: '',
          ),
          openAppResult: const WechatLaunchResult(
            status: WechatLaunchStatus.notInstalled,
            sanitizedUrl: '',
          ),
        ),
      );
      final clipboard = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard.add((call.arguments as Map)['text'] as String);
            }
            return null;
          });

      final result = await runExecuteWechat(tester);

      expect(result.status, CampusActionStatus.fallbackAvailable);
      expect(clipboard, [testUrl]);
      expect(find.text('未检测到微信，链接已复制，请在微信中粘贴打开'), findsOneWidget);
      expect(find.textContaining('已打开微信'), findsNothing);
      expect(find.widgetWithText(SnackBarAction, '复制链接'), findsOneWidget);
    });

    testWidgets('no_handler + 微信 App 拉起失败时回退复制提示', (tester) async {
      WechatLauncher.instance.setGatewayForTesting(
        _FakeWechatGateway(
          openUrlResult: const WechatLaunchResult(
            status: WechatLaunchStatus.noHandler,
            sanitizedUrl: '',
          ),
          openAppResult: const WechatLaunchResult(
            status: WechatLaunchStatus.launchFailed,
            sanitizedUrl: '',
          ),
        ),
      );
      final clipboard = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard.add((call.arguments as Map)['text'] as String);
            }
            return null;
          });

      final result = await runExecuteWechat(tester);

      expect(result.status, CampusActionStatus.fallbackAvailable);
      expect(clipboard, [testUrl]);
      expect(find.text('微信不支持外部直达该网页，链接已复制，请到微信中粘贴打开'), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, '复制链接'), findsOneWidget);
    });

    testWidgets('not_installed 提示未检测到微信并保留复制降级', (tester) async {
      WechatLauncher.instance.setGatewayForTesting(
        _FakeWechatGateway(
          openUrlResult: const WechatLaunchResult(
            status: WechatLaunchStatus.notInstalled,
            sanitizedUrl: '',
          ),
        ),
      );

      final result = await runExecuteWechat(tester);

      expect(result.status, CampusActionStatus.fallbackAvailable);
      expect(find.text('未检测到微信，可复制链接后到微信中打开'), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, '复制链接'), findsOneWidget);
    });

    testWidgets('unsupportedUrl 返回 failed 且不复制链接', (tester) async {
      final gateway = _FakeWechatGateway();
      WechatLauncher.instance.setGatewayForTesting(gateway);
      final clipboard = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard.add((call.arguments as Map)['text'] as String);
            }
            return null;
          });

      final result = await runExecuteWechat(
        tester,
        url: 'not a url',
        autoCopyOnFailure: true,
      );

      expect(result.status, CampusActionStatus.failed);
      // URL 校验在 launcher 内短路，不应触及 gateway。
      expect(gateway.urls, isEmpty);
      expect(clipboard, isEmpty);
      expect(find.text('链接格式不支持，无法在微信中打开'), findsOneWidget);
    });

    testWidgets('launchFailed 提供复制降级', (tester) async {
      WechatLauncher.instance.setGatewayForTesting(
        _FakeWechatGateway(
          openUrlResult: const WechatLaunchResult(
            status: WechatLaunchStatus.launchFailed,
            sanitizedUrl: '',
          ),
        ),
      );

      final result = await runExecuteWechat(tester);

      expect(result.status, CampusActionStatus.fallbackAvailable);
      expect(result.message, '无法拉起微信，请复制链接后到微信中打开');
      expect(find.text('无法拉起微信，请复制链接后到微信中打开'), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, '复制链接'), findsOneWidget);
    });

    testWidgets('snackbar 复制链接动作复制的是清理后的链接', (tester) async {
      WechatLauncher.instance.setGatewayForTesting(
        _FakeWechatGateway(
          openUrlResult: const WechatLaunchResult(
            status: WechatLaunchStatus.launchFailed,
            sanitizedUrl: '',
          ),
        ),
      );
      final clipboard = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard.add((call.arguments as Map)['text'] as String);
            }
            return null;
          });

      await runExecuteWechat(
        tester,
        url: 'https://example.cn/pay?code=abc&hdId=9',
      );

      await tester.tap(find.widgetWithText(SnackBarAction, '复制链接'));
      await tester.pumpAndSettle();

      // 一次性 code 不得进入剪贴板。
      expect(clipboard, ['https://example.cn/pay?hdId=9']);
      expect(find.text('链接已复制'), findsOneWidget);
    });
  });
}

/// 记录式 WechatGateway 替身：openUrl / openApp 结果可配置。
class _FakeWechatGateway implements WechatGateway {
  _FakeWechatGateway({
    this.openUrlResult = const WechatLaunchResult(
      status: WechatLaunchStatus.launched,
      sanitizedUrl: '',
    ),
    this.openAppResult = const WechatLaunchResult(
      status: WechatLaunchStatus.launched,
      sanitizedUrl: '',
    ),
  });

  WechatLaunchResult openUrlResult;
  WechatLaunchResult openAppResult;

  final urls = <String>[];
  int openAppCalls = 0;

  @override
  Future<WechatLaunchResult> openUrl(String sanitizedUrl) async {
    urls.add(sanitizedUrl);
    return openUrlResult;
  }

  @override
  Future<WechatLaunchResult> openApp() async {
    openAppCalls++;
    return openAppResult;
  }
}
