import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 功能区分类：「常用」之外的固定分组，顺序即展示顺序。
enum FeatureEntryCategory {
  study('学习教务'),
  life('校园生活'),
  affairs('办事与通知');

  const FeatureEntryCategory(this.label);

  final String label;
}

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
    required this.category,
    this.keywords = const [],
  });

  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accentColor;
  final int sortOrder;
  final FeatureEntryCategory category;

  /// 搜索别名：标题 / 副标题之外用户可能输入的叫法（如「校园卡」→ 一卡通）。
  final List<String> keywords;

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
      category: FeatureEntryCategory.study,
      keywords: ['课程', '上课', '周次'],
    ),
    const FeatureEntryDefinition(
      id: 'grades',
      title: '成绩查询',
      subtitle: '查看成绩与绩点',
      icon: Icons.school_outlined,
      accentColor: AppColors.warning,
      primaryActionId: 'grades.open',
      sortOrder: 10,
      category: FeatureEntryCategory.study,
      keywords: ['绩点', 'GPA', '学分'],
    ),
    const FeatureEntryDefinition(
      id: 'exam',
      title: '考试安排',
      subtitle: '查看考试时间、地点与倒计时',
      icon: Icons.event_available_outlined,
      accentColor: Color(0xFF7B61FF),
      primaryActionId: 'exam.open',
      sortOrder: 15,
      category: FeatureEntryCategory.study,
      keywords: ['考场', '期末', '补考'],
    ),
    const FeatureEntryDefinition(
      id: 'academic-progress',
      title: '学业情况',
      subtitle: '培养方案学分进度与修读状态',
      icon: Icons.fact_check_outlined,
      accentColor: Color(0xFF2E7D32),
      primaryActionId: 'academic-progress.open',
      sortOrder: 16,
      category: FeatureEntryCategory.study,
      keywords: ['培养方案', '学分', '毕业审核'],
    ),
    const FeatureEntryDefinition(
      id: 'academic-web',
      title: '教务系统',
      subtitle: '正方教务网页版',
      icon: Icons.account_balance_outlined,
      accentColor: AppColors.primary,
      primaryActionId: 'academic-web.open',
      sortOrder: 17,
      category: FeatureEntryCategory.study,
      keywords: ['正方', '选课', '教务网'],
    ),
    const FeatureEntryDefinition(
      id: 'shuati-practice',
      title: '刷题助手',
      subtitle: '题库导入、错题重练、离线练习',
      icon: Icons.quiz_outlined,
      accentColor: Color(0xFF00897B),
      primaryActionId: 'shuati.open',
      sortOrder: 20,
      category: FeatureEntryCategory.study,
      keywords: ['题库', '练习', '错题'],
    ),
    const FeatureEntryDefinition(
      id: 'second-classroom',
      title: '第二课堂',
      subtitle: '学分活动浏览、订阅提醒与微信版入口',
      icon: Icons.workspace_premium_outlined,
      accentColor: AppColors.gold,
      primaryActionId: 'second-classroom.open',
      sortOrder: 25,
      category: FeatureEntryCategory.study,
      keywords: ['活动', '素质拓展'],
    ),
    const FeatureEntryDefinition(
      id: 'library',
      title: '图书馆',
      subtitle: '馆藏检索、借阅与电子资源入口',
      icon: Icons.local_library_outlined,
      accentColor: AppColors.info,
      primaryActionId: 'library.open',
      sortOrder: 30,
      category: FeatureEntryCategory.study,
      keywords: ['借书', '借阅', '馆藏'],
    ),
    const FeatureEntryDefinition(
      id: 'campus-card',
      title: '一卡通',
      subtitle: '余额查询、校园卡服务与充值入口',
      icon: Icons.credit_card_outlined,
      accentColor: Color(0xFF1E88E5),
      primaryActionId: 'campus-card.open',
      sortOrder: 40,
      category: FeatureEntryCategory.life,
      keywords: ['校园卡', '余额', '充值'],
    ),
    const FeatureEntryDefinition(
      id: 'campus-card-payment',
      title: '付款码',
      subtitle: '扫码支付',
      icon: Icons.qr_code_2_rounded,
      accentColor: Color(0xFF1E88E5),
      primaryActionId: 'campus-card.payment',
      sortOrder: 42,
      category: FeatureEntryCategory.life,
      keywords: ['支付', '二维码', '校园卡'],
    ),
    const FeatureEntryDefinition(
      id: 'dorm-electricity',
      title: '宿舍电费',
      subtitle: '查询寝室剩余电量与低电量提醒',
      icon: Icons.bolt_outlined,
      accentColor: Color(0xFFFFB300),
      primaryActionId: 'electricity.open',
      sortOrder: 45,
      category: FeatureEntryCategory.life,
      keywords: ['电量', '寝室', '宿舍'],
    ),
    const FeatureEntryDefinition(
      id: 'service-hall',
      title: '服务大厅',
      subtitle: '统一入口，继续保留主页快捷访问',
      icon: Icons.dashboard_customize_outlined,
      accentColor: AppColors.primary,
      primaryActionId: 'service-hall.open',
      sortOrder: 50,
      category: FeatureEntryCategory.affairs,
      keywords: ['办事', '移动门户'],
    ),
    const FeatureEntryDefinition(
      id: 'changxing-jiada',
      title: '畅行嘉大',
      subtitle: '请假、返校、离校与加班申请',
      icon: Icons.north_rounded,
      accentColor: Color(0xFF2EA567),
      primaryActionId: 'changxing-jiada.open',
      sortOrder: 55,
      category: FeatureEntryCategory.life,
      keywords: ['请假', '返校', '离校'],
    ),
    const FeatureEntryDefinition(
      id: 'sjjx-notice-list',
      title: '实践通知',
      subtitle: '实践教学通知与公告聚合',
      icon: Icons.science_outlined,
      accentColor: Color(0xFF1976D2),
      primaryActionId: 'sjjx-notice.open',
      sortOrder: 60,
      category: FeatureEntryCategory.affairs,
      keywords: ['实践', '实习'],
    ),
    const FeatureEntryDefinition(
      id: 'notification-center',
      title: '通知中心',
      subtitle: '集中查看课程、考试与系统提醒',
      icon: Icons.notifications_outlined,
      accentColor: Color(0xFF546E7A),
      primaryActionId: 'notification.center',
      sortOrder: 70,
      category: FeatureEntryCategory.affairs,
      keywords: ['提醒', '消息', '公告'],
    ),
    const FeatureEntryDefinition(
      id: 'micro-life',
      title: '嘉大微生活',
      subtitle: '后勤生活服务与校园生活入口',
      icon: Icons.storefront_outlined,
      accentColor: Color(0xFF00897B),
      primaryActionId: 'micro-life.open',
      sortOrder: 75,
      category: FeatureEntryCategory.life,
      keywords: ['后勤', '报修'],
    ),
    const FeatureEntryDefinition(
      id: 'one-stop-service',
      title: '校务服务',
      subtitle: '网上办事大厅（WebVPN 访问）',
      icon: Icons.apartment_outlined,
      accentColor: Color(0xFF3949AB),
      primaryActionId: 'one-stop-service.open',
      sortOrder: 80,
      category: FeatureEntryCategory.affairs,
      keywords: ['办事', '网上办事'],
    ),
    const FeatureEntryDefinition(
      id: 'physical-test',
      title: '体测成绩',
      subtitle: '体质测试成绩与预约（WebVPN 访问）',
      icon: Icons.fitness_center_outlined,
      accentColor: Color(0xFF00838F),
      primaryActionId: 'physical-test.open',
      sortOrder: 85,
      category: FeatureEntryCategory.study,
      keywords: ['体测', '体育', '体质'],
    ),
  ];
}
