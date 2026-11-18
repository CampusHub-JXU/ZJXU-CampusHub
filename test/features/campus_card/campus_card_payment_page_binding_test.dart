import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:jxu_campus_hub/app/app_route_observer.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/epay100/epay100_gateway.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_payment_page.dart';
import 'package:jxu_campus_hub/features/campus_card/epay_payment_code_service.dart';
import 'package:jxu_campus_hub/shared/widgets/auth_required_view.dart';
import 'package:jxu_campus_hub/shared/widgets/unified_auth_protected_webview_page.dart';

import '../../helpers/test_setup.dart';

class _NoopGateway implements Epay100Gateway {
  @override
  Future<String> call(String method, Map<String, String> data) async => '';

  @override
  Future<void> invalidate() async {}

  @override
  void debugReset() {}
}

class _FakePaymentCodeService extends EpayPaymentCodeService {
  _FakePaymentCodeService({this.onFetch}) : super(gateway: _NoopGateway());

  Future<EpayPaymentCode> Function()? onFetch;
  int fetchCount = 0;

  @override
  Future<EpayPaymentCode> fetch() async {
    fetchCount++;
    if (onFetch != null) {
      return await onFetch!();
    }
    return const EpayPaymentCode(
      qrcode: 'default_test_qrcode_data',
      refreshAfter: Duration(seconds: 30),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '20260001',
    );
  });

  tearDown(() {
    UnifiedAuthService.instance.debugReset();
  });

  Widget buildSubject({
    EpayPaymentCodeService? service,
    ThemeData? theme,
    NavigatorObserver? observer,
  }) {
    return MaterialApp(
      theme: theme ?? ThemeData(useMaterial3: true),
      navigatorObservers: [appRouteObserver, ?observer],
      home: CampusCardPaymentPage(service: service),
    );
  }

  group('CampusCardPaymentPage C900901 / Binding Required State', () {
    testWidgets('1. C900901 -> 不显示QR，展示专属认证提示、官方入口及手动重试按钮', (tester) async {
      final service = _FakePaymentCodeService(
        onFetch: () async => throw const EpayBindingRequiredException(),
      );

      await tester.pumpWidget(buildSubject(service: service));
      await tester.pumpAndSettle();

      // 不显示二维码
      expect(find.byType(QrImageView), findsNothing);

      // 显示专属认证状态与提示，文案克制友好，不指责用户
      expect(find.text('需完成一卡通认证'), findsOneWidget);
      expect(find.text('请在官方页面完成认证或绑定，返回后重新获取。'), findsOneWidget);

      // 显示当前学工号
      expect(find.text('学工号: 20260001'), findsOneWidget);

      // 按钮：前往官方付款页 + 已完成，重新获取
      expect(find.text('前往官方付款页'), findsOneWidget);
      expect(find.text('已完成，重新获取'), findsOneWidget);

      // 不能宣称自动刷新或8秒定时循环
      expect(find.text('付款码自动定时刷新'), findsNothing);
      expect(find.text('8秒自动刷新'), findsNothing);
      expect(find.text('支付成功'), findsNothing);
    });

    testWidgets('2. 失败后等待 >60s 无任何自动 fetch', (tester) async {
      final service = _FakePaymentCodeService(
        onFetch: () async => throw const EpayBindingRequiredException(),
      );

      await tester.pumpWidget(buildSubject(service: service));
      await tester.pumpAndSettle();

      expect(service.fetchCount, 1);

      // 时间推进 65 秒，验证无自动刷新定时器
      await tester.pump(const Duration(seconds: 65));
      expect(service.fetchCount, 1);
    });

    testWidgets('3. paused/resumed 与 RouteAware didPushNext/pop 后均无自动 fetch', (
      tester,
    ) async {
      final service = _FakePaymentCodeService(
        onFetch: () async => throw const EpayBindingRequiredException(),
      );

      await tester.pumpWidget(buildSubject(service: service));
      await tester.pumpAndSettle();

      expect(service.fetchCount, 1);

      // 模拟切后台并返回 (paused -> resumed)
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      // 待认证状态下 resumed 不得自动重新取码
      expect(service.fetchCount, 1);

      // 模拟被遮挡并返回 (push route -> pop route)
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Overlay Route')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Overlay Route'), findsOneWidget);

      nav.pop();
      await tester.pumpAndSettle();

      // 返回后依然保持状态，不自动重新取码
      expect(find.text('需完成一卡通认证'), findsOneWidget);
      expect(service.fetchCount, 1);
    });

    testWidgets('4. 点击"前往官方付款页"清码打开网页，返回后依然保持该状态无自动 fetch', (tester) async {
      final service = _FakePaymentCodeService(
        onFetch: () async => throw const EpayBindingRequiredException(),
      );

      await tester.pumpWidget(buildSubject(service: service));
      await tester.pumpAndSettle();

      await tester.tap(find.text('前往官方付款页'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 打开官方网页
      expect(find.byType(UnifiedAuthProtectedWebViewPage), findsOneWidget);
      expect(find.text('官方付款码'), findsOneWidget);
      final official = tester.widget<UnifiedAuthProtectedWebViewPage>(
        find.byType(UnifiedAuthProtectedWebViewPage),
      );
      expect(official.emulateDingTalkEnvironment, isFalse);

      // 从官方网页返回
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.pop();
      await tester.pumpAndSettle();

      // 回到付款页，仍保持在需认证状态，且未发生自动取码
      expect(find.text('需完成一卡通认证'), findsOneWidget);
      expect(find.byType(QrImageView), findsNothing);
      expect(service.fetchCount, 1);
    });

    testWidgets('5. 手动重新获取："已完成，重新获取"重新调用，成功后恢复付款码与自动刷新', (tester) async {
      var callCount = 0;
      final service = _FakePaymentCodeService(
        onFetch: () async {
          callCount++;
          if (callCount == 1) {
            throw const EpayBindingRequiredException();
          }
          return const EpayPaymentCode(
            qrcode: 'recovered_payment_qr',
            refreshAfter: Duration(seconds: 30),
          );
        },
      );

      await tester.pumpWidget(buildSubject(service: service));
      await tester.pumpAndSettle();

      expect(find.text('需完成一卡通认证'), findsOneWidget);
      expect(find.byType(QrImageView), findsNothing);
      expect(service.fetchCount, 1);

      // 点击"已完成，重新获取"
      await tester.tap(find.text('已完成，重新获取'));
      await tester.pumpAndSettle();

      // 成功获取新码，渲染二维码并恢复正常提示
      expect(service.fetchCount, 2);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(
        find.byKey(const ValueKey('epay_qr_recovered_payment_qr')),
        findsOneWidget,
      );
      expect(find.text('付款码自动定时刷新'), findsOneWidget);
      expect(find.text('需完成一卡通认证'), findsNothing);

      // 验证定时器已正常恢复（30秒后自动刷新）
      await tester.pump(const Duration(seconds: 30));
      expect(service.fetchCount, 3);
    });

    testWidgets('6. 手动重新获取若依然失败，仍清码并停留在待认证状态', (tester) async {
      final service = _FakePaymentCodeService(
        onFetch: () async => throw const EpayBindingRequiredException(),
      );

      await tester.pumpWidget(buildSubject(service: service));
      await tester.pumpAndSettle();

      expect(find.text('需完成一卡通认证'), findsOneWidget);

      // 再次手动点击
      await tester.tap(find.text('已完成，重新获取'));
      await tester.pumpAndSettle();

      expect(service.fetchCount, 2);
      expect(find.text('需完成一卡通认证'), findsOneWidget);
      expect(find.byType(QrImageView), findsNothing);

      // 仍无定时器
      await tester.pump(const Duration(seconds: 60));
      expect(service.fetchCount, 2);
    });

    testWidgets('7. 同账号无意义 notify 不恢复自动取码；账号真正切换则清除状态并重新拉取', (tester) async {
      var currentAccount = '20260001';
      final service = _FakePaymentCodeService(
        onFetch: () async {
          if (currentAccount == '20260001') {
            throw const EpayBindingRequiredException();
          }
          return const EpayPaymentCode(
            qrcode: 'account_b_payment_qr',
            refreshAfter: Duration(seconds: 60),
          );
        },
      );

      await tester.pumpWidget(buildSubject(service: service));
      await tester.pumpAndSettle();

      expect(find.text('需完成一卡通认证'), findsOneWidget);
      expect(service.fetchCount, 1);

      // 同账号无意义通知（如刷新 token）
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '20260001',
      );
      UnifiedAuthService.instance.notifyListeners();
      await tester.pump();
      // 不得恢复自动取码
      expect(service.fetchCount, 1);
      expect(find.text('需完成一卡通认证'), findsOneWidget);

      // 账号真正切换为 20260002
      currentAccount = '20260002';
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '20260002',
      );
      UnifiedAuthService.instance.notifyListeners();
      await tester.pumpAndSettle();

      // 切换后清除该状态并自动为新账号取码
      expect(service.fetchCount, 2);
      expect(find.text('需完成一卡通认证'), findsNothing);
      expect(find.text('学工号: 20260002'), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(
        find.byKey(const ValueKey('epay_qr_account_b_payment_qr')),
        findsOneWidget,
      );
    });

    testWidgets('8. 登出时清除待认证状态并展示 AuthRequiredView', (tester) async {
      final service = _FakePaymentCodeService(
        onFetch: () async => throw const EpayBindingRequiredException(),
      );

      await tester.pumpWidget(buildSubject(service: service));
      await tester.pumpAndSettle();

      expect(find.text('需完成一卡通认证'), findsOneWidget);

      // 用户登出
      await UnifiedAuthService.instance.markLoggedOut();
      await tester.pumpAndSettle();

      expect(find.text('需完成一卡通认证'), findsNothing);
      expect(find.byType(AuthRequiredView), findsOneWidget);
      expect(find.text('需要登录一卡通后继续'), findsOneWidget);
    });
  });
}
