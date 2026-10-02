/// 学生学业情况查询（正方 `xsxy/xsxyqk_cxXsxyqkIndex.html`，gnmkdm N105515）
/// 的原生数据模型。
///
/// 协议见 `docs/academic-progress-xsxyqk-api.md`。只保留展示需要的字段，
/// 不保存姓名 / 学号等身份原文。
library;

/// 修读状态（响应字段 `XDZT`）。
enum CourseStudyStatus {
  studying('1', '在修'),
  failed('2', '未过'),
  notTaken('3', '未修'),
  passed('4', '已修'),
  replaced('5', '被替代'),
  replacing('6', '课程替代'),
  replacingNode('7', '替代节点'),
  externalRecognized('8', '校外认定'),
  creditRecognized('9', '学分认定'),
  warningExempt('10', '不审核'),
  unknown('', '未知');

  const CourseStudyStatus(this.code, this.label);

  final String code;
  final String label;

  static CourseStudyStatus fromCode(Object? raw) {
    final code = _str(raw);
    for (final status in values) {
      if (status != unknown && status.code == code) return status;
    }
    return unknown;
  }

  /// 计入「通过」的状态（与页面 JS 一致：已修 + 校内替代两类）。
  bool get countsAsPassed =>
      this == passed || this == replaced || this == replacing;
}

/// 单门课程（`xsxyqk_cxJxzxjhxfyqKcxx` / `FKcxx` 返回数组的一项）。
class AcademicProgressCourse {
  const AcademicProgressCourse({
    required this.courseCode,
    required this.courseName,
    required this.status,
    required this.credits,
    this.countsInPlan = true,
    this.hours = '',
    this.nature = '',
    this.category = '',
    this.inPlan = true,
    this.scoreTerm = '',
    this.score = '',
    this.maxScore = '',
    this.gradePoint,
    this.makeupScore = '',
    this.retakeScore = '',
    this.suggestedTerm = '',
  });

  final String courseCode;
  final String courseName;
  final CourseStudyStatus status;
  final double credits;

  /// 原页面 `jdkcsx=1` 节点「共 n 门」只数 `KCZT == 1` 的行。
  final bool countsInPlan;
  final String hours;
  final String nature;
  final String category;

  /// `SFJHKC`：是否计划内课程。
  final bool inPlan;

  /// 成绩所在学年学期，如「2025-2026 第1学期」；在修 / 未修为空。
  final String scoreTerm;
  final String score;
  final String maxScore;
  final double? gradePoint;
  final String makeupScore;
  final String retakeScore;

  /// 建议修读学年学期。
  final String suggestedTerm;

  /// 页面上展示的成绩：优先 `CJ`，计划外重修课只有 `MAXCJ`。
  String get displayScore => score.isNotEmpty ? score : maxScore;

  factory AcademicProgressCourse.fromJson(Map<String, dynamic> json) {
    final kczt = _str(json['KCZT']);
    return AcademicProgressCourse(
      courseCode: _str(json['KCH']),
      courseName: _str(json['KCMC']),
      status: CourseStudyStatus.fromCode(json['XDZT']),
      credits: _double(json['XF']) ?? 0,
      // KCZT 缺失（计划外课程）时按计入处理。
      countsInPlan: kczt.isEmpty || kczt == '1',
      hours: _str(json['XSXXXX']),
      nature: _str(json['KCXZMC']),
      category: _str(json['KCLBMC']),
      inPlan: _str(json['SFJHKC']) != '否',
      scoreTerm: _term(json['XNMC'], json['XQMMC']),
      score: _str(json['CJ']),
      maxScore: _str(json['MAXCJ']),
      gradePoint: _double(json['JD']),
      makeupScore: _str(json['MBKCJ']),
      retakeScore: _str(json['MCXCJ']),
      suggestedTerm: _term(json['JYXDXNMC'], json['JYXDXQMC']),
    );
  }

  /// 本地缓存的往返格式（键名与教务响应一致，便于复用 [fromJson]）。
  Map<String, dynamic> toJson() => {
    'KCH': courseCode,
    'KCMC': courseName,
    'XDZT': status.code,
    'XF': credits.toString(),
    'KCZT': countsInPlan ? '1' : '0',
    'XSXXXX': hours,
    'KCXZMC': nature,
    'KCLBMC': category,
    'SFJHKC': inPlan ? '是' : '否',
    '_scoreTerm': scoreTerm,
    'CJ': score,
    'MAXCJ': maxScore,
    'JD': ?gradePoint,
    'MBKCJ': makeupScore,
    'MCXCJ': retakeScore,
    '_suggestedTerm': suggestedTerm,
  };

  factory AcademicProgressCourse.fromCacheJson(Map<String, dynamic> json) {
    final course = AcademicProgressCourse.fromJson(json);
    return AcademicProgressCourse(
      courseCode: course.courseCode,
      courseName: course.courseName,
      status: course.status,
      credits: course.credits,
      countsInPlan: course.countsInPlan,
      hours: course.hours,
      nature: course.nature,
      category: course.category,
      inPlan: course.inPlan,
      scoreTerm: _str(json['_scoreTerm']),
      score: course.score,
      maxScore: course.maxScore,
      gradePoint: course.gradePoint,
      makeupScore: course.makeupScore,
      retakeScore: course.retakeScore,
      suggestedTerm: _str(json['_suggestedTerm']),
    );
  }
}

/// 子节点之间的关系（`xfyqzjdgx`）。
enum RequirementRelation {
  all('并且'),
  any('或者'),
  any2('或者2'),
  any3('或者3'),
  any4('或者4');

  const RequirementRelation(this.label);

  final String label;

  /// 与页面 `getJdgx` 一致：0=或者，2/3/4=或者N，其它（含空、1）=并且。
  static RequirementRelation fromCode(String raw) => switch (raw.trim()) {
    '0' => any,
    '2' => any2,
    '3' => any3,
    '4' => any4,
    _ => all,
  };
}

/// 学分状态（页面 `xfzt`：比较已获与要求最低学分）。
enum CreditStatus { notMet, met, exceeded, none }

/// 学分要求树的一个节点（课程类别 / 模块 / 课程组）。
class RequirementNode {
  const RequirementNode({
    required this.id,
    required this.name,
    this.parentId = '',
    this.requiredCredits,
    this.earnedCredits,
    this.requiredCount,
    this.metCount,
    this.relation = RequirementRelation.all,
    this.courseAttribute = '',
    this.isLeaf = false,
    this.serverPassedCount,
    this.children = const [],
    this.courses = const [],
  });

  /// 「其他课程」（计划外 / 未归类）固定节点 ID。
  static const otherCoursesId = 'qtkcxfyq';

  /// 「创新创业情况」固定节点 ID。
  static const innovationId = 'cxcyqkxfyq';

  final String id;
  final String name;
  final String parentId;
  final double? requiredCredits;
  final double? earnedCredits;

  /// 门次要求（`要求门次`），与学分要求二选一或并存。
  final int? requiredCount;
  final int? metCount;
  final RequirementRelation relation;

  /// `jdkcsx`：1=课程，2=课程类别，3=课程归属，4=课程组。
  final String courseAttribute;
  final bool isLeaf;

  /// 服务端写在脚本里的「通过（n）门」。
  final int? serverPassedCount;
  final List<RequirementNode> children;
  final List<AcademicProgressCourse> courses;

  bool get isOtherCourses => id == otherCoursesId;

  /// 课程组（`jdkcsx=4`）走 `FKcxx`，其余末节点走 `Kcxx`。
  bool get usesGroupEndpoint =>
      !isOtherCourses && courseAttribute.isNotEmpty && courseAttribute != '1';

  /// 是否需要请求课程明细。
  bool get needsCourses => isLeaf && id != innovationId;

  double? get missingCredits {
    final req = requiredCredits;
    if (req == null) return null;
    final missing = req - (earnedCredits ?? 0);
    return missing > 0 ? missing : 0;
  }

  CreditStatus get creditStatus {
    final req = requiredCredits;
    if (req == null || isOtherCourses) return CreditStatus.none;
    final earned = earnedCredits ?? 0;
    if (earned < req) return CreditStatus.notMet;
    if (earned > req) return CreditStatus.exceeded;
    return CreditStatus.met;
  }

  /// 「共 n 门」：与页面 JS 一致，`jdkcsx=1` 只数 `KCZT==1`。
  int get courseTotal => courseAttribute == '1' && !isOtherCourses
      ? courses.where((c) => c.countsInPlan).length
      : courses.length;

  /// 「通过 n 门」：课程组与「其他课程」按状态重算（服务端给 0，原页面由前端
  /// 计算），其余取服务端值（缺失时按状态计）。
  int get passedTotal {
    if (usesGroupEndpoint || isOtherCourses || serverPassedCount == null) {
      return courses.where((c) => c.status.countsAsPassed).length;
    }
    return serverPassedCount!;
  }

  RequirementNode copyWith({
    List<RequirementNode>? children,
    List<AcademicProgressCourse>? courses,
  }) => RequirementNode(
    id: id,
    name: name,
    parentId: parentId,
    requiredCredits: requiredCredits,
    earnedCredits: earnedCredits,
    requiredCount: requiredCount,
    metCount: metCount,
    relation: relation,
    courseAttribute: courseAttribute,
    isLeaf: isLeaf,
    serverPassedCount: serverPassedCount,
    children: children ?? this.children,
    courses: courses ?? this.courses,
  );

  Iterable<RequirementNode> get leaves sync* {
    if (children.isEmpty) {
      yield this;
      return;
    }
    for (final child in children) {
      yield* child.leaves;
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'parentId': parentId,
    'requiredCredits': ?requiredCredits,
    'earnedCredits': ?earnedCredits,
    'requiredCount': ?requiredCount,
    'metCount': ?metCount,
    'relation': relation.name,
    'courseAttribute': courseAttribute,
    'isLeaf': isLeaf,
    'serverPassedCount': ?serverPassedCount,
    'children': children.map((c) => c.toJson()).toList(),
    'courses': courses.map((c) => c.toJson()).toList(),
  };

  factory RequirementNode.fromJson(Map<String, dynamic> json) =>
      RequirementNode(
        id: json['id'] as String,
        name: json['name'] as String,
        parentId: json['parentId'] as String? ?? '',
        requiredCredits: (json['requiredCredits'] as num?)?.toDouble(),
        earnedCredits: (json['earnedCredits'] as num?)?.toDouble(),
        requiredCount: json['requiredCount'] as int?,
        metCount: json['metCount'] as int?,
        relation: RequirementRelation.values.byName(
          json['relation'] as String? ?? RequirementRelation.all.name,
        ),
        courseAttribute: json['courseAttribute'] as String? ?? '',
        isLeaf: json['isLeaf'] as bool? ?? false,
        serverPassedCount: json['serverPassedCount'] as int?,
        children: [
          for (final c in json['children'] as List? ?? const [])
            RequirementNode.fromJson((c as Map).cast<String, dynamic>()),
        ],
        courses: [
          for (final c in json['courses'] as List? ?? const [])
            AcademicProgressCourse.fromCacheJson(
              (c as Map).cast<String, dynamic>(),
            ),
        ],
      );
}

/// `#alertBox` 统计区。所有字段可缺失：页面改版时宁可不显示也不猜。
class AcademicProgressSummary {
  const AcademicProgressSummary({
    this.statTime = '',
    this.gpa,
    this.planTotal,
    this.planPassed,
    this.planFailed,
    this.planNotTaken,
    this.studying,
    this.outsidePassed,
    this.outsideFailed,
  });

  /// 「统计时间 … 之前有效」中的时间原文。
  final String statTime;
  final String? gpa;
  final int? planTotal;
  final int? planPassed;
  final int? planFailed;
  final int? planNotTaken;
  final int? studying;
  final int? outsidePassed;
  final int? outsideFailed;

  bool get isEmpty =>
      gpa == null &&
      planTotal == null &&
      planPassed == null &&
      planFailed == null &&
      planNotTaken == null &&
      studying == null;

  Map<String, dynamic> toJson() => {
    'statTime': statTime,
    'gpa': ?gpa,
    'planTotal': ?planTotal,
    'planPassed': ?planPassed,
    'planFailed': ?planFailed,
    'planNotTaken': ?planNotTaken,
    'studying': ?studying,
    'outsidePassed': ?outsidePassed,
    'outsideFailed': ?outsideFailed,
  };

  factory AcademicProgressSummary.fromJson(Map<String, dynamic> json) =>
      AcademicProgressSummary(
        statTime: json['statTime'] as String? ?? '',
        gpa: json['gpa'] as String?,
        planTotal: json['planTotal'] as int?,
        planPassed: json['planPassed'] as int?,
        planFailed: json['planFailed'] as int?,
        planNotTaken: json['planNotTaken'] as int?,
        studying: json['studying'] as int?,
        outsidePassed: json['outsidePassed'] as int?,
        outsideFailed: json['outsideFailed'] as int?,
      );
}

/// 一次完整查询的结果。
class AcademicProgressReport {
  const AcademicProgressReport({required this.summary, required this.roots});

  final AcademicProgressSummary summary;

  /// 顶层节点：主修培养方案根、其他课程、创新创业情况。
  final List<RequirementNode> roots;

  Iterable<AcademicProgressCourse> get allCourses sync* {
    for (final root in roots) {
      for (final leaf in root.leaves) {
        yield* leaf.courses;
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'summary': summary.toJson(),
    'roots': roots.map((r) => r.toJson()).toList(),
  };

  factory AcademicProgressReport.fromJson(Map<String, dynamic> json) =>
      AcademicProgressReport(
        summary: AcademicProgressSummary.fromJson(
          (json['summary'] as Map).cast<String, dynamic>(),
        ),
        roots: [
          for (final r in json['roots'] as List)
            RequirementNode.fromJson((r as Map).cast<String, dynamic>()),
        ],
      );
}

String _str(Object? raw) => raw == null ? '' : raw.toString().trim();

double? _double(Object? raw) {
  if (raw is num) return raw.toDouble();
  return double.tryParse(_str(raw));
}

String _term(Object? year, Object? term) {
  final y = _str(year);
  final t = _str(term);
  if (y.isEmpty) return '';
  return t.isEmpty ? y : '$y 第$t学期';
}
