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
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                // 大字号下时间整体等比缩小，保持一列节次整齐可读。
                SizedBox(
                  width: slotColumnWidth - 6,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${ScheduleSlotTimes.startTime(i + 1)}\n${ScheduleSlotTimes.endTime(i + 1)}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 9.5,
                        height: 1.35,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
