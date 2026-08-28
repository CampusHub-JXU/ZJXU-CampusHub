import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/glass_style_controller.dart';
import '../shared/widgets/glass_nav_bar.dart';

class AppShellPage extends StatefulWidget {
  const AppShellPage({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  State<AppShellPage> createState() => _AppShellPageState();
}

class _AppShellPageState extends State<AppShellPage> {
  void _onDestinationSelected(int index) {
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.navigationShell.currentIndex,
    );
  }

  @override
  void initState() {
    super.initState();
    GlassStyleController.instance.restore();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: widget.navigationShell,
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: GlassNavBar(
            currentIndex: widget.navigationShell.currentIndex,
            onDestinationSelected: _onDestinationSelected,
            destinations: const [
              GlassNavBarDestination(
                icon: Icons.home_outlined,
                selectedIcon: Icons.home,
                label: '主页',
              ),
              GlassNavBarDestination(
                icon: Icons.widgets_outlined,
                selectedIcon: Icons.widgets,
                label: '功能',
              ),
              GlassNavBarDestination(
                icon: Icons.person_outline,
                selectedIcon: Icons.person,
                label: '我的',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
