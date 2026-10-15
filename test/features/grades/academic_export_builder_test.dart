import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/features/grades/export/academic_export_builder.dart';
import 'package:jxu_campus_hub/features/grades/export/academic_export_capture.dart';
import 'package:jxu_campus_hub/features/grades/export/grades_export_serializer.dart';
import 'package:jxu_campus_hub/features/grades/progress/academic_progress_model.dart';

import '../../helpers/academic_export_fixtures.dart';
import '../../helpers/test_setup.dart';

const _all = {ExportModule.grades, ExportModule.exams, ExportModule.progress};

final DateTime _fixed = DateTime(2026, 10, 13, 10, 30);

Map<String, dynamic> _json(AcademicExportDocument doc) =>
    jsonDecode(AcademicExportBuilder.jsonString(doc)) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('模块选择与隔离', () {
    test('只选考试时不含成绩 / 学业进度的内容', () {
      final doc = fullExportInput().build(modules: {ExportModule.exams});
      final md = AcademicExportBuilder.markdown(doc);
      expect(md, contains('线性代数'));
      expect(md, isNot(contains('高等数学A')));
      expect(md, isNot(contains('数据结构')));
      expect(md, isNot(contains('## 成绩')));
      final json = _json(doc);
      expect((json['modules'] as Map).keys, ['exams']);
    });

    test('模块顺序固定为 成绩 / 考试安排 / 学业进度', () {
      final doc = fullExportInput().build(
        modules: {ExportModule.progress, ExportModule.grades},
      );
      expect(
        [for (final m in doc.modules) m.module],
        [ExportModule.grades, ExportModule.progress],
      );
    });
  });

  group('Markdown', () {
    test('三个模块齐全，含状态表、免责声明与隐私说明', () {
      final md = AcademicExportBuilder.markdown(
        fullExportInput().build(modules: _all),
      );
      expect(md, contains('# 学业数据导出'));
      expect(md, contains('不代表学校官方学业审核结果'));
      expect(md, contains('默认不含学号、姓名'));
      expect(md, contains('| 成绩 | 已获取 | 1 |'));
      expect(md, contains('| 考试安排 | 已获取 | 1 |'));
      expect(md, contains('| 学业进度 | 已获取 | 2 |'));
      expect(md, contains('| 高等数学A | 优 | 95 | 4.00 | 5.0 |'));
      expect(md, contains('2026-01-10'));
      expect(md, contains('09:00-11:00'));
      expect(md, contains('教学楼A101'));
      // 学业进度：统计 + 学分缺口 + 课程明细。
      expect(md, contains('绩点：3.52'));
      expect(md, contains('培养方案'));
      expect(md, contains('专业必修'));
      expect(md, contains('| 40.0 | 30.0 | 10.0 | 7/10 |'));
      expect(md, contains('操作系统'));
      expect(md, contains('未修'));
    });

    test('中文与竖线 / 换行在单元格内被安全处理', () {
      final doc = AcademicExportInput(
        exportedAt: _fixed,
        allGrades: [gradeEntry(course: '计算机|导论\n实验', method: '开卷<笔试>')],
      ).build(modules: {ExportModule.grades});
      final md = AcademicExportBuilder.markdown(doc);
      expect(md, contains(r'计算机\|导论 实验'));
      expect(md.split('\n').where((l) => l.startsWith('| 计算机')).length, 1);
      expect(md, contains('开卷<笔试>'));
    });
  });

  group('JSON schema', () {
    test('顶层与各模块键集合稳定，schemaVersion 固定', () {
      final json = _json(fullExportInput().build(modules: _all));
      expect(json.keys.toList(), [
        'schemaVersion',
        'exportedAt',
        'disclaimer',
        'privacy',
        'modules',
      ]);
      expect(json['schemaVersion'], kAcademicExportSchemaVersion);
      expect(json['schemaVersion'], 2);
      expect((json['privacy'] as Map)['includesIdentity'], false);
      // exportedAt 是 UTC ISO-8601，可解析回同一时刻。
      expect(
        DateTime.parse(json['exportedAt'] as String)
            .isAtSameMomentAs(DateTime(2026, 10, 13, 10, 30)),
        isTrue,
      );

      final modules = json['modules'] as Map<String, dynamic>;
      expect(modules.keys.toList(), ['grades', 'exams', 'progress']);
      const meta = ['status', 'lastUpdatedAt', 'dataSource', 'itemCount'];
      expect((modules['grades'] as Map).keys.toList(), [
        ...meta,
        'scope',
        'totalCredits',
        'records',
      ]);
      expect((modules['exams'] as Map).keys.toList(), [...meta, 'records']);
      expect((modules['progress'] as Map).keys.toList(), [
        ...meta,
        'summary',
        'requirements',
      ]);

      final exam = ((modules['exams'] as Map)['records'] as List).single as Map;
      expect(exam.keys.toList(), [
        'courseName',
        'courseCode',
        'examName',
        'date',
        'startTime',
        'endTime',
        'timeText',
        'weekNumber',
        'weekday',
        'location',
        'campus',
        'seatNumber',
        'department',
        'isRetake',
        'academicYear',
        'semester',
      ]);
      expect(exam['date'], '2026-01-10');
      // 教务原文是「周六」，模型只认数字星期，无法确证时如实为 null。
      expect(exam['weekday'], isNull);
      expect(exam['weekNumber'], 20);
      expect(exam['isRetake'], false);

      final root =
          ((modules['progress'] as Map)['requirements'] as List).single as Map;
      expect(root.keys.toList(), [
        'id',
        'name',
        'requiredCredits',
        'earnedCredits',
        'missingCredits',
        'requiredCount',
        'metCount',
        'relation',
        'creditStatus',
        'children',
        'courses',
      ]);
      final leaf = (root['children'] as List).single as Map;
      expect(leaf['missingCredits'], 10);
      expect(leaf['creditStatus'], 'notMet');
      final course = (leaf['courses'] as List).first as Map;
      expect(course['gradePoint'], 3.8);
      expect(course['status'], '已修');
    });

    test('缺失值为 null，不用空数组或默认值伪装', () {
      final doc = AcademicExportInput(exportedAt: _fixed).build(modules: _all);
      final modules = _json(doc)['modules'] as Map<String, dynamic>;
      for (final key in ['grades', 'exams', 'progress']) {
        final m = modules[key] as Map<String, dynamic>;
        expect(m['status'], 'missing');
        expect(m['itemCount'], isNull);
        expect(m['lastUpdatedAt'], isNull);
      }
      expect((modules['grades'] as Map)['records'], isNull);
      expect((modules['grades'] as Map)['totalCredits'], isNull);
      expect((modules['exams'] as Map)['records'], isNull);
      expect((modules['progress'] as Map)['requirements'], isNull);
    });

    test('白名单：JSON 键集合与全文都不含身份字段', () {
      final doc = fullExportInput().build(modules: _all);
      final keys = <String>{};
      void walk(Object? node) {
        if (node is Map) {
          for (final e in node.entries) {
            keys.add((e.key as String).toLowerCase());
            walk(e.value);
          }
        } else if (node is List) {
          node.forEach(walk);
        }
      }

      walk(_json(doc));
      for (final forbidden in const [
        'studentid',
        'xh',
        'xm',
        'idcard',
        'phone',
        'cookie',
        'token',
        'password',
      ]) {
        expect(keys, isNot(contains(forbidden)));
      }
      // 注意 'courseName' 等业务字段是允许的；账号学号绝不出现在内容里。
      final text =
          AcademicExportBuilder.jsonString(doc) +
          AcademicExportBuilder.markdown(doc);
      expect(text, isNot(contains('20250001')));
    });
  });

  group('缺失 / 过期 / 空数据', () {
    test('部分模块未获取：只导出可用数据并明确标注缺失', () {
      final doc = AcademicExportInput(
        exportedAt: _fixed,
        allGrades: [gradeEntry()],
        gradesUpdatedAt: DateTime(2026, 10, 13, 9),
      ).build(modules: _all);
      expect(doc.hasAnyData, isTrue);

      final md = AcademicExportBuilder.markdown(doc);
      expect(md, contains('| 考试安排 | 未获取 | — |'));
      expect(md, contains('| 学业进度 | 未获取 | — |'));
      expect(md, contains('未获取：本机暂无该模块已加载的数据，未导出，也未推测。'));
      expect(md, contains('高等数学A'));
      // 没有被杜撰的考试 / 学分内容。
      expect(md, isNot(contains('### 学分要求')));
      expect(md, isNot(contains('考试名称')));
    });

    test('全部未获取：hasAnyData 为 false（UI 据此禁用导出）', () {
      final doc = AcademicExportInput(exportedAt: _fixed).build(modules: _all);
      expect(doc.hasAnyData, isFalse);
      expect(AcademicExportBuilder.markdown(doc), isNot(contains('| 课程 |')));
    });

    test('缓存已过期的模块标记为已过期但仍导出数据', () {
      final input = AcademicExportInput(
        exportedAt: _fixed,
        allGrades: [gradeEntry()],
        gradesStale: true,
        exams: ExamExportData(exams: [examEntry()], isStale: true),
      );
      final doc = input.build(
        modules: {ExportModule.grades, ExportModule.exams},
      );
      final md = AcademicExportBuilder.markdown(doc);
      expect(md, contains('| 成绩 | 已过期 | 1 |'));
      expect(md, contains('已过期：缓存超过有效期'));
      expect(md, contains('高等数学A'));
      final modules = _json(doc)['modules'] as Map<String, dynamic>;
      expect((modules['grades'] as Map)['status'], 'stale');
      expect((modules['exams'] as Map)['status'], 'stale');
    });

    test('已获取但 0 条考试：如实写 0 条，而不是标成未获取', () {
      final doc = AcademicExportInput(
        exportedAt: _fixed,
        exams: const ExamExportData(exams: []),
      ).build(modules: {ExportModule.exams});
      final md = AcademicExportBuilder.markdown(doc);
      expect(md, contains('| 考试安排 | 已获取 | 0 |'));
      expect(md, contains('来源返回 0 条考试安排'));
      final exams =
          (_json(doc)['modules'] as Map)['exams'] as Map<String, dynamic>;
      expect(exams['status'], 'available');
      expect(exams['records'], isEmpty);
    });

    test('时间待定的考试：日期为 null，Markdown 写时间待定', () {
      final doc = AcademicExportInput(
        exportedAt: _fixed,
        exams: ExamExportData(exams: [examEntry(time: '')]),
      ).build(modules: {ExportModule.exams});
      expect(AcademicExportBuilder.markdown(doc), contains('时间待定'));
      final modules = _json(doc)['modules'] as Map;
      final record = ((modules['exams'] as Map)['records'] as List).single;
      expect((record as Map)['date'], isNull);
      expect(record['startTime'], isNull);
      expect(record['timeText'], isNull);
    });
  });

  group('跨学期', () {
    test('选中学期只含该学期，全部学期含多学期并保留学期字段', () {
      final input = fullExportInput();
      final term = input.build(modules: {ExportModule.grades});
      final all = input.build(
        modules: {ExportModule.grades},
        gradesAllTerms: true,
      );
      final termGrades = term.modules.single as GradesModuleData;
      final allGrades = all.modules.single as GradesModuleData;
      expect(termGrades.records.map((r) => r.courseName), ['高等数学A']);
      expect(termGrades.scopeLabel, '2025–26 春');
      expect(allGrades.records.map((r) => r.courseName), ['高等数学A', '大学英语']);
      expect(allGrades.scopeLabel, '全部已加载学期');
      expect(allGrades.totalCredits, 8.0);
      expect(allGrades.records.map((r) => r.semester).toSet(), {
        '第一学期',
        '第二学期',
      });
      final grades = (_json(all)['modules'] as Map)['grades'] as Map;
      expect((grades['scope'] as Map)['academicYear'], isNull);
    });

    test('没有学期范围（页面选了全部）时始终导出全部', () {
      final input = fullExportInput(withTermScope: false);
      final doc = input.build(modules: {ExportModule.grades});
      expect((doc.modules.single as GradesModuleData).records, hasLength(2));
    });
  });

  group('CSV', () {
    test('成绩：BOM、表头与转义；逐模块不混表', () {
      final doc = fullExportInput().build(modules: {ExportModule.grades});
      final csv = AcademicExportBuilder.csv(doc);
      expect(csv.startsWith(GradesExportSerializer.csvBom), isTrue);
      expect(
        csv.split('\n').first.replaceFirst('\uFEFF', ''),
        startsWith('课程,成绩,百分制,绩点,学分'),
      );
      expect(csv, contains('高等数学A,优,95,4.00,5.0,2025-2026,第二学期'));
      expect(csv, isNot(contains('线性代数')));
    });

    test('逗号 / 引号 / 换行字段按 CSV 规则转义', () {
      final doc = AcademicExportInput(
        exportedAt: _fixed,
        allGrades: [
          gradeEntry(course: '数学,分析', method: '含"引号"', requirement: '第一行\n第二行'),
        ],
      ).build(modules: {ExportModule.grades});
      final csv = AcademicExportBuilder.csv(doc);
      expect(csv, contains('"数学,分析"'));
      expect(csv, contains('"含""引号"""'));
      expect(csv, contains('"第一行\n第二行"'));
    });

    test('公式注入：成绩 / 考试 / 学业进度的文本字段都被中和，负数仍是数值', () {
      const evil = '=HYPERLINK("https://example.com")';
      final report = AcademicProgressReport(
        summary: const AcademicProgressSummary(),
        roots: [
          RequirementNode(
            id: 'r',
            name: '@root',
            children: [
              RequirementNode(
                id: 'l',
                name: 'leaf',
                isLeaf: true,
                courses: const [
                  AcademicProgressCourse(
                    courseCode: '-1',
                    courseName: evil,
                    status: CourseStudyStatus.passed,
                    credits: 1,
                    gradePoint: -0.5,
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      final input = AcademicExportInput(
        exportedAt: _fixed,
        allGrades: [gradeEntry(course: '\t$evil', gpa: '-0.5')],
        exams: ExamExportData(
          exams: [examEntry(course: '=1+1', room: '@A')],
        ),
        progress: ProgressExportData(report: report),
      );
      for (final m in ExportModule.values) {
        final csv = AcademicExportBuilder.csv(input.build(modules: {m}));
        final body = csv.replaceFirst('\uFEFF', '');
        // 数据行里不能有以公式字符开头的文本单元格（数值列除外，另行断言）。
        for (final line in body.split('\n').skip(1)) {
          expect(line, isNot(startsWith('=')), reason: '$m');
          expect(line, isNot(startsWith('@')), reason: '$m');
        }
      }
      final grades = AcademicExportBuilder.csv(
        input.build(modules: {ExportModule.grades}),
      );
      expect(grades, contains("'=HYPERLINK("));
      expect(grades, contains(',-0.50,'));
      final exams = AcademicExportBuilder.csv(
        input.build(modules: {ExportModule.exams}),
      );
      expect(exams, contains("'=1+1"));
      expect(exams, contains("'@A"));
      final progress = AcademicExportBuilder.csv(
        input.build(modules: {ExportModule.progress}),
      );
      expect(progress, contains("'@root"));
      expect(progress, contains("'-1"));
      expect(progress, contains(',-0.50,'));
    });

    test('未获取的模块只输出表头，不伪造行', () {
      final doc = AcademicExportInput(exportedAt: _fixed)
          .build(modules: {ExportModule.exams});
      final lines = AcademicExportBuilder.csv(doc).trimRight().split('\n');
      expect(lines, hasLength(1));
    });

    test('文件名带时间戳，CSV 额外带模块名', () {
      final doc = fullExportInput().build(modules: {ExportModule.exams});
      expect(
        AcademicExportBuilder.fileName(GradesExportFormat.markdown, doc),
        '学业数据导出_20261013_1030.md',
      );
      expect(
        AcademicExportBuilder.fileName(GradesExportFormat.csv, doc),
        '学业数据导出_考试安排_20261013_1030.csv',
      );
    });
  });

  test('encode 按格式分派', () {
    final doc = fullExportInput().build(modules: _all);
    expect(
      AcademicExportBuilder.encode(GradesExportFormat.markdown, doc),
      AcademicExportBuilder.markdown(doc),
    );
    expect(
      AcademicExportBuilder.encode(GradesExportFormat.json, doc),
      AcademicExportBuilder.jsonString(doc),
    );
    expect(
      AcademicExportBuilder.encode(GradesExportFormat.csv, doc),
      AcademicExportBuilder.csv(doc),
    );
  });

  group('采集快照与账号归属', () {
    setUp(() async {
      await resetTestEnvironment();
    });

    AcademicExportSnapshot? capture({
      ExamExportReader? readExams,
      ProgressExportReader? readProgress,
    }) => captureAcademicExportSnapshot(
      allGrades: [gradeEntry()],
      gradesUpdatedAt: DateTime(2026, 10, 13, 9, 0),
      readExams: readExams,
      readProgress: readProgress ?? () => null,
      now: _fixed,
    );

    test('未登录时不产生快照（调用方提示先登录）', () {
      expect(capture(), isNull);
    });

    test('已验证账号：快照绑定 owner / revision，且不含学号', () {
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20250001',
      );
      final snap = capture(
        readExams: () => ExamExportData(
          exams: [examEntry()],
          updatedAt: DateTime(2026, 10, 13, 9, 5),
        ),
        readProgress: () => ProgressExportData(report: progressReport()),
      )!;
      expect(snap.owner, '20250001');
      expect(snap.revision, ZhengfangAuth.instance.sessionRevision);

      final doc = snap.input.build(modules: _all);
      final md = AcademicExportBuilder.markdown(doc);
      final json = AcademicExportBuilder.jsonString(doc);
      for (final text in [md, json]) {
        expect(text, isNot(contains('20250001')));
      }
    });

    test('切换账号后重新采集：旧账号缓存读不到的模块一律标记未获取', () {
      final auth = ZhengfangAuth.instance;
      auth.debugSetSession(active: true, studentId: '20250001');
      final first = capture(
        readExams: () => ExamExportData(exams: [examEntry()]),
      )!;
      expect(first.input.exams, isNotNull);

      auth.debugSetSession(
        active: true,
        studentId: '20250002',
        forceRevision: true,
      );
      // 新账号的 owner 缓存读取器对旧数据返回 null。
      final second = capture(readExams: () => null)!;
      expect(second.owner, '20250002');
      expect(second.revision, isNot(first.revision));
      final doc = second.input.build(modules: {ExportModule.exams});
      expect(doc.modules.single.status, ExportModuleStatus.missing);
      expect(AcademicExportBuilder.markdown(doc), isNot(contains('线性代数')));
    });

    test('成绩超过刷新窗口标记为已过期', () {
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20250001',
      );
      final snap = captureAcademicExportSnapshot(
        allGrades: [gradeEntry()],
        gradesUpdatedAt: _fixed.subtract(const Duration(days: 3)),
        readProgress: () => null,
        now: _fixed,
      )!;
      final doc = snap.input.build(modules: {ExportModule.grades});
      expect(doc.modules.single.status, ExportModuleStatus.stale);
    });
  });
}
