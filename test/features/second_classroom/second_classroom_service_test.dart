import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/second_classroom/second_classroom_model.dart';
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

  test('distinguishes guest, not-registered and registered detail states', () {
    Map<String, dynamic> payload({
      required bool sfbm,
      Map<String, dynamic>? hdbm,
    }) => {
      'extend': {
        'hd': {
          'id': 2895,
          'mc': '生涯嘉年华',
          'bmkssj': '2026-11-09T04:10:00+08:00',
          'bmjssj': '2026-11-12T01:00:00+08:00',
          'hdkssj': '2026-11-12T01:00:00+08:00',
          'hdjssj': '2026-11-12T09:00:00+08:00',
          'zmrs': 1000,
        },
        'sfbm': sfbm,
        'hdbm': hdbm,
      },
    };

    expect(
      parseSecondClassroomActivityDetailPayload(payload(sfbm: false))
          .registrationState,
      SecondClassroomRegistrationState.unknown,
    );
    expect(
      parseSecondClassroomActivityDetailPayload(
        payload(sfbm: false),
        authenticated: true,
      ).registrationState,
      SecondClassroomRegistrationState.notRegistered,
    );
    final registered = parseSecondClassroomActivityDetailPayload(
      payload(
        sfbm: true,
        hdbm: {
          'shzt': {'label': '审核通过', 'value': 1},
        },
      ),
      authenticated: true,
    );
    expect(
      registered.registrationState,
      SecondClassroomRegistrationState.registered,
    );
    expect(registered.registrationStatusLabel, '审核通过');
    expect(registered.activity.isRegistered, isTrue);
  });

  test('builds WeChat activity detail url', () {
    expect(
      SecondClassroomService.instance.activityWebUrl(2485),
      'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0#/hd-detail?hdId=2485',
    );
  });

  test('reports auth hint when endpoint returns html', () async {
    final dio = Dio()
      ..httpClientAdapter = _StaticResponseAdapter('''
      <!DOCTYPE html>
      <html><body><a href="https://open.weixin.qq.com/connect/oauth2/authorize">login</a></body></html>
    ''');
    final service = SecondClassroomService(dio: dio);

    await expectLater(
      service.fetchCatalog(),
      throwsA(
        isA<SecondClassroomServiceException>().having(
          (error) => error.message,
          'message',
          '第二课堂登录态失效，请在微信中重新授权',
        ),
      ),
    );
  });

  test('parses my summary and my activities payloads', () {
    final summary = parseSecondClassroomMySummaryPayload({
      'extend': {
        'xs': {'xm': '张三', 'xymc': '信息科学与工程学院'},
        'xsjg': [
          {'flmc': '思想成长', 'yxxs': 4.5, 'yqxs': 6},
          {'flmc': '志愿公益', 'yxxs': 2.0, 'yqxs': 4},
        ],
      },
    });
    expect(summary.studentName, '张三');
    expect(summary.collegeName, '信息科学与工程学院');
    expect(summary.totalHours, 6.5);
    expect(summary.requiredHours, 10.0);
    expect(summary.categories, hasLength(2));

    final records = parseSecondClassroomMyActivitiesPayload({
      'data': [
        {
          'id': 9001,
          'shzt': {'label': '审核通过'},
          'sfqd': true,
          'sfqt': false,
          'xs': 1.5,
          'hdjl': {'id': 2895, 'mc': '生涯嘉年华', 'hddd': '体育馆', 'xs': 1.5},
        },
      ],
    });
    expect(records, hasLength(1));
    expect(records.single.recordId, 9001);
    expect(records.single.activity.id, 2895);
    expect(records.single.statusLabel, '审核通过');
    expect(records.single.hasCheckedIn, isTrue);
    expect(records.single.hasCheckedOut, isFalse);
  });

  test('parses my activities page payload with pagination metadata', () {
    final page = parseSecondClassroomMyActivitiesPagePayload({
      'pageIndex': 1,
      'pageSize': 2,
      'totalPages': 3,
      'count': 5,
      'data': [
        {
          'id': 9001,
          'shzt': {'label': '待审核'},
          'hdjl': {'id': 2895, 'mc': '生涯嘉年华'},
        },
      ],
    });

    expect(page.items, hasLength(1));
    expect(page.pageIndex, 1);
    expect(page.totalPages, 3);
    expect(page.count, 5);
    expect(page.hasMore, isTrue);

    final singlePage = parseSecondClassroomMyActivitiesPagePayload({
      'data': [
        {
          'id': 1,
          'hdjl': {'id': 10, 'mc': 'x'},
        },
      ],
    });
    expect(singlePage.totalPages, 0);
    expect(singlePage.hasMore, isFalse);
  });

  test(
    'parses my activities record check-in fields and extend.list layout',
    () {
      final page = parseSecondClassroomMyActivitiesPagePayload({
        'extend': {
          'totalPages': 1,
          'list': [
            {
              'id': 9100,
              'shzt': {'label': '审核通过'},
              'sfqd': true,
              'sfqt': true,
              'bmsj': '2026-11-01T10:00:00+08:00',
              'qdsj': '2026-11-05T08:55:00+08:00',
              'qtsj': '2026-11-05T11:05:00+08:00',
              'hdjl': {'id': 2895, 'mc': '生涯嘉年华'},
            },
          ],
        },
      });

      expect(page.items.single.checkedInAt, isNotNull);
      expect(page.items.single.checkedOutAt, isNotNull);
      expect(page.items.single.enrolledAt, isNotNull);
      expect(page.totalPages, 1);
    },
  );

  test('fetchMyActivities pulls every page and dedupes by record id', () async {
    Map<String, dynamic> myActivity(int recordId, int activityId) => {
      'id': recordId,
      'shzt': {'label': '审核通过'},
      'hdjl': {'id': activityId, 'mc': '活动$activityId'},
    };
    final adapter = _FormPagingAdapter((data) {
      final page = int.tryParse(data['page'] ?? '') ?? 1;
      return switch (page) {
        1 => {
          'code': 0,
          'pageIndex': 1,
          'pageSize': 2,
          'totalPages': 3,
          'count': 5,
          'data': [myActivity(1, 101), myActivity(2, 102)],
        },
        2 => {
          'code': 0,
          'pageIndex': 2,
          'pageSize': 2,
          'totalPages': 3,
          'count': 5,
          'data': [myActivity(3, 103), myActivity(4, 104)],
        },
        _ => {
          'code': 0,
          'pageIndex': 3,
          'pageSize': 2,
          'totalPages': 3,
          'count': 5,
          // 末页重复一条已见记录（如分页期间有人取消），不得产生重复。
          'data': [myActivity(2, 102), myActivity(5, 105)],
        },
      };
    });
    final service = SecondClassroomService(
      dio: Dio()..httpClientAdapter = adapter,
    );

    final records = await service.fetchMyActivities(limit: 2);

    expect(adapter.requests.map((entry) => entry['page']), ['1', '2', '3']);
    expect(records.map((record) => record.recordId), [1, 2, 3, 4, 5]);
    expect(records.map((record) => record.activity.id).toSet(), hasLength(5));
  });

  test('fetchMyActivities caps pagination at maxPages', () async {
    final adapter = _FormPagingAdapter((data) {
      final page = int.tryParse(data['page'] ?? '') ?? 1;
      return {
        'code': 0,
        'pageIndex': page,
        'pageSize': 1,
        'totalPages': 99,
        'count': 99,
        'data': [
          {
            'id': page,
            'hdjl': {'id': 100 + page, 'mc': '活动$page'},
          },
        ],
      };
    });
    final service = SecondClassroomService(
      dio: Dio()..httpClientAdapter = adapter,
    );

    final records = await service.fetchMyActivities(limit: 1, maxPages: 3);

    expect(adapter.requests, hasLength(3));
    expect(records, hasLength(3));
  });

  test('fetchMyActivities does not paginate without metadata', () async {
    final adapter = _FormPagingAdapter((data) {
      return {
        'code': 0,
        'data': [
          {
            'id': 7,
            'hdjl': {'id': 200, 'mc': '单页活动'},
          },
        ],
      };
    });
    final service = SecondClassroomService(
      dio: Dio()..httpClientAdapter = adapter,
    );

    final records = await service.fetchMyActivities();

    expect(adapter.requests, hasLength(1));
    expect(records.single.recordId, 7);
  });

  test('parses my summary payload with real zjf and sqbjfList structure', () {
    final summary = parseSecondClassroomMySummaryPayload({
      'code': 0,
      'msg': 'success',
      'extend': {
        'zjf': 4.0,
        'ljzjf': 4.0,
        'xsjg': {'zjf': 4.0, 'ljzjf': 4.0},
        'sqbjfList': [
          {'mc': '思想成长', 'jf': 0.5, 'jfxz': 20},
          {'mc': '技能特长', 'jf': 3, 'jfxz': 15},
        ],
      },
    });
    expect(summary.totalHours, 4.0);
    expect(summary.categories, hasLength(2));
    expect(summary.categories.first.name, '思想成长');
    expect(summary.categories.first.earned, 0.5);
    expect(summary.categories.first.requiredHours, 20);
    expect(summary.categories.last.name, '技能特长');
    expect(summary.categories.last.earned, 3.0);
    expect(summary.categories.last.requiredHours, 15);
  });
}

/// 记录 `wdhd` 的 form 请求体并按回调返回 JSON 响应，用于分页测试。
class _FormPagingAdapter implements HttpClientAdapter {
  _FormPagingAdapter(this._responder);

  final Map<String, dynamic> Function(Map<String, String> data) _responder;
  final requests = <Map<String, String>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = await requestStream?.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    final body = bytes == null ? '' : utf8.decode(bytes);
    final data = <String, String>{
      for (final pair in body.split('&').where((part) => part.isNotEmpty))
        pair.split('=').first: Uri.decodeComponent(
          pair.contains('=') ? pair.split('=').sublist(1).join('=') : '',
        ),
    };
    requests.add(data);
    return ResponseBody.fromString(
      jsonEncode(_responder(data)),
      200,
      headers: const {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _StaticResponseAdapter implements HttpClientAdapter {
  const _StaticResponseAdapter(this.body);

  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      body,
      200,
      headers: const {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
