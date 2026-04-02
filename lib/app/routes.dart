import 'package:go_router/go_router.dart';
import '../features/home/home_page.dart';
import '../features/schedule/schedule_page.dart';
import '../features/grades/grades_page.dart';
import '../features/campus_card/campus_card_page.dart';
import '../features/service_hall/service_hall_page.dart';
import '../features/settings/settings_page.dart';

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
      path: '/service-hall',
      name: 'service-hall',
      builder: (context, state) => const ServiceHallPage(),
    ),
    GoRoute(
      path: '/settings',
      name: 'settings',
      builder: (context, state) => const SettingsPage(),
    ),
  ],
);
