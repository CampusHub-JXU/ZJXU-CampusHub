import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:jxu_campus_hub/app/app_route_observer.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/epay100/epay100_gateway.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_payment_page.dart';
import 'package:jxu_campus_hub/features/campus_card/epay_payment_code_service.dart';
import 'package:jxu_campus_hub/shared/widgets/app_error_view.dart';
import 'package:jxu_campus_hub/shared/widgets/auth_required_view.dart';
import 'package:jxu_campus_hub/shared/widgets/unified_auth_protected_webview_page.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';
import '../../helpers/credential_store_test_ext.dart';

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

  /// 旧版备用码页走真实 EcardService → DioClient 链路；用仓库统一的
  /// MockHttpClientAdapter 在 Dio 层伪造 ecard 响应（不触真实网络）。
  ///
  /// 注意 widget 测试体运行在 FakeAsync 区：这里全部使用同步/微任务级 IO
  /// ——临时目录用 createTempSync，并清掉共享 Cookie 拦截器
  /// （FileStorage 的真实文件 IO 在 FakeAsync 区永远无法完成）。
  Future<MockHttpClientAdapter> initEcardMock() async {
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        '${Directory.systemTemp.createTempSync('ecard_test_').path}/'
        '$folderName/';
    await DioClient.instance.ensureInitialized();
    final adapter = MockHttpClientAdapter();
    DioClient.instance.dio.interceptors.clear();
    DioClient.instance.dio.httpClientAdapter = adapter;
    adapter
      ..registerJson('POST', '/QueryAccAuth.aspx', {'Code': '1', 'Msg': 'OK'})
      ..registerJson('POST', '/QueryAccInfoH.aspx', {
        'Code': '1',
        'AccName': '测试用户',
      })
      ..registerJson('POST', '/GetQRCodeInfo.aspx', {
        'Code': '0',
        'Msg': '待支付',
      });
    return adapter;
  }

  Widget buildSubject({
    EpayPaymentCodeService? service,
    ThemeData? theme,
    MediaQueryData? mediaQuery,
    NavigatorObserver? observer,
  }) {
    return MaterialApp(
      theme: theme ?? ThemeData(useMaterial3: true),
      navigatorObservers: [appRouteObserver, ?observer],
      home: mediaQuery != null
          ? MediaQuery(
              data: mediaQuery,
              child: CampusCardPaymentPage(service: service),
            )
          : CampusCardPaymentPage(service: service),
    );
  }

  group('CampusCardPaymentPage UI & Flow', () {
    testWidgets('1. loading -> QR: 正常展示付款码、学工号与安全警示，不显示支付结果', (tester) async {
      final completer = Completer<EpayPaymentCode>();
      final service = _FakePaymentCodeService(onFetch: () => completer.future);

      await tester.pumpWidget(buildSubject(service: service));

      // 正在加载时展示进度指示器，无二维码
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(QrImageView), findsNothing);

      // 请求成功，渲染二维码与中文提示
      completer.complete(
        const EpayPaymentCode(
          qrcode: 'test_student_payment_qr',
          refreshAfter: Duration(seconds: 60),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(QrImageView), findsOneWidget);
      expect(
        find.byKey(const ValueKey('epay_qr_test_student_payment_qr')),
        findsOneWidget,
      );
      // 禁止屏幕阅读器读出实际付款凭证
      expect(find.bySemanticsLabel('付款二维码'), findsOneWidget);
      expect(find.bySemanticsLabel('test_student_payment_qr'), findsNothing);

      // 学工号展示
      expect(find.text('学工号: 20260001'), findsOneWidget);

      // 扫码设备提示
      expect(find.text('请将二维码对准扫码设备'), findsOneWidget);

      // 安全提示文案必须存在
      expect(find.text('需要支付密码确认时，请使用官方付款页。此页面不显示支付结果。'), findsOneWidget);

      // 不能宣称支付成功
      expect(find.text('支付成功'), findsNothing);
    });

    testWidgets('2. manual refresh: 手动刷新立即清空旧码，新码返回后渲染新码', (tester) async {
      var fetchIndex = 0;
      Completer<EpayPaymentCode>? secondCompleter;

      final service = _FakePaymentCodeService(
        onFetch: () async {
          fetchIndex++;
          if (fetchIndex == 1) {
            return const EpayPaymentCode(
              qrcode: 'initial_code',
              refreshAfter: Duration(seconds: 30),
            );
          }
          secondCompleter = Completer<EpayPaymentCode>();
          return await secondCompleter!.future;
        },
      );

      await tester.pumpWidget(buildSubject(service: service));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('epay_qr_initial_code')),
        findsOneWidget,
      );

      // 点击手动刷新（内容超出测试视口，先滚动到可见）
      await tester.ensureVisible(find.text('手动刷新'));
      await tester.pump();
      await tester.tap(find.text('手动刷新'));
      await tester.pump();

      // 刷新开始：旧码必须立即清空，不留旧码
      expect(find.byType(QrImageView), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // 新码完成返回
      secondCompleter!.complete(
        const EpayPaymentCode(
          qrcode: 'refreshed_code',
          refreshAfter: Duration(seconds: 30),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(QrImageView), findsOneWidget);
      expect(
        find.byKey(const ValueKey('epay_qr_refreshed_code')),
        findsOneWidget,
      );
    });

    testWidgets('3. failure leaves no code: 刷新失败立即清码并显示错误，重试成功恢复', (
      tester,
    ) async {
      var shouldFail = false;
      final service = _FakePaymentCodeService(
        onFetch: () async {
          if (shouldFail) {
            throw const EpayGatewayException('网关连接超时，请重试');
          }
          return const EpayPaymentCode(
            qrcode: 'valid_code',
            refreshAfter: Duration(seconds: 30),
          );
        },
      );

      await tester.pumpWidget(buildSubject(service: service));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('epay_qr_valid_code')), findsOneWidget);

      // 设置下一次拉取失败
      shouldFail = true;
      await tester.ensureVisible(find.text('手动刷新'));
      await tester.pump();
      await tester.tap(find.text('手动刷新'));
      await tester.pumpAndSettle();

      // 失败不留码
      expect(find.byType(QrImageView), findsNothing);
      expect(find.byType(AppErrorView), findsOneWidget);
      expect(find.text('网关连接超时，请重试'), findsOneWidget);

      // 点击重试恢复
      shouldFail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.byKey(const ValueKey('epay_qr_valid_code')), findsOneWidget);
    });

    testWidgets('4. timer auto-refresh: 到达 refreshAfter 自动刷新并拉取新码', (
      tester,
    ) async {
      var count = 0;
      final service = _FakePaymentCodeService(
        onFetch: () async {
          count++;
          return EpayPaymentCode(
            qrcode: 'code_version_$count',
            refreshAfter: const Duration(seconds: 40),
          );
        },
      );

      await tester.pumpWidget(buildSubject(service: service));
      await tester.pumpAndSettle();

      expect(count, 1);
      expect(
        find.byKey(const ValueKey('epay_qr_code_version_1')),
        findsOneWidget,
      );

      // 推进 39 秒：未到刷新时间，不刷新
      await tester.pump(const Duration(seconds: 39));
      expect(count, 1);
      expect(
        find.byKey(const ValueKey('epay_qr_code_version_1')),
        findsOneWidget,
      );

      // 推进 2 秒到达 41 秒：触发自动刷新
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(count, 2);
      expect(
        find.byKey(const ValueKey('epay_qr_code_version_2')),
        findsOneWidget,
      );
    });

    testWidgets('5. lifecycle: 后台 paused 立即清码并取消计时，恢复前台重新取新码', (tester) async {
      var fetchCount = 0;
      final service = _FakePaymentCodeService(
        onFetch: () async {
          fetchCount++;
          return EpayPaymentCode(
            qrcode: 'lifecycle_code_$fetchCount',
            refreshAfter: const Duration(seconds: 60),
          );
        },
      );

      await tester.pumpWidget(buildSubject(service: service));
      await tester.pumpAndSettle();

      expect(fetchCount, 1);
      expect(find.byType(QrImageView), findsOneWidget);

      // 切到后台 paused：清码并取消计时。paused 状态下帧调度被禁用
      // （pump 仅在 hasScheduledFrame 时绘制），树面断言在 resumed 后进行。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      // 后台期间即使时间流逝，定时器不触发刷新
      await tester.pump(const Duration(seconds: 120));
      expect(fetchCount, 1);

      // 切回前台 resumed，重新获取新码
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(fetchCount, 2);
      expect(find.byType(QrImageView), findsOneWidget);
      // 旧码必须已被清掉，渲染的是新会话取回的码
      expect(
        find.byKey(const ValueKey('epay_qr_lifecycle_code_1')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('epay_qr_lifecycle_code_2')),
        findsOneWidget,
      );
    });

    testWidgets(
      '6. route awareness: 路由被遮挡 (didPushNext) 清码，返回 (didPopNext) 重取新码',
      (tester) async {
        var count = 0;
        final service = _FakePaymentCodeService(
          onFetch: () async {
            count++;
            return EpayPaymentCode(
              qrcode: 'route_code_$count',
              refreshAfter: const Duration(seconds: 30),
            );
          },
        );

        await tester.pumpWidget(buildSubject(service: service));
        await tester.pumpAndSettle();

        expect(count, 1);
        expect(find.byType(QrImageView), findsOneWidget);

        final nav = tester.state<NavigatorState>(find.byType(Navigator));

        // Push 新页面遮挡当前页面
        nav.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Sub Page')),
          ),
        );
        await tester.pumpAndSettle();

        // 当前页面已被遮挡，新页面在上
        expect(find.text('Sub Page'), findsOneWidget);

        // Pop 回到付款码页面
        nav.pop();
        await tester.pumpAndSettle();

        // didPopNext 触发重新获取新码
        expect(count, 2);
        expect(
          find.byKey(const ValueKey('epay_qr_route_code_2')),
          findsOneWidget,
        );
      },
    );

    testWidgets('7. pending response generation: 丢弃迟到响应，只认最新 generation', (
      tester,
    ) async {
      var call = 0;
      Completer<EpayPaymentCode>? completer1;
      Completer<EpayPaymentCode>? completer2;

      final service = _FakePaymentCodeService(
        onFetch: () async {
          call++;
          if (call == 1) {
            return const EpayPaymentCode(
              qrcode: 'initial_code_gen1',
              refreshAfter: Duration(seconds: 60),
            );
          }
          if (call == 2) {
            completer1 = Completer<EpayPaymentCode>();
            return await completer1!.future;
          }
          completer2 = Completer<EpayPaymentCode>();
          return await completer2!.future;
        },
      );

      await tester.pumpWidget(buildSubject(service: service));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('epay_qr_initial_code_gen1')),
        findsOneWidget,
      );

      // 第一次刷新（生成代数 2），此时请求挂起
      await tester.ensureVisible(find.text('手动刷新'));
      await tester.pump();
      await tester.tap(find.text('手动刷新'));
      await tester.pump();
      expect(call, 2);

      // 路由离开再回来，或者用户切回前台触发生成代数 3
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(call, 3);

      // 迟到的第二代响应返回
      completer1!.complete(
        const EpayPaymentCode(
          qrcode: 'late_obsolete_code',
          refreshAfter: Duration(seconds: 30),
        ),
      );
      await tester.pump();

      // 迟到响应必须被丢弃，不能渲染
      expect(
        find.byKey(const ValueKey('epay_qr_late_obsolete_code')),
        findsNothing,
      );

      // 第三代响应返回
      completer2!.complete(
        const EpayPaymentCode(
          qrcode: 'fresh_generation_code',
          refreshAfter: Duration(seconds: 30),
        ),
      );
      await tester.pumpAndSettle();

      // 正确渲染第三代响应
      expect(find.byType(QrImageView), findsOneWidget);
      expect(
        find.byKey(const ValueKey('epay_qr_fresh_generation_code')),
        findsOneWidget,
      );
    });

    testWidgets('8. auth change: 请求期间切换账号绝不把 A 的码展示给 B', (tester) async {
      final completer = Completer<EpayPaymentCode>();
      final service = _FakePaymentCodeService(onFetch: () => completer.future);

      await tester.pumpWidget(buildSubject(service: service));
      await tester.pump();

      // 请求正在进行中，切换账号为 student_B
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'student_B',
      );

      // A 账号的请求返回
      completer.complete(
        const EpayPaymentCode(
          qrcode: 'account_A_code',
          refreshAfter: Duration(seconds: 30),
        ),
      );
      await tester.pumpAndSettle();

      // A 的码被丢弃，决不能展示
      expect(
        find.byKey(const ValueKey('epay_qr_account_A_code')),
        findsNothing,
      );
      expect(find.bySemanticsLabel('account_A_code'), findsNothing);

      // 登出后立即清码并显示未登录
      await UnifiedAuthService.instance.markLoggedOut();
      await tester.pumpAndSettle();

      expect(find.byType(QrImageView), findsNothing);
      expect(find.byType(AuthRequiredView), findsOneWidget);
    });

    testWidgets('9. auth error: 未登录或会话不可用时展示 AuthRequiredView', (tester) async {
      UnifiedAuthService.instance.debugSetSession(active: false);

      await tester.pumpWidget(buildSubject());
      await tester.pumpAndSettle();

      expect(find.byType(AuthRequiredView), findsOneWidget);
      expect(find.text('需要登录一卡通后继续'), findsOneWidget);
      expect(find.text('登录一卡通'), findsOneWidget);
    });

    testWidgets('10. official entry vs old entry isolation: 官方与旧入口隔离', (
      tester,
    ) async {
      final service = _FakePaymentCodeService();

      await tester.pumpWidget(buildSubject(service: service));
      await tester.pumpAndSettle();

      // 点击官方付款页（底部按钮，先滚动到可见）
      await tester.ensureVisible(find.text('官方付款页'));
      await tester.pump();
      await tester.tap(find.text('官方付款页'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 验证直达官方 epay URL，并开启 warmUpAsResource
      expect(find.byType(UnifiedAuthProtectedWebViewPage), findsOneWidget);
      final webView = tester.widget<UnifiedAuthProtectedWebViewPage>(
        find.byType(UnifiedAuthProtectedWebViewPage),
      );
      expect(webView.url, EpayPaymentCodeService.officialUrl);
      expect(webView.warmUpAsResource, isTrue);
      expect(webView.emulateDingTalkEnvironment, isFalse);

      // 返回
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.pop();
      await tester.pumpAndSettle();

      // 点击旧版备用码
      await tester.ensureVisible(find.text('遇到兼容问题？使用旧版备用码'));
      await tester.pump();
      await tester.tap(find.text('遇到兼容问题？使用旧版备用码'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 验证打开的是旧版备用码页面
      expect(find.byType(CampusCardFallbackPaymentPage), findsOneWidget);
    });

    testWidgets('11. large text scaling & dark theme: 大字与深色主题适配良好', (
      tester,
    ) async {
      final service = _FakePaymentCodeService();

      // 大字 2.0 倍布局测试（确保不会 RenderFlex 溢出）
      await tester.pumpWidget(
        buildSubject(
          service: service,
          mediaQuery: const MediaQueryData(
            textScaler: TextScaler.linear(2.0),
            size: Size(400, 800),
          ),
          theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        ),
      );
      await tester.pumpAndSettle();

      // 无渲染溢出，二维码正常渲染
      expect(find.byType(QrImageView), findsOneWidget);

      // 验证深色模式下二维码依然强制白底黑码
      final qr = tester.widget<QrImageView>(find.byType(QrImageView));
      expect(qr.backgroundColor, Colors.white);
      expect(qr.eyeStyle.color, Colors.black);
      expect(qr.dataModuleStyle.color, Colors.black);
    });

    testWidgets('12. race condition: 在途请求期间切到后台 paused，响应返回后不渲染二维码', (
      tester,
    ) async {
      final completer = Completer<EpayPaymentCode>();
      final service = _FakePaymentCodeService(onFetch: () => completer.future);

      await tester.pumpWidget(buildSubject(service: service));
      await tester.pump();

      // 在途请求期间，切到后台 paused
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      // 挂起的请求在后台期间完成
      completer.complete(
        const EpayPaymentCode(
          qrcode: 'background_late_code',
          refreshAfter: Duration(seconds: 30),
        ),
      );
      await tester.pump();

      // 迟到响应被丢弃，依然没有二维码
      expect(find.byType(QrImageView), findsNothing);
    });

    testWidgets('13. race condition: 在途请求期间路由被遮挡 (didPushNext)，响应返回后不渲染二维码', (
      tester,
    ) async {
      final completer = Completer<EpayPaymentCode>();
      final service = _FakePaymentCodeService(onFetch: () => completer.future);

      await tester.pumpWidget(buildSubject(service: service));
      await tester.pump();

      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Overlay Page')),
        ),
      );
      await tester.pumpAndSettle();

      // 在遮挡期间请求完成
      completer.complete(
        const EpayPaymentCode(
          qrcode: 'obscured_late_code',
          refreshAfter: Duration(seconds: 30),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('epay_qr_obscured_late_code')),
        findsNothing,
      );
      expect(find.byType(QrImageView), findsNothing);
    });

    testWidgets('14. race condition: A 登出再重新登录同一账号 A，旧在途请求返回被拒绝', (
      tester,
    ) async {
      final completer = Completer<EpayPaymentCode>();
      var fetchCount = 0;
      Completer<EpayPaymentCode>? completer2;

      final service = _FakePaymentCodeService(
        onFetch: () async {
          fetchCount++;
          if (fetchCount == 1) return await completer.future;
          completer2 = Completer<EpayPaymentCode>();
          return await completer2!.future;
        },
      );

      await tester.pumpWidget(buildSubject(service: service));
      await tester.pump();
      expect(fetchCount, 1);

      // 登出
      await UnifiedAuthService.instance.markLoggedOut();
      await tester.pumpAndSettle();

      // 重新登录同一账号 '20260001'（登出已清内存态与持久会话；
      // saveUnifiedAuthSession 落盘 + restoreSession 真实身份变化 → 通知）
      await CredentialStore.instance.saveUnifiedAuthSession('20260001');
      await UnifiedAuthService.instance.restoreSession(
        syncWebViewCookies: false,
      );
      await tester.pump();
      expect(fetchCount, 2);

      // 旧的第一个请求完成返回
      completer.complete(
        const EpayPaymentCode(
          qrcode: 'stale_pre_logout_code',
          refreshAfter: Duration(seconds: 30),
        ),
      );
      await tester.pump();

      // 旧请求因 epoch/generation 不匹配必须被拒绝，绝不渲染
      expect(
        find.byKey(const ValueKey('epay_qr_stale_pre_logout_code')),
        findsNothing,
      );

      // 第二次请求完成
      completer2!.complete(
        const EpayPaymentCode(
          qrcode: 'new_session_code',
          refreshAfter: Duration(seconds: 30),
        ),
      );
      await tester.pumpAndSettle();

      // 渲染新 session 的码
      expect(
        find.byKey(const ValueKey('epay_qr_new_session_code')),
        findsOneWidget,
      );
    });

    testWidgets('15. old fallback: 正常出码后，登出立即清码并提示登录', (tester) async {
      await CredentialStore.instance.saveUnifiedAuthCredentials(
        '20260001',
        'pass',
      );
      final adapter = await initEcardMock();
      adapter.registerJson('POST', '/GetQRCode.aspx', {
        'Code': '1',
        'QRCode': 'fallback_init_code',
      });

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [appRouteObserver],
          home: CampusCardFallbackPaymentPage(routeObserver: appRouteObserver),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(QrImageView), findsOneWidget);

      // 登出统一认证
      await UnifiedAuthService.instance.markLoggedOut();
      await tester.pumpAndSettle();

      // 码被清空，显示未登录提示
      expect(find.byType(QrImageView), findsNothing);
      expect(find.text('请先登录一卡通'), findsOneWidget);
    });

    testWidgets('16. old fallback security: 当前登录 B 而本地凭据为 A 时，绝不用 A 的凭据出码', (
      tester,
    ) async {
      // 本地存储仍是 A 的凭据，当前登录账号已切到 B（登录通知先于凭据落盘）。
      await CredentialStore.instance.saveUnifiedAuthCredentials(
        '20260001',
        'pass',
      );
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '20260002',
      );
      final adapter = await initEcardMock();
      adapter.registerJson('POST', '/GetQRCode.aspx', {
        'Code': '1',
        'QRCode': 'should_never_render',
      });

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [appRouteObserver],
          home: CampusCardFallbackPaymentPage(routeObserver: appRouteObserver),
        ),
      );
      await tester.pumpAndSettle();

      // 学号与登录账号不一致：不发出任何 ecard 请求
      expect(adapter.requestLog, isEmpty);
      // 绝不渲染任何二维码
      expect(find.byType(QrImageView), findsNothing);
      // 给出明确的重新登录提示
      expect(find.text('登录凭据与当前账号不一致，请重新登录一卡通'), findsOneWidget);
    });

    testWidgets('17. old fallback security: 同账号 logout→login，旧在途出码响应不被应用', (
      tester,
    ) async {
      await CredentialStore.instance.saveUnifiedAuthCredentials(
        '20260001',
        'pass',
      );
      final adapter = await initEcardMock();

      // 第一轮 initialize 的 GetQRCode 挂起，模拟在途请求。
      final qrGate = Completer<ResponseBody>();
      var qrCalls = 0;
      adapter.register('POST', '/GetQRCode.aspx', (options) async {
        qrCalls++;
        if (qrCalls == 1) return await qrGate.future;
        return ResponseBody.fromString(
          jsonEncode({'Code': '1', 'QRCode': 'fresh_relogin_code'}),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      });

      // 捕获状态轮询使用的 QRCode，证明旧码从未进入轮询/应用流程。
      final polledQrCodes = <String>[];
      adapter.register('POST', '/GetQRCodeInfo.aspx', (options) async {
        final raw = options.data;
        final params = raw is Map
            ? raw.map((k, v) => MapEntry(k.toString(), v.toString()))
            : Uri.splitQueryString(raw?.toString() ?? '');
        polledQrCodes.add(params['QRCode'] ?? '');
        return ResponseBody.fromString(
          jsonEncode({'Code': '0', 'Msg': '待支付'}),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      });

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [appRouteObserver],
          home: CampusCardFallbackPaymentPage(routeObserver: appRouteObserver),
        ),
      );
      // dio 请求链经事件循环 Timer 推进：有限步进假时钟直到首个请求挂起
      // 在 GetQRCode 闸门上（loading spinner 持续产帧，此处不能用
      // pumpAndSettle，否则无限等待）。
      for (var i = 0; i < 20 && qrCalls < 1; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(qrCalls, 1);

      // 登出
      await UnifiedAuthService.instance.markLoggedOut();
      await tester.pumpAndSettle();
      expect(find.text('请先登录一卡通'), findsOneWidget);

      // 同账号 A 重新登录（登出已清内存态与持久会话；落盘 + restoreSession
      // 真实身份变化 null→A → 触发会话通知）
      await CredentialStore.instance.saveUnifiedAuthSession('20260001');
      await UnifiedAuthService.instance.restoreSession(
        syncWebViewCookies: false,
      );
      // 有限步进假时钟直到第二轮出码完成（此阶段 spinner 产帧，
      // pumpAndSettle 在链路未完成前会无限等待）
      for (var i = 0; i < 20 && qrCalls < 2; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(qrCalls, 2);

      // 新会话的码已渲染
      expect(find.byType(QrImageView), findsOneWidget);

      // 旧会话的 GetQRCode 响应此时才返回：epoch/generation 已变，必须丢弃
      qrGate.complete(
        ResponseBody.fromString(
          jsonEncode({'Code': '1', 'QRCode': 'stale_pre_logout_code'}),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
      await tester.pumpAndSettle();

      // 旧响应被丢弃：不再触发新一轮出码，旧码也从未进入状态轮询
      expect(qrCalls, 2);
      expect(polledQrCodes, everyElement('fresh_relogin_code'));
      expect(find.byType(QrImageView), findsOneWidget);
    });

    testWidgets(
      '18. old fallback security: QueryAccAuth 在途登出后，后续 ecard 请求零发送',
      (tester) async {
        await CredentialStore.instance.saveUnifiedAuthCredentials(
          '20260001',
          'pass',
        );
        final adapter = await initEcardMock();
        // 认证请求挂起，模拟在途
        final authGate = Completer<ResponseBody>();
        adapter.register('POST', '/QueryAccAuth.aspx', (options) async {
          return await authGate.future;
        });

        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [appRouteObserver],
            home: CampusCardFallbackPaymentPage(
              routeObserver: appRouteObserver,
            ),
          ),
        );
        for (var i = 0; i < 20 && adapter.requestLog.isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(adapter.requestLog, ['POST /QueryAccAuth.aspx']);

        // 认证在途期间登出
        await UnifiedAuthService.instance.markLoggedOut();
        await tester.pumpAndSettle();
        expect(find.text('请先登录一卡通'), findsOneWidget);

        // 认证响应此时才返回：guard 拦截，后续 QueryAccInfoH/GetQRCode 零发送
        authGate.complete(
          ResponseBody.fromString(
            jsonEncode({'Code': '1'}),
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          ),
        );
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(adapter.requestLog, ['POST /QueryAccAuth.aspx']);
        expect(find.byType(QrImageView), findsNothing);
      },
    );

    testWidgets('19. old fallback RouteAware: didPushNext 清码，didPopNext 重取新码', (
      tester,
    ) async {
      await CredentialStore.instance.saveUnifiedAuthCredentials(
        '20260001',
        'pass',
      );
      final adapter = await initEcardMock();
      var qrCalls = 0;
      adapter.register('POST', '/GetQRCode.aspx', (options) async {
        qrCalls++;
        return ResponseBody.fromString(
          jsonEncode({'Code': '1', 'QRCode': 'fallback_route_code_$qrCalls'}),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      });

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [appRouteObserver],
          home: CampusCardFallbackPaymentPage(routeObserver: appRouteObserver),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsOneWidget);
      expect(qrCalls, 1);

      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Sub Page')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sub Page'), findsOneWidget);
      // 被遮挡的旧页仍在树中：必须真清码，不能只靠 offstage 藏起来。
      expect(find.byType(QrImageView, skipOffstage: false), findsNothing);

      nav.pop();
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsOneWidget);
      expect(qrCalls, 2);
    });
  });
}
