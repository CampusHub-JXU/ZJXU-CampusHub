import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 功能入口元数据（Feature Catalog，PRD 0.7.0 §7）。
///
/// 只描述“展示什么”与稳定的 [primaryActionId]；不保存 routeName / wechatH5Url，
/// 启动方式全部由 `CampusActionRegistry` 决定。
class FeatureEntryDefinition {
  const FeatureEntryDefinition({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accentColor,
    required this.primaryActionId,
    required this.sortOrder,
  });

  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accentColor;
  final int sortOrder;

  /// 该入口的主 CampusAction ID（见 `lib/core/actions/campus_action_ids.dart`）。
  final String primaryActionId;
}

class AppFeaturesConfig {
  AppFeaturesConfig._();

  static final entries = <FeatureEntryDefinition>[
    const FeatureEntryDefinition(
      id: 'schedule',
      title: '课表',
      subtitle: '查看本学期课程、周次与调课提醒',
      icon: Icons.calendar_month_outlined,
      accentColor: AppColors.primary,
      primaryActionId: 'schedule.open',
      sortOrder: 5,
    ),
    const FeatureEntryDefinition(
      id: 'grades',
      title: '成绩查询',
      subtitle: '查看成绩、绩点和学业进展',
      icon: Icons.school_outlined,
      accentColor: AppColors.warning,
      primaryActionId: 'grades.open',
      sortOrder: 10,
    ),
    const FeatureEntryDefinition(
      id: 'exam',
      title: '考试安排',
      subtitle: '查看考试时间、地点与倒计时',
      icon: Icons.event_available_outlined,
      accentColor: Color(0xFF7B61FF),
      primaryActionId: 'exam.open',
      sortOrder: 15,
    ),
    const FeatureEntryDefinition(
      id: 'academic-web',
      title: '教务系统',
      subtitle: '正方教务网页版',
      icon: Icons.account_balance_outlined,
      accentColor: AppColors.primary,
      primaryActionId: 'academic-web.open',
      sortOrder: 17,
    ),
    const FeatureEntryDefinition(
      id: 'shuati-practice',
      title: '刷题助手',
      subtitle: '题库导入、错题重练、离线练习',
      icon: Icons.quiz_outlined,
      accentColor: Color(0xFF00897B),
      primaryActionId: 'shuati.open',
      sortOrder: 20,
    ),
    const FeatureEntryDefinition(
      id: 'second-classroom',
      title: '第二课堂',
      subtitle: '学分活动浏览、订阅提醒与微信版入口',
      icon: Icons.workspace_premium_outlined,
      accentColor: AppColors.gold,
      primaryActionId: 'second-classroom.open',
      sortOrder: 25,
    ),
    const FeatureEntryDefinition(
      id: 'library',
      title: '图书馆',
      subtitle: '馆藏检索、借阅与电子资源入口',
      icon: Icons.local_library_outlined,
      accentColor: AppColors.info,
      primaryActionId: 'library.open',
      sortOrder: 30,
    ),
    const FeatureEntryDefinition(
      id: 'campus-card',
      title: '一卡通',
      subtitle: '余额查询、校园卡服务与充值入口',
      icon: Icons.credit_card_outlined,
      accentColor: Color(0xFF1E88E5),
      primaryActionId: 'campus-card.open',
      sortOrder: 40,
    ),
    const FeatureEntryDefinition(
      id: 'campus-card-payment',
      title: '付款码',
      subtitle: '扫码支付',
      icon: Icons.qr_code_2_rounded,
      accentColor: Color(0xFF1E88E5),
      primaryActionId: 'campus-card.payment',
      sortOrder: 42,
    ),
    const FeatureEntryDefinition(
      id: 'dorm-electricity',
      title: '宿舍电费',
      subtitle: '查询寝室剩余电量与低电量提醒',
      icon: Icons.bolt_outlined,
      accentColor: Color(0xFFFFB300),
      primaryActionId: 'electricity.open',
      sortOrder: 45,
    ),
    const FeatureEntryDefinition(
      id: 'service-hall',
      title: '服务大厅',
      subtitle: '统一入口，继续保留主页快捷访问',
      icon: Icons.dashboard_customize_outlined,
      accentColor: AppColors.primary,
      primaryActionId: 'service-hall.open',
      sortOrder: 50,
    ),
    const FeatureEntryDefinition(
      id: 'changxing-jiada',
      title: '畅行嘉大',
      subtitle: '请假、返校、离校与加班申请',
      icon: Icons.north_rounded,
      accentColor: Color(0xFF2EA567),
      primaryActionId: 'changxing-jiada.open',
      sortOrder: 55,
    ),
    const FeatureEntryDefinition(
      id: 'sjjx-notice-list',
      title: '实践通知',
      subtitle: '实践教学通知与公告聚合',
      icon: Icons.science_outlined,
      accentColor: Color(0xFF1976D2),
      primaryActionId: 'sjjx-notice.open',
      sortOrder: 60,
    ),
    const FeatureEntryDefinition(
      id: 'notice-list',
      title: '校园公告',
      subtitle: '校级通知与重要公告快速查看',
      icon: Icons.campaign_outlined,
      accentColor: Color(0xFFE7A400),
      primaryActionId: 'notice.inbox',
      sortOrder: 65,
    ),
    const FeatureEntryDefinition(
      id: 'notification-center',
      title: '通知中心',
      subtitle: '集中查看课程、考试与系统提醒',
      icon: Icons.notifications_outlined,
      accentColor: Color(0xFF546E7A),
      primaryActionId: 'notification.center',
      sortOrder: 70,
    ),
    const FeatureEntryDefinition(
      id: 'micro-life',
      title: '嘉大微生活',
      subtitle: '后勤生活服务与校园生活入口',
      icon: Icons.storefront_outlined,
      accentColor: Color(0xFF00897B),
      primaryActionId: 'micro-life.open',
      sortOrder: 75,
    ),
    const FeatureEntryDefinition(
      id: 'one-stop-service',
      title: '校务服务',
      subtitle: '网上办事大厅（WebVPN 访问）',
      icon: Icons.apartment_outlined,
      accentColor: Color(0xFF3949AB),
      primaryActionId: 'one-stop-service.open',
      sortOrder: 80,
    ),
    const FeatureEntryDefinition(
      id: 'physical-test',
      title: '体测成绩',
      subtitle: '体质测试成绩与预约（WebVPN 访问）',
      icon: Icons.fitness_center_outlined,
      accentColor: Color(0xFF00838F),
      primaryActionId: 'physical-test.open',
      sortOrder: 85,
    ),
  ];
}
