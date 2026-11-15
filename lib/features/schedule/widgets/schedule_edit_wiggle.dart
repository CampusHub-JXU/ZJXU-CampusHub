import 'dart:math' as math;

import '../../../core/academic/schedule_model.dart';

/// 编辑模式 iOS 式抖动的共享驱动：课表页持有一个 `AnimationController`
/// 周期推进，所有本周课程块共用同一驱动、按 [courseWigglePhase] 错开相位，
/// 避免每个卡片各起一条 ticker。
class ScheduleWiggleDriver {
  ScheduleWiggleDriver._();

  /// 正弦抖动周期（一个完整「左-右-左」循环）。
  static const Duration period = Duration(milliseconds: 280);

  /// 最大旋转角（弧度，约 ±1.26°）。
  static const double maxAngle = 0.022;

  /// 稳定相位：同一门课同一时间段每次进入编辑模式都错开同样的量，
  /// 不用 `String.hashCode`（跨版本不稳定），用 FNV-1a 取模。
  static double courseWigglePhase(CourseEntry course) {
    var hash = 0x811C9DC5;
    final key =
        '${course.courseName}|${course.weekday}|'
        '${course.startLesson}|${course.endLesson}';
    for (final unit in key.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return (hash % 628) / 100.0;
  }

  /// 当前旋转角：controller 的 0..1 进度映射到完整正弦周期。
  static double angleOf(double progress, double phase) =>
      math.sin(progress * math.pi * 2 + phase) * maxAngle;
}
