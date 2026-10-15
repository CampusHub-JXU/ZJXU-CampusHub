import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/academic/exam_model.dart';
import 'package:jxu_campus_hub/core/notice/notice_model.dart';
import 'package:jxu_campus_hub/features/ai_export/export_background.dart';
import 'package:jxu_campus_hub/features/ai_export/export_builder.dart';
import 'package:jxu_campus_hub/features/ai_export/export_document.dart';
import 'package:jxu_campus_hub/features/ai_export/export_model.dart';

import '../../helpers/ai_export_fixtures.dart';

void main() {
  group('用途预设', () {
    test('三个预设对应的模块集合', () {
      expect(ExportPreset.planning.modules, {
        ExportModule.progress,
        ExportModule.grades,
      });
      expect(ExportPreset.upcoming.modules, {
        ExportModule.schedule,
        ExportModule.exams,
        ExportModule.secondClassroom,
        ExportModule.notices,
      });
      expect(ExportPreset.all.modules, ExportModule.values.toSet());
      // 体测只在「全部」里。
      expect(
        ExportPreset.planning.modules,
        isNot(contains(ExportModule.physicalTest)),
      );
      expect(
        ExportPreset.upcoming.modules,
        isNot(contains(ExportModule.physicalTest)),
      );
    });

    test('matching：恰好等于预设才命中，手动微调后为自定义', () {
      expect(
        ExportPreset.matching(ExportPreset.planning.modules),
        ExportPreset.planning,
      );
      expect(ExportPreset.matching(ExportPreset.all.modules), ExportPreset.all);
      expect(ExportPreset.matching({ExportModule.grades}), isNull);
      expect(
        ExportPreset.matching({
          ...ExportPreset.planning.modules,
          ExportModule.exams,
        }),
        isNull,
      );
    });
  });

  group('给 AI 的背景说明', () {
    test('Markdown：学校 / 日期 / 学期 / 周次 与绩点口径', () {
      final md = ExportBuilder.markdown(
        fullDocument(modules: ExportPreset.planning.modules),
      );
      expect(md, contains('## 给 AI 的背景说明'));
      expect(md, contains('嘉兴大学'));
      expect(md, contains('导出日期：2026-10-13（周二）'));
      expect(md, contains('2026-2027 学年第一学期（教务系统识别）；第 7 周'));
      // 说明在模块内容之前。
      expect(md.indexOf('给 AI 的背景说明'), lessThan(md.indexOf('## 成绩')));
    });

    test('绩点口径：只陈述应用逻辑与观测值，不编造换算表', () {
      final md = ExportBuilder.markdown(
        fullDocument(modules: {ExportModule.grades}),
      );
      expect(md, contains('没有、也不使用百分制 / 等级制到绩点的换算表'));
      expect(md, contains('Σ(绩点×学分) ÷ Σ学分'));
      expect(md, contains('只统计绩点 > 0'));
      expect(md, contains('没有对同一课程取最高分或去重'));
      // 等级制观测值（来自本次数据，而不是内置换算表）。
      expect(md, contains('优秀 → 4.50（1 门）'));
      expect(md, contains('良好 → 3.50（1 门）'));
      expect(md, contains('合格 → 0（1 门）'));
      expect(md, contains('未出现的等级无法得知其绩点'));
      // 百分制数值成绩不会被当成等级。
      expect(md, isNot(contains('88 →')));
    });

    test('没有等级制成绩时如实说明；未选成绩 / 学业进度时不写绩点口径', () {
      final noLetters = ExportBuilder.markdown(
        fullDocument(
          modules: {ExportModule.grades},
          overrides: {
            ExportModule.grades: gradesData(
              records: [
                gradeRecord(
                  grade: '90',
                  percentage: '90',
                  gpa: 4.0,
                  credits: 2,
                ),
              ],
            ),
          },
        ),
      );
      expect(noLetters, contains('本次数据中没有等级制成绩'));

      final noGpa = ExportBuilder.markdown(
        fullDocument(modules: {ExportModule.exams}),
      );
      expect(noGpa, isNot(contains('绩点与学分口径')));
    });

    test('课程性质 / 考试性质按原文统计，不做解释', () {
      final doc = fullDocument(
        modules: {ExportModule.grades, ExportModule.progress},
      );
      final bg = ExportBackground.from(doc);
      final gradeNature = {for (final c in bg.gradeNatures) c.value: c.courses};
      expect(gradeNature['必修'], 3);
      expect(gradeNature['专业必修'], 1);
      expect(gradeNature['公共选修'], 1);
      expect(bg.progressNatures.single.value, '必修');
      final examTypes = {for (final c in bg.examTypes) c.value: c.courses};
      expect(examTypes['补考'], 1);
      expect(examTypes['正常考试'], 4);
      expect(
        ExportBuilder.markdown(doc),
        contains('课程性质原文取自教务，含义以学校培养方案为准，本应用不做归类或解释'),
      );
    });

    test('数据时效与缺失模块：缺失的明确列出，不含其数据', () {
      final doc = fullDocument(
        modules: {
          ExportModule.grades,
          ExportModule.schedule,
          ExportModule.notices,
        },
        overrides: {
          ExportModule.notices: const ExportModuleData.missing(
            ExportModule.notices,
          ),
          ExportModule.grades: gradesData(status: ExportModuleStatus.stale),
        },
      );
      final bg = ExportBackground.from(doc);
      expect(bg.missing, [ExportModule.notices]);
      expect(
        {for (final f in bg.freshness) f.module: f.status},
        {
          ExportModule.grades: ExportModuleStatus.stale,
          ExportModule.schedule: ExportModuleStatus.available,
          ExportModule.notices: ExportModuleStatus.missing,
        },
      );

      final md = ExportBuilder.markdown(doc);
      expect(md, contains('| 教务处通知 | 未获取 | — | — |'));
      expect(md, contains('以下模块未获取，本文件不含其数据，请勿推测：教务处通知'));
      expect(md, contains('| 成绩 | 已过期 |'));
    });

    test('周次缺失时写明原因；学期来源如实标注', () {
      final md = ExportBuilder.markdown(
        fullDocument(
          modules: {ExportModule.exams},
          environment: const ExportEnvironment(
            termLabel: '2026-2027 学年第一学期',
            termSource: '按日期推算，可能与教务不一致',
            weekNote: '尚未开学',
          ),
        ),
      );
      expect(md, contains('按日期推算，可能与教务不一致'));
      expect(md, contains('尚未开学'));
    });

    test('背景数据：学期 / 周次 / 观测到的等级对应', () {
      final bg = ExportBackground.from(
        fullDocument(modules: ExportPreset.planning.modules),
      );
      expect(bg.environment.week, 7);
      expect(bg.environment.termCode, 3);
      expect(bg.weekdayLabel, '周二');
      expect(bg.gpaRules.first, contains('没有、也不使用'));
      final letters = {for (final l in bg.letterGrades) l.grade: l.gpaPoints};
      expect(letters['优秀'], [4.5]);
      expect(letters['合格'], [0.0]);
    });

    test('背景说明不出现 JSON 字段名，改用 Markdown 里读者能看到的列名', () {
      final md = ExportBuilder.markdown(fullDocument());
      for (final raw in [
        'gpaPoints',
        'missingCredits',
        'relation',
        'creditsVerified',
        'nominalCreditHours',
        'weekRange',
        'schemaVersion',
      ]) {
        expect(md, isNot(contains(raw)), reason: raw);
      }
      expect(md, contains('「缺口」列 = 要求学分 − 已获学分'));
      expect(md, contains('「子节点关系」列表示同一节点下子节点的关系'));
      expect(md, contains('「整学期课表底稿」是整学期的周课表'));
      expect(md, contains('「第 N 周有效课表」是当前周与下一周'));
      expect(md, contains('「标称学时」列只是活动标称学时'));
    });
  });

  group('成绩（全部学期 + 绩点汇总）', () {
    test('默认导出全部学期，汇总绩点与手算一致', () {
      final grades = gradesData();
      // Σ(绩点×学分) = 22.5 + 10.5 + 15.2 + 4.5 = 52.7；Σ学分 = 15。
      expect(grades.summary.gpa, closeTo(52.7 / 15, 1e-9));
      expect(grades.summary.countedCredits, 15);
      expect(grades.summary.excludedCourses, 1);
      expect(grades.summary.excludedCredits, 2);
      expect(grades.totalCredits, 17);
      expect(grades.scopeLabel, '全部学期');
      expect(grades.terms.map((t) => t.label).toList(), [
        '2024-2025 第一学期',
        '2024-2025 第二学期',
        '2025-2026 第一学期',
        '2025-2026 第二学期',
      ]);

      final md = ExportBuilder.markdown(
        fullDocument(modules: {ExportModule.grades}),
      );
      expect(md, contains('加权绩点：3.51（计入 4 条 / 15.0 学分）'));
      expect(md, contains('未计入绩点（绩点为 0）：1 条 / 2.0 学分'));
      expect(
        md,
        contains('| 线性代数 | 65 | 65 | 1.50 | 3.0 | 2024-2025 | 第二学期 | 补考 |'),
      );
    });

    test('汇总 / 分学期 / 明细条数', () {
      final m = gradesData();
      expect(m.itemCount, 5);
      expect(m.scopeLabel, '全部学期');
      expect(m.totalCredits, 17);
      expect(m.summary.countedCourses, 4);
      expect(m.terms, hasLength(4));
      expect(m.records, hasLength(5));
    });

    test('学期排序：数字 "1"/"2"/"3" 与中文名统一，第三学期在第二学期之后', () {
      final g = gradesData(
        records: [
          gradeRecord(course: 'c', year: '2025-2026', semester: '3'),
          gradeRecord(course: 'b', year: '2025-2026', semester: '2'),
          gradeRecord(course: 'a', year: '2025-2026', semester: '1'),
          gradeRecord(course: 'd', year: '2024-2025', semester: '第二学期'),
          gradeRecord(course: 'e', year: '2024-2025', semester: '第一学期'),
          gradeRecord(course: 'f', year: '2024-2025', semester: '第三学期'),
        ],
      );
      expect(g.terms.map((t) => t.label).toList(), [
        '2024-2025 第一学期',
        '2024-2025 第二学期',
        '2024-2025 第三学期',
        '2025-2026 1',
        '2025-2026 2',
        '2025-2026 3',
      ]);
      expect(exportSemesterRank('1'), lessThan(exportSemesterRank('2')));
      expect(exportSemesterRank('3'), greaterThan(exportSemesterRank('第二学期')));
      expect(exportSemesterRank('未知'), greaterThan(exportSemesterRank('3')));
    });

    test('部分结果：说明原因，汇总标注只覆盖已取到的记录', () {
      final g = GradesModuleData(
        status: ExportModuleStatus.available,
        lastUpdatedAt: DateTime(2026, 10, 13, 9),
        dataSource: '刚获取',
        partialNote: '仅前 1000 条，可能不全',
        records: [gradeRecord()],
      );
      expect(g.isPartial, isTrue);
      expect(g.scopeLabel, '已取到的学期');
      final md = ExportBuilder.markdown(
        fullDocument(
          modules: {ExportModule.grades},
          overrides: {ExportModule.grades: g},
        ),
      );
      expect(md, contains('> 部分结果：仅前 1000 条，可能不全'));
      expect(md, contains('以下汇总只覆盖已取到的 1 条记录，不是全部成绩'));
      expect(md, contains('| 成绩 | 已获取（部分） |'));
      expect(md, contains('以下模块只是部分结果，不要当作完整数据：成绩（仅前 1000 条，可能不全）'));
    });

    test('没有可计入记录时绩点为 null 而不是 0', () {
      final g = gradesData(
        records: [gradeRecord(grade: '合格', gpa: 0, credits: 1)],
      );
      expect(g.summary.gpa, isNull);
      expect(
        ExportBuilder.markdown(
          fullDocument(
            modules: {ExportModule.grades},
            overrides: {ExportModule.grades: g},
          ),
        ),
        contains('加权绩点：—'),
      );
    });
  });

  group('学业进度', () {
    test('学分缺口、补考成绩与子节点关系', () {
      final md = ExportBuilder.markdown(
        fullDocument(modules: {ExportModule.progress}),
      );
      expect(md, contains('绩点（教务学业情况页）：3.52'));
      expect(
        md,
        contains('| 培养方案 / 专业必修 | 40.0 | 30.0 | 10.0 | 7/10 | 未满足 | — |'),
      );
      expect(md, contains('| 培养方案 | 160.0 | 90.0 | 70.0 | — | 未满足 | 并且 |'));
      expect(md, contains('操作系统'));
      final m = fullDocument(modules: {ExportModule.progress})
          .moduleOf<ProgressModuleData>()!;
      final leaf = m.nodes.single.children.single;
      final course = leaf.courses.first;
      expect(course.makeupScore, '60');
      expect(course.retakeScore, isNull);
    });
  });

  group('课表（已应用调课）', () {
    test('当前周与下一周的有效课表应用调课，整学期底稿不变', () {
      final data = scheduleData();
      expect(data.weeks.map((w) => w.week).toList(), [7, 8]);
      // 第 7 周周一 1-2 节高等数学被停课；第 8 周恢复。
      expect(data.weeks[0].courses.map((c) => c.courseName), ['大学英语']);
      expect(data.weeks[1].courses.map((c) => c.courseName), ['高等数学A', '大学英语']);
      expect(data.courses.map((c) => c.courseName), ['高等数学A', '大学英语']);
      expect(data.changeRuleCount, 1);
      expect(data.termLabel, '2026-2027 学年第一学期');
    });

    test('Markdown 含节次时间、教室、教务调课标记；学号不外泄', () {
      final doc = fullDocument(modules: {ExportModule.schedule});
      final md = ExportBuilder.markdown(doc);
      expect(md, contains('### 第 7 周有效课表（已应用调课）'));
      expect(
        md,
        contains(
          '| 周三 | 3-4 | 09:45-11:10 | 大学英语 | 李老师 | 教学楼B202 | 南湖校区 | 理论 | 1-16周 | 是 |',
        ),
      );
      expect(md, isNot(contains('SHOULD-NOT-LEAK')));
    });

    test('未开学只给第 1 周，超出教学周不给有效周课表', () {
      final before = ScheduleModuleData.fromSnapshot(
        scheduleSnapshot(),
        now: kExportNow,
        currentWeek: 1,
        beforeSemesterStart: true,
        afterSemesterEnd: false,
      );
      expect(before.weeks.map((w) => w.week), [1]);
      final after = ScheduleModuleData.fromSnapshot(
        scheduleSnapshot(),
        now: kExportNow,
        currentWeek: 20,
        beforeSemesterStart: false,
        afterSemesterEnd: true,
      );
      expect(after.weeks, isEmpty);
    });
  });

  group('考试', () {
    test('Markdown 字段', () {
      final doc = fullDocument(modules: {ExportModule.exams});
      final md = ExportBuilder.markdown(doc);
      expect(md, contains('2027-01-10'));
      expect(md, contains('09:00-11:00'));
      final m = doc.moduleOf<ExamsModuleData>()!;
      expect(m.scopeLabel, '当前学期');
      expect(m.records.single.date, '2027-01-10');
    });

    ExamsModuleData examsFrom(Object? rawTime) => ExamsModuleData.fromEntries(
      [
        ExamEntry.fromJson({'kcmc': '线性代数', 'kssj': rawTime, 'ksmc': '期末考试'}),
      ],
      status: ExportModuleStatus.available,
      lastUpdatedAt: DateTime(2026, 10, 13, 9, 5),
      dataSource: '刚获取',
    );

    String examMd(ExamsModuleData data) => ExportBuilder.markdown(
      fullDocument(
        modules: {ExportModule.exams},
        overrides: {ExportModule.exams: data},
      ),
    );

    test('时间文案解析不出日期 / 起止时间：保留教务原文，不写成「时间待定」', () {
      final md = examMd(examsFrom('2027年1月10日 上午第二场'));
      expect(md, contains('| 未解析 | 原文：2027年1月10日 上午第二场 |'));
      expect(md, isNot(contains('时间待定 |')));
      expect(md, contains('已原样保留'));
    });

    test('只解析出日期、没有起止时间：日期照写，时间列保留原文', () {
      final md = examMd(examsFrom('第20周 周六(2027-01-10) 上午'));
      expect(md, contains('| 2027-01-10 | 原文：第20周 周六(2027-01-10) 上午 |'));
    });

    test('教务没有给出任何时间文案：才是「时间待定」（未安排）', () {
      final md = examMd(examsFrom(''));
      expect(md, contains('| 时间待定 |'));
      expect(md, contains('教务尚未给出考试时间（未安排）'));
      expect(md, isNot(contains('未解析')));
    });

    test('完整可解析时不重复输出原文', () {
      final md = examMd(examsFrom('第20周 周六(2027-01-10) 09:00-11:00'));
      expect(md, contains('| 2027-01-10 | 09:00-11:00 |'));
      expect(md, isNot(contains('原文：')));
    });
  });

  group('第二课堂：已报名 ≠ 已签到 ≠ 已认定学时', () {
    test('区分报名 / 签到，学时只是标称值', () {
      final data = secondClassroomData();
      expect(data.enrolled, hasLength(2));
      expect(data.checkedInCount, 1);
      expect(data.checkedInNominalHours, 1.5);

      final doc = fullDocument(modules: {ExportModule.secondClassroom});
      final md = ExportBuilder.markdown(doc);
      expect(md, contains('已报名 2 项，其中已签到 1 项'));
      expect(md, contains('不是学校认定学时'));
      expect(md, contains('「已报名」「已签到」「已认定学时」是三件事'));
      expect(md, contains('| 活动 | 类别 | 主办 | 开始 | 结束 | 地点 | 标称学时 | 已签到 |'));
    });
  });

  group('教务处通知：只有标题，没有正文', () {
    test('近 30 天窗口：窗口外与无日期的不导出，新 → 旧', () {
      final data = noticesData();
      expect(data.records.map((r) => r.title), ['关于期末考试安排的通知', '选课通知']);
    });

    test('部分结果：说明覆盖范围；窗口内为空时不断言「没有通知」', () {
      NoticesModuleData build({String? partial}) =>
          NoticesModuleData.fromNotices(
            const <Notice>[],
            exportedAt: kExportNow,
            status: ExportModuleStatus.available,
            lastUpdatedAt: kExportNow,
            dataSource: '刚获取',
            partialNote: partial,
          );
      String md(NoticesModuleData d) => ExportBuilder.markdown(
        fullDocument(
          modules: {ExportModule.notices},
          overrides: {ExportModule.notices: d},
        ),
      );

      expect(md(build()), contains('近 30 天内没有教务处通知。'));

      final partial = md(build(partial: '第 2 页获取失败，仅含前 1 页'));
      expect(partial, contains('> 部分结果：第 2 页获取失败，仅含前 1 页'));
      expect(partial, contains('不能据此判断没有通知'));
      expect(partial, isNot(contains('近 30 天内没有教务处通知。')));
    });

    test('只有标题 / 日期 / 栏目 / 链接，不含正文', () {
      final doc = fullDocument(modules: {ExportModule.notices});
      final md = ExportBuilder.markdown(doc);
      expect(md, contains('| 日期 | 栏目 | 标题 | 链接 |'));
      expect(md, contains('仅标题、日期、栏目与链接，不含正文'));
      expect(md, contains('关于期末考试安排的通知'));
      expect(md, isNot(contains('去年的旧通知')));
    });
  });

  group('体测', () {
    test('学年合计与分项', () {
      final doc = fullDocument(modules: {ExportModule.physicalTest});
      final md = ExportBuilder.markdown(doc);
      expect(md, contains('### 2025-2026（总分 82.5，等级 良好）'));
      expect(md, contains('| 50 米跑 | 7.2 秒 | 85 | 良好 |'));
      final m = doc.moduleOf<PhysicalTestModuleData>()!;
      expect(m.records.single.items, hasLength(1));
    });
  });

  group('未获取的模块', () {
    test('占位模块：Markdown 明确标注未获取，绝不用空表伪装', () {
      final doc = fullDocument(
        modules: {ExportModule.exams, ExportModule.grades},
        overrides: {
          ExportModule.exams: const ExportModuleData.missing(
            ExportModule.exams,
          ),
        },
      );
      expect(doc.hasAnyData, isTrue);
      final md = ExportBuilder.markdown(doc);
      expect(md, contains('未获取：本机暂无该模块数据，未导出，也未推测。'));
      final m = doc.modules.whereType<MissingModuleData>().single;
      expect(m.module, ExportModule.exams);
      expect(m.status, ExportModuleStatus.missing);
      expect(m.itemCount, isNull);

      final none = fullDocument(
        modules: {ExportModule.exams},
        overrides: {
          ExportModule.exams: const ExportModuleData.missing(
            ExportModule.exams,
          ),
        },
      );
      expect(none.hasAnyData, isFalse);
    });
  });

  group('隐私', () {
    test('全部模块的 Markdown 不含学号 / 姓名 / 账号字符串', () {
      final md = ExportBuilder.markdown(fullDocument());
      expect(md, isNot(contains('SHOULD-NOT-LEAK')));
      expect(md, isNot(contains('20250001')));
      expect(md, contains('默认不含学号、姓名'));
    });
  });

  group('文件名与格式', () {
    test('固定 Markdown：.md 扩展名、text/markdown', () {
      final doc = fullDocument(
        modules: {ExportModule.exams, ExportModule.grades},
      );
      expect(ExportBuilder.fileName(doc), '学业数据导出_20261013_1030.md');
      expect(kExportExtension, 'md');
      expect(kExportMimeType, 'text/markdown');
    });
  });

  test('ExportBackground 单独可用', () {
    final bg = ExportBackground.from(
      fullDocument(modules: {ExportModule.grades}),
    );
    expect(
      bg.letterGrades.map((l) => l.grade),
      containsAll(['优秀', '良好', '合格']),
    );
    expect(bg.missing, isEmpty);
  });
}
