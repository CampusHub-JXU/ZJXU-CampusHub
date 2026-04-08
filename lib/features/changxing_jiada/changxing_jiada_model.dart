class ChangxingUserProfile {
  const ChangxingUserProfile({
    required this.name,
    required this.jobNo,
    required this.phone,
    required this.emergencyContact,
    required this.emergencyPhone,
  });

  final String name;
  final String jobNo;
  final String phone;
  final String emergencyContact;
  final String emergencyPhone;

  factory ChangxingUserProfile.fromJson(Map<String, dynamic> json) {
    final userInfo = (json['userInfo'] as Map<String, dynamic>?) ?? json;
    return ChangxingUserProfile(
      name: (userInfo['name'] as String?)?.trim() ?? '',
      jobNo: (userInfo['jobNo'] as String?)?.trim() ?? '',
      phone: (userInfo['phone'] as String?)?.trim() ?? '',
      emergencyContact: (userInfo['emergencyContact'] as String?)?.trim() ?? '',
      emergencyPhone: (userInfo['emergencyPhone'] as String?)?.trim() ?? '',
    );
  }
}

class ChangxingApplication {
  const ChangxingApplication({
    required this.id,
    required this.type,
    required this.status,
    required this.userName,
    required this.departmentName,
    required this.userJobNo,
    required this.userPhone,
    required this.descr,
    required this.remark,
    required this.trafficTool,
    required this.backStatus,
    required this.notBackReason,
    required this.emergencyContact,
    required this.emergencyPhone,
    required this.startTime,
    required this.endTime,
    required this.upTime,
  });

  final int id;
  final int type;
  final int status;
  final String userName;
  final String departmentName;
  final String userJobNo;
  final String userPhone;
  final String descr;
  final String remark;
  final String trafficTool;
  final int backStatus;
  final String notBackReason;
  final String emergencyContact;
  final String emergencyPhone;
  final DateTime? startTime;
  final DateTime? endTime;
  final DateTime? upTime;

  String get typeLabel {
    switch (type) {
      case 1:
        return '请假';
      case 2:
        return '离校';
      case 3:
        return '返校';
      case 4:
        return '超时登记';
      default:
        return '申请';
    }
  }

  String get statusLabel {
    switch (status) {
      case 0:
        return '待审核';
      case 1:
        if (type == 1 || type == 2) return '待出校';
        if (type == 3 || type == 4) return '待返校';
        return '处理中';
      case 2:
        return '未通过';
      case 3:
        return '已撤销';
      case 4:
        return '已返校';
      case 5:
        return '离校需销假';
      case 6:
        return '已销假';
      default:
        return '未知';
    }
  }

  bool get shouldShowRemark => status != 0 && status != 3 && remark.isNotEmpty;

  factory ChangxingApplication.fromJson(Map<String, dynamic> json) {
    int parseInt(dynamic value) {
      if (value is int) return value;
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    DateTime? parseDate(dynamic value) {
      final text = value?.toString().trim() ?? '';
      if (text.isEmpty) return null;
      return DateTime.tryParse(text);
    }

    String parseText(dynamic value) => value?.toString().trim() ?? '';

    return ChangxingApplication(
      id: parseInt(json['id']),
      type: parseInt(json['type']),
      status: parseInt(json['status']),
      userName: parseText(json['userName']),
      departmentName: parseText(json['departmentName']),
      userJobNo: parseText(json['userJobNo']),
      userPhone: parseText(json['userPhone']),
      descr: parseText(json['descr']),
      remark: parseText(json['remark']),
      trafficTool: parseText(json['trafficTool']),
      backStatus: parseInt(json['backStatus']),
      notBackReason: parseText(json['notBackReason']),
      emergencyContact: parseText(json['emergencyContact']),
      emergencyPhone: parseText(json['emergencyPhone']),
      startTime: parseDate(json['startTime']),
      endTime: parseDate(json['endTime']),
      upTime: parseDate(json['upTime']),
    );
  }
}
