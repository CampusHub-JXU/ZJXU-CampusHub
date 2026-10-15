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

/// 把整份文档渲染成 Markdown：说明头 + 给 AI 的背景说明 + 各模块。
String renderExportMarkdown(AiExportDocument doc) {
  final b = StringBuffer()
    ..writeln('# 学业数据导出')
    ..writeln()
    ..writeln('> $_disclaimer')
    ..writeln('>')
    ..writeln('> $_privacyNote')
    ..writeln('> 导出时间：${_T.formatDateTime(doc.exportedAt)}')
    ..writeln()
    ..writeln(ExportBackground.from(doc).toMarkdown());
  for (final m in doc.modules) {
    b
      ..writeln()
      ..writeln('## ${m.module.label}')
      ..writeln();
    if (!m.status.hasData) {
      b.writeln('> 未获取：本机暂无该模块数据，未导出，也未推测。');
      continue;
    }
    b.writeln(
      '> ${m.status.label} · ${m.itemCount ?? 0} 条 · ${m.scopeLabel}'
      ' · 更新 ${_T.formatDateTime(m.lastUpdatedAt)}'
      ' · 来源 ${m.dataSource ?? '未知'}',
    );
    if (m.status == ExportModuleStatus.stale) {
      b.writeln('> 已过期：缓存超过有效期，可能不是最新数据。');
    }
    b.writeln();
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
  b
    ..writeln('### 汇总（应用口径）')
    ..writeln()
    ..writeln(
      '- 记录 ${m.records.length} 条，学分合计 ${_T.formatCredits(m.totalCredits)}',
    )
    ..writeln(
      '- 加权绩点：${s.gpa == null ? _dash : _T.formatPoints(s.gpa!)}'
      '（计入 ${s.countedCourses} 条 / ${_T.formatCredits(s.countedCredits)} 学分）',
    )
    ..writeln(
      '- 未计入绩点（绩点为 0）：${s.excludedCourses} 条 / '
      '${_T.formatCredits(s.excludedCredits)} 学分',
    )
    ..writeln()
    ..writeln('| 学期 | 记录数 | 学分 | 加权绩点 | 未计入绩点 |')
    ..writeln('| --- | --- | --- | --- | --- |');
  for (final t in m.terms) {
    b.writeln(
      '| ${_T.mdCell(t.label)} | ${t.courseCount} '
      '| ${_T.formatCredits(t.credits)} '
      '| ${t.summary.gpa == null ? _dash : _T.formatPoints(t.summary.gpa!)} '
      '| ${t.summary.excludedCourses} |',
    );
  }
  b
    ..writeln()
    ..writeln('### 成绩明细')
    ..writeln()
    ..writeln('| 课程 | 成绩 | 百分制 | 绩点 | 学分 | 学年 | 学期 | 考试性质 | 考核方式 | 课程性质 |')
    ..writeln('| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |');
  for (final r in m.records) {
    b.writeln(
      '| ${_T.mdCell(r.courseName)} '
      '| ${_T.mdCell(r.grade)} '
      '| ${_T.mdCell(r.percentageScore)} '
      '| ${_T.formatPoints(r.gpaPoints)} '
      '| ${_T.formatCredits(r.credits)} '
      '| ${_T.mdCell(r.academicYear)} '
      '| ${_T.mdCell(r.semester)} '
      '| ${_T.mdCell(r.examType)} '
      '| ${_T.mdCell(r.assessmentMethod)} '
      '| ${_T.mdCell(r.courseRequirement)} |',
    );
  }
}

void _progress(StringBuffer b, ProgressModuleData m) {
  final s = m.summary;
  if (s != null) {
    b
      ..writeln('### 统计')
      ..writeln()
      ..writeln('- 统计时间：${_T.mdCell(s.statTime)}')
      ..writeln('- 绩点（教务学业情况页）：${_T.mdCell(s.gpa)}')
      ..writeln(
        '- 计划内课程：${_n(s.planTotal)}（通过 ${_n(s.planPassed)}，未过 '
        '${_n(s.planFailed)}，未修 ${_n(s.planNotTaken)}，在修 ${_n(s.studying)}）',
      )
      ..writeln('- 计划外：通过 ${_n(s.outsidePassed)}，未过 ${_n(s.outsideFailed)}')
      ..writeln();
  }
  b
    ..writeln('### 学分要求')
    ..writeln()
    ..writeln('| 节点 | 要求学分 | 已获学分 | 缺口 | 门次（满足/要求） | 状态 | 子节点关系 |')
    ..writeln('| --- | --- | --- | --- | --- | --- | --- |');
  for (final (path, n) in m.flatNodes) {
    final count = (n.requiredCount == null && n.metCount == null)
        ? _dash
        : '${_n(n.metCount)}/${_n(n.requiredCount)}';
    b.writeln(
      '| ${_T.mdCell(path)} '
      '| ${_cr(n.requiredCredits)} '
      '| ${_cr(n.earnedCredits)} '
      '| ${_cr(n.missingCredits)} '
      '| $count '
      '| ${creditStatusLabel(n.creditStatus)} '
      '| ${n.children.isEmpty ? _dash : _T.mdCell(n.relation)} |',
    );
  }
  b
    ..writeln()
    ..writeln('### 课程明细')
    ..writeln();
  final courses = m.flatCourses;
  if (courses.isEmpty) {
    b.writeln('来源未包含课程明细。');
    return;
  }
  b
    ..writeln(
      '| 所属节点 | 课程号 | 课程 | 修读状态 | 学分 | 性质 | 类别 | 计划内 '
      '| 成绩学期 | 成绩 | 绩点 | 补考成绩 | 重修成绩 | 建议修读学期 |',
    )
    ..writeln(
      '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- '
      '| --- | --- | --- |',
    );
  for (final (path, c) in courses) {
    b.writeln(
      '| ${_T.mdCell(path)} '
      '| ${_T.mdCell(c.courseCode)} '
      '| ${_T.mdCell(c.courseName)} '
      '| ${c.status} '
      '| ${_T.formatCredits(c.credits)} '
      '| ${_T.mdCell(c.nature)} '
      '| ${_T.mdCell(c.category)} '
      '| ${_yesNo(c.inPlan)} '
      '| ${_T.mdCell(c.scoreTerm)} '
      '| ${_T.mdCell(c.score)} '
      '| ${c.gradePoint == null ? _dash : _T.formatPoints(c.gradePoint!)} '
      '| ${_T.mdCell(c.makeupScore)} '
      '| ${_T.mdCell(c.retakeScore)} '
      '| ${_T.mdCell(c.suggestedTerm)} |',
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
  b
    ..writeln('| 星期 | 节次 | 时间 | 课程 | 教师 | 地点 | 校区 | 类型 | 周次 | 教务标记调课 |')
    ..writeln('| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |');
  for (final c in rows) {
    b.writeln(
      '| ${_weekday(c.weekday)} '
      '| ${c.startLesson}-${c.endLesson} '
      '| ${c.startTime}-${c.endTime} '
      '| ${_T.mdCell(c.courseName)} '
      '| ${_T.mdCell(c.teacher)} '
      '| ${_T.mdCell(c.location)} '
      '| ${_T.mdCell(c.campus)} '
      '| ${_T.mdCell(c.courseType)} '
      '| ${_T.mdCell(c.weekRange)} '
      '| ${_yesNo(c.hasScheduleChange)} |',
    );
  }
}

void _schedule(StringBuffer b, ScheduleModuleData m) {
  b.writeln('- 课表所属学期：${m.termLabel}；已纳入调课通知 ${m.changeRuleCount} 条');
  for (final w in m.weeks) {
    b
      ..writeln()
      ..writeln('### 第 ${w.week} 周有效课表（已应用调课）')
      ..writeln();
    if (w.courses.isEmpty) {
      b.writeln('该周没有课程。');
    } else {
      _scheduleTable(b, w.courses);
    }
  }
  b
    ..writeln()
    ..writeln('### 整学期课表底稿（未应用调课通知）')
    ..writeln();
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
  b
    ..writeln('| 课程 | 课程号 | 考试名称 | 日期 | 时间 | 地点 | 校区 | 座位号 | 重修 | 学年 | 学期 |')
    ..writeln(
      '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |',
    );
  for (final r in m.records) {
    final time = (r.startTime != null && r.endTime != null)
        ? '${r.startTime}-${r.endTime}'
        : null;
    b.writeln(
      '| ${_T.mdCell(r.courseName)} '
      '| ${_T.mdCell(r.courseCode)} '
      '| ${_T.mdCell(r.examName)} '
      '| ${r.date ?? '时间待定'} '
      '| ${_T.mdCell(time)} '
      '| ${_T.mdCell(r.location)} '
      '| ${_T.mdCell(r.campus)} '
      '| ${_T.mdCell(r.seatNumber)} '
      '| ${_yesNo(r.isRetake)} '
      '| ${_T.mdCell(r.academicYear)} '
      '| ${_T.mdCell(r.semester)} |',
    );
  }
}

String _dt(DateTime? d) => d == null ? _dash : _T.formatDateTime(d);

void _secondClassroom(StringBuffer b, SecondClassroomModuleData m) {
  b
    ..writeln('- 已报名 ${m.enrolled.length} 项，其中已签到 ${m.checkedInCount} 项')
    ..writeln(
      '- 已签到活动的标称学时合计 ${_T.formatCredits(m.checkedInNominalHours)}'
      '（活动标称值，不是学校认定学时；认定结果本应用未获取）',
    )
    ..writeln();
  if (m.enrolled.isEmpty) {
    b.writeln('未结束的活动中没有已报名的项目。');
    return;
  }
  b
    ..writeln('| 活动 | 类别 | 主办 | 开始 | 结束 | 地点 | 标称学时 | 已签到 |')
    ..writeln('| --- | --- | --- | --- | --- | --- | --- | --- |');
  for (final r in m.enrolled) {
    b.writeln(
      '| ${_T.mdCell(r.title)} '
      '| ${_T.mdCell(r.category)} '
      '| ${_T.mdCell(r.organizer)} '
      '| ${_dt(r.activityStart)} '
      '| ${_dt(r.activityEnd)} '
      '| ${_T.mdCell(r.location)} '
      '| ${_T.formatCredits(r.creditHours)} '
      '| ${_yesNo(r.checkedIn)} |',
    );
  }
}

void _notices(StringBuffer b, NoticesModuleData m) {
  if (m.records.isEmpty) {
    b.writeln('近 $kNoticeWindowDays 天内没有教务处通知。');
    return;
  }
  b
    ..writeln('| 日期 | 栏目 | 标题 | 链接 |')
    ..writeln('| --- | --- | --- | --- |');
  for (final r in m.records) {
    b.writeln(
      '| ${_T.mdCell(r.date)} | ${_T.mdCell(r.category)} '
      '| ${_T.mdCell(r.title)} | ${_T.mdCell(r.url)} |',
    );
  }
}

void _physicalTest(StringBuffer b, PhysicalTestModuleData m) {
  if (m.records.isEmpty) {
    b.writeln('来源返回 0 条体测记录。');
    return;
  }
  for (final r in m.records) {
    b
      ..writeln(
        '### ${_T.mdCell(r.academicYear)}'
        '（总分 ${_T.mdCell(r.totalScore)}，等级 ${_T.mdCell(r.grade)}）',
      )
      ..writeln();
    if (r.items.isEmpty) {
      b.writeln('该学年没有分项成绩。');
    } else {
      b
        ..writeln('| 项目 | 成绩 | 得分 | 等级 |')
        ..writeln('| --- | --- | --- | --- |');
      for (final i in r.items) {
        b.writeln(
          '| ${_T.mdCell(i.name)} | ${_T.mdCell(i.result)} '
          '| ${_T.mdCell(i.score)} | ${_T.mdCell(i.level)} |',
        );
      }
    }
    b.writeln();
  }
}
