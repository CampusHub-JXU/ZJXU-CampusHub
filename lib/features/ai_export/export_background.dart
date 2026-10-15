import 'export_document.dart';
import 'export_model.dart';
import 'export_text.dart';

const String kExportSchool = '嘉兴大学';

const List<String> _weekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// 某个取值出现的次数与学分合计（课程性质 / 考试性质统计用）。
class ExportValueCount {
  const ExportValueCount({
    required this.value,
    required this.courses,
    required this.credits,
  });

  final String value;
  final int courses;
  final double credits;
}

/// 等级制成绩在**本次数据里观测到**的绩点对应（不是学校的官方换算表）。
class ObservedLetterGrade {
  const ObservedLetterGrade({
    required this.grade,
    required this.gpaPoints,
    required this.courses,
  });

  final String grade;

  /// 该等级在数据里出现过的全部绩点取值（升序，通常只有一个）。
  final List<double> gpaPoints;
  final int courses;
}

/// 单个所选模块的新鲜度。
class ModuleFreshness {
  const ModuleFreshness({
    required this.module,
    required this.status,
    this.lastUpdatedAt,
    this.dataSource,
  });

  final ExportModule module;
  final ExportModuleStatus status;
  final DateTime? lastUpdatedAt;
  final String? dataSource;
}

/// 「给 AI 的背景说明」：每份导出开头的紧凑事实清单，目的是让大模型
/// 不会算错绩点 / 学分、不会误读课程性质与数据时效。
///
/// 只陈述**可从应用逻辑或本次数据推出**的事实；应用不知道的映射（例如
/// 学校官方的等级制 → 绩点换算表）明确写「未知」，绝不编造。
class ExportBackground {
  const ExportBackground._({
    required this.exportedAt,
    required this.environment,
    required this.gpaRules,
    required this.hasGradesData,
    required this.letterGrades,
    required this.gradeNatures,
    required this.progressNatures,
    required this.examTypes,
    required this.freshness,
    required this.missing,
    required this.notes,
  });

  factory ExportBackground.from(AiExportDocument doc) {
    final grades = doc.moduleOf<GradesModuleData>();
    final progress = doc.moduleOf<ProgressModuleData>();
    final hasGrades = grades != null && grades.status.hasData;
    final hasProgress = progress != null && progress.status.hasData;

    final modules = {for (final m in doc.modules) m.module: m};
    return ExportBackground._(
      exportedAt: doc.exportedAt,
      environment: doc.environment,
      gpaRules:
          (modules.containsKey(ExportModule.grades) ||
              modules.containsKey(ExportModule.progress))
          ? _gpaRules(hasGrades: hasGrades, hasProgress: hasProgress)
          : const [],
      hasGradesData: hasGrades,
      letterGrades: hasGrades ? _letterGrades(grades.records) : const [],
      gradeNatures: hasGrades
          ? _tally(grades.records, (r) => r.courseRequirement, (r) => r.credits)
          : const [],
      progressNatures: hasProgress
          ? _tally(
              [for (final (_, c) in progress.flatCourses) c],
              (c) => c.nature,
              (c) => c.credits,
            )
          : const [],
      examTypes: hasGrades
          ? _tally(grades.records, (r) => r.examType, (r) => r.credits)
          : const [],
      freshness: [
        for (final m in doc.modules)
          ModuleFreshness(
            module: m.module,
            status: m.status,
            lastUpdatedAt: m.lastUpdatedAt,
            dataSource: m.dataSource,
          ),
      ],
      missing: [
        for (final m in doc.modules)
          if (!m.status.hasData) m.module,
      ],
      notes: _notes(modules.keys.toSet()),
    );
  }

  final DateTime exportedAt;
  final ExportEnvironment environment;

  /// 绩点 / 学分口径说明（选了成绩或学业进度才有）。
  final List<String> gpaRules;
  final bool hasGradesData;
  final List<ObservedLetterGrade> letterGrades;
  final List<ExportValueCount> gradeNatures;
  final List<ExportValueCount> progressNatures;
  final List<ExportValueCount> examTypes;
  final List<ModuleFreshness> freshness;
  final List<ExportModule> missing;
  final List<String> notes;

  String get weekdayLabel => _weekdayLabels[exportedAt.weekday - 1];

  String get termLine {
    final env = environment;
    final term = env.termLabel == null
        ? '未知'
        : '${env.termLabel}（${env.termSource ?? '来源未知'}）';
    final week = env.week != null
        ? '第 ${env.week} 周'
        : (env.weekNote ?? '教学周未知');
    return '$term；$week';
  }

  // ── 构造期的事实陈述 ─────────────────────────────────────────────────────

  static List<String> _gpaRules({
    required bool hasGrades,
    required bool hasProgress,
  }) => [
    '各门课的绩点（「绩点」列）逐门由教务系统给出。本应用没有、也不使用百分制 / 等级制到绩点的换算表，'
        '请直接使用「绩点」列，不要自行用分数或等级换算。',
    if (hasGrades)
      '应用内汇总绩点 = Σ(绩点×学分) ÷ Σ学分，只统计绩点 > 0 的记录；'
          '绩点为 0 的记录既不进分子也不进分母。',
    if (hasGrades)
      '成绩表包含全部记录（含补考、重修产生的记录），汇总时没有对同一课程取最高分或去重；'
          '教务的官方绩点口径可能不同，以教务为准。',
    if (hasGrades && hasProgress)
      '「学业进度」里的绩点来自教务的学业情况页，「成绩」汇总来自本应用对成绩记录的计算，'
          '二者数据源与口径可能不一致，不要互相校验或混用。',
  ];

  static List<ObservedLetterGrade> _letterGrades(
    List<GradesExportRecord> records,
  ) {
    final points = <String, Set<double>>{};
    final counts = <String, int>{};
    for (final r in records) {
      if (!r.isLetterGrade) continue;
      final g = r.grade!;
      (points[g] ??= <double>{}).add(r.gpaPoints);
      counts[g] = (counts[g] ?? 0) + 1;
    }
    final out = [
      for (final e in points.entries)
        ObservedLetterGrade(
          grade: e.key,
          gpaPoints: (e.value.toList()..sort()),
          courses: counts[e.key]!,
        ),
    ];
    out.sort((a, b) => b.gpaPoints.last.compareTo(a.gpaPoints.last));
    return out;
  }

  static List<ExportValueCount> _tally<T>(
    Iterable<T> items,
    String? Function(T) valueOf,
    double Function(T) creditsOf,
  ) {
    final courses = <String, int>{};
    final credits = <String, double>{};
    for (final item in items) {
      final v = exportOptional(valueOf(item));
      if (v == null) continue;
      courses[v] = (courses[v] ?? 0) + 1;
      credits[v] = (credits[v] ?? 0) + creditsOf(item);
    }
    final out = [
      for (final e in courses.entries)
        ExportValueCount(
          value: e.key,
          courses: e.value,
          credits: credits[e.key]!,
        ),
    ];
    out.sort((a, b) => b.courses.compareTo(a.courses));
    return out;
  }

  static List<String> _notes(Set<ExportModule> included) => [
    if (included.contains(ExportModule.progress))
      '学业进度：「子节点关系」列表示同一节点下子节点的关系（并且 = 全部须满足，或者 = 满足其一）；'
          '「缺口」列 = 要求学分 − 已获学分，最低为 0。',
    if (included.contains(ExportModule.schedule))
      '课表：「整学期课表底稿」是整学期的周课表（按「周次」列在对应周出现，未应用调课通知）；'
          '「第 N 周有效课表」是当前周与下一周已应用调课通知后的有效课表，排期以有效课表为准。',
    if (included.contains(ExportModule.secondClassroom))
      '第二课堂：「已报名」「已签到」「已认定学时」是三件事。「标称学时」列只是活动标称学时，'
          '应用无法得知学校是否已认定或计入；只含未结束的活动，不含历史活动。',
    if (included.contains(ExportModule.notices))
      '教务处通知：仅标题、日期、栏目与链接，不含正文；日期缺失的通知无法判断是否在近 '
          '$kNoticeWindowDays 天内，已略去。',
    if (included.contains(ExportModule.physicalTest))
      '体测：成绩、得分与等级均为教务 / 体测平台原文，评分标准本应用未知。',
  ];

  // ── 输出 ────────────────────────────────────────────────────────────────

  /// Markdown 形态：紧凑的要点清单，供放在文档最前面。
  String toMarkdown() {
    final b = StringBuffer()
      ..writeln('## 给 AI 的背景说明')
      ..writeln()
      ..writeln('- 学校：$kExportSchool（学生本人从校园 App 整理导出，仅供参考）')
      ..writeln('- 导出日期：${exportDate(exportedAt)}（$weekdayLabel）')
      ..writeln('- 当前学期：$termLine');
    if (gpaRules.isNotEmpty) {
      b
        ..writeln()
        ..writeln('### 绩点与学分口径')
        ..writeln();
      for (final rule in gpaRules) {
        b.writeln('- $rule');
      }
      if (letterGrades.isNotEmpty) {
        b.writeln(
          '- 本次数据中等级制成绩与绩点的对应（观测值，非官方换算表）：'
          '${letterGrades.map(_letterText).join('；')}。未出现的等级无法得知其绩点。',
        );
      } else if (hasGradesData) {
        b.writeln('- 本次数据中没有等级制成绩。');
      }
    }
    if (gradeNatures.isNotEmpty || progressNatures.isNotEmpty) {
      b
        ..writeln()
        ..writeln('### 课程性质与考试性质')
        ..writeln()
        ..writeln('- 课程性质原文取自教务，含义以学校培养方案为准，本应用不做归类或解释。');
      if (gradeNatures.isNotEmpty) {
        b.writeln('- 成绩中的课程性质：${gradeNatures.map(_countText).join('、')}');
      }
      if (progressNatures.isNotEmpty) {
        b.writeln('- 学业进度中的课程性质：${progressNatures.map(_countText).join('、')}');
      }
    }
    if (examTypes.isNotEmpty) {
      b.writeln(
        '- 成绩的「考试性质」（补考 / 重修以此区分）：'
        '${examTypes.map(_countText).join('、')}',
      );
    }
    if (notes.isNotEmpty) {
      b
        ..writeln()
        ..writeln('### 模块说明')
        ..writeln();
      for (final n in notes) {
        b.writeln('- $n');
      }
    }
    b
      ..writeln()
      ..writeln('### 数据时效')
      ..writeln()
      ..writeln('| 模块 | 状态 | 最后更新 | 数据来源 |')
      ..writeln('| --- | --- | --- | --- |');
    for (final f in freshness) {
      final has = f.status.hasData;
      b.writeln(
        '| ${f.module.label} | ${f.status.label} '
        '| ${has ? ExportText.formatDateTime(f.lastUpdatedAt) : '—'} '
        '| ${has ? ExportText.mdCell(f.dataSource ?? '未知') : '—'} |',
      );
    }
    if (missing.isNotEmpty) {
      b
        ..writeln()
        ..writeln(
          '> 以下模块未获取，本文件不含其数据，请勿推测：'
          '${missing.map((m) => m.label).join('、')}。',
        );
    }
    return b.toString().trimRight();
  }

  static String _letterText(ObservedLetterGrade l) {
    final pts = l.gpaPoints.map(ExportText.formatPoints).join(' / ');
    return '${l.grade} → $pts（${l.courses} 门）';
  }

  static String _countText(ExportValueCount c) =>
      '${c.value}（${c.courses} 门 / ${ExportText.formatCredits(c.credits)} 学分）';
}
