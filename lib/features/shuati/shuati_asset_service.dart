import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class ShuatiAssetService {
  ShuatiAssetService({AssetBundle? assetBundle})
    : _assetBundle = assetBundle ?? rootBundle;

  static const host = 'shuati.local.app';
  static const origin = 'https://$host';
  static const basePath = '/shuatipwa/';
  static const initialUrl = '$origin$basePath';
  static const assetRoot = 'assets/shuatipwa';
  static const indexAssetPath = '$assetRoot/index.html';

  static final initialWebUri = WebUri(initialUrl);

  final AssetBundle _assetBundle;

  Future<WebResourceResponse?> responseForRequest(
    WebResourceRequest request,
  ) async {
    final method = (request.method ?? 'GET').toUpperCase();
    if (method != 'GET' && method != 'HEAD') {
      return null;
    }

    final uri = request.url.uriValue;
    if (!isInternalUri(uri)) {
      return null;
    }

    final assetPath = assetPathForUri(uri, isMainFrame: request.isForMainFrame);
    if (assetPath == null) {
      return _notFoundResponse(uri.path);
    }

    try {
      return _okResponse(
        assetPath,
        bytes: await _loadBytes(assetPath, includeBody: method != 'HEAD'),
      );
    } on FlutterError {
      final fallbackPath =
          _shouldFallbackToIndex(uri, isMainFrame: request.isForMainFrame)
          ? indexAssetPath
          : null;
      if (fallbackPath == null || fallbackPath == assetPath) {
        return _notFoundResponse(uri.path);
      }
      try {
        return _okResponse(
          fallbackPath,
          bytes: await _loadBytes(fallbackPath, includeBody: method != 'HEAD'),
        );
      } on FlutterError {
        return _notFoundResponse(uri.path);
      }
    }
  }

  static bool isInternalUri(Uri uri) {
    return uri.scheme.toLowerCase() == 'https' &&
        uri.host.toLowerCase() == host;
  }

  static String? assetPathForUri(Uri uri, {bool? isMainFrame}) {
    if (!isInternalUri(uri)) return null;

    final path = uri.path;
    if (path == '/shuatipwa' || path == basePath) {
      return indexAssetPath;
    }
    if (!path.startsWith(basePath)) {
      return null;
    }

    final relativePath = path.substring(basePath.length);
    if (relativePath.isEmpty) {
      return indexAssetPath;
    }
    if (_hasUnsafePathSegment(relativePath)) {
      return null;
    }
    if (_shouldFallbackToIndex(uri, isMainFrame: isMainFrame)) {
      return indexAssetPath;
    }
    return '$assetRoot/$relativePath';
  }

  static String contentTypeForAsset(String assetPath) {
    final lowerPath = assetPath.toLowerCase();
    if (lowerPath.endsWith('.html') || lowerPath.endsWith('.htm')) {
      return 'text/html';
    }
    if (lowerPath.endsWith('.js') || lowerPath.endsWith('.mjs')) {
      return 'text/javascript';
    }
    if (lowerPath.endsWith('.css')) {
      return 'text/css';
    }
    if (lowerPath.endsWith('.svg')) {
      return 'image/svg+xml';
    }
    if (lowerPath.endsWith('.webmanifest')) {
      return 'application/manifest+json';
    }
    if (lowerPath.endsWith('.json') || lowerPath.endsWith('.map')) {
      return 'application/json';
    }
    if (lowerPath.endsWith('.wasm')) {
      return 'application/wasm';
    }
    if (lowerPath.endsWith('.png')) {
      return 'image/png';
    }
    if (lowerPath.endsWith('.jpg') || lowerPath.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lowerPath.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lowerPath.endsWith('.ico')) {
      return 'image/x-icon';
    }
    if (lowerPath.endsWith('.woff')) {
      return 'font/woff';
    }
    if (lowerPath.endsWith('.woff2')) {
      return 'font/woff2';
    }
    if (lowerPath.endsWith('.ttf')) {
      return 'font/ttf';
    }
    if (lowerPath.endsWith('.csv')) {
      return 'text/csv';
    }
    return 'application/octet-stream';
  }

  static bool isTextAsset(String assetPath) {
    final contentType = contentTypeForAsset(assetPath);
    return contentType.startsWith('text/') ||
        contentType == 'application/json' ||
        contentType == 'application/manifest+json';
  }

  Future<Uint8List> _loadBytes(
    String assetPath, {
    required bool includeBody,
  }) async {
    if (!includeBody) return Uint8List(0);
    final data = await _assetBundle.load(assetPath);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  WebResourceResponse _okResponse(
    String assetPath, {
    required Uint8List bytes,
  }) {
    final contentType = contentTypeForAsset(assetPath);
    return WebResourceResponse(
      contentType: contentType,
      contentEncoding: isTextAsset(assetPath) ? 'utf-8' : null,
      data: bytes,
      headers: _headersForAsset(assetPath, contentType),
      statusCode: 200,
      reasonPhrase: 'OK',
    );
  }

  WebResourceResponse _notFoundResponse(String path) {
    return WebResourceResponse(
      contentType: 'text/plain',
      contentEncoding: 'utf-8',
      data: Uint8List.fromList(utf8.encode('Not found: $path')),
      headers: const {
        'Cache-Control': 'no-store',
        'Access-Control-Allow-Origin': '*',
      },
      statusCode: 404,
      reasonPhrase: 'Not Found',
    );
  }

  Map<String, String> _headersForAsset(String assetPath, String contentType) {
    final headers = <String, String>{
      'Cache-Control': _cacheControlForAsset(assetPath),
      'Access-Control-Allow-Origin': '*',
      'Content-Type': isTextAsset(assetPath)
          ? '$contentType; charset=utf-8'
          : contentType,
    };
    if (assetPath.endsWith('/sw.js')) {
      headers['Service-Worker-Allowed'] = basePath;
    }
    return headers;
  }

  String _cacheControlForAsset(String assetPath) {
    if (assetPath == indexAssetPath ||
        assetPath.endsWith('/sw.js') ||
        assetPath.endsWith('.webmanifest')) {
      return 'no-cache';
    }
    return 'public, max-age=31536000, immutable';
  }

  static bool _shouldFallbackToIndex(Uri uri, {bool? isMainFrame}) {
    final path = uri.path;
    if (path == '/shuatipwa' || path == basePath) {
      return true;
    }
    if (!path.startsWith(basePath)) {
      return false;
    }

    final relativePath = path.substring(basePath.length);
    if (relativePath.isEmpty || path.endsWith('/')) {
      return true;
    }

    final fileName = relativePath.split('/').last;
    final hasExtension = fileName.contains('.');
    return isMainFrame != false && !hasExtension;
  }

  static bool _hasUnsafePathSegment(String relativePath) {
    return relativePath
        .replaceAll('\\', '/')
        .split('/')
        .any((segment) => segment == '..' || segment == '.');
  }
}
