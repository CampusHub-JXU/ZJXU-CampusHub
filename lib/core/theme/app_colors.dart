import 'package:material_ui/material_ui.dart';

/// 全局品牌/语义色常量。
///
/// 自 `app/theme.dart` 抽出：core/shared 层（如 feature_entry_catalog）
/// 需要引用品牌色但不得反向依赖 app 层，故下沉至 core/theme。
class AppColors {
  AppColors._();

  // Primary - Wine Red
  static const Color primary = Color(0xFF8B1A2D);
  static const Color primaryDark = Color(0xFF6B0F1F);
  static const Color primaryLight = Color(0xFFB85C6E);

  // Secondary - Gold
  static const Color gold = Color(0xFFD4AF37);

  // Semantic
  static const Color success = Color(0xFF2E7D32);
  static const Color warning = Color(0xFFF57C00);
  static const Color error = Color(0xFFC62828);
  static const Color info = Color(0xFF1565C0);
}
