import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'app_route_observer.dart';
import 'app_shell_page.dart';
import '../features/home/home_page.dart';
import '../features/my/my_page.dart';
import '../features/my/academic_service_page.dart';
import '../features/my/unified_auth_login_page.dart';
import '../features/my/academic_system_login_page.dart';
import '../features/schedule/schedule_page.dart';
import '../features/grades/grades_page.dart';
import '../features/campus_card/campus_card_page.dart';
import '../features/campus_card/campus_card_payment_page.dart';
import '../features/library/library_page.dart';
import '../features/notice/notice_list_page.dart';
import '../features/sjjx_notice/sjjx_notice_list_page.dart';
import '../features/service_hall/service_hall_page.dart';
import '../features/notification_center/notification_center_page.dart';
import '../features/exam/exam_page.dart';
import '../features/shuati/shuati_webview_page.dart';
import '../features/settings/settings_page.dart';
import '../features/settings/about_page.dart';
import '../features/settings/personalization_page.dart';
import '../features/settings/push_debug_page.dart';
import '../features/settings/theme_settings_page.dart';
import '../features/dorm_electricity/dorm_electricity_page.dart';
import '../features/dorm_electricity/dorm_electricity_settings_page.dart';
import '../features/second_classroom/second_classroom_page.dart';
import '../features/changxing_jiada/changxing_back_school_form_page.dart';
import '../features/changxing_jiada/changxing_jiada_page.dart';
import '../features/changxing_jiada/changxing_leave_form_page.dart';
import '../features/changxing_jiada/changxing_overtime_form_page.dart';
import '../features/changxing_jiada/changxing_jiada_model.dart';
import '../shared/widgets/unified_auth_protected_webview_page.dart';
import '../shared/widgets/webview_page.dart';

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
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) {
        return AppShellPage(navigationShell: navigationShell);
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
      path: '/exam',
      name: 'exam',
      builder: (context, state) => const ExamPage(),
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
      path: '/personalization',
      name: 'personalization',
      builder: (context, state) => const PersonalizationPage(),
    ),
    GoRoute(
      path: '/theme',
      name: 'theme',
      redirect: (context, state) => '/theme-settings',
    ),
    _appRoute(
      path: '/theme-settings',
      name: 'theme-settings',
      builder: (context, state) => const ThemeSettingsPage(),
    ),
    _appRoute(
      path: '/push-debug',
      name: 'push-debug',
      builder: (context, state) => const PushDebugPage(),
    ),
    _appRoute(
      path: '/about',
      name: 'about',
      builder: (context, state) => const AboutPage(),
    ),
    _appRoute(
      path: '/notification-center',
      name: 'notification-center',
      builder: (context, state) => const NotificationCenterPage(),
    ),
    _appRoute(
      path: '/unified-auth-login',
      name: 'unified-auth-login',
      builder: (context, state) => const UnifiedAuthLoginPage(),
    ),
    _appRoute(
      path: '/academic-system-login',
      name: 'academic-system-login',
      builder: (context, state) => const AcademicSystemLoginPage(),
    ),
    _appRoute(
      path: '/academic-service',
      name: 'academic-service',
      builder: (context, state) => const AcademicServicePage(),
    ),
    _appRoute(
      path: '/notice-list',
      name: 'notice-list',
      builder: (context, state) => const NoticeListPage(),
    ),
    _appRoute(
      path: '/sjjx-notice-list',
      name: 'sjjx-notice-list',
      builder: (context, state) => const SjjxNoticeListPage(),
    ),
    _appRoute(
      path: '/news-detail',
      name: 'news-detail',
      builder: (context, state) {
        final extra = Map<String, dynamic>.from(
          (state.extra as Map?) ?? const <String, dynamic>{},
        );
        return WebViewPage(
          title: extra['title'] as String? ?? '新闻详情',
          url: extra['url'] as String? ?? '',
          onHomePressed: () => context.goNamed('home'),
        );
      },
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
      builder: (context, state) {
        final extra = Map<String, dynamic>.from(
          (state.extra as Map?) ?? const <String, dynamic>{},
        );
        if (extra['requireUnifiedAuthProtection'] == true) {
          return UnifiedAuthProtectedWebViewPage(
            title: extra['title'] ?? '网页',
            url: extra['url'] ?? '',
            serviceUrl:
                extra['serviceUrl'] as String? ??
                (extra['url'] as String? ?? ''),
            loginDescription:
                extra['loginDescription'] as String? ?? '需要先完成统一认证',
            emulateDingTalkEnvironment:
                extra['emulateDingTalkEnvironment'] == true,
            showWebViewBottomBackButton:
                extra['showWebViewBottomBackButton'] == true,
            onHomePressed: () => context.goNamed('home'),
          );
        }
        return WebViewPage(
          title: extra['title'] ?? '网页',
          url: extra['url'] ?? '',
          enableLoginQuickFill: extra['enableLoginQuickFill'] == true,
          emulateDingTalkEnvironment:
              extra['emulateDingTalkEnvironment'] == true,
          showWebViewBottomBackButton:
              extra['showWebViewBottomBackButton'] == true,
          onHomePressed: () => context.goNamed('home'),
        );
      },
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
