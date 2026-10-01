import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/notice/jwc_html_fetch.dart';

void main() {
  tearDown(() => CasAuthBroker.debugGetResourceOverride = null);

  void stub(Future<Response<List<int>>> Function(Duration? timeout) handler) {
    CasAuthBroker.debugGetResourceOverride = (
      url, {
      dio,
      needsLogin,
      cancelToken,
      timeout,
      deadline,
    }) => handler(timeout);
  }

  Response<List<int>> resp(List<int>? data) => Response(
    data: data,
    requestOptions: RequestOptions(path: 'https://jwc.zjxu.edu.cn/x'),
    statusCode: 200,
  );

  test('非空 body 宽松 UTF-8 解码，默认预算为 defaultResourceBudget', () async {
    Duration? seen;
    stub((timeout) async {
      seen = timeout;
      return resp(utf8.encode('<p>你好</p>'));
    });
    final result = await fetchJwcHtml(
      'https://jwc.zjxu.edu.cn/x',
      failureLabel: 'l',
    );
    expect(result, isA<JwcHtmlOk>());
    expect((result as JwcHtmlOk).html, '<p>你好</p>');
    expect(seen, CasAuthBroker.defaultResourceBudget);
  });

  test('空 body → unavailable', () async {
    stub((_) async => resp(null));
    expect(
      await fetchJwcHtml('https://jwc.zjxu.edu.cn/x', failureLabel: 'l'),
      isA<JwcHtmlUnavailable>(),
    );
    stub((_) async => resp(const []));
    expect(
      await fetchJwcHtml('https://jwc.zjxu.edu.cn/x', failureLabel: 'l'),
      isA<JwcHtmlUnavailable>(),
    );
  });

  test('CasAuthExpiredException → authRequired；其它异常 → unavailable', () async {
    stub((_) async => throw const CasAuthExpiredException());
    expect(
      await fetchJwcHtml('https://jwc.zjxu.edu.cn/x', failureLabel: 'l'),
      isA<JwcHtmlAuthRequired>(),
    );
    stub((_) async => throw StateError('net'));
    expect(
      await fetchJwcHtml('https://jwc.zjxu.edu.cn/x', failureLabel: 'l'),
      isA<JwcHtmlUnavailable>(),
    );
  });
}
