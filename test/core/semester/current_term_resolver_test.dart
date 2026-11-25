import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/semester/current_term_resolver.dart';
import 'package:jxu_campus_hub/core/semester/schedule_term_context.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const storageKey = 'zjxu_current_term_context_v1';
  const termEndpoint = '/jwglxt/kbcx/xskbcx_cxXskbcxIndex.html';
  const htmlHeaders = <String, List<String>>{
    Headers.contentTypeHeader: ['text/html;charset=UTF-8'],
  };

  const termContextA = ScheduleTermContext(academicYear: 2026, term: 3);
  const termContextB = ScheduleTermContext(academicYear: 2025, term: 12);
  const termHtmlA = '''
<select id="xnm"><option value="2026" selected="selected">2026</option></select>
<select id="xqm"><option value="3" selected="selected">第1学期</option></select>
''';
  const termHtmlB = '''
<select id="xnm"><option value="2025" selected="selected">2025</option></select>
<select id="xqm"><option value="12" selected="selected">第2学期</option></select>
''';
  const loginHtml = '''
<html><body><form action="/jwglxt/xtgl/login_slogin.html">
<input id="yhm" name="yhm"/><input id="mm" name="mm"/>
<input id="yzm" name="yzm"/><button id="dl">登录</button>
</form></body></html>
''';
  const maintenanceHtml = '<html><body>系统维护中</body></html>';

  group('CurrentTermResolver.parseCurrentTermFromIndexHtml', () {
    test('parses selected options from standard zfsoft markup', () {
      const html = '''
<html><body>
<select id="xnm" name="xnm" class="form-control" width="120px">
  <option value="2024">2024</option>
  <option value="2025">2025</option>
  <option value="2026" selected="selected">2026</option>
</select>
<select id="xqm" name="xqm" class="form-control" width="120px">
  <option value="3" selected="selected">第1学期</option>
  <option value="12">第2学期</option>
</select>
</body></html>
''';

      final context = CurrentTermResolver.parseCurrentTermFromIndexHtml(html);
      expect(context, const ScheduleTermContext(academicYear: 2026, term: 3));
    });

    test('parses unquoted selected attribute placed before value', () {
      const html = '''
<select id="xnm">
  <option selected value='2025'>2025</option>
</select>
<select id="xqm">
  <option selected value='12'>第2学期</option>
</select>
''';

      final context = CurrentTermResolver.parseCurrentTermFromIndexHtml(html);
      expect(context, const ScheduleTermContext(academicYear: 2025, term: 12));
    });

    test(
      'falls back to jQuery val() assignment when options miss selected',
      () {
        const html = '''
<select id="xnm">
  <option value="2025">2025</option>
</select>
<select id="xqm">
  <option value="3">第1学期</option>
</select>
<script>
jQuery("#xnm").val("2025");
jQuery("#xqm").val("12");
</script>
''';

        final context = CurrentTermResolver.parseCurrentTermFromIndexHtml(html);
        expect(
          context,
          const ScheduleTermContext(academicYear: 2025, term: 12),
        );
      },
    );

    test('does not confuse xnm with ids like xnm2', () {
      const html = '''
<select id="xnm2" name="xnm2">
  <option value="9999" selected="selected">9999</option>
</select>
<select id="xnm">
  <option value="2026" selected="selected">2026</option>
</select>
<select id="xqm">
  <option value="3" selected="selected">第1学期</option>
</select>
''';

      final context = CurrentTermResolver.parseCurrentTermFromIndexHtml(html);
      expect(context, const ScheduleTermContext(academicYear: 2026, term: 3));
    });

    test('returns null when selects are missing', () {
      expect(
        CurrentTermResolver.parseCurrentTermFromIndexHtml('<p>登录</p>'),
        isNull,
      );
      expect(CurrentTermResolver.parseCurrentTermFromIndexHtml(''), isNull);
    });

    test('returns null on out-of-range year or unknown term code', () {
      const badYear = '''
<select id="xnm"><option value="1899" selected="selected">1899</option></select>
<select id="xqm"><option value="3" selected="selected">第1学期</option></select>
''';
      const badTerm = '''
<select id="xnm"><option value="2026" selected="selected">2026</option></select>
<select id="xqm"><option value="16" selected="selected">第3学期</option></select>
''';

      expect(
        CurrentTermResolver.parseCurrentTermFromIndexHtml(badYear),
        isNull,
      );
      expect(
        CurrentTermResolver.parseCurrentTermFromIndexHtml(badTerm),
        isNull,
      );
    });
  });

  group('CurrentTermResolver cache', () {
    setUp(() async {
      const pathProviderChannel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
        if (call.method == 'getApplicationDocumentsDirectory' ||
            call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.path;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(pathProviderChannel, null),
      );

      await resetTestEnvironment();
      ConnectModeResolver.instance.directReachabilityChecker = () async => true;
      DioClient.instance.debugCookieDirectoryPathProvider = (
        folderName,
      ) async => 'test/$folderName';
      await DioClient.instance.ensureInitialized();
      await CurrentTermResolver.instance.debugReset();
    });

    void login(String account) {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: account);
    }

    void logout() {
      ZhengfangAuth.instance.debugSetSession(active: false, studentId: null);
    }

    void useAdapter(MockHttpClientAdapter adapter) {
      DioClient.instance.dio.httpClientAdapter = adapter;
    }

    MockHttpClientAdapter adapterReturning(
      String html, {
      int statusCode = 200,
    }) {
      return MockHttpClientAdapter()..registerText(
        'GET',
        termEndpoint,
        html,
        statusCode: statusCode,
        headers: htmlHeaders,
      );
    }

    Future<Map<String, dynamic>?> readEnvelope() async {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    }

    Future<void> seedEnvelope({
      required String owner,
      required ScheduleTermContext context,
      required DateTime resolvedAt,
    }) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        storageKey,
        jsonEncode({
          ...context.toJson(),
          'resolvedAt': resolvedAt.millisecondsSinceEpoch,
          'owner': owner,
        }),
      );
    }

    test(
      'resolve returns null without login instead of hitting network',
      () async {
        final adapter = MockHttpClientAdapter();
        useAdapter(adapter);

        final context = await CurrentTermResolver.instance.resolve();

        expect(context, isNull);
        expect(adapter.requestLog, isEmpty);
      },
    );

    test('resolveWithStatus reports no auth expiry without login', () async {
      final adapter = MockHttpClientAdapter();
      useAdapter(adapter);

      final resolution = await CurrentTermResolver.instance.resolveWithStatus();

      expect(resolution.context, isNull);
      expect(resolution.authExpired, isFalse);
      expect(adapter.requestLog, isEmpty);
    });

    test(
      'resolve keeps legacy signature and serves from owner cache',
      () async {
        login('A');
        final adapter = adapterReturning(termHtmlA);
        useAdapter(adapter);

        expect(
          await CurrentTermResolver.instance.resolve(studentId: 'A'),
          termContextA,
        );
        expect(
          await CurrentTermResolver.instance.resolve(studentId: 'A'),
          termContextA,
        );

        expect(adapter.requestLog, ['GET $termEndpoint']);
        expect(CurrentTermResolver.instance.knownCurrentTerm, termContextA);
      },
    );

    test(
      'rejects explicit studentId that differs from logged-in account',
      () async {
        login('A');
        final adapter = adapterReturning(termHtmlA);
        useAdapter(adapter);

        final resolution = await CurrentTermResolver.instance.resolveWithStatus(
          studentId: 'B',
        );

        expect(resolution.context, isNull);
        expect(resolution.authExpired, isFalse);
        expect(adapter.requestLog, isEmpty);
        expect(
          await CurrentTermResolver.instance.resolve(studentId: 'B'),
          isNull,
        );
      },
    );

    test('901 response reports authExpired and stores nothing', () async {
      login('A');
      final adapter = adapterReturning('', statusCode: 901);
      useAdapter(adapter);

      final resolution = await CurrentTermResolver.instance.resolveWithStatus(
        studentId: 'A',
      );

      expect(resolution.context, isNull);
      expect(resolution.authExpired, isTrue);
      expect(CurrentTermResolver.instance.knownCurrentTerm, isNull);
      expect(await readEnvelope(), isNull);
    });

    test('200 zhengfang login page reports authExpired', () async {
      login('A');
      final adapter = adapterReturning(loginHtml);
      useAdapter(adapter);

      final resolution = await CurrentTermResolver.instance.resolveWithStatus(
        studentId: 'A',
      );

      expect(resolution.context, isNull);
      expect(resolution.authExpired, isTrue);
      expect(await readEnvelope(), isNull);
    });

    test('non-auth http status is not reported as auth expiry', () async {
      login('A');
      final adapter = adapterReturning('server error', statusCode: 500);
      useAdapter(adapter);

      final resolution = await CurrentTermResolver.instance.resolveWithStatus(
        studentId: 'A',
      );

      expect(resolution.context, isNull);
      expect(resolution.authExpired, isFalse);
    });

    test('network failure is not reported as auth expiry', () async {
      login('A');
      final adapter = MockHttpClientAdapter()
        ..register('GET', termEndpoint, (options) async {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          );
        });
      useAdapter(adapter);

      final resolution = await CurrentTermResolver.instance.resolveWithStatus(
        studentId: 'A',
      );

      expect(resolution.context, isNull);
      expect(resolution.authExpired, isFalse);
      expect(adapter.requestLog, ['GET $termEndpoint']);
    });

    test('structural page change is not reported as auth expiry', () async {
      login('A');
      final adapter = adapterReturning(maintenanceHtml);
      useAdapter(adapter);

      final resolution = await CurrentTermResolver.instance.resolveWithStatus(
        studentId: 'A',
      );

      expect(resolution.context, isNull);
      expect(resolution.authExpired, isFalse);
    });

    test('persisted envelope is served only to its owner', () async {
      await seedEnvelope(
        owner: 'A',
        context: termContextA,
        resolvedAt: DateTime.now(),
      );
      login('A');
      final adapter = MockHttpClientAdapter();
      useAdapter(adapter);

      final resolution = await CurrentTermResolver.instance.resolveWithStatus(
        studentId: 'A',
      );

      expect(resolution.context, termContextA);
      expect(resolution.authExpired, isFalse);
      expect(adapter.requestLog, isEmpty);
    });

    test('persisted envelope of another owner is never reused', () async {
      await seedEnvelope(
        owner: 'A',
        context: termContextA,
        resolvedAt: DateTime.now(),
      );
      login('B');
      final adapter = adapterReturning(termHtmlB);
      useAdapter(adapter);

      final resolution = await CurrentTermResolver.instance.resolveWithStatus(
        studentId: 'B',
      );

      expect(resolution.context, termContextB);
      expect(adapter.requestLog, ['GET $termEndpoint']);
      final envelope = await readEnvelope();
      expect(envelope?['owner'], 'B');
      expect(envelope?['academicYear'], 2025);
      expect(envelope?['term'], 12);
    });

    test(
      'legacy envelope without owner is invalidated and refetched',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          storageKey,
          jsonEncode({
            ...termContextA.toJson(),
            'resolvedAt': DateTime.now().millisecondsSinceEpoch,
          }),
        );
        login('A');
        final adapter = adapterReturning(termHtmlA);
        useAdapter(adapter);

        final resolution = await CurrentTermResolver.instance.resolveWithStatus(
          studentId: 'A',
        );

        expect(resolution.context, termContextA);
        expect(adapter.requestLog, ['GET $termEndpoint']);
        expect((await readEnvelope())?['owner'], 'A');
      },
    );

    test('expired persisted envelope triggers a refetch', () async {
      await seedEnvelope(
        owner: 'A',
        context: termContextB,
        resolvedAt: DateTime.now().subtract(const Duration(hours: 13)),
      );
      login('A');
      final adapter = adapterReturning(termHtmlA);
      useAdapter(adapter);

      final resolution = await CurrentTermResolver.instance.resolveWithStatus(
        studentId: 'A',
      );

      expect(resolution.context, termContextA);
      expect(adapter.requestLog, ['GET $termEndpoint']);
      final envelope = await readEnvelope();
      expect(envelope?['owner'], 'A');
      expect(envelope?['academicYear'], 2026);
      expect(envelope?['term'], 3);
    });

    test('logout hides the previous owner term and requests nothing', () async {
      login('A');
      final adapter = adapterReturning(termHtmlA);
      useAdapter(adapter);
      expect(
        await CurrentTermResolver.instance.resolve(studentId: 'A'),
        termContextA,
      );
      expect(CurrentTermResolver.instance.knownCurrentTerm, termContextA);

      logout();

      expect(CurrentTermResolver.instance.knownCurrentTerm, isNull);
      expect(await CurrentTermResolver.instance.resolve(), isNull);
      final resolution = await CurrentTermResolver.instance.resolveWithStatus(
        studentId: 'A',
      );
      expect(resolution.context, isNull);
      expect(resolution.authExpired, isFalse);
      expect(adapter.requestLog, ['GET $termEndpoint']);
    });

    test('same owner relogin may reuse the fresh persisted envelope', () async {
      login('A');
      final adapter = adapterReturning(termHtmlA);
      useAdapter(adapter);
      expect(
        await CurrentTermResolver.instance.resolve(studentId: 'A'),
        termContextA,
      );

      logout();
      login('A');

      final resolution = await CurrentTermResolver.instance.resolveWithStatus(
        studentId: 'A',
      );
      expect(resolution.context, termContextA);
      expect(adapter.requestLog, ['GET $termEndpoint']);
    });

    test(
      'late response after account switch is dropped and not persisted',
      () async {
        login('A');
        final pendingA = Completer<ResponseBody>();
        final adapter = MockHttpClientAdapter()
          ..register('GET', termEndpoint, (options) {
            if (options.queryParameters['su'] == 'A') return pendingA.future;
            return Future<ResponseBody>.value(
              ResponseBody.fromString(termHtmlB, 200, headers: htmlHeaders),
            );
          });
        useAdapter(adapter);

        final futureA = CurrentTermResolver.instance.resolveWithStatus(
          studentId: 'A',
        );
        await _waitFor(() => adapter.requestLog.length == 1);

        login('B');
        final resultB = await CurrentTermResolver.instance.resolveWithStatus(
          studentId: 'B',
        );
        expect(resultB.context, termContextB);

        pendingA.complete(
          ResponseBody.fromString(termHtmlA, 200, headers: htmlHeaders),
        );
        final resultA = await futureA;

        expect(resultA.context, isNull);
        expect(resultA.authExpired, isFalse);
        expect(CurrentTermResolver.instance.knownCurrentTerm, termContextB);
        final envelope = await readEnvelope();
        expect(envelope?['owner'], 'B');
        expect(envelope?['academicYear'], 2025);
        expect(envelope?['term'], 12);
        expect(adapter.requestLog, ['GET $termEndpoint', 'GET $termEndpoint']);
      },
    );

    test('concurrent calls for the same account share one request', () async {
      login('A');
      final pending = Completer<ResponseBody>();
      final adapter = MockHttpClientAdapter()
        ..register('GET', termEndpoint, (_) => pending.future);
      useAdapter(adapter);

      final first = CurrentTermResolver.instance.resolveWithStatus(
        studentId: 'A',
      );
      final second = CurrentTermResolver.instance.resolveWithStatus(
        studentId: 'A',
      );
      await _waitFor(() => adapter.requestLog.length == 1);

      pending.complete(
        ResponseBody.fromString(termHtmlA, 200, headers: htmlHeaders),
      );

      expect((await first).context, termContextA);
      expect((await second).context, termContextA);
      expect(adapter.requestLog, ['GET $termEndpoint']);
    });

    test('forceRefresh bypasses the owner cache and refetches', () async {
      login('A');
      final adapter = adapterReturning(termHtmlA);
      useAdapter(adapter);

      expect(
        await CurrentTermResolver.instance.resolve(studentId: 'A'),
        termContextA,
      );
      final refreshed = await CurrentTermResolver.instance.resolveWithStatus(
        studentId: 'A',
        forceRefresh: true,
      );

      expect(refreshed.context, termContextA);
      expect(adapter.requestLog, ['GET $termEndpoint', 'GET $termEndpoint']);
    });

    test('debugReset clears memory and persisted state', () async {
      login('A');
      useAdapter(adapterReturning(termHtmlA));
      await CurrentTermResolver.instance.resolve(studentId: 'A');

      await CurrentTermResolver.instance.debugReset();

      expect(CurrentTermResolver.instance.knownCurrentTerm, isNull);
      expect(await readEnvelope(), isNull);
    });
  });
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue, reason: 'condition not met in time');
}
