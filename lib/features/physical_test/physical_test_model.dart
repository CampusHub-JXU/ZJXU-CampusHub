/// 体测单项成绩（对应学校「学生服务平台」我的信息里的
/// 项目名称 / 测试成绩 / 得分 / 等级）。
class PhysicalTestItem {
  const PhysicalTestItem({
    required this.name,
    required this.result,
    this.score = '',
    this.level = '',
  });

  /// 项目名称，如「50 米跑」。
  final String name;

  /// 测试成绩原文，如「7.2 秒」。
  final String result;

  /// 得分，可能为空。
  final String score;

  /// 等级（优秀 / 良好 / …），可能为空。
  final String level;

  factory PhysicalTestItem.fromJson(Map<String, dynamic> json) {
    return PhysicalTestItem(
      name: json['name']?.toString() ?? '',
      result: json['result']?.toString() ?? '',
      score: json['score']?.toString() ?? '',
      level: json['level']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'result': result,
    'score': score,
    'level': level,
  };
}

/// 一次体测记录（按学年聚合）。
class PhysicalTestRecord {
  const PhysicalTestRecord({
    required this.academicYear,
    this.totalScore = '',
    this.grade = '',
    this.items = const [],
  });

  /// 学年，如 `2025-2026`。
  final String academicYear;

  /// 总分，可能为空。
  final String totalScore;

  /// 总评等级，可能为空。
  final String grade;

  final List<PhysicalTestItem> items;

  factory PhysicalTestRecord.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return PhysicalTestRecord(
      academicYear: json['academicYear']?.toString() ?? '',
      totalScore: json['totalScore']?.toString() ?? '',
      grade: json['grade']?.toString() ?? '',
      items: rawItems is List
          ? rawItems
                .whereType<Map>()
                .map(
                  (item) => PhysicalTestItem.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList(growable: false)
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
    'academicYear': academicYear,
    'totalScore': totalScore,
    'grade': grade,
    'items': items.map((item) => item.toJson()).toList(growable: false),
  };
}

/// 体测成绩快照：原生页面唯一的数据契约。
///
/// [message] 仅在 [records] 为空时有意义，用于说明「学校侧暂未开放」等
/// 中性原因，而不是把无数据渲染成错误。
class PhysicalTestSnapshot {
  const PhysicalTestSnapshot({
    this.records = const [],
    this.message,
    this.updatedAt,
  });

  final List<PhysicalTestRecord> records;
  final String? message;
  final DateTime? updatedAt;

  factory PhysicalTestSnapshot.fromJson(Map<String, dynamic> json) {
    final rawRecords = json['records'];
    final rawUpdatedAt = json['updatedAt']?.toString();
    return PhysicalTestSnapshot(
      records: rawRecords is List
          ? rawRecords
                .whereType<Map>()
                .map(
                  (record) => PhysicalTestRecord.fromJson(
                    Map<String, dynamic>.from(record),
                  ),
                )
                .toList(growable: false)
          : const [],
      message: json['message']?.toString(),
      updatedAt: rawUpdatedAt == null ? null : DateTime.tryParse(rawUpdatedAt),
    );
  }
}
