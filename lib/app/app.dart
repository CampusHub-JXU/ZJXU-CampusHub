import 'package:flutter/material.dart';

import 'routes.dart';
import 'theme.dart';
import 'theme_mode_controller.dart';

class JiaxingUniversityApp extends StatelessWidget {
  const JiaxingUniversityApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeModeController.instance.themeMode,
      builder: (context, themeMode, child) {
        return MaterialApp.router(
          title: '嘉兴大学-校园门户',
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: themeMode,
          routerConfig: appRouter,
          debugShowCheckedModeBanner: false,
        );
      },
    );
  }
}
