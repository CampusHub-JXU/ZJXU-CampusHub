import '../../core/semester/current_term_resolver.dart';
import '../../core/semester/schedule_term_context.dart';
import '../../core/semester/semester_calendar.dart';
import 'export_model.dart';

/// 导出时刻的「当前学期 / 教学周」环境：给 AI 的背景说明用。
///
/// 纯数据，便于测试注入；[capture] 只读取已有的内存状态，不触发网络。
class ExportEnvironment {
  const ExportEnvironment({
    this.termLabel,
    this.academicYear,
    this.termCode,
    this.termSource,
    this.week,
    this.weekNote,
  });

  /// 如 `2025-2026 学年第二学期`；未知为 `null`。
  final String? termLabel;
  final int? academicYear;

  /// 正方学期代码：3 = 第一学期，12 = 第二学期。
  final int? termCode;

  /// 学期来源：教务系统识别 / 按日期推算。
  final String? termSource;

  /// 当前教学周（1-20）；未开学 / 已超出范围时为 `null`。
  final int? week;

  /// 周次缺失的原因（尚未开学 / 已超出教学周范围）。
  final String? weekNote;

  static ExportEnvironment capture(DateTime now) {
    final known = CurrentTermResolver.instance.knownCurrentTerm;
    final term = known ?? ScheduleTermContext.current(now);
    final calendar = SemesterCalendar.instance;
    final before = calendar.isBeforeSemesterStart(now);
    final after = calendar.isAfterSemesterEnd(now);
    return ExportEnvironment(
      termLabel:
          '${term.academicYear}-${term.academicYear + 1} 学年${term.termLabel}',
      academicYear: term.academicYear,
      termCode: term.term,
      termSource: known != null ? '教务系统识别' : '按日期推算，可能与教务不一致',
      week: (before || after) ? null : calendar.weekForDate(now),
      weekNote: before
          ? '尚未开学'
          : after
          ? '已超出 20 个教学周'
          : null,
    );
  }
}

/// 一次导出的完整文档：所选模块（按固定顺序）+ 导出时间 + 环境。
class AiExportDocument {
  const AiExportDocument({
    required this.exportedAt,
    required this.environment,
    required this.modules,
  });

  final DateTime exportedAt;
  final ExportEnvironment environment;
  final List<ExportModuleData> modules;

  bool get hasAnyData => modules.any((m) => m.status.hasData);

  T? moduleOf<T extends ExportModuleData>() {
    for (final m in modules) {
      if (m is T) return m;
    }
    return null;
  }
}
