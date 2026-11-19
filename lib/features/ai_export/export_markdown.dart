import 'export_background.dart';
import 'export_document.dart';
import 'export_model.dart';
import 'export_text.dart';

typedef _T = ExportText;

const String _dash = '—';

const String _disclaimer =
    '本文件由本机已加载 / 获取的数据整理生成，不代表学校官方学业审核结果；'
    '成绩、绩点与学分以教务系统为准。';

const String _privacyNote = '默认不含学号、姓名、账号凭据、Cookie 或支付信息。';

const List<String> _weekdayShort = ['一', '二', '三', '四', '五', '六', '日'];

String _n(int? v) => v?.toString() ?? _dash;

String _cr(double? v) => v == null ? _dash : _T.formatCredits(v);

String _weekday(int d) => d >= 1 && d <= 7 ? '周${_weekdayShort[d - 1]}' : _dash;

String _yesNo(bool v) => v ? '是' : '否';

/// 把整份文档渲染成高信息熵纯文本：说明头 + 给 AI 的背景说明 + 各模块。
/// 不含 Markdown 标题/引用/列表/表格分隔符等格式噪音。
String renderExportMarkdown(AiExportDocument doc) {
  final b = StringBuffer()
    ..writeln('[学业数据导出]')
    ..writeln(_disclaimer)
    ..writeln(_privacyNote)
    ..writeln('导出时间: ${_T.formatDateTime(doc.exportedAt)}')
    ..writeln()
    ..writeln(ExportBackground.from(doc).toPlainText());
  for (final m in doc.modules) {
    b
      ..writeln()
      ..writeln('[${m.module.label}]');
    if (!m.status.hasData) {
      b.writeln('未获取: 本机暂无该模块数据，未导出，也未推测。');
      continue;
    }
    b.writeln(
      '状态: ${m.status.label} | 条数: ${m.itemCount ?? 0} | 范围: ${m.scopeLabel}'
      ' | 更新: ${_T.formatDateTime(m.lastUpdatedAt)}'
      ' | 来源: ${m.dataSource ?? '未知'}',
    );
    if (m.status == ExportModuleStatus.stale) {
      b.writeln('过期提示: 缓存超过有效期，可能不是最新数据。');
    }
    if (m.partialNote != null) {
      b.writeln('部分结果: ${m.partialNote}');
    }
    switch (m) {
      case MissingModuleData():
        break;
      case GradesModuleData():
        _grades(b, m);
      case ProgressModuleData():
        _progress(b, m);
      case ScheduleModuleData():
        _schedule(b, m);
      case ExamsModuleData():
        _exams(b, m);
      case SecondClassroomModuleData():
        _secondClassroom(b, m);
      case NoticesModuleData():
        _notices(b, m);
      case PhysicalTestModuleData():
        _physicalTest(b, m);
    }
  }
  return b.toString().trimRight();
}

void _grades(StringBuffer b, GradesModuleData m) {
  final s = m.summary;
  b.writeln('汇总（应用口径）:');
  if (m.isPartial) {
    b.writeln('注意: 以下汇总只覆盖已取到的 ${m.records.length} 条记录，不是全部成绩。');
  }
  b
    ..writeln(
      '记录 ${m.records.length} 条，学分合计 ${_T.formatCredits(m.totalCredits)}',
    )
    ..writeln(
      '加权绩点: ${s.gpa == null ? _dash : _T.formatPoints(s.gpa!)}'
      '（计入 ${s.countedCourses} 条 / ${_T.formatCredits(s.countedCredits)} 学分）',
    )
    ..writeln(
      '未计入绩点（绩点为 0）: ${s.excludedCourses} 条 / '
      '${_T.formatCredits(s.excludedCredits)} 学分',
    )
    ..writeln('学期 | 记录数 | 学分 | 加权绩点 | 未计入绩点');
  for (final t in m.terms) {
    b.writeln(
      '${_T.cell(t.label)} | ${t.courseCount} | '
      '${_T.formatCredits(t.credits)} | '
      '${t.summary.gpa == null ? _dash : _T.formatPoints(t.summary.gpa!)} | '
      '${t.summary.excludedCourses}',
    );
  }
  b
    ..writeln('成绩明细:')
    ..writeln('课程 | 成绩 | 百分制 | 绩点 | 学分 | 学年 | 学期 | 考试性质 | 考核方式 | 课程性质');
  for (final r in m.records) {
    b.writeln(
      '${_T.cell(r.courseName)} | '
      '${_T.cell(r.grade)} | '
      '${_T.cell(r.percentageScore)} | '
      '${_T.formatPoints(r.gpaPoints)} | '
      '${_T.formatCredits(r.credits)} | '
      '${_T.cell(r.academicYear)} | '
      '${_T.cell(r.semester)} | '
      '${_T.cell(r.examType)} | '
      '${_T.cell(r.assessmentMethod)} | '
      '${_T.cell(r.courseRequirement)}',
    );
  }
}

void _progress(StringBuffer b, ProgressModuleData m) {
  final s = m.summary;
  if (s != null) {
    b
      ..writeln('统计时间: ${_T.cell(s.statTime)}')
      ..writeln('绩点（教务学业情况页）: ${_T.cell(s.gpa)}')
      ..writeln(
        '计划内课程: ${_n(s.planTotal)}（通过 ${_n(s.planPassed)}，未过 '
        '${_n(s.planFailed)}，未修 ${_n(s.planNotTaken)}，在修 ${_n(s.studying)}）',
      )
      ..writeln('计划外: 通过 ${_n(s.outsidePassed)}，未过 ${_n(s.outsideFailed)}');
  }
  b
    ..writeln('学分要求:')
    ..writeln('节点 | 要求学分 | 已获学分 | 缺口 | 门次（满足/要求） | 状态 | 子节点关系');
  for (final (path, n) in m.flatNodes) {
    final count = (n.requiredCount == null && n.metCount == null)
        ? _dash
        : '${_n(n.metCount)}/${_n(n.requiredCount)}';
    b.writeln(
      '${_T.cell(path)} | '
      '${_cr(n.requiredCredits)} | '
      '${_cr(n.earnedCredits)} | '
      '${_cr(n.missingCredits)} | '
      '$count | '
      '${creditStatusLabel(n.creditStatus)} | '
      '${n.children.isEmpty ? _dash : _T.cell(n.relation)}',
    );
  }
  b.writeln('课程明细:');
  final courses = m.flatCourses;
  if (courses.isEmpty) {
    b.writeln('来源未包含课程明细。');
    return;
  }
  b.writeln(
    '所属节点 | 课程号 | 课程 | 修读状态 | 学分 | 性质 | 类别 | 计划内 | '
    '成绩学期 | 成绩 | 绩点 | 补考成绩 | 重修成绩 | 建议修读学期',
  );
  for (final (path, c) in courses) {
    b.writeln(
      '${_T.cell(path)} | '
      '${_T.cell(c.courseCode)} | '
      '${_T.cell(c.courseName)} | '
      '${c.status} | '
      '${_T.formatCredits(c.credits)} | '
      '${_T.cell(c.nature)} | '
      '${_T.cell(c.category)} | '
      '${_yesNo(c.inPlan)} | '
      '${_T.cell(c.scoreTerm)} | '
      '${_T.cell(c.score)} | '
      '${c.gradePoint == null ? _dash : _T.formatPoints(c.gradePoint!)} | '
      '${_T.cell(c.makeupScore)} | '
      '${_T.cell(c.retakeScore)} | '
      '${_T.cell(c.suggestedTerm)}',
    );
  }
}

String creditStatusLabel(String name) => switch (name) {
  'notMet' => '未满足',
  'met' => '已满足',
  'exceeded' => '已超出',
  _ => _dash,
};

void _scheduleTable(StringBuffer b, List<ScheduleCourseRecord> rows) {
  b.writeln('星期 | 节次 | 时间 | 课程 | 教师 | 地点 | 校区 | 类型 | 周次 | 教务标记调课');
  for (final c in rows) {
    b.writeln(
      '${_weekday(c.weekday)} | '
      '${c.startLesson}-${c.endLesson} | '
      '${c.startTime}-${c.endTime} | '
      '${_T.cell(c.courseName)} | '
      '${_T.cell(c.teacher)} | '
      '${_T.cell(c.location)} | '
      '${_T.cell(c.campus)} | '
      '${_T.cell(c.courseType)} | '
      '${_T.cell(c.weekRange)} | '
      '${_yesNo(c.hasScheduleChange)}',
    );
  }
}

void _schedule(StringBuffer b, ScheduleModuleData m) {
  b.writeln('课表所属学期: ${m.termLabel}；已纳入调课通知 ${m.changeRuleCount} 条');
  for (final w in m.weeks) {
    b.writeln('第 ${w.week} 周有效课表（已应用调课）:');
    if (w.courses.isEmpty) {
      b.writeln('该周没有课程。');
    } else {
      _scheduleTable(b, w.courses);
    }
  }
  b.writeln('整学期课表底稿（未应用调课通知）:');
  if (m.courses.isEmpty) {
    b.writeln('来源返回 0 门课程。');
  } else {
    _scheduleTable(b, m.courses);
  }
}

void _exams(StringBuffer b, ExamsModuleData m) {
  if (m.records.isEmpty) {
    b.writeln('来源返回 0 条考试安排。');
    return;
  }
  b.writeln('课程 | 课程号 | 考试名称 | 日期 | 时间 | 地点 | 校区 | 座位号 | 重修 | 学年 | 学期');
  var anyUnparsed = false;
  var anyUnscheduled = false;
  for (final r in m.records) {
    final parsedTime = (r.startTime != null && r.endTime != null)
        ? '${r.startTime}-${r.endTime}'
        : null;
    final raw = r.timeText;
    final unparsed = raw != null && (r.date == null || parsedTime == null);
    if (unparsed) anyUnparsed = true;
    if (r.date == null && raw == null) anyUnscheduled = true;
    final dateCell = r.date ?? (raw == null ? '时间待定' : '未解析');
    final time = unparsed ? '原文: $raw' : parsedTime;
    b.writeln(
      '${_T.cell(r.courseName)} | '
      '${_T.cell(r.courseCode)} | '
      '${_T.cell(r.examName)} | '
      '$dateCell | '
      '${_T.cell(time)} | '
      '${_T.cell(r.location)} | '
      '${_T.cell(r.campus)} | '
      '${_T.cell(r.seatNumber)} | '
      '${_yesNo(r.isRetake)} | '
      '${_T.cell(r.academicYear)} | '
      '${_T.cell(r.semester)}',
    );
  }
  if (anyUnscheduled) {
    b.writeln('「时间待定」= 教务尚未给出考试时间（未安排）。');
  }
  if (anyUnparsed) {
    b.writeln('「未解析」「原文: …」= 教务给出了时间文案，但应用未能完整解析出日期 / 起止时间，已原样保留。');
  }
}

String _dt(DateTime? d) => d == null ? _dash : _T.formatDateTime(d);

void _secondClassroom(StringBuffer b, SecondClassroomModuleData m) {
  b
    ..writeln('已报名 ${m.enrolled.length} 项，其中已签到 ${m.checkedInCount} 项')
    ..writeln(
      '已签到活动的标称学时合计 ${_T.formatCredits(m.checkedInNominalHours)}'
      '（活动标称值，不是学校认定学时；认定结果本应用未获取）',
    );
  if (m.enrolled.isEmpty) {
    b.writeln('未结束的活动中没有已报名的项目。');
    return;
  }
  b.writeln('活动 | 类别 | 主办 | 开始 | 结束 | 地点 | 标称学时 | 已签到');
  for (final r in m.enrolled) {
    b.writeln(
      '${_T.cell(r.title)} | '
      '${_T.cell(r.category)} | '
      '${_T.cell(r.organizer)} | '
      '${_dt(r.activityStart)} | '
      '${_dt(r.activityEnd)} | '
      '${_T.cell(r.location)} | '
      '${_T.formatCredits(r.creditHours)} | '
      '${_yesNo(r.checkedIn)}',
    );
  }
}

void _notices(StringBuffer b, NoticesModuleData m) {
  if (m.records.isEmpty) {
    b.writeln(
      m.isPartial
          ? '在已获取的范围内未发现近 $kNoticeWindowDays 天的教务处通知；'
                '覆盖范围不完整，不能据此判断没有通知。'
          : '近 $kNoticeWindowDays 天内没有教务处通知。',
    );
    return;
  }
  b.writeln('日期 | 栏目 | 标题 | 链接');
  for (final r in m.records) {
    b.writeln(
      '${_T.cell(r.date)} | ${_T.cell(r.category)} | '
      '${_T.cell(r.title)} | ${_T.cell(r.url)}',
    );
  }
}

void _physicalTest(StringBuffer b, PhysicalTestModuleData m) {
  if (m.records.isEmpty) {
    b.writeln('来源返回 0 条体测记录。');
    return;
  }
  for (final r in m.records) {
    b.writeln(
      '${_T.cell(r.academicYear)}（总分 ${_T.cell(r.totalScore)}，等级 ${_T.cell(r.grade)}）:',
    );
    if (r.items.isEmpty) {
      b.writeln('该学年没有分项成绩。');
    } else {
      b.writeln('项目 | 成绩 | 得分 | 等级');
      for (final i in r.items) {
        b.writeln(
          '${_T.cell(i.name)} | ${_T.cell(i.result)} | '
          '${_T.cell(i.score)} | ${_T.cell(i.level)}',
        );
      }
    }
  }
}
