import 'package:flutter/material.dart';
import 'theme.dart';
import 'routes.dart';

class JiadatongApp extends StatelessWidget {
  const JiadatongApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: '嘉大通',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      routerConfig: appRouter,
      debugShowCheckedModeBanner: false,
    );
  }
}
