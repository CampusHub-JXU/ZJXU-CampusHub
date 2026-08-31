import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class FeatureEntryDefinition {
  const FeatureEntryDefinition({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accentColor,
    required this.routeName,
    required this.sortOrder,
  });

  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accentColor;
  final String routeName;
  final int sortOrder;
}

class AppFeaturesConfig {
  AppFeaturesConfig._();

  static const entries = <FeatureEntryDefinition>[
    FeatureEntryDefinition(
      id: 'schedule',
      title: '课表',
      subtitle: '查看本学期课程、周次与调课提醒',
      icon: Icons.calendar_month_outlined,
      accentColor: AppColors.primary,
      routeName: 'schedule',
      sortOrder: 5,
    ),
    FeatureEntryDefinition(
      id: 'grades',
      title: '成绩查询',
      subtitle: '查看成绩、绩点和学业进展',
      icon: Icons.school_outlined,
      accentColor: AppColors.warning,
      routeName: 'grades',
      sortOrder: 10,
    ),
    FeatureEntryDefinition(
      id: 'exam',
      title: '考试安排',
      subtitle: '查看考试时间、地点与倒计时',
      icon: Icons.event_available_outlined,
      accentColor: Color(0xFF7B61FF),
      routeName: 'exam',
      sortOrder: 15,
    ),
    FeatureEntryDefinition(
      id: 'shuati-practice',
      title: '刷题助手',
      subtitle: '题库导入、错题重练、离线练习',
      icon: Icons.quiz_outlined,
      accentColor: Color(0xFF00897B),
      routeName: 'shuati-practice',
      sortOrder: 20,
    ),
    FeatureEntryDefinition(
      id: 'second-classroom',
      title: '第二课堂',
      subtitle: '学分活动浏览、订阅提醒与微信版入口',
      icon: Icons.workspace_premium_outlined,
      accentColor: AppColors.gold,
      routeName: 'second-classroom',
      sortOrder: 25,
    ),
    FeatureEntryDefinition(
      id: 'library',
      title: '图书馆',
      subtitle: '馆藏检索、借阅与电子资源入口',
      icon: Icons.local_library_outlined,
      accentColor: AppColors.info,
      routeName: 'library',
      sortOrder: 30,
    ),
    FeatureEntryDefinition(
      id: 'campus-card',
      title: '一卡通',
      subtitle: '余额查询、校园卡服务与充值入口',
      icon: Icons.credit_card_outlined,
      accentColor: Color(0xFF1E88E5),
      routeName: 'campus-card',
      sortOrder: 40,
    ),
    FeatureEntryDefinition(
      id: 'campus-card-payment',
      title: '付款码',
      subtitle: '扫码支付',
      icon: Icons.qr_code_2_rounded,
      accentColor: Color(0xFF1E88E5),
      routeName: 'campus-card-payment',
      sortOrder: 42,
    ),
    FeatureEntryDefinition(
      id: 'dorm-electricity',
      title: '宿舍电费',
      subtitle: '查询寝室剩余电量与低电量提醒',
      icon: Icons.bolt_outlined,
      accentColor: Color(0xFFFFB300),
      routeName: 'dorm-electricity',
      sortOrder: 45,
    ),
    FeatureEntryDefinition(
      id: 'service-hall',
      title: '服务大厅',
      subtitle: '统一入口，继续保留主页快捷访问',
      icon: Icons.dashboard_customize_outlined,
      accentColor: AppColors.primary,
      routeName: 'service-hall',
      sortOrder: 50,
    ),
    FeatureEntryDefinition(
      id: 'changxing-jiada',
      title: '畅行嘉大',
      subtitle: '请假、返校、离校与加班申请',
      icon: Icons.north_rounded,
      accentColor: Color(0xFF2EA567),
      routeName: 'changxing-jiada',
      sortOrder: 55,
    ),
    FeatureEntryDefinition(
      id: 'sjjx-notice-list',
      title: '实践通知',
      subtitle: '实践教学通知与公告聚合',
      icon: Icons.science_outlined,
      accentColor: Color(0xFF1976D2),
      routeName: 'sjjx-notice-list',
      sortOrder: 60,
    ),
    FeatureEntryDefinition(
      id: 'notice-list',
      title: '校园公告',
      subtitle: '校级通知与重要公告快速查看',
      icon: Icons.campaign_outlined,
      accentColor: Color(0xFFE7A400),
      routeName: 'notice-list',
      sortOrder: 65,
    ),
    FeatureEntryDefinition(
      id: 'notification-center',
      title: '通知中心',
      subtitle: '集中查看课程、考试与系统提醒',
      icon: Icons.notifications_outlined,
      accentColor: Color(0xFF546E7A),
      routeName: 'notification-center',
      sortOrder: 70,
    ),
  ];
}
