import 'package:jxu_campus_hub/core/academic/exam_model.dart';
import 'package:jxu_campus_hub/features/grades/export/academic_export_builder.dart';
import 'package:jxu_campus_hub/features/grades/export/grades_export_serializer.dart';
import 'package:jxu_campus_hub/features/grades/grades_model.dart';
import 'package:jxu_campus_hub/features/grades/progress/academic_progress_model.dart';

GradeEntry gradeEntry({
  String course = '高等数学A',
  String grade = '优',
  String percentage = '95',
  String gpa = '4.0',
  String credits = '5.0',
  String year = '2025-2026',
  String semester = '第二学期',
  String examType = '考试',
  String method = '闭卷',
  String requirement = '必修',
}) => GradeEntry(
  courseName: course,
  grade: grade,
  percentageScore: percentage,
  gpaPoints: double.parse(gpa),
  credits: double.parse(credits),
  academicYear: year,
  semester: semester,
  examType: examType,
  assessmentMethod: method,
  courseRequirement: requirement,
);

ExamEntry examEntry({
  String course = '线性代数',
  String time = '第20周 周六(2026-01-10) 09:00-11:00',
  String room = '教学楼A101',
  String exam = '期末考试',
  String retake = '',
}) => ExamEntry.fromJson({
  'kcmc': course,
  'kch': 'MATH102',
  'kssj': time,
  'cdmc': room,
  'cdxqmc': '南湖校区',
  'zwh': '23',
  'ksmc': exam,
  'kkxy': '数学学院',
  'cxbj': retake,
  'xnmc': '2025-2026',
  'xqmmc': '1',
});

AcademicProgressReport progressReport({String courseName = '数据结构'}) =>
    AcademicProgressReport(
      summary: const AcademicProgressSummary(
        statTime: '2026-10-13 09:00:00',
        gpa: '3.52',
        planTotal: 60,
        planPassed: 30,
        planFailed: 1,
        planNotTaken: 25,
        studying: 4,
      ),
      roots: [
        RequirementNode(
          id: 'root',
          name: '培养方案',
          requiredCredits: 160,
          earnedCredits: 90,
          children: [
            RequirementNode(
              id: 'leaf1',
              name: '专业必修',
              requiredCredits: 40,
              earnedCredits: 30,
              requiredCount: 10,
              metCount: 7,
              isLeaf: true,
              courses: [
                AcademicProgressCourse(
                  courseCode: 'CS201',
                  courseName: courseName,
                  status: CourseStudyStatus.passed,
                  credits: 4,
                  nature: '必修',
                  scoreTerm: '2025-2026 第1学期',
                  score: '88',
                  gradePoint: 3.8,
                ),
                const AcademicProgressCourse(
                  courseCode: 'CS301',
                  courseName: '操作系统',
                  status: CourseStudyStatus.notTaken,
                  credits: 3,
                  suggestedTerm: '2026-2027 第1学期',
                ),
              ],
            ),
          ],
        ),
      ],
    );

/// 三个模块都已获取的输入；[termSubset] 提供「当前选中学期」子集。
AcademicExportInput fullExportInput({
  DateTime? exportedAt,
  bool withTermScope = true,
  bool gradesStale = false,
}) {
  final spring = gradeEntry();
  final fall = gradeEntry(
    course: '大学英语',
    year: '2025-2026',
    semester: '第一学期',
    credits: '3.0',
  );
  return AcademicExportInput(
    exportedAt: exportedAt ?? DateTime(2026, 10, 13, 10, 30),
    allGrades: [spring, fall],
    termGrades: withTermScope ? [spring] : null,
    termScope: withTermScope
        ? const GradesExportScope(
            label: '2025–26 春',
            academicYear: '2025-2026',
            semester: '第二学期',
          )
        : null,
    gradesUpdatedAt: DateTime(2026, 10, 13, 9, 0),
    gradesStale: gradesStale,
    exams: ExamExportData(
      exams: [examEntry()],
      updatedAt: DateTime(2026, 10, 13, 9, 5),
    ),
    progress: ProgressExportData(
      report: progressReport(),
      updatedAt: DateTime(2026, 10, 13, 9, 10),
    ),
  );
}
