// 由 tools/architecture/check_design_ratchet.dart --write 生成，
// 不要手写。数量只许减少：迁移页面后重新生成，diff 里只应出现
// 数字变小或条目消失。

const designRatchetBaseline = <String, Map<String, int>>{
  'features/home/widgets/home_primary_status_hero.dart': {'fontSize': 1},
  'features/my/my_page.dart': {'fontSize': 7},
  'features/settings/background_editor_page.dart': {'fontSize': 2},
  'features/settings/widgets/appearance_preview.dart': {'fontSize': 2},
  'features/settings/widgets/hsv_color_picker_sheet.dart': {'fontSize': 1},
  'features/settings/widgets/personalization_background_section.dart': {
    'fontSize': 1,
  },
  'shared/widgets/app_dropdown.dart': {'fontSize': 2},
  'shared/widgets/app_surface_style.dart': {'hexColor': 1},
  'shared/widgets/auth_required_view.dart': {'rawCard': 1},
  'shared/widgets/copy_text_feedback.dart': {'showSnackBar': 1},
  'shared/widgets/glass_nav_bar.dart': {'fontSize': 1},
  'shared/widgets/login_shell.dart': {'fontSize': 2},
  'shared/widgets/login_widget.dart': {'fontSize': 1},
  'shared/widgets/network_error_toast.dart': {'showSnackBar': 1},
  'shared/widgets/qr_scanner_page.dart': {'fontSize': 1},
  'shared/widgets/unified_auth_login_widget.dart': {'fontSize': 1},
  'shared/widgets/webview_page.dart': {'showSnackBar': 1},
  'shared/widgets/webview_page_build.dart': {'fontSize': 2},
};
