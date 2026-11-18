import 'package:material_ui/material_ui.dart';

/// 全局 ScaffoldMessenger key：供无 BuildContext 的入口
/// （深链 / 快捷方式 / 通知）经 CampusActionExecutor 显示 SnackBar。
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
