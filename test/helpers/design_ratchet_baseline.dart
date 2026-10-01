// 由 tools/architecture/check_design_ratchet.dart --write 生成，
// 不要手写。数量只许减少：迁移页面后重新生成，diff 里只应出现
// 数字变小或条目消失。

const designRatchetBaseline = <String, Map<String, int>>{
  'features/home/function_zone/function_zone_section.dart': {
    'fontSize': 5,
    'showSnackBar': 1,
  },
  'features/home/widgets/home_asset_strip.dart': {'fontSize': 2},
  'features/home/widgets/home_campus_notice_section.dart': {'fontSize': 4},
  'features/home/widgets/home_event_banner.dart': {'fontSize': 1},
  'features/home/widgets/home_primary_status_hero.dart': {'fontSize': 14},
  'features/home/widgets/home_today_section.dart': {'fontSize': 6},
  'features/my/my_page.dart': {
    'fontSize': 8,
    'showDialog': 1,
    'showSnackBar': 1,
  },
  'features/notice/notice_detail_page.dart': {'showSnackBar': 1},
  'features/schedule/widgets/schedule_change_sheet.dart': {'fontSize': 11},
  'features/schedule/widgets/schedule_course_cell.dart': {
    'fontSize': 1,
    'showModalBottomSheet': 1,
  },
  'features/schedule/widgets/schedule_day_headers.dart': {'fontSize': 4},
  'features/schedule/widgets/schedule_info_banner.dart': {'fontSize': 1},
  'features/schedule/widgets/schedule_slot_column.dart': {'fontSize': 2},
  'features/settings/about_page.dart': {'fontSize': 1},
  'features/settings/background_editor_page.dart': {'fontSize': 2},
  'features/settings/push_debug_page.dart': {
    'fontSize': 1,
    'rawCard': 1,
    'showSnackBar': 1,
  },
  'features/settings/widgets/appearance_preview.dart': {'fontSize': 2},
  'features/settings/widgets/hsv_color_picker_sheet.dart': {'fontSize': 1},
  'features/settings/widgets/personalization_background_section.dart': {
    'fontSize': 1,
  },
  'features/shuati/shuati_webview_page.dart': {'showSnackBar': 1},
  'shared/widgets/app_dropdown.dart': {'fontSize': 2},
  'shared/widgets/app_surface_style.dart': {'hexColor': 1},
  'shared/widgets/auth_required_view.dart': {'rawCard': 1},
  'shared/widgets/copy_text_feedback.dart': {'showSnackBar': 1},
  'shared/widgets/glass_nav_bar.dart': {'fontSize': 1},
  'shared/widgets/login_shell.dart': {'fontSize': 2},
  'shared/widgets/login_widget.dart': {'fontSize': 4},
  'shared/widgets/network_error_toast.dart': {'showSnackBar': 1},
  'shared/widgets/qr_scanner_page.dart': {'fontSize': 1},
  'shared/widgets/unified_auth_login_widget.dart': {'fontSize': 4},
  'shared/widgets/update_dialog.dart': {'showSnackBar': 2},
  'shared/widgets/webview_page.dart': {'showSnackBar': 1},
  'shared/widgets/webview_page_build.dart': {'fontSize': 3},
};
