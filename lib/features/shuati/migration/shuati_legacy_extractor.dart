/// 旧版 WebView 数据提取器。
///
/// 抽象 [ShuatiLegacyExtractor] 便于测试注入伪造数据；
/// [ShuatiLegacyHeadlessExtractor] 用不可见的 `HeadlessInAppWebView` 加载
/// 与 [ShuatiAssetService] 同源（`https://shuati.local.app/shuatipwa/`）的页面，
/// 在该 origin 下执行 JS 读取 IndexedDB `ShuaTiDB` 与 localStorage。
///
/// 安全：JS 侧先用 `indexedDB.databases()` 探测库是否存在，不存在直接返回空；
/// `open` 不带版本号，一旦意外触发 upgrade（老设备无 `databases()` 且库不存在）
/// 立即 abort 事务，**不会创建空库、不会改写任何旧数据**。全程只读。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../shuati_asset_service.dart';
import 'legacy_payload.dart';

/// 从旧 WebView 存储提取原始数据。
abstract class ShuatiLegacyExtractor {
  /// 读取旧数据；提取通道本身失败（WebView 不可用 / JS 抛错 / 超时）时抛异常。
  /// 旧库不存在 / 无数据时返回**空的** [ShuatiLegacyExtraction]，不抛。
  Future<ShuatiLegacyExtraction> extract();
}

/// 在旧 PWA 页面里执行的导出脚本主体（`callAsyncJavaScript` 的 functionBody，
/// 返回值即 `Promise` 的 resolve 值）。
const String kLegacyExtractionScript = r'''
const DB_NAME = 'ShuaTiDB';
const PROGRESS_PREFIX = 'practice-progress-';

function dumpLocalStorage() {
  const out = {};
  try {
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i);
      if (key && key.indexOf(PROGRESS_PREFIX) === 0) {
        const value = localStorage.getItem(key);
        if (typeof value === 'string') out[key] = value;
      }
    }
  } catch (e) { /* 忽略：隐私模式等场景 localStorage 不可读 */ }
  return out;
}

function openExisting(name) {
  return new Promise((resolve) => {
    let req;
    try {
      req = indexedDB.open(name);
    } catch (e) { resolve(null); return; }
    req.onupgradeneeded = () => {
      // 库不存在时 open（无版本号）会试图创建：绝不写旧设备，直接中止。
      try { req.transaction.abort(); } catch (e) { /* ignore */ }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => resolve(null);
    req.onblocked = () => resolve(null);
  });
}

function getAllRows(db, storeName) {
  return new Promise((resolve) => {
    try {
      const tx = db.transaction(storeName, 'readonly');
      const req = tx.objectStore(storeName).getAll();
      req.onsuccess = () => resolve(req.result || []);
      req.onerror = () => resolve([]);
    } catch (e) { resolve([]); }
  });
}

async function dump() {
  const progress = dumpLocalStorage();
  const empty = {
    databaseVersion: null, storeNames: [], stores: {}, progress: progress,
  };
  if (typeof indexedDB === 'undefined') return empty;
  // 探测库是否存在，避免为从未用过旧版的设备创建空库。
  let exists = null;
  try {
    if (indexedDB.databases) {
      const dbs = await indexedDB.databases();
      exists = dbs.some((d) => d.name === DB_NAME);
    }
  } catch (e) { exists = null; }
  if (exists === false) return empty;
  const db = await openExisting(DB_NAME);
  if (!db) return empty;
  try {
    const storeNames = Array.prototype.slice.call(db.objectStoreNames);
    const stores = {};
    for (const name of storeNames) {
      stores[name] = await getAllRows(db, name);
    }
    return {
      databaseVersion: db.version,
      storeNames: storeNames,
      stores: stores,
      progress: progress,
    };
  } finally {
    try { db.close(); } catch (e) { /* ignore */ }
  }
}

return await dump();
''';

/// 用 headless WebView 读取真实旧数据。仅在能创建平台 WebView 的环境可用
/// （Android / iOS 真机与模拟器）；桌面 / 单元测试环境会抛异常（调用方按失败处理）。
class ShuatiLegacyHeadlessExtractor implements ShuatiLegacyExtractor {
  ShuatiLegacyHeadlessExtractor({
    ShuatiAssetService? assetService,
    this.loadTimeout = const Duration(seconds: 20),
  }) : _assetService = assetService ?? ShuatiAssetService();

  final ShuatiAssetService _assetService;

  /// 页面加载 + JS 执行的总超时（超时按提取失败处理，可重试）。
  final Duration loadTimeout;

  @override
  Future<ShuatiLegacyExtraction> extract() async {
    final loadDone = Completer<void>();
    InAppWebViewController? controller;
    final headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: ShuatiAssetService.initialWebUri),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        useShouldInterceptRequest: true,
      ),
      onWebViewCreated: (c) => controller = c,
      onLoadStop: (c, url) {
        if (!loadDone.isCompleted) loadDone.complete();
      },
      onReceivedError: (c, request, error) {
        if (request.isForMainFrame == false) return;
        if (!loadDone.isCompleted) {
          loadDone.completeError(StateError('旧版页面加载失败：${error.description}'));
        }
      },
      shouldInterceptRequest: (c, request) =>
          _assetService.responseForRequest(request),
    );

    Object? payload;
    try {
      await headless.run();
      await loadDone.future.timeout(loadTimeout);
      final c = controller;
      if (c == null) {
        throw StateError('旧版页面控制器不可用');
      }
      final result = await c
          .callAsyncJavaScript(functionBody: kLegacyExtractionScript)
          .timeout(loadTimeout);
      payload = result?.value;
    } finally {
      try {
        await headless.dispose();
      } catch (_) {
        // 平台未实现 / 已销毁：忽略，不影响失败路径。
      }
    }

    // Android WebView 桥返回值已是对象；部分平台 / 版本可能回传 JSON 字符串。
    if (payload is String) {
      payload = jsonDecode(payload);
    }
    final extraction = ShuatiLegacyExtraction.tryFromJson(payload);
    if (extraction == null) {
      throw StateError('旧版数据导出脚本返回了无法识别的结构');
    }
    return extraction;
  }
}
