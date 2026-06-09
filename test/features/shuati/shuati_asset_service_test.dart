import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:jxu_campus_hub/features/shuati/shuati_asset_service.dart';

void main() {
  group('ShuatiAssetService', () {
    test('maps internal PWA URLs to bundled asset paths', () {
      expect(
        ShuatiAssetService.assetPathForUri(
          Uri.parse('https://shuati.local.app/shuatipwa/'),
        ),
        ShuatiAssetService.indexAssetPath,
      );
      expect(
        ShuatiAssetService.assetPathForUri(
          Uri.parse('https://shuati.local.app/shuatipwa/assets/index.js'),
        ),
        'assets/shuatipwa/assets/index.js',
      );
      expect(
        ShuatiAssetService.assetPathForUri(
          Uri.parse('https://shuati.local.app/shuatipwa/practice/session'),
          isMainFrame: true,
        ),
        ShuatiAssetService.indexAssetPath,
      );
    });

    test('rejects external or unsafe paths', () {
      expect(
        ShuatiAssetService.assetPathForUri(
          Uri.parse('https://example.com/shuatipwa/'),
        ),
        isNull,
      );
      expect(
        ShuatiAssetService.assetPathForUri(
          Uri.parse('https://shuati.local.app/shuatipwa/../secret.txt'),
        ),
        isNull,
      );
      expect(
        ShuatiAssetService.assetPathForUri(
          Uri.parse('https://shuati.local.app/other/index.html'),
        ),
        isNull,
      );
    });

    test('resolves common content types', () {
      expect(
        ShuatiAssetService.contentTypeForAsset('assets/shuatipwa/index.html'),
        'text/html',
      );
      expect(
        ShuatiAssetService.contentTypeForAsset('assets/shuatipwa/app.js'),
        'text/javascript',
      );
      expect(
        ShuatiAssetService.contentTypeForAsset(
          'assets/shuatipwa/manifest.webmanifest',
        ),
        'application/manifest+json',
      );
      expect(
        ShuatiAssetService.contentTypeForAsset('assets/shuatipwa/app.wasm'),
        'application/wasm',
      );
    });

    test('builds WebResourceResponse from asset bundle', () async {
      final service = ShuatiAssetService(
        assetBundle: _FakeAssetBundle({
          ShuatiAssetService.indexAssetPath: '<html></html>',
        }),
      );

      final response = await service.responseForRequest(
        WebResourceRequest(
          method: 'GET',
          isForMainFrame: true,
          url: WebUri(ShuatiAssetService.initialUrl),
        ),
      );

      expect(response, isNotNull);
      expect(response!.statusCode, 200);
      expect(response.contentType, 'text/html');
      expect(utf8.decode(response.data!), '<html></html>');
      expect(response.headers?['Cache-Control'], 'no-cache');
    });
  });
}

class _FakeAssetBundle extends CachingAssetBundle {
  _FakeAssetBundle(this.assets);

  final Map<String, String> assets;

  @override
  Future<ByteData> load(String key) async {
    final value = assets[key];
    if (value == null) {
      throw FlutterError('Missing asset: $key');
    }
    final bytes = Uint8List.fromList(utf8.encode(value));
    return ByteData.sublistView(bytes);
  }
}
