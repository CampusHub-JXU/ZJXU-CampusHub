import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import 'home_card_container.dart';

class HomeCampusCardBalanceCard extends StatelessWidget {
  const HomeCampusCardBalanceCard({
    super.key,
    required this.balanceText,
    required this.onTap,
    required this.onPaymentTap,
  });

  final String balanceText;
  final Future<void> Function() onTap;
  final Future<void> Function() onPaymentTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return HomeCardContainer(
      height: 160,
      onTap: () => onTap(),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '校园卡',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 12),
                balanceText == '--'
                    ? Text(
                        '余额未刷新，请先登录一卡通',
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            balanceText,
                            style: TextStyle(
                              fontSize: 32,
                              height: 1,
                              fontWeight: FontWeight.w700,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '元',
                            style: TextStyle(
                              fontSize: 16,
                              height: 1,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.bottomLeft,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => onPaymentTap(),
                child: Transform.translate(
                  offset: const Offset(-4, 0),
                  child: IntrinsicWidth(
                    child: Container(
                      height: 44,
                      constraints: const BoxConstraints(minWidth: 80),
                      padding: const EdgeInsets.only(left: 12, right: 14),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const Icon(
                                Icons.qr_code_2_rounded,
                                size: 28,
                                color: AppColors.primary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '付款码',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurface,
                                  height: 1.0,
                                ),
                                maxLines: 1,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 2, bottom: 4),
              child: Icon(
                Icons.arrow_forward_ios,
                size: 14,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
