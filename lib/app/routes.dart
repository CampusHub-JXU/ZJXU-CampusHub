import 'package:go_router/go_router.dart';
import '../features/home/home_page.dart';
import '../features/schedule/schedule_page.dart';
import '../features/grades/grades_page.dart';
import '../features/campus_card/campus_card_page.dart';
import '../features/campus_card/campus_card_payment_page.dart';
import '../features/notice/notice_list_page.dart';
import '../features/service_hall/service_hall_page.dart';
import '../features/settings/settings_page.dart';
import '../features/dorm_electricity/dorm_electricity_page.dart';
import '../features/dorm_electricity/dorm_electricity_settings_page.dart';
import '../shared/widgets/webview_page.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      name: 'home',
      builder: (context, state) => const HomePage(),
    ),
    GoRoute(
      path: '/schedule',
      name: 'schedule',
      builder: (context, state) => const SchedulePage(),
    ),
    GoRoute(
      path: '/grades',
      name: 'grades',
      builder: (context, state) => const GradesPage(),
    ),
    GoRoute(
      path: '/campus-card',
      name: 'campus-card',
      builder: (context, state) => const CampusCardPage(),
    ),
    GoRoute(
      path: '/campus-card-payment',
      name: 'campus-card-payment',
      builder: (context, state) => const CampusCardPaymentPage(),
    ),
    GoRoute(
      path: '/service-hall',
      name: 'service-hall',
      builder: (context, state) => const ServiceHallPage(),
    ),
    GoRoute(
      path: '/settings',
      name: 'settings',
      builder: (context, state) => const SettingsPage(),
    ),
    GoRoute(
      path: '/notice-list',
      name: 'notice-list',
      builder: (context, state) => const NoticeListPage(),
    ),
    GoRoute(
      path: '/news-detail',
      name: 'news-detail',
      builder: (context, state) {
        final extra = state.extra as Map<String, String>;
        return WebViewPage(
          title: extra['title'] ?? '新闻详情',
          url: extra['url'] ?? '',
        );
      },
    ),
    GoRoute(
      path: '/dorm-electricity',
      name: 'dorm-electricity',
      builder: (context, state) => const DormElectricityPage(),
    ),
    GoRoute(
      path: '/dorm-electricity-settings',
      name: 'dorm-electricity-settings',
      builder: (context, state) => const DormElectricitySettingsPage(),
    ),
  ],
);
