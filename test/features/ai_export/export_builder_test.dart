import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/ai_export/export_background.dart';
import 'package:jxu_campus_hub/features/ai_export/export_builder.dart';
import 'package:jxu_campus_hub/features/ai_export/export_document.dart';
import 'package:jxu_campus_hub/features/ai_export/export_model.dart';
import 'package:jxu_campus_hub/features/ai_export/export_text.dart';

import '../../helpers/ai_export_fixtures.dart';

Map<String, dynamic> _json(AiExportDocument doc) =>
    jsonDecode(ExportBuilder.jsonString(doc)) as Map<String, dynamic>;

Map<String, dynamic> _module(AiExportDocument doc, ExportModule m) =>
    ((_json(doc)['modules'] as Map<String, dynamic>)[m.key]
        as Map<String, dynamic>);

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
      expect(md, contains('只统计 gpaPoints > 0'));
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
      final json = _json(
        fullDocument(modules: {ExportModule.grades, ExportModule.progress}),
      );
      final ctx = json['context'] as Map<String, dynamic>;
      final nature = ctx['courseNature'] as Map<String, dynamic>;
      final gradeNature = {
        for (final c in nature['grades'] as List)
          (c as Map)['value']: c['courses'],
      };
      expect(gradeNature['必修'], 3);
      expect(gradeNature['专业必修'], 1);
      expect(gradeNature['公共选修'], 1);
      final progressNature = nature['progress'] as List;
      expect(progressNature.single['value'], '必修');
      expect(nature['note'], contains('本应用不做归类或解释'));
      final examTypes = {
        for (final c in ctx['examTypes'] as List)
          (c as Map)['value']: c['courses'],
      };
      expect(examTypes['补考'], 1);
      expect(examTypes['正常考试'], 4);
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
      final ctx = _json(doc)['context'] as Map<String, dynamic>;
      expect(ctx['missingModules'], ['notices']);
      final fresh = {
        for (final f in ctx['dataFreshness'] as List)
          (f as Map)['module']: f['status'],
      };
      expect(fresh, {
        'grades': 'stale',
        'schedule': 'available',
        'notices': 'missing',
      });

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

    test('JSON 顶层 context 键稳定', () {
      final json = _json(fullDocument(modules: ExportPreset.planning.modules));
      expect(json.keys.toList(), [
        'schemaVersion',
        'exportedAt',
        'disclaimer',
        'privacy',
        'context',
        'modules',
      ]);
      expect(json['schemaVersion'], kAiExportSchemaVersion);
      final ctx = json['context'] as Map<String, dynamic>;
      expect(ctx.keys.toList(), [
        'purpose',
        'school',
        'exportedAt',
        'weekday',
        'currentTerm',
        'currentWeek',
        'currentWeekNote',
        'gpa',
        'courseNature',
        'examTypes',
        'dataFreshness',
        'missingModules',
        'notes',
      ]);
      expect(ctx['school'], '嘉兴大学');
      expect(ctx['currentWeek'], 7);
      expect((ctx['currentTerm'] as Map)['termCode'], 3);
      final gpa = ctx['gpa'] as Map<String, dynamic>;
      expect((gpa['rules'] as List).first, contains('没有、也不使用'));
      final letters = {
        for (final l in gpa['observedLetterGrades'] as List)
          (l as Map)['grade']: l['gpaPoints'],
      };
      expect(letters['优秀'], [4.5]);
      expect(letters['合格'], [0.0]);
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
      expect(md, contains('未计入绩点（gpaPoints 为 0）：1 条 / 2.0 学分'));
      expect(
        md,
        contains('| 线性代数 | 65 | 65 | 1.50 | 3.0 | 2024-2025 | 第二学期 | 补考 |'),
      );
    });

    test('JSON：汇总 / 分学期 / 明细', () {
      final m = _module(
        fullDocument(modules: {ExportModule.grades}),
        ExportModule.grades,
      );
      expect(m['itemCount'], 5);
      expect(m['scope'], '全部学期');
      expect(m['totalCredits'], 17);
      expect((m['summary'] as Map)['countedCourses'], 4);
      expect((m['terms'] as List), hasLength(4));
      expect((m['records'] as List), hasLength(5));
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
      final m = _module(
        fullDocument(modules: {ExportModule.progress}),
        ExportModule.progress,
      );
      final root = (m['requirements'] as List).single as Map;
      final leaf = (root['children'] as List).single as Map;
      final course = (leaf['courses'] as List).first as Map;
      expect(course['makeupScore'], '60');
      expect(course['retakeScore'], isNull);
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

    test('Markdown / JSON 含节次时间、教室、教务调课标记；学号不外泄', () {
      final doc = fullDocument(modules: {ExportModule.schedule});
      final md = ExportBuilder.markdown(doc);
      expect(md, contains('### 第 7 周有效课表（已应用调课）'));
      expect(
        md,
        contains(
          '| 周三 | 3-4 | 09:45-11:10 | 大学英语 | 李老师 | 教学楼B202 | 南湖校区 | 理论 | 1-16周 | 是 |',
        ),
      );
      final raw = ExportBuilder.jsonString(doc);
      expect(raw, isNot(contains('SHOULD-NOT-LEAK')));
      final m = _module(doc, ExportModule.schedule);
      expect(
        m.keys,
        containsAll(['term', 'changeRuleCount', 'effectiveWeeks', 'courses']),
      );
      expect((m['effectiveWeeks'] as List).first['week'], 7);
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
    test('Markdown / JSON 字段', () {
      final doc = fullDocument(modules: {ExportModule.exams});
      final md = ExportBuilder.markdown(doc);
      expect(md, contains('2027-01-10'));
      expect(md, contains('09:00-11:00'));
      final m = _module(doc, ExportModule.exams);
      expect(m['scope'], '当前学期');
      expect(((m['records'] as List).single as Map)['date'], '2027-01-10');
    });
  });

  group('第二课堂：已报名 ≠ 已签到 ≠ 已认定学时', () {
    test('区分报名 / 签到，学时只是标称值', () {
      final data = secondClassroomData();
      expect(data.enrolled, hasLength(2));
      expect(data.checkedInCount, 1);
      expect(data.checkedInNominalHours, 1.5);

      final doc = fullDocument(modules: {ExportModule.secondClassroom});
      final m = _module(doc, ExportModule.secondClassroom);
      expect(m['creditsVerified'], false);
      expect(m['checkedInCount'], 1);
      expect(m['checkedInNominalHours'], 1.5);
      final first = (m['enrolled'] as List).first as Map;
      expect(first.containsKey('nominalCreditHours'), isTrue);
      expect(first.containsKey('creditHours'), isFalse);

      final md = ExportBuilder.markdown(doc);
      expect(md, contains('已报名 2 项，其中已签到 1 项'));
      expect(md, contains('不是学校认定学时'));
      expect(md, contains('「已报名」「已签到」「已认定学时」是三件事'));
    });
  });

  group('教务处通知：只有标题，没有正文', () {
    test('近 30 天窗口：窗口外与无日期的不导出，新 → 旧', () {
      final data = noticesData();
      expect(data.records.map((r) => r.title), ['关于期末考试安排的通知', '选课通知']);
    });

    test('字段仅 title / date / category / url', () {
      final doc = fullDocument(modules: {ExportModule.notices});
      final m = _module(doc, ExportModule.notices);
      expect(m['includesBody'], false);
      expect(m['windowDays'], 30);
      final rec = (m['records'] as List).first as Map;
      expect(rec.keys.toList(), ['title', 'date', 'category', 'url']);
      final md = ExportBuilder.markdown(doc);
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
      final m = _module(doc, ExportModule.physicalTest);
      expect(((m['records'] as List).single as Map)['items'], hasLength(1));
    });
  });

  group('未获取的模块', () {
    test('占位模块：Markdown 标注、JSON 数据键为 null，绝不用空表伪装', () {
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
      final m = _module(doc, ExportModule.exams);
      expect(m['status'], 'missing');
      expect(m['itemCount'], isNull);

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
    const forbiddenKeys = {
      'xh',
      'xm',
      'studentId',
      'student_id',
      'idCard',
      'realName',
      'studentName',
      'fullName',
      'username',
      'phone',
      'password',
      'token',
      'cookie',
      'account',
    };

    void scan(Object? node, List<String> hits) {
      if (node is Map) {
        for (final e in node.entries) {
          if (forbiddenKeys.contains(e.key)) hits.add('${e.key}');
          scan(e.value, hits);
        }
      } else if (node is List) {
        for (final v in node) {
          scan(v, hits);
        }
      }
    }

    test('全部模块的 JSON 不含任何身份 / 凭据键，也不含账号字符串', () {
      final doc = fullDocument();
      final raw = ExportBuilder.jsonString(doc);
      final hits = <String>[];
      scan(jsonDecode(raw), hits);
      expect(hits, isEmpty);
      expect((jsonDecode(raw) as Map)['privacy'], {'includesIdentity': false});
      for (final text in [
        raw,
        ExportBuilder.markdown(doc),
        for (final m in ExportModule.values)
          ExportBuilder.csvFor(doc.modules.firstWhere((x) => x.module == m)),
      ]) {
        expect(text, isNot(contains('SHOULD-NOT-LEAK')));
        expect(text, isNot(contains('20250001')));
      }
      expect(ExportBuilder.markdown(doc), contains('默认不含学号、姓名'));
    });
  });

  group('CSV', () {
    test('逐模块表头与行，BOM 开头', () {
      final doc = fullDocument();
      for (final m in doc.modules) {
        final csv = ExportBuilder.csvFor(m);
        expect(csv.startsWith(ExportText.csvBom), isTrue, reason: m.module.key);
        expect(
          csv.trim().split('\n').length,
          greaterThan(1),
          reason: m.module.key,
        );
      }
      final grades = ExportBuilder.csv(doc, module: ExportModule.grades);
      expect(grades, contains('课程,成绩,百分制,绩点,学分'));
      expect(grades, contains('线性代数,65,65,1.50,3.0,2024-2025,第二学期,补考'));
      final notices = ExportBuilder.csv(doc, module: ExportModule.notices);
      expect(notices, contains('日期,栏目,标题,链接'));
      expect(notices, isNot(contains('去年的旧通知')));
    });

    test('指定模块不在文档内时取第一个有数据的模块；文件名带模块名', () {
      final doc = fullDocument(
        modules: {ExportModule.exams, ExportModule.grades},
      );
      expect(
        ExportBuilder.csvTarget(doc, ExportModule.notices)!.module,
        ExportModule.grades,
      );
      expect(
        ExportBuilder.fileName(
          ExportFormat.csv,
          doc,
          csvModule: ExportModule.exams,
        ),
        '学业数据导出_考试安排_20261013_1030.csv',
      );
      expect(
        ExportBuilder.fileName(ExportFormat.markdown, doc),
        '学业数据导出_20261013_1030.md',
      );
      expect(
        ExportBuilder.fileName(ExportFormat.json, doc),
        '学业数据导出_20261013_1030.json',
      );
    });

    test('公式注入被中和', () {
      final doc = fullDocument(
        modules: {ExportModule.grades},
        overrides: {
          ExportModule.grades: gradesData(
            records: [gradeRecord(course: '=HYPERLINK("x")')],
          ),
        },
      );
      expect(ExportBuilder.csv(doc), contains("'=HYPERLINK"));
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
