import 'dart:io' show Directory, HttpHeaders, Platform;

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/isolated_auth_session.dart';
import 'package:jxu_campus_hub/core/network/cookie_interceptor.dart';

import '../../helpers/mock_http_client_adapter.dart';

void main() {
  final login = Uri.parse('https://jwzx.zjxu.edu.cn/jwglxt/login');
  final menu = login.resolve('/jwglxt/xtgl/index_initMenu.html');
  final captcha = login.resolve('/jwglxt/xtgl/kaptcha');
  late MockHttpClientAdapter adapter;
  late Dio template;

  setUp(() {
    adapter = MockHttpClientAdapter();
    template = Dio()..httpClientAdapter = adapter;
    addTearDown(template.close);
  });

  Future<IsolatedAuthSession> create(CookieJar source) =>
      IsolatedAuthSession.create(
        sourceJar: source,
        seedUris: [login, menu, captcha],
        template: template,
      );

  Future<void> send(IsolatedAuthSession session, Uri uri) => session.send<void>(
    label: 'test',
    request: (dio, token) => dio.getUri<void>(
      uri,
      cancelToken: token,
      options: Options(
        followRedirects: false,
        validateStatus: (status) => status != null && status < 400,
      ),
    ),
  );

  test('无 Path Cookie 只使用原始存储路径，seed 与提交均不复制', () async {
    final jar = CookieJar();
    await jar.saveFromResponse(login, [Cookie('seed', 'original')]);
    adapter.registerText(
      'GET',
      login.path,
      '',
      headers: {
        'set-cookie': ['route=nodeA'],
      },
    );
    final sent = <String?>[];
    adapter.register('GET', menu.path, (options) async {
      sent.add(options.headers[HttpHeaders.cookieHeader] as String?);
      return ResponseBody.fromString('', 200);
    });
    final session = await create(jar);
    await send(session, menu);
    await send(session, login);
    await send(session, menu);
    await session.commitTo(jar);

    final shared = template..interceptors.add(buildCookieInterceptor(jar));
    await shared.getUri<void>(menu);
    expect(sent.first, 'seed=original');
    for (final header in sent.skip(1)) {
      expect(
        header?.split('; '),
        unorderedEquals(['seed=original', 'route=nodeA']),
      );
    }
    expect(await jar.loadForRequest(login.resolve('/outside')), isEmpty);
  });

  test('从冷加载持久 jar 快照并向冷加载目标回放 Cookie 删除', () async {
    final temp = await Directory.systemTemp.createTemp('isolated_cookie_test_');
    addTearDown(() => temp.delete(recursive: true));
    PersistCookieJar openJar() => PersistCookieJar(
      storage: FileStorage('${temp.path}${Platform.pathSeparator}'),
    );
    await openJar().saveFromResponse(login, [
      Cookie('route', 'old'),
      Cookie('legacy', 'old')..path = '/jwglxt',
      Cookie('keep', 'valid')..path = '/',
    ]);
    final sent = <String?>[];
    adapter.register('GET', login.path, (options) async {
      sent.add(options.headers[HttpHeaders.cookieHeader] as String?);
      return ResponseBody.fromString(
        '',
        200,
        headers: {
          'set-cookie': [
            'route=gone; Max-Age=0',
            'legacy=gone; Path=/jwglxt; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
          ],
        },
      );
    });
    final coldSeed = await create(openJar());
    await send(coldSeed, login);
    expect(
      sent.single?.split('; '),
      unorderedEquals(['route=old', 'legacy=old', 'keep=valid']),
    );

    final session = await create(CookieJar());
    await send(session, login);
    final target = openJar();
    await session.commitTo(target);

    for (final jar in [target, openJar()]) {
      expect((await jar.loadForRequest(menu)).map((cookie) => cookie.name), [
        'keep',
      ]);
    }
  });

  test('共享请求仅发新 JSESSIONID，长 Path 的旧值被清理', () async {
    final jar = CookieJar();
    await jar.saveFromResponse(login, [
      Cookie('JSESSIONID', 'OLD')..path = '/jwglxt/',
    ]);
    adapter.registerText(
      'GET',
      login.path,
      '',
      headers: {
        'set-cookie': ['JSESSIONID=NEW; Path=/jwglxt'],
      },
    );
    final sent = <String?>[];
    adapter.register('GET', menu.path, (options) async {
      sent.add(options.headers[HttpHeaders.cookieHeader] as String?);
      return ResponseBody.fromString('', 200);
    });
    final session = await create(jar);
    await send(session, login);
    await send(session, menu);
    await session.commitTo(jar);
    template.interceptors.add(buildCookieInterceptor(jar));
    await template.getUri<void>(menu);

    expect(sent, ['JSESSIONID=NEW', 'JSESSIONID=NEW']);
  });

  test('共享合并保留其它域与其它 WebVPN 路径的同名 Cookie', () async {
    final gateway = Uri.parse('https://webvpn.zjxu.edu.cn');
    final cas = Uri.parse('https://newca.zjxu.edu.cn/cas/login');
    final academic = gateway.resolve('/https/academic/jwglxt/login');
    final other = gateway.resolve('/https/other/account');
    final jar = CookieJar();
    await jar.saveFromResponse(cas, [
      Cookie('JSESSIONID', 'CAS')..path = '/cas',
    ]);
    await jar.saveFromResponse(gateway, [
      Cookie('JSESSIONID', 'OTHER')..path = '/https/other',
      Cookie('gateway', 'VPN')..path = '/',
      Cookie('JSESSIONID', 'OLD')
        ..domain = '.webvpn.zjxu.edu.cn'
        ..path = '/https/academic/jwglxt/',
    ]);
    adapter.registerText(
      'GET',
      academic.path,
      '',
      headers: {
        'set-cookie': [
          'JSESSIONID=NEW; Domain=webvpn.zjxu.edu.cn; Path=/https/academic/jwglxt',
        ],
      },
    );
    final session = await IsolatedAuthSession.create(
      sourceJar: jar,
      seedUris: [gateway, academic, other, cas],
      template: template,
    );
    await send(session, academic);
    await session.commitTo(jar);

    Future<List<String>> values(Uri uri) async =>
        (await jar.loadForRequest(uri))
            .where((cookie) => cookie.name == 'JSESSIONID')
            .map((cookie) => cookie.value)
            .toList();
    expect(await values(academic), ['NEW']);
    expect(await values(other), ['OTHER']);
    expect(await values(cas), ['CAS']);
    expect(
      (await jar.loadForRequest(gateway.resolve('/'))).single.value,
      'VPN',
    );
  });

  test('3xx 的无 Path Cookie 只写到响应来源，不复制给 Location', () async {
    final jar = CookieJar();
    final redirect = Uri.parse('https://newca.zjxu.edu.cn/cas/login');
    adapter.registerText(
      'GET',
      login.path,
      '',
      statusCode: 302,
      headers: {
        'location': [redirect.toString()],
        'set-cookie': ['route=nodeA'],
      },
    );
    final session = await create(jar);
    await send(session, login);
    await session.commitTo(jar);

    expect((await jar.loadForRequest(menu)).single.value, 'nodeA');
    expect(await jar.loadForRequest(redirect), isEmpty);
  });
}
