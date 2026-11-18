import 'package:material_ui/material_ui.dart';

import '../../../core/academic/schedule_constants.dart';
import '../../../core/academic/schedule_model.dart';
import '../../../core/theme/app_surface_tokens.dart';
import '../../../core/theme/app_typography.dart';

/// 课表左侧节次列：`1`…`13` + 开始 / 结束时刻。
///
/// 设计系统 v2 · `O1`：节次序号 `12/700`、时刻 `9.5/400`（等宽数字）。
/// 列宽只有 `30dp`，所以时刻整体走 [FittedBox] 等比缩小，
/// 既不换行也不撑破节次列。
class ScheduleSlotColumn extends StatelessWidget {
  const ScheduleSlotColumn({super.key, required this.slotColumnWidth});

  final double slotColumnWidth;

  @override
  Widget build(BuildContext context) {
    final surfaces = context.appSurfaces;
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
                  style: AppScheduleType.slotIndex.copyWith(
                    color: surfaces.ink1,
                  ),
                ),
                const SizedBox(height: 2),
                SizedBox(
                  width: slotColumnWidth - 4,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${ScheduleSlotTimes.startTime(i + 1)}\n${ScheduleSlotTimes.endTime(i + 1)}',
                      textAlign: TextAlign.center,
                      style: AppScheduleType.slotTime.copyWith(
                        color: surfaces.ink3,
                        height: 1.35,
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
