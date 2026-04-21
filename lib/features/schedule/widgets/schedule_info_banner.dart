import 'package:flutter/material.dart';

class ScheduleInfoBanner extends StatelessWidget {
  const ScheduleInfoBanner({
    super.key,
    required this.message,
    required this.updatedAt,
    required this.loggedIn,
  });

  final String? message;
  final DateTime? updatedAt;
  final bool loggedIn;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final parts = <String>[
      if ((message ?? '').isNotEmpty) message!,
      if (updatedAt != null) '最近更新 ${_formatDateTime(updatedAt!)}',
      if (!loggedIn && updatedAt != null) '当前仅展示缓存',
    ];

    if (parts.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        parts.join(' · '),
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
    );
  }

  String _formatDateTime(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$month-$day $hour:$minute';
  }
}

