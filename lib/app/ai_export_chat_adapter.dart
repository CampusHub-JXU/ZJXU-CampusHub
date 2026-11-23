import 'dart:async';

import 'package:flutter/widgets.dart';

import '../features/ai_export/ai_export_page.dart';
import '../features/ai_export/export_builder.dart';
import '../features/ai_export/export_controller.dart';
import '../features/ai_export/export_document.dart';
import '../features/ai_export/export_model.dart';
import '../shared/ai_chat/ai_chat_context.dart';

/// 组合层桥接：把「导出给 AI」的 [AiExportController] 适配成共享 AI 对话的
/// [AiChatContextProvider]，使 `shared/ai_chat` 与 `features/ai_chat` 都不
/// 依赖 `features/ai_export`。
class AiExportChatContextProvider extends ChangeNotifier
    implements AiChatContextProvider {
  AiExportChatContextProvider({
    /// 各模块取数来源的工厂（惰性调用，见 [AiExportController]）。
    List<ExportModuleSource> Function()? sources,
    ExportIdentityReader? identity,
    Listenable? identityChanges,
    DateTime Function()? clock,
    ExportEnvironment Function(DateTime now)? environment,
    ExportPreset initialPreset = ExportPreset.all,
    ExportLoginHandler? loginHandler,
  }) : _loginHandler = loginHandler ?? defaultExportLoginHandler {
    _controller = AiExportController(
      sources: sources?.call() ?? const [],
      identity: identity,
      identityChanges: identityChanges,
      clock: clock,
      environment: environment,
      initialPreset: initialPreset,
    );
    _controller.addListener(notifyListeners);
  }

  late final AiExportController _controller;
  final ExportLoginHandler _loginHandler;

  Future<void>? _initFuture;

  /// 测试 / 宿主访问底层导出控制器（页面层只经 [AiChatContextProvider] 契约）。
  AiExportController get exportController => _controller;

  @override
  List<AiChatContextModule> get modules => [
    for (final module in _controller.availableModules) _moduleOf(module),
  ];

  @override
  int get readyCount => _controller.selected
      .where((m) => _controller.slotOf(m).data?.status.hasData ?? false)
      .length;

  @override
  int get selectedCount => _controller.selected.length;

  @override
  bool get isBusy => _controller.availableModules.any(
    (m) => _controller.slotOf(m).phase == ExportSlotPhase.loading,
  );

  @override
  Future<void> initialize() => _initFuture ??= _controller.initialize();

  @override
  void toggleModule(String id, bool selected) {
    final module = _moduleById(id);
    if (module == null) return;
    final isSelected = _controller.selected.contains(module);
    if (isSelected == selected) return;
    _controller.toggleModule(module);
  }

  @override
  Future<void> ensureSelectedReady() async {
    await initialize();
    // 补齐已勾选但未就绪 / 已过期 / 部分结果 / 失败的模块；
    // 「需登录」不重复触发取数（取数只会再次得到需登录）。
    final targets = [
      for (final module in _controller.selected)
        switch (_controller.rowKindOf(module)) {
          ExportRowKind.missing || ExportRowKind.failed => module,
          ExportRowKind.ready =>
            (slotData(module)?.isPartial ?? false) ? module : null,
          ExportRowKind.loading || ExportRowKind.needsLogin => null,
        },
    ].whereType<ExportModule>();
    await Future.wait([for (final m in targets) _controller.fetch(m)]);
  }

  ExportModuleData? slotData(ExportModule module) =>
      _controller.slotOf(module).data;

  @override
  String buildContextText() {
    final doc = _controller.buildDocument();
    final ready = [
      for (final m in doc.modules)
        if (m.status.hasData) m,
    ];
    if (ready.isEmpty) return '';
    return ExportBuilder.plainText(
      AiExportDocument(
        exportedAt: doc.exportedAt,
        environment: doc.environment,
        modules: ready,
      ),
    );
  }

  @override
  Future<bool> requestLogin(BuildContext context, String moduleId) async {
    final module = _moduleById(moduleId);
    if (module == null) return false;
    final ok = await _loginHandler(context, module.domain);
    if (ok) unawaited(_controller.fetch(module));
    return ok;
  }

  @override
  bool get identityReset => _controller.identityReset;

  @override
  void acknowledgeIdentityReset() => _controller.acknowledgeIdentityReset();

  AiChatContextModule _moduleOf(ExportModule module) {
    final slot = _controller.slotOf(module);
    final data = slot.data;
    final kind = _controller.rowKindOf(module);
    final String? error;
    switch (kind) {
      case ExportRowKind.needsLogin:
        error = kAiChatContextNeedsLogin;
      case ExportRowKind.failed:
        error = (slot.message?.trim().isNotEmpty ?? false)
            ? slot.message!.trim()
            : '获取失败';
      case ExportRowKind.ready:
        // 「已过期」仍算就绪（数据会进上下文），仅作状态标记。
        error = data?.status == ExportModuleStatus.stale
            ? kAiChatContextStale
            : null;
      default:
        error = null;
    }
    return AiChatContextModule(
      id: module.key,
      label: module.label,
      selected: _controller.selected.contains(module),
      isReady: data?.status.hasData ?? false,
      isLoading: kind == ExportRowKind.loading,
      error: error,
    );
  }

  ExportModule? _moduleById(String id) {
    for (final m in _controller.availableModules) {
      if (m.key == id) return m;
    }
    return null;
  }

  @override
  void dispose() {
    _controller.removeListener(notifyListeners);
    _controller.dispose();
    super.dispose();
  }
}
