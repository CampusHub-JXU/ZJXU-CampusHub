class ExamEntry {
  const ExamEntry({
    required this.courseName,
    required this.courseCode,
    required this.examTimeRaw,
    required this.examDate,
    required this.startTime,
    required this.endTime,
    required this.location,
    required this.campus,
    required this.seatNumber,
    required this.examName,
    required this.department,
    required this.isRetake,
    required this.academicYear,
    required this.semester,
    required this.weekday,
    required this.weekNumber,
  });

  final String courseName;
  final String courseCode;
  final String examTimeRaw;
  final DateTime? examDate;
  final String startTime;
  final String endTime;
  final String location;
  final String campus;
  final String seatNumber;
  final String examName;
  final String department;
  final bool isRetake;
  final String academicYear;
  final String semester;
  final int weekday;
  final int weekNumber;

  bool get hasDate => examDate != null;

  bool get isPast {
    if (examDate == null) return false;
    final end = _parseEndTime();
    if (end == null) return DateTime.now().isAfter(examDate!);
    return DateTime.now().isAfter(end);
  }

  int get daysUntil {
    if (examDate == null) return -1;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(examDate!.year, examDate!.month, examDate!.day);
    return target.difference(today).inDays;
  }

  String get countdownLabel {
    if (!hasDate) return '时间待定';
    final days = daysUntil;
    if (days < 0) return '已结束';
    if (days == 0) return '今天';
    if (days == 1) return '明天';
    if (days == 2) return '后天';
    return '$days天后';
  }

  String get weekdayLabel {
    const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    if (weekday < 1 || weekday > 7) return '';
    return labels[weekday - 1];
  }

  String get timeRange {
    if (startTime.isEmpty || endTime.isEmpty) return '';
    return '$startTime-$endTime';
  }

  DateTime? _parseEndTime() {
    if (examDate == null || endTime.isEmpty) return null;
    final parts = endTime.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    return DateTime(
      examDate!.year,
      examDate!.month,
      examDate!.day,
      hour,
      minute,
    );
  }

  static final _datePattern = RegExp(r'\((\d{4}-\d{2}-\d{2})\)');
  static final _timePattern = RegExp(r'(\d{1,2}:\d{2})-(\d{1,2}:\d{2})$');
  static final _weekPattern = RegExp(r'第(\d+)周');
  static final _weekdayPattern = RegExp(r'周(\d)');

  factory ExamEntry.fromJson(Map<String, dynamic> json) {
    final raw = json['kssj'] as String? ?? '';
    DateTime? examDate;
    var startTime = '';
    var endTime = '';
    var weekday = 0;
    var weekNumber = 0;

    final dateMatch = _datePattern.firstMatch(raw);
    if (dateMatch != null) {
      examDate = DateTime.tryParse(dateMatch.group(1)!);
    }

    final timeMatch = _timePattern.firstMatch(raw);
    if (timeMatch != null) {
      startTime = timeMatch.group(1)!;
      endTime = timeMatch.group(2)!;
    }

    final weekMatch = _weekPattern.firstMatch(raw);
    if (weekMatch != null) {
      weekNumber = int.tryParse(weekMatch.group(1)!) ?? 0;
    }

    final weekdayMatch = _weekdayPattern.firstMatch(raw);
    if (weekdayMatch != null) {
      weekday = int.tryParse(weekdayMatch.group(1)!) ?? 0;
    }

    return ExamEntry(
      courseName: json['kcmc'] as String? ?? '',
      courseCode: json['kch'] as String? ?? '',
      examTimeRaw: raw,
      examDate: examDate,
      startTime: startTime,
      endTime: endTime,
      location: json['cdmc'] as String? ?? '',
      campus: json['cdxqmc'] as String? ?? '',
      seatNumber: json['zwh'] as String? ?? '',
      examName: json['ksmc'] as String? ?? '',
      department: json['kkxy'] as String? ?? '',
      isRetake: (json['cxbj'] as String?) == '是',
      academicYear: json['xnmc'] as String? ?? '',
      semester: json['xqmmc'] as String? ?? '',
      weekday: weekday,
      weekNumber: weekNumber,
    );
  }

  Map<String, dynamic> toJson() => {
    'kcmc': courseName,
    'kch': courseCode,
    'kssj': examTimeRaw,
    'cdmc': location,
    'cdxqmc': campus,
    'zwh': seatNumber,
    'ksmc': examName,
    'kkxy': department,
    'cxbj': isRetake ? '是' : '',
    'xnmc': academicYear,
    'xqmmc': semester,
  };
}
