import 'package:material_ui/material_ui.dart';

/// 只观察 PageRoute：PopupRoute/DialogRoute（如右上角 ⋯ 菜单、对话框）
/// 不算「离开本页」，不应触发 RouteAware 的遮挡清理（否则弹菜单会顶掉付款码）。
final RouteObserver<PageRoute<dynamic>> appRouteObserver =
    RouteObserver<PageRoute<dynamic>>();
