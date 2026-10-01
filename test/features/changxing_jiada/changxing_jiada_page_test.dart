import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_model.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_page.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_service.dart';
import 'package:jxu_campus_hub/shared/widgets/app_error_view.dart';
import 'package:jxu_campus_hub/shared/widgets/auth_required_view.dart';
import 'package:jxu_campus_hub/shared/widgets/login_shell.dart';
import 'package:jxu_campus_hub/shared/widgets/webview_page.dart';

import '../../helpers/test_setup.dart';

ChangxingUserProfile _profile({String name = '李明'}) => ChangxingUserProfile(
  name: name,
  jobNo: '20260001',
  phone: '13800000000',
  emergencyContact: '家长',
  emergencyPhone: '13900000000',
);

ChangxingApplication _application({String userName = '王小明'}) =>
    ChangxingApplication(
      id: 1,
      type: 1,
      status: 0,
      userName: userName,
      departmentName: '计算机261',
      userJobNo: '20260001',
      userPhone: '13800000000',
      descr: '临时请假',
      remark: '',
      trafficTool: '火车',
      backStatus: 0,
      notBackReason: '',
      emergencyContact: '家长',
      emergencyPhone: '13900000000',
      startTime: DateTime(2026, 9, 1, 8),
      endTime: DateTime(2026, 9, 2, 18),
      upTime: DateTime(2026, 9, 1, 9),
    );

ChangxingDashboardSnapshot _snapshot({
  String name = '李明',
  List<ChangxingApplication>? applications,
}) => (
  profile: _profile(name: name),
  unreadCount: 2,
  applications: applications ?? [_application()],
);

/// 关闭统一认证登录弹窗（等价于关闭按钮 / 点遮罩）。
Future<void> _dismissLoginModal(WidgetTester tester, {required bool ok}) async {
  Navigator.of(
    tester.element(find.byType(LoginShell)),
    rootNavigator: true,
  ).pop(ok);
  await tester.pumpAndSettle();
}

/// 等待统一认证登录弹窗入场（弹窗打开期间不可 pumpAndSettle）。
Future<void> _pumpLoginModal(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() async {
    await resetTestEnvironment();
    ChangxingJiadaService.instance.debugReset();
  });

  testWidgets('明确未认证时首屏直接弹原生统一认证登录，且不发起 CAS 链路', (tester) async {
    var casCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChangxingJiadaPage(
          sessionRestorer: () async => false,
          casLogin: () async {
            casCalls++;
            throw StateError('明确未认证时不应发起 CAS 登录');
          },
          dashboardFetcher: () async => throw StateError('不应加载数据'),
        ),
      ),
    );
    await _pumpLoginModal(tester);

    // 直接弹原生统一认证登录弹窗（原生表单），不是 CAS H5、也没有全屏加载页中转。
    expect(find.byType(LoginShell), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
    expect(find.byType(WebViewPage), findsNothing);
    expect(casCalls, 0);

    // 背后是同一稳定 Scaffold：标题常驻，无第二个 Scaffold 交替。
    expect(find.text(ChangxingJiadaPage.titleText), findsOneWidget);
    expect(find.text('正在连接校园通行服务…'), findsOneWidget);

    // 收尾：取消后落到可重试的登录提示（弹窗一次性，不自动重弹）。
    await _dismissLoginModal(tester, ok: false);
    expect(find.byType(LoginShell), findsNothing);
    expect(find.byType(AuthRequiredView), findsOneWidget);
    expect(find.text('已取消登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('登录弹窗一次性：取消后不自动重弹，点「登录」可再次唤起', (tester) async {
    var casCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChangxingJiadaPage(
          sessionRestorer: () async => false,
          casLogin: () async {
            casCalls++;
            throw StateError('取消登录后不应发起 CAS 登录');
          },
          dashboardFetcher: () async => throw StateError('不应加载数据'),
        ),
      ),
    );
    await _pumpLoginModal(tester);
    expect(find.byType(LoginShell), findsOneWidget);

    // 取消：一次性关闭，停在提示态，绝不自动重弹。
    await _dismissLoginModal(tester, ok: false);
    expect(find.byType(LoginShell), findsNothing);
    expect(find.byType(AuthRequiredView), findsOneWidget);
    expect(find.text('已取消登录'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(casCalls, 0);

    // 明确的单次重试动作：点「登录」再唤起一次。
    await tester.tap(find.text('登录'));
    await _pumpLoginModal(tester);
    expect(find.byType(LoginShell), findsOneWidget);
    expect(find.byType(WebViewPage), findsNothing);

    // 再次取消仍不循环。
    await _dismissLoginModal(tester, ok: false);
    expect(find.byType(LoginShell), findsNothing);
    expect(find.byType(AuthRequiredView), findsOneWidget);
    expect(casCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('统一认证登录成功后自动继续到仪表盘，无需二次点击', (tester) async {
    var casCalls = 0;
    var loadCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChangxingJiadaPage(
          sessionRestorer: () async => false,
          casLogin: () async => casCalls++,
          signOut: () async {},
          dashboardFetcher: () async {
            loadCalls++;
            return _snapshot();
          },
        ),
      ),
    );
    await _pumpLoginModal(tester);
    expect(find.byType(LoginShell), findsOneWidget);

    // 模拟统一认证登录成功并关闭弹窗。
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '20260001',
    );
    await _dismissLoginModal(tester, ok: true);

    // 登录成功自动继续：无需再点任何按钮即达仪表盘。
    expect(find.byType(LoginShell), findsNothing);
    expect(find.byType(AuthRequiredView), findsNothing);
    expect(find.byType(AppErrorView), findsNothing);
    expect(find.text('李明'), findsOneWidget);
    expect(find.text('快速办理'), findsOneWidget);
    expect(find.text('请假申请'), findsOneWidget);
    expect(find.text('离校登记'), findsOneWidget);
    expect(find.text('返校登记'), findsOneWidget);
    expect(find.text('超时登记'), findsOneWidget);

    // 「我的申请」在首屏之下（ListView 懒构建），滚入视口后再断言。
    await tester.drag(find.byType(ListView), const Offset(0, -350));
    await tester.pumpAndSettle();
    expect(find.textContaining('我的申请 · '), findsOneWidget);
    expect(find.text('王小明'), findsOneWidget);
    expect(casCalls, 1);
    expect(loadCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('CAS 网络失败不弹登录框，单次有意义重试后直达仪表盘', (tester) async {
    // 已明确认证（会话 active）：网络未知失败不得被当作认证失效弹登录框。
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '20260001',
    );
    var casCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChangxingJiadaPage(
          sessionRestorer: () async => false,
          casLogin: () async {
            casCalls++;
            if (casCalls == 1) {
              throw ChangxingCasLoginException('网络异常：connection timeout');
            }
          },
          dashboardFetcher: () async => _snapshot(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 网络未知 ≠ 认证失效：停在可重试的失败态，绝不弹统一认证登录框。
    expect(find.byType(LoginShell), findsNothing);
    expect(find.byType(AppErrorView), findsOneWidget);
    expect(find.text('登录失败'), findsOneWidget);
    expect(find.text('网络异常：connection timeout'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(casCalls, 1);

    // 一次明确重试 = 一次新尝试；成功后自动进仪表盘。
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(casCalls, 2);
    expect(find.byType(LoginShell), findsNothing);
    expect(find.byType(AppErrorView), findsNothing);
    expect(find.text('快速办理'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('恢复到有效 token 时直达仪表盘，退出登录回到登录提示', (tester) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '20260001',
    );
    var casCalls = 0;
    var signOutCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChangxingJiadaPage(
          sessionRestorer: () async => true,
          casLogin: () async {
            casCalls++;
            throw StateError('已有 token 不应重新登录');
          },
          signOut: () async => signOutCalls++,
          dashboardFetcher: () async => _snapshot(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 已登录仪表盘行为保留：数据 + 刷新/退出按钮，全程不弹登录框。
    expect(find.byType(LoginShell), findsNothing);
    expect(find.text('快速办理'), findsOneWidget);
    expect(find.text('李明'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(find.byIcon(Icons.logout), findsOneWidget);
    expect(casCalls, 0);

    // 退出登录：落到登录提示（不自动弹窗）。
    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();
    expect(signOutCalls, 1);
    expect(find.byType(LoginShell), findsNothing);
    expect(find.byType(AuthRequiredView), findsOneWidget);
    expect(find.text('已退出登录'), findsOneWidget);
    expect(find.text('快速办理'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('业务 token 明确过期落到「重新登录」提示，不自动循环弹窗', (tester) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '20260001',
    );
    var loadCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChangxingJiadaPage(
          sessionRestorer: () async => true,
          casLogin: () async => throw StateError('不应重新走 CAS'),
          dashboardFetcher: () async {
            loadCalls++;
            if (loadCalls == 1) return _snapshot();
            throw ChangxingAuthExpiredException();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('快速办理'), findsOneWidget);

    // 刷新触发 token 过期：明确过期也不自动循环弹登录框，只给一次「重新登录」动作。
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(loadCalls, 2);
    expect(find.byType(LoginShell), findsNothing);
    expect(find.byType(AuthRequiredView), findsOneWidget);
    expect(find.text('登录已失效'), findsOneWidget);
    expect(find.text('重新登录'), findsOneWidget);
    expect(find.text('快速办理'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('统一认证 A→B 切换立即清空 A 仪表盘，且不为 B 弹登录弹窗', (tester) async {
    UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
    var casCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChangxingJiadaPage(
          sessionRestorer: () async => true,
          casLogin: () async => casCalls++,
          dashboardFetcher: () async {
            final owner = UnifiedAuthService.instance.currentAccount;
            return _snapshot(name: 'user-$owner');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('user-A'), findsOneWidget);

    // A→B：A 的仪表盘必须立即清空，不残留任何 A 的数据。
    UnifiedAuthService.instance.debugSetSession(active: false, account: null);
    UnifiedAuthService.instance.notifyListeners();
    await tester.pump();
    expect(find.text('user-A'), findsNothing);
    expect(find.text('快速办理'), findsNothing);

    // B 登录：走有界进入路径（不弹统一认证弹窗），只渲染 B 的数据。
    UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
    UnifiedAuthService.instance.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(LoginShell), findsNothing);
    expect(find.text('user-A'), findsNothing);
    expect(find.text('user-B'), findsOneWidget);
    expect(casCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('登出时在途仪表盘响应被丢弃，不渲染旧账号数据', (tester) async {
    UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
    final gate = Completer<ChangxingDashboardSnapshot>();
    await tester.pumpWidget(
      MaterialApp(
        home: ChangxingJiadaPage(
          sessionRestorer: () async => true,
          casLogin: () async => throw StateError('登出后不得自动 CAS 登录'),
          dashboardFetcher: () => gate.future,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('快速办理'), findsNothing);

    // 登出：页面立即清空；在途响应虽然稍后返回，但身份戳已作废。
    UnifiedAuthService.instance.debugSetSession(active: false, account: null);
    UnifiedAuthService.instance.notifyListeners();
    await tester.pump();
    expect(find.byType(AuthRequiredView), findsOneWidget);
    expect(find.text('已退出登录'), findsOneWidget);

    gate.complete(_snapshot());
    await tester.pumpAndSettle();
    expect(find.text('快速办理'), findsNothing);
    expect(find.text('李明'), findsNothing);
    expect(find.byType(AuthRequiredView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同账号重登丢弃重登前的迟到仪表盘响应', (tester) async {
    UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
    final gate = Completer<ChangxingDashboardSnapshot>();
    var fetchCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChangxingJiadaPage(
          sessionRestorer: () async => true,
          casLogin: () async => throw StateError('重登后已有 token，不应走 CAS'),
          dashboardFetcher: () {
            fetchCalls++;
            if (fetchCalls == 1) return gate.future;
            return Future.value(_snapshot(name: '新会话'));
          },
        ),
      ),
    );
    await tester.pump();
    expect(find.text('新会话'), findsNothing);

    // 同账号重登：登出 + 再登录，sessionRevision 推进。
    UnifiedAuthService.instance.debugSetSession(active: false, account: null);
    UnifiedAuthService.instance.notifyListeners();
    await tester.pump();
    UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
    UnifiedAuthService.instance.notifyListeners();
    await tester.pump();
    // 旧请求仍挂起：连接中，绝不渲染旧数据。
    expect(find.text('旧会话'), findsNothing);

    // 旧会话的迟到响应到达：必须被丢弃，随后为新身份续走一次新的抓取。
    gate.complete(_snapshot(name: '旧会话'));
    await tester.pumpAndSettle();
    expect(find.text('旧会话'), findsNothing);
    expect(find.text('新会话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
