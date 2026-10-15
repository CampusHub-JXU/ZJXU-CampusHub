import '../../../core/auth/zhengfang_auth.dart';
import '../grades_model.dart';
import '../grades_service.dart';
import '../progress/academic_progress_service.dart';
import 'academic_export_builder.dart';
import 'grades_export_serializer.dart';

/// 考试安排的只读取数点：由组合层（`lib/app`）注入，避免成绩模块反向依赖
/// 考试模块。返回 `null` 即「本机没有当前账号的考试缓存」。
typedef ExamExportReader = ExamExportData? Function();

/// 学业进度的只读取数点；默认读 [AcademicProgressService] 的已验证缓存。
typedef ProgressExportReader = ProgressExportData? Function();

/// 打开导出弹层那一刻冻结的快照：已加载数据 + 其归属身份。
///
/// [owner] / [revision] 是弹层存活期间的有效性凭据：账号切换 / 登出 / 同账号
/// 重登都会让弹层立即失效，避免导出上一个账号的残留数据。
class AcademicExportSnapshot {
  const AcademicExportSnapshot({
    required this.owner,
    required this.revision,
    required this.input,
  });

  final String owner;
  final int revision;
  final AcademicExportInput input;
}

/// 默认学业进度取数：只读已缓存且归属当前账号的报告，绝不触发请求。
ProgressExportData? readCachedProgress() {
  final service = AcademicProgressService.instance;
  final report = service.cachedReport;
  if (report == null) return null;
  return ProgressExportData(
    report: report,
    updatedAt: service.updatedAt,
    isStale: service.updatedAt != null && !service.isCacheFresh,
  );
}

/// 采集一次导出快照。仅读取内存里**已有**的数据，不联网、不登录。
///
/// 未登录 / 无已验证学号时返回 `null`（调用方应提示先登录）。考试与学业进度
/// 的缓存读取器自带归属校验（`PrivateOwnerCache.cached`），账号切换后读到的
/// 一律是 `null`，即标记为「未获取」，不会带出上一个账号的数据。
AcademicExportSnapshot? captureAcademicExportSnapshot({
  required List<GradeEntry> allGrades,
  List<GradeEntry>? termGrades,
  GradesExportScope? termScope,
  DateTime? gradesUpdatedAt,
  ExamExportReader? readExams,
  ProgressExportReader readProgress = readCachedProgress,
  DateTime? now,
}) {
  final auth = ZhengfangAuth.instance;
  final owner = auth.verifiedStudentId;
  if (!auth.isLoggedIn || owner == null || owner.isEmpty) return null;
  final stamp = now ?? DateTime.now();
  final revision = auth.sessionRevision;

  final exams = readExams?.call();
  final progress = readProgress();

  // 读取期间身份若变化（极端竞态），整份作废。
  if (auth.verifiedStudentId != owner || auth.sessionRevision != revision) {
    return null;
  }

  return AcademicExportSnapshot(
    owner: owner,
    revision: revision,
    input: AcademicExportInput(
      exportedAt: stamp,
      allGrades: allGrades,
      termGrades: termGrades,
      termScope: termScope,
      gradesUpdatedAt: gradesUpdatedAt,
      gradesStale:
          gradesUpdatedAt != null &&
          stamp.difference(gradesUpdatedAt) >= GradesService.refreshWindow,
      exams: exams,
      progress: progress,
    ),
  );
}
