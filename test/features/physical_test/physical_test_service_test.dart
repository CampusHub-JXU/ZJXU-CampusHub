import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/auth/cas_routed_access.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/features/physical_test/physical_test_service.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

String _fixture(String name) =>
    File('test/features/physical_test/fixtures/$name').readAsStringSync();

final _menuHtml = _fixture('login_menu_main_jsp.html');
final _currentHtml = _fixture('current_score_healthscore.html');
final _unavailableCurrentHtml = _fixture(
  'current_score_unavailable_healthscore.html',
);
final _yearListHtml = _fixture('year_list_score_total.html');
final _proxyYearListHtml = _fixture('year_list_score_total_webvpn_links.html');
final _detailHtml = _fixture('score_detail_score_details.html');

const _stuNo = 'VEVTVF9TVFVERU5UXzAwMDE=';
const _schoolid = 'TEST_SCHOOL_0001';
const _loginHtml = '''
<html><body><form id="fm1">
  <input type="hidden" name="execution" value="e1s1"/>
  <input type="hidden" name="lt" value="LT-1"/>
</form></body></html>
''';
const _casLoginLocation =
    'https://newca.zjxu.edu.cn/cas/login'
    '?service=http%3A%2F%2Fjkjy.zjxu.edu.cn%2Fweixin%2Flogin.jsp';

Dio _dioWith(MockHttpClientAdapter adapter) =>
    Dio(BaseOptions(responseType: ResponseType.bytes))
      ..httpClientAdapter = adapter;

MockHttpClientAdapter _happyPathAdapter({
  void Function(RequestOptions options)? onMenu,
  void Function(RequestOptions options)? onPost,
  void Function(RequestOptions options)? onDetail,
}) {
  return MockHttpClientAdapter(
    handlers: {
      'GET /weixin/main.jsp': (options) async {
        onMenu?.call(options);
        return ResponseBody.fromString(_menuHtml, 200);
      },
      'POST /spQuery': (options) async {
        onPost?.call(options);
        final method = options.data is Map ? options.data['method'] : null;
        if (method == 'healthscore') {
          return ResponseBody.fromString(_currentHtml, 200);
        }
        if (method == null &&
            options.uri.queryParameters['method'] == 'scoreTotal') {
          return ResponseBody.fromString(_yearListHtml, 200);
        }
        throw StateError('unexpected POST: ${options.uri} ${options.data}');
      },
      'GET /spQuery': (options) async {
        onDetail?.call(options);
        if (options.uri.queryParameters['method'] == 'scoreDetails' &&
            options.uri.queryParameters['year'] == '2025-2026' &&
            options.uri.queryParameters['term'] == '1') {
          return ResponseBody.fromString(_detailHtml, 200);
        }
        throw StateError('unexpected detail fetch: ${options.uri}');
      },
    },
  );
}

void main() {
  setUp(() async {
    await resetTestEnvironment();
    PhysicalTestService.instance.debugReset();
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'TEST_STUDENT_0001',
    );
    UnifiedAuthService.instance.debugSessionValidator = (_) async => true;
    ConnectModeResolver.instance.targetDirectReachabilityChecker = (_) async =>
        true;
  });

  tearDown(() {
    CasRoutedAccess.debugGatewayEnsurer = null;
    PhysicalTestService.instance.debugReset();
  });

  test('抓取当前与历年成绩：真实 method/body，同学期不重复抓取', () async {
    final postOptions = <RequestOptions>[];
    final detailUris = <Uri>[];
    final adapter = _happyPathAdapter(
      onPost: postOptions.add,
      onDetail: (options) => detailUris.add(options.uri),
    );
    final service = PhysicalTestService.instance
      ..debugSetDio(_dioWith(adapter));

    final snapshot = await service.fetchSnapshot();

    expect(snapshot.records, hasLength(2));
    expect(snapshot.updatedAt, isNotNull);

    final current = snapshot.records.first;
    expect(current.academicYear, '2025-2026-2');
    expect(current.totalScore, '55.0');
    expect(current.grade, '及格');
    expect(current.items, hasLength(8));
    expect(current.items.first.result, '170.0 厘米');
    expect(current.items[1].score, '100');
    expect(current.items.last.name, '1000米跑');
    expect(current.items.last.result, '4.00 分钟');

    final history = snapshot.records.last;
    expect(history.academicYear, '2025-2026-1');
    expect(history.totalScore, '52.0');
    expect(history.items, hasLength(8));
    expect(history.items.first.result, '170.5 厘米');

    expect(postOptions, hasLength(2));
    final currentPost = postOptions.first;
    expect(currentPost.method, 'POST');
    expect(currentPost.uri.toString(), 'http://jkjy.zjxu.edu.cn/spQuery');
    expect(currentPost.data, {
      'method': 'healthscore',
      'stuNo': _stuNo,
      'schoolid': _schoolid,
    });

    final yearPost = postOptions.last;
    expect(yearPost.method, 'POST');
    expect(yearPost.uri.path, '/spQuery');
    expect(yearPost.uri.queryParameters, {'method': 'scoreTotal'});
    expect(yearPost.data, {'stuNo': _stuNo, 'schoolid': _schoolid});

    // 当前学期已由 healthscore 覆盖，只用 GET 抓了另一学期的明细。
    expect(detailUris, hasLength(1));
    expect(detailUris.single.toString(), contains('method=scoreDetails'));
    expect(detailUris.single.queryParameters, {
      'method': 'scoreDetails',
      'schoolid': _schoolid,
      'stuNo': _stuNo,
      'year': '2025-2026',
      'term': '1',
    });
  });

  test('healthscore 未开放时不阻断历年成绩加载', () async {
    final detailUris = <Uri>[];
    final adapter = MockHttpClientAdapter(
      handlers: {
        'GET /weixin/main.jsp': (_) async =>
            ResponseBody.fromString(_menuHtml, 200),
        'POST /spQuery': (options) async {
          final method = options.data is Map ? options.data['method'] : null;
          if (method == 'healthscore') {
            return ResponseBody.fromString(_unavailableCurrentHtml, 200);
          }
          return ResponseBody.fromString(_yearListHtml, 200);
        },
        'GET /spQuery': (options) async {
          detailUris.add(options.uri);
          return ResponseBody.fromString(_detailHtml, 200);
        },
      },
    );
    final service = PhysicalTestService.instance
      ..debugSetDio(_dioWith(adapter));

    final snapshot = await service.fetchSnapshot();

    // current 为中性空，历年两条（2025-2026-1 / 2025-2026-2）仍展示。
    expect(snapshot.records, hasLength(2));
    expect(snapshot.records.first.academicYear, '2025-2026-1');
    expect(snapshot.records.first.totalScore, '52.0');
    expect(snapshot.records.first.items, hasLength(8));
    expect(detailUris, hasLength(2));
    expect(detailUris.map((uri) => uri.queryParameters['term']).toList(), [
      '1',
      '2',
    ]);
  });

  test('healthscore 结构损坏仍失败，不默认为无成绩', () async {
    var yearListRequested = false;
    final adapter = MockHttpClientAdapter(
      handlers: {
        'GET /weixin/main.jsp': (_) async =>
            ResponseBody.fromString(_menuHtml, 200),
        'POST /spQuery': (options) async {
          final method = options.data is Map ? options.data['method'] : null;
          if (method == 'healthscore') {
            return ResponseBody.fromString(
              '<html><body><div>成绩查询升级维护中</div></body></html>',
              200,
            );
          }
          yearListRequested = true;
          return ResponseBody.fromString(_yearListHtml, 200);
        },
      },
    );
    final service = PhysicalTestService.instance
      ..debugSetDio(_dioWith(adapter));

    await expectLater(service.fetchSnapshot(), throwsA(isA<StateError>()));
    expect(yearListRequested, isFalse);
    expect(service.debugCachedSnapshot, isNull);
  });

  test('WebVPN 代理相对详情链接被接受并重建为源站资源 URL', () async {
    final detailUris = <Uri>[];
    final adapter = MockHttpClientAdapter(
      handlers: {
        'GET /weixin/main.jsp': (_) async =>
            ResponseBody.fromString(_menuHtml, 200),
        'POST /spQuery': (options) async {
          final method = options.data is Map ? options.data['method'] : null;
          if (method == 'healthscore') {
            return ResponseBody.fromString(_currentHtml, 200);
          }
          return ResponseBody.fromString(_proxyYearListHtml, 200);
        },
        'GET /spQuery': (options) async {
          detailUris.add(options.uri);
          return ResponseBody.fromString(_detailHtml, 200);
        },
      },
    );
    final service = PhysicalTestService.instance
      ..debugSetDio(_dioWith(adapter));

    final snapshot = await service.fetchSnapshot();

    expect(snapshot.records, hasLength(3));
    expect(snapshot.records[1].academicYear, '2025-2026-1');
    expect(snapshot.records[1].items, hasLength(8));
    expect(detailUris, hasLength(2));
    for (final uri in detailUris) {
      expect(uri.host, 'jkjy.zjxu.edu.cn');
      expect(uri.path, '/spQuery');
      expect(uri.queryParameters['method'], 'scoreDetails');
      expect(uri.queryParameters['stuNo'], _stuNo);
      expect(uri.queryParameters['schoolid'], _schoolid);
    }
    expect(detailUris[0].queryParameters['year'], '2025-2026');
    expect(detailUris[0].queryParameters['term'], '1');
    expect(detailUris[1].queryParameters['year'], '2024-2025');
    expect(detailUris[1].queryParameters['term'], '2');
  });

  test('重建参数优先取行内可信学年，缺学期时回退白名单 href', () async {
    const mixedYearList = '''
<html><body>
<table class="ui-table">
<thead><tr><th>学年</th><th>年级</th><th>加分</th><th>得分</th><th>等级</th><th>详情</th></tr></thead>
<tbody>
<tr><td>2023-2024-1</td><td>99</td><td>0</td><td>48.0</td><td>及格</td><td><a href="/spQuery?method=scoreDetails&amp;schoolid=TEST_SCHOOL_0001&amp;stuNo=VEVTVF9TVFVERU5UXzAwMDE=&amp;year=1999-2000&amp;term=9">查看</a></td></tr>
<tr><td>2022-2023</td><td>99</td><td>0</td><td>47.0</td><td>及格</td><td><a href="/spQuery?method=scoreDetails&amp;schoolid=TEST_SCHOOL_0001&amp;stuNo=VEVTVF9TVFVERU5UXzAwMDE=&amp;year=2022-2023&amp;term=2">查看</a></td></tr>
</tbody></table>
</body></html>
''';
    final detailUris = <Uri>[];
    final adapter = MockHttpClientAdapter(
      handlers: {
        'GET /weixin/main.jsp': (_) async =>
            ResponseBody.fromString(_menuHtml, 200),
        'POST /spQuery': (options) async {
          final method = options.data is Map ? options.data['method'] : null;
          if (method == 'healthscore') {
            return ResponseBody.fromString(_currentHtml, 200);
          }
          return ResponseBody.fromString(mixedYearList, 200);
        },
        'GET /spQuery': (options) async {
          detailUris.add(options.uri);
          return ResponseBody.fromString(_detailHtml, 200);
        },
      },
    );
    final service = PhysicalTestService.instance
      ..debugSetDio(_dioWith(adapter));

    await service.fetchSnapshot();

    expect(detailUris, hasLength(2));
    // 行内学年 2023-2024-1 覆盖 href 里的 1999-2000/9。
    expect(detailUris[0].queryParameters['year'], '2023-2024');
    expect(detailUris[0].queryParameters['term'], '1');
    // 行内学年缺学期时，使用白名单校验过的 href 参数。
    expect(detailUris[1].queryParameters['year'], '2022-2023');
    expect(detailUris[1].queryParameters['term'], '2');
  });

  test('同一会话重复调用命中缓存，forceRefresh 重新抓取', () async {
    final adapter = _happyPathAdapter();
    final service = PhysicalTestService.instance
      ..debugSetDio(_dioWith(adapter));

    final first = await service.fetchSnapshot();
    final requestsAfterFirst = adapter.requestLog.length;

    final second = await service.fetchSnapshot();
    expect(identical(first, second), isTrue);
    expect(adapter.requestLog, hasLength(requestsAfterFirst));

    final refreshed = await service.fetchSnapshot(forceRefresh: true);
    expect(identical(first, refreshed), isFalse);
    expect(adapter.requestLog.length, greaterThan(requestsAfterFirst));
  });

  test('身份空值 / null / base64 null 一律拒绝，不发起查询', () async {
    for (final badValue in ['', 'null', 'bnVsbA==']) {
      PhysicalTestService.instance.debugReset();
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'TEST_STUDENT_0001',
      );
      UnifiedAuthService.instance.debugSessionValidator = (_) async => true;

      final badMenu = _menuHtml.replaceFirst(
        'value="VEVTVF9TVFVERU5UXzAwMDE="',
        'value="$badValue"',
      );
      final adapter = MockHttpClientAdapter(
        handlers: {
          'GET /weixin/main.jsp': (_) async =>
              ResponseBody.fromString(badMenu, 200),
          'POST /spQuery': (_) async =>
              throw StateError('identity was rejected but query was sent'),
        },
      );
      final service = PhysicalTestService.instance
        ..debugSetDio(_dioWith(adapter));

      await expectLater(
        service.fetchSnapshot(),
        throwsA(isA<StateError>()),
        reason: 'stuNo=$badValue should be rejected',
      );
      expect(
        adapter.requestLog.where((line) => line.startsWith('POST')),
        isEmpty,
      );
    }
  });

  test('无本地会话抛 CasAuthExpiredException，且不发起请求', () async {
    UnifiedAuthService.instance.debugReset();
    final adapter = MockHttpClientAdapter();
    final service = PhysicalTestService.instance
      ..debugSetDio(_dioWith(adapter));

    await expectLater(
      service.fetchSnapshot(),
      throwsA(isA<CasAuthExpiredException>()),
    );
    expect(adapter.requestLog, isEmpty);
  });

  test('会话明确失效抛 CasAuthExpiredException', () async {
    UnifiedAuthService.instance.debugSessionValidator = (_) async => false;
    final adapter = MockHttpClientAdapter();
    final service = PhysicalTestService.instance
      ..debugSetDio(_dioWith(adapter));

    await expectLater(
      service.fetchSnapshot(),
      throwsA(isA<CasAuthExpiredException>()),
    );
    expect(adapter.requestLog, isEmpty);
  });

  test('会话校验网络未知抛 TimeoutException 且保留全局会话', () async {
    UnifiedAuthService.instance.debugSessionValidator = (_) async => null;
    final adapter = MockHttpClientAdapter();
    final service = PhysicalTestService.instance
      ..debugSetDio(_dioWith(adapter));

    await expectLater(
      service.fetchSnapshot(),
      throwsA(isA<TimeoutException>()),
    );
    expect(adapter.requestLog, isEmpty);
    expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
  });

  test('资源页返回 CAS 登录页时有界重试一次，不清理全局会话', () async {
    var menuRequests = 0;
    final adapter = MockHttpClientAdapter(
      handlers: {
        'GET /weixin/main.jsp': (_) async {
          menuRequests++;
          return ResponseBody.fromString(_loginHtml, 200);
        },
      },
    );
    final service = PhysicalTestService.instance
      ..debugSetDio(_dioWith(adapter));

    await expectLater(
      service.fetchSnapshot(),
      throwsA(isA<CasAuthExpiredException>()),
    );
    expect(menuRequests, 2);
    expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
    expect(service.debugCachedSnapshot, isNull);
  });

  test('查询 POST 命中 CAS 跳转时有界重试一次，不 markLoggedOut', () async {
    var postRequests = 0;
    final adapter = MockHttpClientAdapter(
      handlers: {
        'GET /weixin/main.jsp': (_) async =>
            ResponseBody.fromString(_menuHtml, 200),
        'POST /spQuery': (_) async {
          postRequests++;
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': [_casLoginLocation],
            },
          );
        },
      },
    );
    final service = PhysicalTestService.instance
      ..debugSetDio(_dioWith(adapter));

    await expectLater(
      service.fetchSnapshot(),
      throwsA(isA<CasAuthExpiredException>()),
    );
    expect(postRequests, 2);
    expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
    expect(service.debugCachedSnapshot, isNull);
  });

  test('网络未知原样抛出且保留全局会话', () async {
    final adapter = MockHttpClientAdapter(
      handlers: {
        'GET /weixin/main.jsp': (_) async =>
            ResponseBody.fromString(_menuHtml, 200),
        'POST /spQuery': (options) async {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            message: 'offline',
          );
        },
      },
    );
    final service = PhysicalTestService.instance
      ..debugSetDio(_dioWith(adapter));

    await expectLater(service.fetchSnapshot(), throwsA(isA<DioException>()));
    expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
  });

  test('异步登出后的迟到结果被拒绝且不进入缓存', () async {
    final started = Completer<void>();
    final pending = Completer<ResponseBody>();
    final adapter = MockHttpClientAdapter(
      handlers: {
        'GET /weixin/main.jsp': (_) {
          if (!started.isCompleted) started.complete();
          return pending.future;
        },
      },
    );
    final service = PhysicalTestService.instance
      ..debugSetDio(_dioWith(adapter));

    final future = service.fetchSnapshot();
    await started.future;
    await UnifiedAuthService.instance.markLoggedOut();
    pending.complete(ResponseBody.fromString(_menuHtml, 200));

    await expectLater(future, throwsA(isA<StateError>()));
    expect(service.debugCachedSnapshot, isNull);
    expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
  });

  test('异步切换账号后旧账号迟到结果被拒绝', () async {
    final started = Completer<void>();
    final pending = Completer<ResponseBody>();
    final adapter = MockHttpClientAdapter(
      handlers: {
        'GET /weixin/main.jsp': (_) {
          if (!started.isCompleted) started.complete();
          return pending.future;
        },
      },
    );
    final service = PhysicalTestService.instance
      ..debugSetDio(_dioWith(adapter));

    final future = service.fetchSnapshot();
    await started.future;
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'TEST_STUDENT_0002',
    );
    pending.complete(ResponseBody.fromString(_menuHtml, 200));

    await expectLater(future, throwsA(isA<StateError>()));
    expect(service.debugCachedSnapshot, isNull);
  });

  group('历年链接白名单', () {
    test('接受同站 /spQuery scoreDetails 链接并返回学年学期', () {
      final detail = PhysicalTestService.validatePhysicalTestDetailLink(
        href:
            '/spQuery?method=scoreDetails&schoolid=$_schoolid'
            '&stuNo=$_stuNo&year=2025-2026&term=1',
        stuNo: _stuNo,
        schoolid: _schoolid,
      );

      expect(detail, isNotNull);
      expect(detail!.year, '2025-2026');
      expect(detail.term, '1');
    });

    test('拒绝跨 host / 错误 path / 错误 method / 身份不符 / 缺参', () {
      ({String year, String term})? check(String href) =>
          PhysicalTestService.validatePhysicalTestDetailLink(
            href: href,
            stuNo: _stuNo,
            schoolid: _schoolid,
          );

      expect(
        check(
          'http://evil.example.com/spQuery?method=scoreDetails'
          '&schoolid=$_schoolid&stuNo=$_stuNo&year=2025-2026&term=1',
        ),
        isNull,
      );
      expect(
        check(
          '/other?method=scoreDetails&schoolid=$_schoolid'
          '&stuNo=$_stuNo&year=2025-2026&term=1',
        ),
        isNull,
      );
      expect(
        check(
          '/spQuery?method=healthscore&schoolid=$_schoolid'
          '&stuNo=$_stuNo&year=2025-2026&term=1',
        ),
        isNull,
      );
      expect(
        check(
          '/spQuery?method=scoreDetails&schoolid=$_schoolid'
          '&stuNo=OTHER&year=2025-2026&term=1',
        ),
        isNull,
      );
      expect(
        check(
          '/spQuery?method=scoreDetails&schoolid=999999'
          '&stuNo=$_stuNo&year=2025-2026&term=1',
        ),
        isNull,
      );
      expect(
        check(
          '/spQuery?method=scoreDetails&schoolid=$_schoolid'
          '&stuNo=$_stuNo&year=2025-2026',
        ),
        isNull,
      );
      expect(
        check(
          'http://jkjy.zjxu.edu.cn/spQuery?method=scoreDetails'
          '&schoolid=$_schoolid&stuNo=$_stuNo&year=2025-2026&term=1',
        ),
        isNotNull,
      );
      // base64 学号里的 `+` 既不能按空格解码，也不能在重建时丢失。
      for (final encodedStuNo in ['a+b/c=', 'a%2Bb%2Fc%3D']) {
        expect(
          PhysicalTestService.validatePhysicalTestDetailLink(
            href:
                '/spQuery?method=scoreDetails&schoolid=$_schoolid'
                '&stuNo=$encodedStuNo&year=2025-2026&term=1',
            stuNo: 'a+b/c=',
            schoolid: _schoolid,
          ),
          isNotNull,
        );
      }
    });

    test('接受 jkjy 的 WebVPN 代理详情链接（相对与绝对）', () {
      const proxyPath =
          '/http/77726476706e69737468656265737421fafc4b85692a62486b468ca88d1b203b'
          '/spQuery?method=scoreDetails&schoolid=$_schoolid'
          '&stuNo=$_stuNo&year=2025-2026&term=1';

      final relative = PhysicalTestService.validatePhysicalTestDetailLink(
        href: proxyPath,
        stuNo: _stuNo,
        schoolid: _schoolid,
      );
      expect(relative, isNotNull);
      expect(relative!.year, '2025-2026');
      expect(relative.term, '1');

      final absolute = PhysicalTestService.validatePhysicalTestDetailLink(
        href: 'https://webvpn.zjxu.edu.cn$proxyPath',
        stuNo: _stuNo,
        schoolid: _schoolid,
      );
      expect(absolute, isNotNull);
      expect(absolute!.year, '2025-2026');
      expect(absolute.term, '1');
    });

    test('拒绝恶意代理主机 / 路径 / 跨域与非法参数', () {
      ({String year, String term})? check(String href) =>
          PhysicalTestService.validatePhysicalTestDetailLink(
            href: href,
            stuNo: _stuNo,
            schoolid: _schoolid,
          );
      const token =
          '77726476706e69737468656265737421fafc4b85692a62486b468ca88d1b203b';
      final query =
          '?method=scoreDetails&schoolid=$_schoolid&stuNo=$_stuNo'
          '&year=2025-2026&term=1';

      // 冒充代理的跨域主机。
      expect(
        check('https://evil.example.com/http/$token/spQuery$query'),
        isNull,
      );
      // 同一个 WebVPN 网关但 host hash 不是 jkjy。
      expect(
        check(
          'https://webvpn.zjxu.edu.cn/http/'
          '0000000000000000000000000000000000000000000000000000000000000000'
          '/spQuery$query',
        ),
        isNull,
      );
      // 合法 jkjy 代理前缀但路径被追加 / 改写。
      expect(
        check('https://webvpn.zjxu.edu.cn/http/$token/spQuery/extra$query'),
        isNull,
      );
      expect(
        check('https://webvpn.zjxu.edu.cn/http/$token/other$query'),
        isNull,
      );
      // WebVPN 网关下的 `https` 版本前缀不是 jkjy 的登记映射。
      expect(
        check('https://webvpn.zjxu.edu.cn/https/$token/spQuery$query'),
        isNull,
      );
      // userinfo 伪装的源站跨域。
      expect(
        check('http://evil.example.com@jkjy.zjxu.edu.cn/spQuery$query'),
        isNull,
      );
      // 代理形态下 method / 身份 / 学年格式不符。
      expect(
        check(
          'https://webvpn.zjxu.edu.cn/http/$token/spQuery'
          '?method=healthscore&schoolid=$_schoolid&stuNo=$_stuNo'
          '&year=2025-2026&term=1',
        ),
        isNull,
      );
      expect(
        check(
          'https://webvpn.zjxu.edu.cn/http/$token/spQuery'
          '?method=scoreDetails&schoolid=$_schoolid&stuNo=OTHER'
          '&year=2025-2026&term=1',
        ),
        isNull,
      );
      expect(
        check(
          'https://webvpn.zjxu.edu.cn/http/$token/spQuery'
          '?method=scoreDetails&schoolid=$_schoolid&stuNo=$_stuNo'
          '&year=2025&term=1',
        ),
        isNull,
      );
    });

    test('非白名单链接不跟随，仅保留列表页学年汇总', () async {
      const hostileYearList = '''
<html><body>
<table class="ui-table">
<thead><tr><th>学年</th><th>年级</th><th>加分</th><th>得分</th><th>等级</th><th>详情</th></tr></thead>
<tbody>
<tr><td>2024-2025-1</td><td>99</td><td>0</td><td>50.0</td><td>及格</td><td><a href="http://evil.example.com/spQuery?method=scoreDetails&amp;schoolid=TEST_SCHOOL_0001&amp;stuNo=VEVTVF9TVFVERU5UXzAwMDE=&amp;year=2024-2025&amp;term=1">查看</a></td></tr>
<tr><td>2024-2025-2</td><td>99</td><td>0</td><td>51.0</td><td>及格</td><td><a href="/spQuery?method=healthscore&amp;schoolid=TEST_SCHOOL_0001&amp;stuNo=VEVTVF9TVFVERU5UXzAwMDE=&amp;year=2024-2025&amp;term=2">查看</a></td></tr>
<tr><td>2023-2024-1</td><td>99</td><td>0</td><td>49.0</td><td>及格</td><td><a href="/spQuery?method=scoreDetails&amp;schoolid=TEST_SCHOOL_0001&amp;stuNo=WRONG&amp;year=2023-2024&amp;term=1">查看</a></td></tr>
<tr><td>2025-2026-2</td><td>99</td><td>0</td><td>57.0</td><td>及格</td><td><a href="/spQuery?method=scoreDetails&amp;schoolid=TEST_SCHOOL_0001&amp;stuNo=VEVTVF9TVFVERU5UXzAwMDE=&amp;year=2025-2026&amp;term=2">查看</a></td></tr>
</tbody></table>
</body></html>
''';
      final requestUris = <Uri>[];
      final adapter = MockHttpClientAdapter(
        handlers: {
          'GET /weixin/main.jsp': (options) async {
            requestUris.add(options.uri);
            return ResponseBody.fromString(_menuHtml, 200);
          },
          'POST /spQuery': (options) async {
            requestUris.add(options.uri);
            final method = options.data is Map ? options.data['method'] : null;
            return ResponseBody.fromString(
              method == 'healthscore' ? _currentHtml : hostileYearList,
              200,
            );
          },
          'GET /spQuery': (_) async =>
              throw StateError('hostile detail link must not be followed'),
        },
      );
      final service = PhysicalTestService.instance
        ..debugSetDio(_dioWith(adapter));

      final snapshot = await service.fetchSnapshot();

      expect(snapshot.records, hasLength(4));
      expect(snapshot.records[0].academicYear, '2025-2026-2');
      expect(snapshot.records[1].totalScore, '50.0');
      expect(snapshot.records[1].items, isEmpty);
      expect(snapshot.records[2].totalScore, '51.0');
      expect(snapshot.records[3].totalScore, '49.0');
      expect(
        requestUris.map((uri) => uri.host),
        everyElement('jkjy.zjxu.edu.cn'),
      );
    });
  });

  group('WebVPN 路由（共享 CasRoutedAccess）', () {
    const proxyPrefix =
        '/http/77726476706e69737468656265737421fafc4b85692a62486b468ca88d1b203b';

    void forceWebVpn() {
      ConnectModeResolver.instance.targetDirectReachabilityChecker = (
        _,
      ) async => false;
      ConnectModeResolver.instance.webVpnReachabilityChecker = () async => true;
    }

    test('选路 WebVPN 时经共享网关钩子建会话，资源走代理路径且不改全局 mode', () async {
      forceWebVpn();
      final before = ZhengfangAuth.instance.mode;
      var gatewayCalls = 0;
      CasRoutedAccess.debugGatewayEnsurer = (_, _) async => gatewayCalls++;
      final adapter = MockHttpClientAdapter(
        handlers: {
          'GET $proxyPrefix/weixin/main.jsp': (_) async =>
              ResponseBody.fromString(_menuHtml, 200),
          'POST $proxyPrefix/spQuery': (options) async {
            final method = options.data is Map ? options.data['method'] : null;
            return ResponseBody.fromString(
              method == 'healthscore' ? _currentHtml : _yearListHtml,
              200,
            );
          },
          'GET $proxyPrefix/spQuery': (_) async =>
              ResponseBody.fromString(_detailHtml, 200),
        },
      );
      final service = PhysicalTestService.instance
        ..debugSetDio(_dioWith(adapter));

      final snapshot = await service.fetchSnapshot();

      expect(snapshot.records, hasLength(2));
      expect(gatewayCalls, 1);
      expect(ZhengfangAuth.instance.mode, before);
      expect(adapter.requestLog, everyElement(contains(proxyPrefix)));
    });

    test('WebVPN 下 bounce 有界重试一次：恢复时再建一次网关，仍 bounce 则过期', () async {
      forceWebVpn();
      var gatewayCalls = 0;
      CasRoutedAccess.debugGatewayEnsurer = (_, _) async => gatewayCalls++;
      var menuRequests = 0;
      final adapter = MockHttpClientAdapter(
        handlers: {
          'GET $proxyPrefix/weixin/main.jsp': (_) async {
            menuRequests++;
            return ResponseBody.fromString(_loginHtml, 200);
          },
        },
      );
      final service = PhysicalTestService.instance
        ..debugSetDio(_dioWith(adapter));

      await expectLater(
        service.fetchSnapshot(),
        throwsA(isA<CasAuthExpiredException>()),
      );
      expect(menuRequests, 2);
      expect(gatewayCalls, 2);
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
    });

    test('网关明确过期抛 CasAuthExpiredException 且不发业务请求', () async {
      forceWebVpn();
      CasRoutedAccess.debugGatewayEnsurer = (_, _) async =>
          throw const CasAuthExpiredException();
      final adapter = MockHttpClientAdapter();
      final service = PhysicalTestService.instance
        ..debugSetDio(_dioWith(adapter));

      await expectLater(
        service.fetchSnapshot(),
        throwsA(isA<CasAuthExpiredException>()),
      );
      expect(adapter.requestLog, isEmpty);
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
    });
  });

  test('WebVPN 模式按 host 映射重建代理资源 URL', () {
    const proxyPrefix =
        'https://webvpn.zjxu.edu.cn/http/'
        '77726476706e69737468656265737421fafc4b85692a62486b468ca88d1b203b';

    expect(
      PhysicalTestService.buildResourceUrl(
        '/weixin/main.jsp',
        ZhengfangMode.direct,
      ),
      'http://jkjy.zjxu.edu.cn/weixin/main.jsp',
    );
    expect(
      PhysicalTestService.buildResourceUrl(
        '/weixin/main.jsp',
        ZhengfangMode.webVpn,
      ),
      '$proxyPrefix/weixin/main.jsp',
    );
    expect(
      PhysicalTestService.buildResourceUrl(
        '/spQuery?method=scoreTotal',
        ZhengfangMode.webVpn,
      ),
      '$proxyPrefix/spQuery?method=scoreTotal',
    );
  });

  test('jkjy host 映射生成抓包路径', () {
    expect(
      ZhengfangAuth.instance.buildWebVpnProxyUrl(
        'http://jkjy.zjxu.edu.cn/weixin/main.jsp',
      ),
      'https://webvpn.zjxu.edu.cn/http/'
      '77726476706e69737468656265737421fafc4b85692a62486b468ca88d1b203b'
      '/weixin/main.jsp',
    );
  });
}
