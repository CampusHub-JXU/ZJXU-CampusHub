import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'ai_export_sources.dart';
import 'app_route_observer.dart';
import 'app_shell_page.dart';
import '../features/home/home_page.dart';
import '../features/my/my_page.dart';
import '../features/schedule/schedule_page.dart';
import '../features/grades/grades_page.dart';
import '../features/campus_card/campus_card_page.dart';
import '../features/campus_card/campus_card_payment_page.dart';
import '../features/library/library_book_page.dart';
import '../features/library/library_borrows_page.dart';
import '../features/library/library_page.dart';
import '../features/physical_test/physical_test_page.dart';
import '../features/notice/notice_detail_page.dart';
import '../features/sjjx_notice/sjjx_notice_list_page.dart';
import '../features/service_hall/service_hall_page.dart';
import '../features/notification_center/notification_center_page.dart';
import '../features/exam/exam_page.dart';
import '../features/ai_export/ai_export_page.dart';
import '../features/shuati/shuati_webview_page.dart';
import '../features/settings/settings_page.dart';
import '../features/settings/about_page.dart';
import '../features/settings/performance_diagnostics_page.dart';
import '../features/settings/appearance_page.dart';
import '../features/settings/personalization_page.dart';
import '../features/settings/background_editor_page.dart';
import '../features/settings/desktop_background_page.dart';
import '../features/home/home_surface_scene.dart';
import '../features/home/models/example_campus_snapshot.dart';
import '../features/dorm_electricity/dorm_electricity_page.dart';
import '../features/dorm_electricity/dorm_electricity_settings_page.dart';
import '../features/second_classroom/second_classroom_page.dart';
import '../features/changxing_jiada/changxing_back_school_form_page.dart';
import '../features/changxing_jiada/changxing_jiada_page.dart';
import '../features/changxing_jiada/changxing_leave_form_page.dart';
import '../features/changxing_jiada/changxing_overtime_form_page.dart';
import '../features/changxing_jiada/changxing_jiada_model.dart';
import '../core/auth/unified_auth.dart';
import '../shared/widgets/unified_auth_protected_webview_page.dart';
import '../shared/widgets/webview_page.dart';
import '../shared/widgets/academic_web_entry_page.dart';

int? _parseOptionalId(GoRouterState state) {
  final text = state.uri.queryParameters['id']?.trim() ?? '';
  if (text.isEmpty) return null;
  return int.tryParse(text);
}

/// go_router 18 在 MaterialApp.router 下探测不到 Material app 类型
/// （material_ui 的 exact-type 匹配失败），会把 `builder:` 路由包进
/// [NoTransitionPage]——零时长、不读主题的 pageTransitionsTheme，
/// 页面切换表现为硬切。这里显式包 [MaterialPage]，让
/// MaterialRouteTransitionMixin 接回全局统一转场（app_theme_builder）。
///
/// 所有被 push 的顶层路由必须走本构造器；shell 分支根路由（tab 根）
/// 保持 `builder:` 即可——它们不参与 push 转场。
GoRoute _appRoute({
  required String path,
  required String name,
  required Widget Function(BuildContext context, GoRouterState state) builder,
}) {
  return GoRoute(
    path: path,
    name: name,
    pageBuilder: (context, state) => MaterialPage(
      key: state.pageKey,
      name: name,
      child: builder(context, state),
    ),
  );
}

final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  observers: [appRouteObserver],
  routes: [
    // 自定义分支容器：交叉淡化切换，避免整体淡入时透出底色闪黑。
    StatefulShellRoute(
      builder: (context, state, navigationShell) {
        return AppShellPage(navigationShell: navigationShell);
      },
      navigatorContainerBuilder: (context, navigationShell, children) {
        return AppShellBranchContainer(
          currentIndex: navigationShell.currentIndex,
          children: children,
        );
      },
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/',
              name: 'home',
              builder: (context, state) => const HomePage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/my',
              name: 'my',
              builder: (context, state) => const MyPage(),
            ),
          ],
        ),
      ],
    ),
    _appRoute(
      path: '/schedule',
      name: 'schedule',
      builder: (context, state) => const SchedulePage(),
    ),
    _appRoute(
      path: '/grades',
      name: 'grades',
      builder: (context, state) => const GradesPage(),
    ),
    _appRoute(
      path: '/ai-export',
      name: 'ai-export',
      // 各模块的取数来源在组合层注入，导出功能本身不依赖业务 feature。
      builder: (context, state) =>
          AiExportPage(sources: buildAiExportSources()),
    ),
    _appRoute(
      path: '/exam',
      name: 'exam',
      builder: (context, state) => const ExamPage(),
    ),
    _appRoute(
      path: '/academic-progress',
      name: 'academic-progress',
      // 学业情况已并入成绩页，旧路由（快捷方式 / 动作）直接打开「学业进度」分段。
      builder: (context, state) =>
          const GradesPage(initialView: GradesPageView.progress),
    ),
    _appRoute(
      path: '/shuati-practice',
      name: 'shuati-practice',
      builder: (context, state) => const ShuatiWebViewPage(),
    ),
    _appRoute(
      path: '/campus-card',
      name: 'campus-card',
      builder: (context, state) => const CampusCardPage(),
    ),
    _appRoute(
      path: '/campus-card-payment',
      name: 'campus-card-payment',
      builder: (context, state) => const CampusCardPaymentPage(),
    ),
    _appRoute(
      path: '/service-hall',
      name: 'service-hall',
      builder: (context, state) => const ServiceHallPage(),
    ),
    _appRoute(
      path: '/library',
      name: 'library',
      builder: (context, state) => const LibraryPage(),
    ),
    _appRoute(
      path: '/library/book/:bid',
      name: 'library-book',
      builder: (context, state) => LibraryBookPage(
        bid: state.pathParameters['bid'] ?? '',
        title: state.uri.queryParameters['title'],
      ),
    ),
    _appRoute(
      path: '/library/borrows',
      name: 'library-borrows',
      builder: (context, state) => const LibraryBorrowsPage(),
    ),
    _appRoute(
      path: '/physical-test',
      name: 'physical-test',
      builder: (context, state) => const PhysicalTestPage(),
    ),
    _appRoute(
      path: '/second-classroom',
      name: 'second-classroom',
      builder: (context, state) =>
          SecondClassroomPage(initialActivityId: _parseOptionalId(state)),
    ),
    _appRoute(
      path: '/settings',
      name: 'settings',
      builder: (context, state) => const SettingsPage(),
    ),
    _appRoute(
      path: '/appearance',
      name: 'appearance',
      builder: (context, state) => AppearancePage(
        homeSceneBuilder: (context) => const HomeSurfaceScene(
          presentation: ExampleCampusSnapshot.presentation,
        ),
      ),
    ),
    _appRoute(
      path: '/personalization',
      name: 'personalization',
      builder: (context, state) => PersonalizationPage(
        homeSceneBuilder: (context) => const HomeSurfaceScene(
          presentation: ExampleCampusSnapshot.presentation,
        ),
      ),
    ),
    _appRoute(
      path: '/background-editor',
      name: 'background-editor',
      builder: (context, state) {
        final args = state.extra;
        if (args is! BackgroundEditorArgs) {
          return const SizedBox.shrink();
        }
        return BackgroundEditorPage(args: args);
      },
    ),
    _appRoute(
      path: '/desktop-background',
      name: 'desktop-background',
      builder: (context, state) => const DesktopBackgroundPage(),
    ),
    _appRoute(
      path: '/about',
      name: 'about',
      builder: (context, state) => const AboutPage(),
    ),
    _appRoute(
      path: '/performance-diagnostics',
      name: 'performance-diagnostics',
      // 内部诊断页：未启用时页面自身 fail closed（不提供开启采样的开关）。
      builder: (context, state) => const PerformanceDiagnosticsPage(),
    ),
    _appRoute(
      path: '/notification-center',
      name: 'notification-center',
      builder: (context, state) => const NotificationCenterPage(),
    ),
    _appRoute(
      path: '/notice-detail',
      name: 'notice-detail',
      builder: (context, state) {
        final extra = (state.extra as Map?) ?? const {};
        return NoticeDetailPage(
          title: extra['title'] as String? ?? '通知详情',
          url: extra['url'] as String? ?? '',
        );
      },
    ),
    _appRoute(
      path: '/sjjx-notice-list',
      name: 'sjjx-notice-list',
      builder: (context, state) => const SjjxNoticeListPage(),
    ),
    _appRoute(
      path: '/dorm-electricity',
      name: 'dorm-electricity',
      builder: (context, state) => const DormElectricityPage(),
    ),
    _appRoute(
      path: '/dorm-electricity-settings',
      name: 'dorm-electricity-settings',
      builder: (context, state) => const DormElectricitySettingsPage(),
    ),
    _appRoute(
      path: '/external-webview',
      name: 'external-webview',
      builder: buildExternalWebViewPage,
    ),
    _appRoute(
      path: '/changxing-jiada',
      name: 'changxing-jiada',
      builder: (context, state) => const ChangxingJiadaPage(),
    ),
    _appRoute(
      path: '/changxing-jiada/leave-request',
      name: ChangxingFormType.leaveRequest.routeName,
      builder: (context, state) => ChangxingLeaveFormPage(
        formType: ChangxingFormType.leaveRequest,
        applicationId: _parseOptionalId(state),
      ),
    ),
    _appRoute(
      path: '/changxing-jiada/leave-school',
      name: ChangxingFormType.leaveSchool.routeName,
      builder: (context, state) => ChangxingLeaveFormPage(
        formType: ChangxingFormType.leaveSchool,
        applicationId: _parseOptionalId(state),
      ),
    ),
    _appRoute(
      path: '/changxing-jiada/back-school',
      name: ChangxingFormType.backSchool.routeName,
      builder: (context, state) =>
          ChangxingBackSchoolFormPage(applicationId: _parseOptionalId(state)),
    ),
    _appRoute(
      path: '/changxing-jiada/overtime',
      name: ChangxingFormType.overtime.routeName,
      builder: (context, state) =>
          ChangxingOvertimeFormPage(applicationId: _parseOptionalId(state)),
    ),
  ],
);

/// 外部 WebView 路由：资源型目标必须转发 [warmUpAsResource]，
/// 不能把资源 URL 当 CAS service。
Widget buildExternalWebViewPage(BuildContext context, GoRouterState state) {
  final extra = Map<String, dynamic>.from(
    (state.extra as Map?) ?? const <String, dynamic>{},
  );
  if (extra['academicEntry'] == true) {
    // 教务 H5 入口：headless 选路 + 一次性直连→WebVPN 兜底，不再是裸 WebView。
    return AcademicWebEntryPage(
      title: extra['title'] as String? ?? '教务系统',
      onHomePressed: () => context.goNamed('home'),
    );
  }
  if (extra['requireUnifiedAuthProtection'] == true) {
    final warmUpAsResource = extra['warmUpAsResource'] == true;
    final url = extra['url'] as String? ?? '';
    final serviceUrl = extra['serviceUrl'] as String?;
    return UnifiedAuthProtectedWebViewPage(
      title: extra['title'] as String? ?? '网页',
      url: url,
      // 资源 URL 不是 CAS service：登录弹窗用注册服务默认值，
      // 业务 Cookie 由 getResource 跟随站点真实回调建立。
      serviceUrl: warmUpAsResource
          ? (serviceUrl == null || serviceUrl.isEmpty || serviceUrl == url
                ? UnifiedAuthService.defaultServiceUrl
                : serviceUrl)
          : (serviceUrl ?? url),
      loginDescription: extra['loginDescription'] as String? ?? '需要先完成统一认证',
      emulateDingTalkEnvironment: extra['emulateDingTalkEnvironment'] == true,
      showWebViewBottomBackButton: extra['showWebViewBottomBackButton'] == true,
      warmUpAsResource: warmUpAsResource,
      onHomePressed: () => context.goNamed('home'),
    );
  }
  return WebViewPage(
    title: extra['title'] as String? ?? '网页',
    url: extra['url'] as String? ?? '',
    enableLoginQuickFill: extra['enableLoginQuickFill'] == true,
    emulateDingTalkEnvironment: extra['emulateDingTalkEnvironment'] == true,
    showWebViewBottomBackButton: extra['showWebViewBottomBackButton'] == true,
    onHomePressed: () => context.goNamed('home'),
  );
}
