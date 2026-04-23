import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import 'home_card_container.dart';

class HomeNoticeCard extends StatelessWidget {
  const HomeNoticeCard({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: HomeCardContainer(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.gold.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.campaign_outlined,
                color: AppColors.gold,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '校园公告',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
            ),
            Icon(Icons.arrow_forward_ios, size: 12, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
