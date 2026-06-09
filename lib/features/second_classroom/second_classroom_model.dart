enum SecondClassroomActivityStatus {
  all('', '全部状态'),
  warming('1', '活动预热'),
  recruiting('2', '正在招募'),
  running('3', '正在进行'),
  ended('4', '活动结束'),
  allIncludingUnauthorized('5', '全部活动');

  const SecondClassroomActivityStatus(this.value, this.label);

  final String value;
  final String label;
}

enum SecondClassroomActivitySort {
  upcoming('1', '即将开始'),
  popular('2', '最热排序'),
  latest('3', '最新发布');

  const SecondClassroomActivitySort(this.value, this.label);

  final String value;
  final String label;
}

enum SecondClassroomOrganizationType {
  all('', '全部组织'),
  studentDepartment('2', '学生部门'),
  studentClub('3', '学生社团');

  const SecondClassroomOrganizationType(this.value, this.label);

  final String value;
  final String label;
}

class SecondClassroomFilterOption {
  const SecondClassroomFilterOption({required this.value, required this.text});

  final String value;
  final String text;

  factory SecondClassroomFilterOption.fromJson(Map<String, dynamic> json) {
    return SecondClassroomFilterOption(
      value: json['value']?.toString() ?? json['id']?.toString() ?? '',
      text: json['text'] as String? ?? json['mc'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {'value': value, 'text': text};
  }
}

class SecondClassroomActivityQuery {
  const SecondClassroomActivityQuery({
    this.categoryId = '',
    this.status = SecondClassroomActivityStatus.recruiting,
    this.departmentId = '',
    this.sort = SecondClassroomActivitySort.upcoming,
    this.organizationType = SecondClassroomOrganizationType.all,
    this.keyword = '',
    this.searchUpdate = false,
    this.page = 1,
    this.limit = 10,
  });

  final String categoryId;
  final SecondClassroomActivityStatus status;
  final String departmentId;
  final SecondClassroomActivitySort sort;
  final SecondClassroomOrganizationType organizationType;
  final String keyword;
  final bool searchUpdate;
  final int page;
  final int limit;

  SecondClassroomActivityQuery copyWith({
    String? categoryId,
    SecondClassroomActivityStatus? status,
    String? departmentId,
    SecondClassroomActivitySort? sort,
    SecondClassroomOrganizationType? organizationType,
    String? keyword,
    bool? searchUpdate,
    int? page,
    int? limit,
  }) {
    return SecondClassroomActivityQuery(
      categoryId: categoryId ?? this.categoryId,
      status: status ?? this.status,
      departmentId: departmentId ?? this.departmentId,
      sort: sort ?? this.sort,
      organizationType: organizationType ?? this.organizationType,
      keyword: keyword ?? this.keyword,
      searchUpdate: searchUpdate ?? this.searchUpdate,
      page: page ?? this.page,
      limit: limit ?? this.limit,
    );
  }

  Map<String, dynamic> toFormData({required String menuToken}) {
    return {
      's0': categoryId,
      's1': status.value,
      's2': departmentId,
      's3': sort.value,
      's4': organizationType.value,
      'keyword': keyword,
      'searchUpdate': searchUpdate.toString(),
      'page': page,
      'limit': limit,
      '.me': menuToken,
    };
  }
}

class SecondClassroomCatalog {
  const SecondClassroomCatalog({
    required this.categories,
    required this.departments,
    required this.organizationTypes,
  });

  final List<SecondClassroomFilterOption> categories;
  final List<SecondClassroomFilterOption> departments;
  final List<SecondClassroomFilterOption> organizationTypes;

  factory SecondClassroomCatalog.fromJson(Map<String, dynamic> json) {
    return SecondClassroomCatalog(
      categories: _filterOptionsFromStoredJson(json['categories']),
      departments: _filterOptionsFromStoredJson(json['departments']),
      organizationTypes: _filterOptionsFromStoredJson(
        json['organizationTypes'],
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'categories': categories.map((option) => option.toJson()).toList(),
      'departments': departments.map((option) => option.toJson()).toList(),
      'organizationTypes': organizationTypes
          .map((option) => option.toJson())
          .toList(),
    };
  }
}

class SecondClassroomActivityPage {
  const SecondClassroomActivityPage({
    required this.items,
    required this.pageIndex,
    required this.pageSize,
    required this.totalPages,
    required this.count,
  });

  final List<SecondClassroomActivity> items;
  final int pageIndex;
  final int pageSize;
  final int totalPages;
  final int count;

  bool get hasMore => pageIndex < totalPages;
}

class SecondClassroomActivity {
  const SecondClassroomActivity({
    required this.id,
    required this.title,
    required this.coverId,
    required this.iconId,
    required this.registrationStartAt,
    required this.registrationEndAt,
    required this.activityStartAt,
    required this.activityEndAt,
    required this.creditHours,
    required this.location,
    required this.summary,
    required this.contactName,
    required this.contactPhone,
    required this.categoryName,
    required this.organizerName,
    required this.capacity,
    required this.enrolledCount,
    required this.isRegistered,
    required this.hasCheckedIn,
    required this.hasRetaken,
  });

  final int id;
  final String title;
  final String coverId;
  final String iconId;
  final DateTime? registrationStartAt;
  final DateTime? registrationEndAt;
  final DateTime? activityStartAt;
  final DateTime? activityEndAt;
  final double creditHours;
  final String location;
  final String summary;
  final String contactName;
  final String contactPhone;
  final String categoryName;
  final String organizerName;
  final int capacity;
  final int enrolledCount;
  final bool isRegistered;
  final bool hasCheckedIn;
  final bool hasRetaken;

  bool get isFull => capacity > 0 && enrolledCount >= capacity;

  bool get hasFutureReminderTarget {
    final now = DateTime.now();
    return (registrationEndAt?.isAfter(now) ?? false) ||
        (activityStartAt?.isAfter(now) ?? false);
  }

  bool isRecruitingAt(DateTime now) {
    final start = registrationStartAt;
    final end = registrationEndAt;
    if (start != null && now.isBefore(start)) return false;
    if (end != null && !now.isBefore(end)) return false;
    return !isFull;
  }

  String get recruitmentLabel {
    final now = DateTime.now();
    final start = registrationStartAt;
    final end = registrationEndAt;
    if (end != null && now.isAfter(end)) return '报名结束';
    if (start != null && now.isBefore(start)) return '活动预热';
    if (isFull) return '已招满';
    return '招募中';
  }

  SecondClassroomActivity copyWith({
    int? id,
    String? title,
    String? coverId,
    String? iconId,
    DateTime? registrationStartAt,
    DateTime? registrationEndAt,
    DateTime? activityStartAt,
    DateTime? activityEndAt,
    double? creditHours,
    String? location,
    String? summary,
    String? contactName,
    String? contactPhone,
    String? categoryName,
    String? organizerName,
    int? capacity,
    int? enrolledCount,
    bool? isRegistered,
    bool? hasCheckedIn,
    bool? hasRetaken,
  }) {
    return SecondClassroomActivity(
      id: id ?? this.id,
      title: title ?? this.title,
      coverId: coverId ?? this.coverId,
      iconId: iconId ?? this.iconId,
      registrationStartAt: registrationStartAt ?? this.registrationStartAt,
      registrationEndAt: registrationEndAt ?? this.registrationEndAt,
      activityStartAt: activityStartAt ?? this.activityStartAt,
      activityEndAt: activityEndAt ?? this.activityEndAt,
      creditHours: creditHours ?? this.creditHours,
      location: location ?? this.location,
      summary: summary ?? this.summary,
      contactName: contactName ?? this.contactName,
      contactPhone: contactPhone ?? this.contactPhone,
      categoryName: categoryName ?? this.categoryName,
      organizerName: organizerName ?? this.organizerName,
      capacity: capacity ?? this.capacity,
      enrolledCount: enrolledCount ?? this.enrolledCount,
      isRegistered: isRegistered ?? this.isRegistered,
      hasCheckedIn: hasCheckedIn ?? this.hasCheckedIn,
      hasRetaken: hasRetaken ?? this.hasRetaken,
    );
  }

  factory SecondClassroomActivity.fromJson(Map<String, dynamic> json) {
    return SecondClassroomActivity(
      id: _intValue(json['id']),
      title: _stringValue(json['mc']),
      coverId: _stringValue(json['fm']),
      iconId: _stringValue(json['tb']),
      registrationStartAt: parseSecondClassroomDate(json['bmkssj']),
      registrationEndAt: parseSecondClassroomDate(json['bmjssj']),
      activityStartAt: parseSecondClassroomDate(json['hdkssj']),
      activityEndAt: parseSecondClassroomDate(json['hdjssj']),
      creditHours: _doubleValue(json['xs']),
      location: _stringValue(json['hddd']),
      summary: _stringValue(json['hdjj']),
      contactName: _stringValue(json['lxr']),
      contactPhone: _stringValue(json['hdlxfs']),
      categoryName: _stringValue(json['flmc']),
      organizerName: _stringValue(json['zbzz']),
      capacity: _intValue(json['zmrs']),
      enrolledCount: _intValue(json['hdbmrs']),
      isRegistered: json['sfbm'] == true,
      hasCheckedIn: json['sfqd'] == true,
      hasRetaken: json['sfqt'] == true,
    );
  }

  factory SecondClassroomActivity.fromDetailJson(Map<String, dynamic> json) {
    final category = json['hdfl'];
    final organizer = json['zzdw'];
    return SecondClassroomActivity(
      id: _intValue(json['id']),
      title: _stringValue(json['mc']),
      coverId: _stringValue(json['fm']),
      iconId: category is Map<String, dynamic>
          ? _stringValue(category['tb'])
          : '',
      registrationStartAt: parseSecondClassroomDate(json['bmkssj']),
      registrationEndAt: parseSecondClassroomDate(json['bmjssj']),
      activityStartAt: parseSecondClassroomDate(json['hdkssj']),
      activityEndAt: parseSecondClassroomDate(json['hdjssj']),
      creditHours: _doubleValue(json['xs']),
      location: _stringValue(json['hddd']),
      summary: _stringValue(json['hdjj']),
      contactName: _stringValue(json['lxr']),
      contactPhone: _stringValue(json['hdlxfs']),
      categoryName: category is Map<String, dynamic>
          ? _stringValue(category['mc'])
          : '',
      organizerName: organizer is Map<String, dynamic>
          ? _stringValue(organizer['mc'])
          : _stringValue(json['zbf']),
      capacity: _intValue(json['zmrs']),
      enrolledCount: _intValue(json['hdbmrs']),
      isRegistered: json['sfbm'] == true,
      hasCheckedIn: json['sfqd'] == true,
      hasRetaken: json['sfqt'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'coverId': coverId,
      'iconId': iconId,
      'registrationStartAt': registrationStartAt?.toIso8601String(),
      'registrationEndAt': registrationEndAt?.toIso8601String(),
      'activityStartAt': activityStartAt?.toIso8601String(),
      'activityEndAt': activityEndAt?.toIso8601String(),
      'creditHours': creditHours,
      'location': location,
      'summary': summary,
      'contactName': contactName,
      'contactPhone': contactPhone,
      'categoryName': categoryName,
      'organizerName': organizerName,
      'capacity': capacity,
      'enrolledCount': enrolledCount,
      'isRegistered': isRegistered,
      'hasCheckedIn': hasCheckedIn,
      'hasRetaken': hasRetaken,
    };
  }

  factory SecondClassroomActivity.fromStoredJson(Map<String, dynamic> json) {
    return SecondClassroomActivity(
      id: _intValue(json['id']),
      title: _stringValue(json['title']),
      coverId: _stringValue(json['coverId']),
      iconId: _stringValue(json['iconId']),
      registrationStartAt: parseSecondClassroomDate(
        json['registrationStartAt'],
      ),
      registrationEndAt: parseSecondClassroomDate(json['registrationEndAt']),
      activityStartAt: parseSecondClassroomDate(json['activityStartAt']),
      activityEndAt: parseSecondClassroomDate(json['activityEndAt']),
      creditHours: _doubleValue(json['creditHours']),
      location: _stringValue(json['location']),
      summary: _stringValue(json['summary']),
      contactName: _stringValue(json['contactName']),
      contactPhone: _stringValue(json['contactPhone']),
      categoryName: _stringValue(json['categoryName']),
      organizerName: _stringValue(json['organizerName']),
      capacity: _intValue(json['capacity']),
      enrolledCount: _intValue(json['enrolledCount']),
      isRegistered: json['isRegistered'] == true,
      hasCheckedIn: json['hasCheckedIn'] == true,
      hasRetaken: json['hasRetaken'] == true,
    );
  }
}

class SecondClassroomActivityDetail {
  const SecondClassroomActivityDetail({
    required this.activity,
    required this.signUpMode,
    required this.limitedCollege,
    required this.limitedGrade,
    required this.hasCredit,
    required this.isFavorite,
    required this.isInRegistrationTime,
  });

  final SecondClassroomActivity activity;
  final String signUpMode;
  final String limitedCollege;
  final String limitedGrade;
  final bool hasCredit;
  final bool isFavorite;
  final bool isInRegistrationTime;

  factory SecondClassroomActivityDetail.fromExtend(
    Map<String, dynamic> extend,
  ) {
    final hd = extend['hd'];
    if (hd is! Map<String, dynamic>) {
      throw const FormatException('第二课堂活动详情缺少 hd 字段');
    }
    final signUpMode = hd['bmfs'];
    final activity = SecondClassroomActivity.fromDetailJson(hd).copyWith(
      enrolledCount: extend.containsKey('bmrs')
          ? _intValue(extend['bmrs'])
          : null,
      isRegistered: extend['sfbm'] == true,
    );
    return SecondClassroomActivityDetail(
      activity: activity,
      signUpMode: signUpMode is Map<String, dynamic>
          ? _stringValue(signUpMode['label'])
          : '',
      limitedCollege: _stringValue(hd['kcyxy']),
      limitedGrade: _stringValue(hd['kcynj']),
      hasCredit: _doubleValue(hd['xs']) > 0,
      isFavorite: extend['sfsc'] == true,
      isInRegistrationTime: extend['inTime'] == true,
    );
  }
}

DateTime? parseSecondClassroomDate(Object? value) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty || text == 'null') return null;
  return DateTime.tryParse(text)?.toLocal();
}

int _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _doubleValue(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

String _stringValue(Object? value) {
  return value?.toString().trim() ?? '';
}

List<SecondClassroomFilterOption> _filterOptionsFromStoredJson(Object? value) {
  if (value is! List) return const <SecondClassroomFilterOption>[];
  return value
      .whereType<Map>()
      .map(
        (json) => SecondClassroomFilterOption.fromJson(
          Map<String, dynamic>.from(json),
        ),
      )
      .where((option) => option.value.isNotEmpty && option.text.isNotEmpty)
      .toList(growable: false);
}
