import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jiaxing_university_portal/app/app_shell_page.dart';
import 'package:jiaxing_university_portal/features/home/home_page.dart';
import 'package:jiaxing_university_portal/features/my/my_page.dart';
import 'package:jiaxing_university_portal/features/service_hub/service_hub_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows service hub destination in bottom navigation', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/',
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
                  builder: (context, state) => const HomePage(),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/services',
                  builder: (context, state) => const ServiceHubPage(),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/my',
                  builder: (context, state) => const MyPage(),
                ),
              ],
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('主页'), findsOneWidget);
    expect(find.text('功能'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
  });
}
