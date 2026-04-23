import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../app/theme.dart';
import '../home_controller.dart';

class HomeHeaderCard extends StatelessWidget {
  const HomeHeaderCard({
    super.key,
    required this.currentWeek,
    required this.canShowUpdateAction,
    required this.onTap,
    required this.onNoticeTap,
    required this.courseContent,
    this.updateAction,
  });

  final int currentWeek;
  final bool canShowUpdateAction;
  final VoidCallback onTap;
  final VoidCallback onNoticeTap;
  final Widget courseContent;
  final Widget? updateAction;

  @override
  Widget build(BuildContext context) {
    final glassEnabled = HomeController.instance.headerGlassEnabled.value;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: glassEnabled
              ? BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: _buildContent(context),
                )
              : _buildContent(context),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF7B1527),
            AppColors.primary,
            Color(0xFFB7485E),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        children: [
          Positioned(
            left: -40,
            bottom: -48,
            child: Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.08),
              ),
            ),
          ),
          Positioned(
            right: -30,
            top: -20,
            child: Opacity(
              opacity: 0.12,
              child: SvgPicture.asset(
                'assets/header_texture.svg',
                width: 200,
                height: 200,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '第 $currentWeek 周',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '下节课',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (canShowUpdateAction && updateAction != null) ...[
                      updateAction!,
                      const SizedBox(width: 12),
                    ],
                    IconButton(
                      icon: const Icon(
                        Icons.notifications_outlined,
                        color: Colors.white,
                        size: 22,
                      ),
                      onPressed: onNoticeTap,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(child: courseContent),
                    const SizedBox(width: 8),
                    Text(
                      '查看课表 →',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
