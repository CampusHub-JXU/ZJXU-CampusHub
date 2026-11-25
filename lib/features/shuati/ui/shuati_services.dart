/// 原生刷题助手（第二阶段骨架）的依赖入口：单例 [ShuatiStore] 与文件 I/O。
///
/// 页面通过 [ShuatiServices.instance] 取库与文件能力；测试用
/// [ShuatiServices.debugUse] 注入内存库与假的文件 I/O。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../ai/shuati_ai_runner.dart';
import '../ai/shuati_ai_service.dart';
import '../migration/shuati_legacy_extractor.dart';
import '../migration/shuati_legacy_migration_service.dart';
import '../persistence/activity_repositories.dart';
import '../persistence/shuati_store.dart';

/// 用户选中的文件。
class PickedShuatiFile {
  const PickedShuatiFile(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

/// 文件选择 / 保存 / 分享的可注入点。
abstract class ShuatiFileIo {
  /// 选择一个文件；用户取消返回 `null`。
  Future<PickedShuatiFile?> pickFile({required List<String> extensions});

  /// 保存字节到用户选择的位置；返回保存路径，取消返回 `null`。
  Future<String?> saveFile(String fileName, Uint8List bytes);

  /// 通过系统分享菜单分享一个文件。
  Future<void> shareFile(String fileName, Uint8List bytes);
}

class DefaultShuatiFileIo implements ShuatiFileIo {
  const DefaultShuatiFileIo();

  @override
  Future<PickedShuatiFile?> pickFile({required List<String> extensions}) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: true,
      type: FileType.custom,
      allowedExtensions: extensions,
    );
    final file = result?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return null;
    return PickedShuatiFile(file.name, bytes);
  }

  @override
  Future<String?> saveFile(String fileName, Uint8List bytes) {
    return FilePicker.platform.saveFile(
      dialogTitle: '保存刷题助手备份',
      fileName: fileName,
      bytes: bytes,
    );
  }

  @override
  Future<void> shareFile(String fileName, Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  }
}

class ShuatiServices {
  ShuatiServices._();

  static final ShuatiServices instance = ShuatiServices._();

  Future<ShuatiStore>? _store;

  ShuatiFileIo io = const DefaultShuatiFileIo();

  /// AI 服务的可注入点：默认走 `CoreAiShuatiRunner`（全局 AI 配置 →
  /// OpenAI 兼容端点）；测试注入假 runner / fake service。
  ShuatiAiService Function(AiExplanationRepository) aiServiceFactory = (
    explanations,
  ) => ShuatiAiService(explanations, CoreAiShuatiRunner());

  /// 创建 AI 服务（解析缓存写当前打开的库）。
  ShuatiAiService createAiService(ShuatiStore store) =>
      aiServiceFactory(store.aiExplanations);

  /// 旧版 WebView 数据迁移服务的可注入点：默认用 headless WebView 真读；
  /// 测试可注入假 extractor / prefs，或置 `null` 完全禁用自动迁移。
  ShuatiLegacyMigrationService? Function(ShuatiStore store)
  legacyMigrationFactory = (store) => ShuatiLegacyMigrationService(
    store: store,
    extractor: ShuatiLegacyHeadlessExtractor(),
  );

  /// 创建旧版迁移服务；`null` 表示迁移被禁用（测试默认）。
  ShuatiLegacyMigrationService? createLegacyMigration(ShuatiStore store) =>
      legacyMigrationFactory(store);

  /// 打开（或复用）默认数据库；打开失败时下次调用会重试。
  Future<ShuatiStore> store() => _store ??= _open();

  Future<ShuatiStore> _open() async {
    try {
      return (await ShuatiStore.openDefault()).$2;
    } catch (_) {
      _store = null;
      rethrow;
    }
  }

  @visibleForTesting
  void debugUse(
    ShuatiStore store, {
    ShuatiFileIo? io,
    ShuatiAiService Function(AiExplanationRepository)? aiServiceFactory,
    ShuatiLegacyMigrationService? Function(ShuatiStore store)?
    legacyMigrationFactory,
  }) {
    _store = Future<ShuatiStore>.value(store);
    if (io != null) this.io = io;
    if (aiServiceFactory != null) this.aiServiceFactory = aiServiceFactory;
    // 测试默认禁用自动迁移（widget 测试没有平台 WebView），显式注入才启用。
    this.legacyMigrationFactory = legacyMigrationFactory ?? (_) => null;
  }

  @visibleForTesting
  void debugReset() {
    _store = null;
    io = const DefaultShuatiFileIo();
    aiServiceFactory = (explanations) =>
        ShuatiAiService(explanations, CoreAiShuatiRunner());
    legacyMigrationFactory = (store) => ShuatiLegacyMigrationService(
      store: store,
      extractor: ShuatiLegacyHeadlessExtractor(),
    );
  }
}
