import 'package:flutter/material.dart';

import '../../home/widgets/home_header_schedule_status.dart';

class ServiceHubHeader extends StatelessWidget {
  const ServiceHubHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const HomeHeaderScheduleStatus(
          hasScheduleCache: true,
          updatedAtText: '功能页',
        ),
        const SizedBox(height: 10),
        Text(
          '更多服务',
          style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          '首页保留高频入口，这里继续承接低频但常用的校内功能。',
          style: textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}
