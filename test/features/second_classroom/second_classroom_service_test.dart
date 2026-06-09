import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/second_classroom/second_classroom_service.dart';

void main() {
  test('parses second classroom catalog payload', () {
    final catalog = parseSecondClassroomCatalogPayload({
      'extend': {
        'hdflList': [
          {'value': '1', 'text': '思想成长'},
          {'value': '3', 'text': '实践实习'},
        ],
        'zzjgList': [
          {'value': '51', 'text': '建筑工程学院'},
        ],
        'zzlbList': [
          {'id': 2, 'mc': '学生部门'},
          {'id': 3, 'mc': '学生社团'},
        ],
      },
    });

    expect(catalog.categories.map((item) => item.text), ['思想成长', '实践实习']);
    expect(catalog.departments.single.value, '51');
    expect(catalog.organizationTypes.map((item) => item.value), ['2', '3']);
  });

  test('parses second classroom search page payload', () {
    final page = parseSecondClassroomActivityPagePayload({
      'pageIndex': 1,
      'pageSize': 2,
      'totalPages': 3,
      'count': 6,
      'data': [
        {
          'id': 2485,
          'fm': 'cover-id',
          'bmkssj': '2026-06-08T00:00:00+08:00',
          'bmjssj': '2026-06-15T17:00:00+08:00',
          'hdkssj': '2026-06-15T18:30:00+08:00',
          'hdjssj': '2026-06-15T20:00:00+08:00',
          'xs': 0.0,
          'mc': '榜样分享活动',
          'hddd': '兴德楼北楼201',
          'zmrs': 90,
          'hdjj': '报名成功后加群',
          'lxr': '张展健',
          'hdlxfs': '18536419261',
          'flmc': '思想成长',
          'tb': 'icon-id',
          'sfbm': null,
          'sfqd': null,
          'sfqt': null,
          'zbzz': '建工学院团委学生会',
          'hdbmrs': 31,
        },
      ],
    });

    expect(page.hasMore, isTrue);
    expect(page.items.single.id, 2485);
    expect(page.items.single.title, '榜样分享活动');
    expect(page.items.single.enrolledCount, 31);
    expect(page.items.single.registrationEndAt, isNotNull);
  });

  test('parses detail payload with extend state overrides', () {
    final detail = parseSecondClassroomActivityDetailPayload({
      'extend': {
        'hd': {
          'id': 2485,
          'hdfl': {'mc': '思想成长', 'tb': 'icon-id'},
          'mc': '榜样分享活动',
          'bmkssj': '2026-06-08T00:00:00+08:00',
          'bmjssj': '2026-06-15T17:00:00+08:00',
          'hdkssj': '2026-06-15T18:30:00+08:00',
          'hdjssj': '2026-06-15T20:00:00+08:00',
          'zmrs': 90,
          'hddd': '兴德楼北楼201',
          'kcyxy': '建筑工程学院',
          'kcynj': '不限',
          'bmfs': {'label': '报名无需审核，人满即止'},
          'zzdw': {'mc': '建工学院团委学生会'},
          'fm': 'cover-id',
          'hdjj': '报名成功后加群',
          'lxr': '张展健',
          'hdlxfs': '18536419261',
          'xs': 0.0,
        },
        'inTime': true,
        'sfsc': true,
        'sfbm': true,
        'bmrs': 31,
      },
    });

    expect(detail.activity.isRegistered, isTrue);
    expect(detail.activity.enrolledCount, 31);
    expect(detail.isFavorite, isTrue);
    expect(detail.isInRegistrationTime, isTrue);
    expect(detail.signUpMode, '报名无需审核，人满即止');
  });

  test('builds WeChat activity detail url', () {
    expect(
      SecondClassroomService.instance.activityWebUrl(2485),
      'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0#/hd-detail?hdId=2485',
    );
  });
}
