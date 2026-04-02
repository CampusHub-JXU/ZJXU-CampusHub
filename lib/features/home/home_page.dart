import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('嘉兴大学', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            Text('欢迎使用嘉兴大学门户', style: TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.pushNamed('settings'),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '你好，同学',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
              Text(
                '欢迎使用嘉兴大学门户',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.1,
                  children: [
                    _ActionCard(
                      icon: Icons.calendar_today,
                      title: '课表查询',
                      subtitle: '查看本周课程安排',
                      color: colorScheme.primaryContainer,
                      onColor: colorScheme.onPrimaryContainer,
                      onTap: () => context.pushNamed('schedule'),
                    ),
                    _ActionCard(
                      icon: Icons.grade,
                      title: '成绩查询',
                      subtitle: '查看成绩与绩点',
                      color: colorScheme.secondaryContainer,
                      onColor: colorScheme.onSecondaryContainer,
                      onTap: () => context.pushNamed('grades'),
                    ),
                    _ActionCard(
                      icon: Icons.payment,
                      title: '校园卡',
                      subtitle: '付款码 · 充值',
                      color: colorScheme.tertiaryContainer,
                      onColor: colorScheme.onTertiaryContainer,
                      onTap: () => context.pushNamed('campus-card'),
                    ),
                    _ActionCard(
                      icon: Icons.school,
                      title: '服务大厅',
                      subtitle: '学生事务办理',
                      color: colorScheme.surfaceContainerHighest,
                      onColor: colorScheme.onSurface,
                      onTap: () => context.pushNamed('service-hall'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final Color onColor;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      color: color,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 32, color: onColor),
              const Spacer(),
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: onColor,
                    ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: onColor.withValues(alpha: 0.7),
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
