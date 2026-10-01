import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';

import '../../helpers/mock_http_client_adapter.dart';

/// `DioClient.reloadPersistedCookies()` / `reloadPersistedCookieJar` 的聚焦测试。
///
/// 用两个 [PersistCookieJar] 共享同一 [FileStorage] 目录模拟跨 isolate / 进程
/// 的 cookie 改动；不 mock `forceInit` 本体，只注入失败点（debug seam）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final probeUri = Uri.parse('https://jwzx.zjxu.edu.cn/jwglxt/probe');
  final unifiedProbeUri = Uri.parse('https://newca.zjxu.edu.cn/probe');

  PersistCookieJar jarAt(String dir) =>
      PersistCookieJar(storage: FileStorage(dir), persistSession: true);

  Future<void> writeHostCookie(
    PersistCookieJar jar,
    Uri uri,
    String name,
    String value,
  ) {
    return jar.saveFromResponse(uri, [Cookie(name, value)..path = '/']);
  }

  Future<void> writeDomainCookie(
    PersistCookieJar jar,
    Uri uri,
    String domain,
    String name,
    String value,
  ) {
    return jar.saveFromResponse(uri, [
      Cookie(name, value)
        ..domain = domain
        ..path = '/',
    ]);
  }

  Future<Set<String>> cookieNames(PersistCookieJar jar, Uri uri) async {
    final cookies = await jar.loadForRequest(uri);
    return cookies.map((c) => c.name).toSet();
  }

  group('reloadPersistedCookieJar (pure jar helper)', () {
    late Directory tempDir;
    late String cookieDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cookie_reload_jar_');
      cookieDir = '${tempDir.path}/.cookies/';
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('picks up host and domain cookies written by another jar', () async {
      final reader = jarAt(cookieDir);
      final writer = jarAt(cookieDir);

      // reader 先初始化（内存里是旧身份的空缓存）。
      expect(await cookieNames(reader, probeUri), isEmpty);

      await writeHostCookie(writer, probeUri, 'host_token', 'NEW_HOST');
      await writeDomainCookie(
        writer,
        probeUri,
        '.zjxu.edu.cn',
        'domain_token',
        'NEW_DOMAIN',
      );

      // reload 前 reader 仍看不到新值（内存 hostCookies 已缓存/无该 host）。
      expect(await cookieNames(reader, probeUri), isEmpty);

      await DioClient.reloadPersistedCookieJar(reader);

      expect(
        await cookieNames(reader, probeUri),
        containsAll(<String>['host_token', 'domain_token']),
      );
    });

    test(
      'does not resurrect host/domain cookies legally deleted by another jar',
      () async {
        final reader = jarAt(cookieDir);
        final writer = jarAt(cookieDir);

        await writeHostCookie(writer, probeUri, 'host_token', 'OLD_HOST');
        await writeDomainCookie(
          writer,
          probeUri,
          '.zjxu.edu.cn',
          'domain_token',
          'OLD_DOMAIN',
        );
        // reader 先把旧身份 cookie 载入内存。
        expect(
          await cookieNames(reader, probeUri),
          containsAll(<String>['host_token', 'domain_token']),
        );

        // 另一实例合法清空（删除 .index/.domains 与 host 文件）。
        await writer.deleteAll();

        await DioClient.reloadPersistedCookieJar(reader);

        // `.domains` 文件已不存在：必须清掉内存 domainCookies，不得复活旧身份。
        expect(await cookieNames(reader, probeUri), isEmpty);
      },
    );

    test('does not resurrect a host deleted via delete(uri)', () async {
      final reader = jarAt(cookieDir);
      final writer = jarAt(cookieDir);

      await writeHostCookie(writer, probeUri, 'host_token', 'OLD_HOST');
      expect(await cookieNames(reader, probeUri), contains('host_token'));

      await writer.delete(probeUri, true);

      await DioClient.reloadPersistedCookieJar(reader);

      expect(await cookieNames(reader, probeUri), isEmpty);
    });

    test('leaves disk cookie files intact', () async {
      final reader = jarAt(cookieDir);
      final writer = jarAt(cookieDir);
      await writeHostCookie(writer, probeUri, 'host_token', 'KEEP');

      Set<String> diskFiles() =>
          Directory(cookieDir)
              .listSync(recursive: true)
              .whereType<File>()
              .map((f) => f.path)
              .toSet();

      final before = diskFiles();
      expect(before, isNotEmpty);

      await DioClient.reloadPersistedCookieJar(reader);

      expect(diskFiles(), before);
      expect(await cookieNames(reader, probeUri), contains('host_token'));
    });

    test('is safe on a jar that was never initialized', () async {
      final writer = jarAt(cookieDir);
      await writeHostCookie(writer, probeUri, 'host_token', 'FRESH');

      final fresh = jarAt(cookieDir);

      await DioClient.reloadPersistedCookieJar(fresh);

      expect(await cookieNames(fresh, probeUri), contains('host_token'));
    });
  });

  group('DioClient.reloadPersistedCookies', () {
    late Directory baseDir;

    String dirFor(String folderName) => '${baseDir.path}/$folderName/';

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      NetworkSettings.instance.debugReset();
      DioClient.instance.debugReset();
      baseDir = await Directory.systemTemp.createTemp('dio_reload_');
      DioClient.instance.debugCookieDirectoryPathProvider = (
        folderName,
      ) async => dirFor(folderName);
    });

    tearDown(() async {
      DioClient.instance.debugReset();
      NetworkSettings.instance.debugReset();
      if (baseDir.existsSync()) await baseDir.delete(recursive: true);
    });

    test(
      'reloads both jars in place; the existing Dio still reads new cookies',
      () async {
        await DioClient.instance.ensureInitialized();
        final zhengfangJar = DioClient.instance.zhengfangCookieJar;
        final unifiedJar = DioClient.instance.unifiedAuthCookieJar;
        final dio = DioClient.instance.dio;
        final interceptorCount = dio.interceptors.length;

        // 先让两个 jar 初始化内存（旧身份状态，磁盘尚无 cookie）。
        expect(await cookieNames(zhengfangJar, probeUri), isEmpty);
        expect(await cookieNames(unifiedJar, unifiedProbeUri), isEmpty);

        // 外部实例向两个 cookie 目录写入新身份 cookie。
        await writeHostCookie(
          jarAt(dirFor('.cookies')),
          probeUri,
          'zf_token',
          'NEW_ZF',
        );
        await writeHostCookie(
          jarAt(dirFor('.cookies_unified_auth')),
          unifiedProbeUri,
          'uni_token',
          'NEW_UNI',
        );

        // reload 前内存里仍是旧状态。
        expect(await cookieNames(zhengfangJar, probeUri), isEmpty);

        await DioClient.instance.reloadPersistedCookies();

        // 对象身份保持：jar / Dio / interceptor 都不替换。
        expect(
          identical(zhengfangJar, DioClient.instance.zhengfangCookieJar),
          isTrue,
        );
        expect(
          identical(unifiedJar, DioClient.instance.unifiedAuthCookieJar),
          isTrue,
        );
        expect(identical(dio, DioClient.instance.dio), isTrue);
        expect(dio.interceptors.length, interceptorCount);
        expect(await cookieNames(zhengfangJar, probeUri), contains('zf_token'));
        expect(
          await cookieNames(unifiedJar, unifiedProbeUri),
          contains('uni_token'),
        );

        // 现有 Dio 的 CookieManager 拦截器仍读同一个 jar → 请求头带新 cookie。
        String? cookieHeader;
        final adapter = MockHttpClientAdapter();
        adapter.register('GET', '/jwglxt/probe', (options) async {
          for (final entry in options.headers.entries) {
            if (entry.key.toLowerCase() == 'cookie') {
              cookieHeader = entry.value?.toString();
            }
          }
          return ResponseBody.fromString(
            jsonEncode({'ok': true}),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['application/json'],
            },
          );
        });
        dio.httpClientAdapter = adapter;

        await dio.get<Map<String, dynamic>>(
          'https://jwzx.zjxu.edu.cn/jwglxt/probe',
        );

        expect(adapter.requestLog, ['GET /jwglxt/probe']);
        expect(cookieHeader, contains('zf_token=NEW_ZF'));
      },
    );

    test('initializes when called before ensureInitialized', () async {
      await DioClient.instance.reloadPersistedCookies();

      expect(() => DioClient.instance.zhengfangCookieJar, returnsNormally);
      expect(() => DioClient.instance.dio, returnsNormally);
    });

    test(
      'concurrent reloads share one pass; a failed reload can be retried',
      () async {
        await DioClient.instance.ensureInitialized();

        var hookCalls = 0;
        final gate = Completer<void>();
        DioClient.debugBeforeForceInit = (jar) async {
          hookCalls++;
          await gate.future;
        };

        // 同 isolate 并发两次：应合并为一轮（两个 jar 各一次 hook）。
        final first = DioClient.instance.reloadPersistedCookies();
        final second = DioClient.instance.reloadPersistedCookies();
        gate.complete();
        await Future.wait(<Future<void>>[first, second]);
        expect(hookCalls, 2);

        // 合并仅限在途：完成后再调一次会开新一轮。
        await DioClient.instance.reloadPersistedCookies();
        expect(hookCalls, 4);

        // 任一 jar 失败 → 向上抛出（不吞错假成功），且引用清理后可重试。
        DioClient.debugBeforeForceInit = (jar) async =>
            throw StateError('boom');
        await expectLater(
          DioClient.instance.reloadPersistedCookies(),
          throwsA(isA<StateError>()),
        );

        DioClient.debugBeforeForceInit = null;
        await DioClient.instance.reloadPersistedCookies();
        expect(DioClient.debugBeforeForceInit, isNull);
      },
    );
  });
}
