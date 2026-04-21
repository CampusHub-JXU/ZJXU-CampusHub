import 'package:flutter/material.dart';

import '../schedule_constants.dart';
import '../schedule_model.dart';

class ScheduleSlotColumn extends StatelessWidget {
  const ScheduleSlotColumn({super.key, required this.slotColumnWidth});

  final double slotColumnWidth;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (int i = 0; i < scheduleSlotCount; i++)
          Container(
            width: slotColumnWidth,
            height: scheduleGridSlotHeight,
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${i + 1}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${ScheduleSlotTimes.startTime(i + 1)}\n${ScheduleSlotTimes.endTime(i + 1)}',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 9, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
