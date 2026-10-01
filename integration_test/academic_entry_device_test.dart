import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:jxu_campus_hub/app/app.dart';
import 'package:jxu_campus_hub/app/app_bootstrap_controller.dart';
import 'package:jxu_campus_hub/core/auth/academic_web_entry_preparer.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_nav_bar.dart';
import 'package:jxu_campus_hub/shared/widgets/login_shell.dart';
import 'package:jxu_campus_hub/shared/widgets/academic_web_entry_page.dart';

/// 设备端 UI 流程：真实 App 启动 → 底部 dock → 「我的」页 → 点开教务受信入口
/// → 读取 `AcademicWebEntryPageState.debugStatus` → 登出确认框「返回」取消
/// → 标签页往返。
///
/// 边界（与 `docs/agents/testing.md` 的设备集成纪律一致）：
/// - **不登录、不提交任何凭据、不输入账号 / 密码**；本文件只做导航与状态读取。
/// - 会话来自设备上已存在的持久登录态：这里只调用无网络的
///   `restoreSession`（读凭据元数据），**不**跑暖启动里的静默自动登录。
/// - 所有等待都有有界超时；绝不使用无界 `pumpAndSettle` 等网络驱动状态。
/// - 每个断言都带 label + 观测值，失败可从日志直接定位。
const String _tag = 'ACADEMIC_DEVICE_TEST';

/// 首屏 / 页面元素渲染预算。
const Duration _renderBudget = Duration(seconds: 15);

/// 点按「教务系统」→ 入口页出现的预算。
const Duration _openBudget = Duration(seconds: 45);

/// 入口页 `preparing` → 终态的预算（preparer 自身总预算 20s）。
const Duration _terminalBudget = Duration(seconds: 60);

/// 单次重试点按之间的等待窗口（处理「教务状态未知时首点只触发重新校验」）。
const Duration _retapSlice = Duration(seconds: 8);

void _log(String label, Object? value) {
  debugPrint('$_tag | $label = $value');
}

/// 有界推进真实时间（live binding 下 `pump(duration)` 为真实延迟）。
Future<void> _pumpFor(
  WidgetTester tester,
  Duration total, {
  Duration step = const Duration(milliseconds: 100),
}) async {
  final int steps = (total.inMilliseconds / step.inMilliseconds).ceil();
  for (var i = 0; i < steps; i++) {
    await tester.pump(step);
  }
}

/// 在预算内轮询 finder 直到命中。
Future<bool> _awaitFinder(
  WidgetTester tester,
  Finder finder,
  Duration budget,
) async {
  final DateTime deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    if (finder.evaluate().isNotEmpty) return true;
    await tester.pump(const Duration(milliseconds: 150));
  }
  return finder.evaluate().isNotEmpty;
}

/// 轮询入口页状态直到离开 `preparing`（或页面消失 / 超预算）。
///
/// 返回 `null` 表示页面已从树上移除；返回 `preparing` 表示超预算仍卡住。
Future<AcademicEntryPageStatus?> _pollTerminalStatus(
  WidgetTester tester,
  Finder pageFinder,
  Duration budget,
) async {
  final DateTime deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    if (pageFinder.evaluate().isEmpty) return null;
    final AcademicWebEntryPageState state = tester
        .state<AcademicWebEntryPageState>(pageFinder);
    if (state.debugStatus != AcademicEntryPageStatus.preparing) {
      return state.debugStatus;
    }
    await tester.pump(const Duration(milliseconds: 250));
  }
  if (pageFinder.evaluate().isEmpty) return null;
  return tester.state<AcademicWebEntryPageState>(pageFinder).debugStatus;
}

/// 关闭可能自动弹出的登录弹窗（**只取消，不填任何凭据**）。
Future<void> _dismissLoginShellIfAny(WidgetTester tester) async {
  final Finder modal = find.byType(LoginShell);
  if (modal.evaluate().isEmpty) return;
  _log('dismissLoginShell', 'present -> cancel via root pop');
  try {
    final BuildContext ctx = tester.element(modal.first);
    Navigator.of(ctx, rootNavigator: true).pop(false);
  } catch (error) {
    _log('dismissLoginShell.error', error);
  }
  await _pumpFor(tester, const Duration(milliseconds: 600));
}

/// 在「我的」页点开教务入口，返回是否真的出现了 [AcademicWebEntryPage]。
///
/// `false` 表示出现了登录弹窗（设备无有效教务会话）或超预算。
Future<bool> _openAcademicEntry(WidgetTester tester) async {
  final Finder pageFinder = find.byType(AcademicWebEntryPage);
  final Finder modalFinder = find.byType(LoginShell);
  final Finder academicRow = find.text('教务系统');
  final DateTime deadline = DateTime.now().add(_openBudget);

  while (DateTime.now().isBefore(deadline)) {
    if (pageFinder.evaluate().isNotEmpty) return true;
    if (modalFinder.evaluate().isNotEmpty) return false;

    if (academicRow.evaluate().isNotEmpty) {
      _log('tap.academicRow', 'attempt');
      try {
        await tester.tap(academicRow.first);
      } catch (error) {
        _log('tap.academicRow.error', error);
      }
    } else {
      _log('tap.academicRow.missing', '当前树上找不到「教务系统」行');
    }

    final DateTime sliceEnd = DateTime.now().add(_retapSlice);
    while (DateTime.now().isBefore(sliceEnd) &&
        DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (pageFinder.evaluate().isNotEmpty) return true;
      if (modalFinder.evaluate().isNotEmpty) return false;
    }
  }
  return pageFinder.evaluate().isNotEmpty;
}

/// 从入口页返回「我的」页：优先 `pageBack()`，失败则直接 pop 顶层路由。
Future<void> _popEntryPage(WidgetTester tester) async {
  final Finder pageFinder = find.byType(AcademicWebEntryPage);
  try {
    await tester.pageBack();
    _log('popEntryPage', 'pageBack ok');
  } catch (error) {
    _log('popEntryPage.pageBack.error', error);
    if (pageFinder.evaluate().isNotEmpty) {
      Navigator.of(tester.element(pageFinder.first)).pop();
      _log('popEntryPage', 'manual Navigator.pop');
    }
  }
  await _pumpFor(tester, const Duration(seconds: 2));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('academic entry + my page device flow (no login, read-only)', (
    WidgetTester tester,
  ) async {
    final List<String> uncaught = <String>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      uncaught.add(details.exceptionAsString());
      _log('FlutterError.onError', details.exceptionAsString());
      previousOnError?.call(details);
    };

    // ── 启动：镜像 lib/main.dart 的首帧引导（偏好 / 学期日历），
    // 但只做无网络的会话恢复，刻意不走静默自动登录。
    await AppBootstrapController.instance.prepareForFirstFrame();
    try {
      await ZhengfangAuth.instance.restoreSession();
    } catch (error) {
      _log('restore.zhengfang.error', error);
    }
    try {
      await UnifiedAuthService.instance.restoreSession(
        syncWebViewCookies: false,
      );
    } catch (error) {
      _log('restore.unifiedAuth.error', error);
    }
    _log('restored.zhengfang.isLoggedIn', ZhengfangAuth.instance.isLoggedIn);
    _log(
      'restored.unifiedAuth.isLoggedIn',
      UnifiedAuthService.instance.isLoggedIn,
    );

    await tester.pumpWidget(JXUCampusHubApp());
    _log('boot.pumpWidget', 'done');

    // ── 步骤 1：shell 渲染 + 底部 dock 存在。
    final Finder navBar = find.byType(GlassNavBar);
    final bool navPresent = await _awaitFinder(tester, navBar, _renderBudget);
    _log('step1.glassNavBar.present', navPresent);
    expect(
      navPresent,
      isTrue,
      reason: '底部 dock 未在 $_renderBudget 内渲染（App 启动可能已崩溃）',
    );
    for (final String label in <String>['主页', '功能', '我的']) {
      final Finder tab = find.descendant(
        of: navBar,
        matching: find.text(label),
      );
      final bool tabPresent = tab.evaluate().isNotEmpty;
      _log('step1.dockTab.$label', tabPresent);
      expect(tabPresent, isTrue, reason: 'dock 缺少标签：$label');
    }

    // ── 步骤 2：进入「我的」，两行存在。
    await tester.tap(find.descendant(of: navBar, matching: find.text('我的')));
    final Finder campusRow = find.text('统一认证（含一卡通）');
    final Finder academicRow = find.text('教务系统');
    final bool myPageReady = await _awaitFinder(
      tester,
      find.byKey(const Key('my_academic_status')),
      _renderBudget,
    );
    _log('step2.myPage.academicStatusRow', myPageReady);
    expect(myPageReady, isTrue, reason: '「我的」页教务行未在 $_renderBudget 内渲染');
    _log('step2.campusRow.present', campusRow.evaluate().isNotEmpty);
    _log('step2.academicRow.present', academicRow.evaluate().isNotEmpty);
    expect(
      campusRow.evaluate().isNotEmpty,
      isTrue,
      reason: '「我的」页缺少 统一认证（含一卡通） 行',
    );
    expect(academicRow.evaluate().isNotEmpty, isTrue, reason: '「我的」页缺少 教务系统 行');
    final bool campusSubtitle = find
        .byKey(const Key('my_campus_status'))
        .evaluate()
        .isNotEmpty;
    _log('step2.campusStatusKey.present', campusSubtitle);
    _log(
      'step2.campusSubtitle',
      campusSubtitle
          ? tester.widget<Text>(find.byKey(const Key('my_campus_status'))).data
          : null,
    );
    _log(
      'step2.academicSubtitle',
      tester.widget<Text>(find.byKey(const Key('my_academic_status'))).data,
    );

    // ── 步骤 3：点开教务入口，读终态。
    final bool opened = await _openAcademicEntry(tester);
    final bool loginModalShown = find.byType(LoginShell).evaluate().isNotEmpty;
    _log('step3.academicEntry.opened', opened);
    _log('step3.academicEntry.loginModalShown', loginModalShown);
    if (!opened) {
      fail(
        '未能在 $_openBudget 内打开 AcademicWebEntryPage。'
        'loginModalShown=$loginModalShown，'
        'zhengfangLoggedIn=${ZhengfangAuth.instance.isLoggedIn}，'
        'campusLoggedIn=${UnifiedAuthService.instance.isLoggedIn}。'
        '若 loginModalShown=true，说明本机教务会话未恢复 / 未登录，'
        '点按「教务系统」只弹出登录框（本测试不登录，故到此终止）。',
      );
    }

    final Finder entryFinder = find.byType(AcademicWebEntryPage);
    final AcademicWebEntryPageState entryState = tester
        .state<AcademicWebEntryPageState>(entryFinder);
    final AcademicEntryPageStatus? status = await _pollTerminalStatus(
      tester,
      entryFinder,
      _terminalBudget,
    );
    _log('step3.academicEntry.status', status);
    _log('step3.academicEntry.mode', entryState.debugReadyMode);
    _log('step3.academicEntry.fallbackUsed', entryState.debugFallbackUsed);
    _log('step3.academicEntry.readyUrl', entryState.debugReadyUrl);
    _log('step3.academicEntry.errorRetryable', entryState.debugErrorRetryable);
    _log('step3.academicEntry.generation', entryState.debugGeneration);

    expect(status, isNotNull, reason: '入口页在准备结束前已从树上移除（无终态可读）');
    expect(
      status,
      isNot(AcademicEntryPageStatus.preparing),
      reason:
          '入口页状态在 $_terminalBudget 后仍停留在 preparing'
          '（疑似卡死；generation=${entryState.debugGeneration}）',
    );
    expect(
      status,
      isIn(<AcademicEntryPageStatus>[
        AcademicEntryPageStatus.ready,
        AcademicEntryPageStatus.needsUnifiedLogin,
        AcademicEntryPageStatus.needsAcademicLogin,
        AcademicEntryPageStatus.unavailable,
        AcademicEntryPageStatus.denied,
      ]),
      reason: '非终态：status=$status',
    );

    if (status == AcademicEntryPageStatus.ready) {
      final String? url = entryState.debugReadyUrl;
      expect(url, isNotNull, reason: 'ready 却没有 debugReadyUrl');
      final Uri? uri = Uri.tryParse(url!);
      final String? trusted = AcademicWebEntryPreparer.trustedEntryUrl();
      final bool directOk = url == trusted;
      final bool webVpnOk =
          uri != null &&
          uri.host.toLowerCase() == 'webvpn.zjxu.edu.cn' &&
          uri.path.contains('/jwglxt/xtgl/index_initMenu.html');
      _log('step3.readyUrl.directOk', directOk);
      _log('step3.readyUrl.webVpnOk', webVpnOk);
      expect(
        directOk || webVpnOk,
        isTrue,
        reason:
            'ready 的 debugReadyUrl 不是受信入口：url=$url，'
            'mode=${entryState.debugReadyMode}，'
            'fallbackUsed=${entryState.debugFallbackUsed}，'
            'directExpected=$trusted',
      );
    }

    // 回到「我的」页（若自动弹了登录框，只取消不登录）。
    await _dismissLoginShellIfAny(tester);
    await _popEntryPage(tester);
    final bool backToMy = await _awaitFinder(
      tester,
      find.byKey(const Key('my_academic_status')),
      _renderBudget,
    );
    _log('step3.backToMyPage', backToMy);
    expect(backToMy, isTrue, reason: '未能从入口页返回「我的」页');

    // ── 步骤 4：登出确认框 → 「返回」取消（真实会话必须存活）。
    final bool zfBefore = ZhengfangAuth.instance.isLoggedIn;
    final bool casBefore = UnifiedAuthService.instance.isLoggedIn;
    _log('step4.sessionBefore.zhengfang', zfBefore);
    _log('step4.sessionBefore.unifiedAuth', casBefore);

    final Finder logoutButton = find.byTooltip('退出登录');
    final bool logoutPresent = logoutButton.evaluate().isNotEmpty;
    _log('step4.logoutButton.present', logoutPresent);
    if (logoutPresent) {
      await tester.tap(logoutButton.first);
      final bool dialogShown = await _awaitFinder(
        tester,
        find.text('退出登录'),
        _renderBudget,
      );
      _log('step4.confirmDialog.shown', dialogShown);
      expect(dialogShown, isTrue, reason: '点登出后未出现确认框');
      final Finder cancelButton = find.widgetWithText(TextButton, '返回');
      _log('step4.cancelButton.present', cancelButton.evaluate().isNotEmpty);
      expect(
        cancelButton.evaluate().isNotEmpty,
        isTrue,
        reason: '登出确认框缺少「返回」按钮',
      );
      await tester.tap(cancelButton.first);
      await _pumpFor(tester, const Duration(seconds: 1));
      final bool dialogGone = find.text('返回').evaluate().isEmpty;
      _log('step4.confirmDialog.dismissed', dialogGone);
      expect(dialogGone, isTrue, reason: '点「返回」后确认框未关闭');
      _log('step4.sessionAfter.zhengfang', ZhengfangAuth.instance.isLoggedIn);
      _log(
        'step4.sessionAfter.unifiedAuth',
        UnifiedAuthService.instance.isLoggedIn,
      );
      expect(
        ZhengfangAuth.instance.isLoggedIn == zfBefore &&
            UnifiedAuthService.instance.isLoggedIn == casBefore,
        isTrue,
        reason:
            '点「返回」取消后会话发生了变化（不应登出）：'
            'zhengfang $zfBefore->${ZhengfangAuth.instance.isLoggedIn}，'
            'unifiedAuth $casBefore->${UnifiedAuthService.instance.isLoggedIn}',
      );
    } else {
      _log('step4.logoutButton.skipped', '未显示登出按钮（无已登录身份）；跳过登出确认框分支');
    }

    // ── 步骤 5：标签页往返，shell 无崩溃。
    await tester.tap(find.descendant(of: navBar, matching: find.text('主页')));
    await _pumpFor(tester, const Duration(seconds: 2));
    final bool homeTabOk = find.byType(GlassNavBar).evaluate().isNotEmpty;
    _log('step5.homeTab.dockPresent', homeTabOk);
    expect(homeTabOk, isTrue, reason: '切到「主页」后 dock 消失');

    await tester.tap(find.descendant(of: navBar, matching: find.text('我的')));
    final bool myTabOk = await _awaitFinder(
      tester,
      find.byKey(const Key('my_academic_status')),
      _renderBudget,
    );
    _log('step5.myTab.rowsPresent', myTabOk);
    expect(myTabOk, isTrue, reason: '切回「我的」后行未渲染');

    // ── 未捕获异常断言。
    _log('uncaught.count', uncaught.length);
    if (uncaught.isNotEmpty) {
      _log('uncaught.items', uncaught.join(' || '));
    }
    expect(uncaught, isEmpty, reason: '观察到未捕获异常：$uncaught');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
