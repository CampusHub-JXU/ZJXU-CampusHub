import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';

class ServiceHubPage extends StatelessWidget {
  const ServiceHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    final cards = <_ServiceHubCardData>[
      _ServiceHubCardData(
        title: '服务大厅',
        subtitle: '统一入口，继续保留主页快捷访问',
        icon: Icons.dashboard_customize_outlined,
        accentColor: AppColors.primary,
        onTap: () => context.pushNamed('service-hall'),
      ),
      _ServiceHubCardData(
        title: '第二课堂',
        subtitle: '学分活动、个人中心与微信版页面',
        icon: Icons.workspace_premium_outlined,
        accentColor: AppColors.gold,
        onTap: () => context.pushNamed('second-classroom'),
      ),
      _ServiceHubCardData(
        title: '图书馆',
        subtitle: '馆藏检索、借阅与电子资源入口',
        icon: Icons.local_library_outlined,
        accentColor: AppColors.info,
        onTap: () => context.pushNamed('library'),
      ),
      _ServiceHubCardData(
        title: '畅行嘉大',
        subtitle: '请假、返校、离校与加班申请',
        icon: Icons.north_rounded,
        accentColor: const Color(0xFF2EA567),
        onTap: () => context.pushNamed('changxing-jiada'),
      ),
      _ServiceHubCardData(
        title: '实践通知',
        subtitle: '实践教学通知与公告聚合',
        icon: Icons.science_outlined,
        accentColor: const Color(0xFF1976D2),
        onTap: () => context.pushNamed('sjjx-notice-list'),
      ),
      _ServiceHubCardData(
        title: '校园公告',
        subtitle: '校级通知与重要公告快速查看',
        icon: Icons.campaign_outlined,
        accentColor: const Color(0xFFE7A400),
        onTap: () => context.pushNamed('notice-list'),
      ),
      _ServiceHubCardData(
        title: '成绩查询',
        subtitle: '查看成绩、绩点和学业进展',
        icon: Icons.school_outlined,
        accentColor: AppColors.warning,
        onTap: () => context.pushNamed('grades'),
      ),
      _ServiceHubCardData(
        title: '宿舍电费',
        subtitle: '查询剩余电量并管理宿舍配置',
        icon: Icons.bolt_outlined,
        accentColor: const Color(0xFF7B61FF),
        onTap: () => context.pushNamed('dorm-electricity'),
      ),
    ];
    final columns = _splitWaterfallColumns(cards);

    return Scaffold(
      appBar: AppBar(title: const Text('功能')),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            final horizontalPadding = wide ? 24.0 : 16.0;

            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                16,
                horizontalPadding,
                28,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '更多服务',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '把低频但常用的校园入口集中放在这里，主页保持现有布局不变。',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            for (final card in columns.$1) ...[
                              _ServiceHubCard(card: card),
                              const SizedBox(height: 12),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          children: [
                            for (final card in columns.$2) ...[
                              _ServiceHubCard(card: card),
                              const SizedBox(height: 12),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  (List<_ServiceHubCardData>, List<_ServiceHubCardData>) _splitWaterfallColumns(
    List<_ServiceHubCardData> cards,
  ) {
    final left = <_ServiceHubCardData>[];
    final right = <_ServiceHubCardData>[];
    var leftHeight = 0.0;
    var rightHeight = 0.0;

    for (final card in cards) {
      final estimatedHeight = 132.0 + card.subtitle.length * 1.4;
      if (leftHeight <= rightHeight) {
        left.add(card);
        leftHeight += estimatedHeight;
      } else {
        right.add(card);
        rightHeight += estimatedHeight;
      }
    }

    return (left, right);
  }
}

class _ServiceHubCardData {
  const _ServiceHubCardData({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accentColor,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color accentColor;
  final VoidCallback onTap;
}

class _ServiceHubCard extends StatelessWidget {
  const _ServiceHubCard({required this.card});

  final _ServiceHubCardData card;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return InkWell(
      onTap: card.onTap,
      borderRadius: BorderRadius.circular(24),
      child: Ink(
        decoration: BoxDecoration(
          color: isDark ? cs.surfaceContainerLowest : Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: card.accentColor.withValues(alpha: isDark ? 0.26 : 0.18),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.06 : 0.05),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: card.accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(card.icon, color: card.accentColor, size: 22),
              ),
              const SizedBox(height: 24),
              Text(
                card.title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                card.subtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  height: 1.45,
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                children: [
                  Text(
                    '进入服务',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: card.accentColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 18,
                    color: card.accentColor,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
