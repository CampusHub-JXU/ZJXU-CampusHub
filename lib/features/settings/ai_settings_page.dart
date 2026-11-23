import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../core/ai/llm_client.dart';
import '../../core/ai/llm_config_controller.dart';
import '../../core/ai/llm_profile.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/plain_list.dart';

enum _ProfileRowAction { edit, delete }

class _ConnectionTestOutcome {
  const _ConnectionTestOutcome.success(this.message) : isError = false;
  const _ConnectionTestOutcome.error(this.message) : isError = true;

  final String message;
  final bool isError;
}

/// App 级 AI 模型与接口配置页。
///
/// 管理多个 [LlmProfile]（切换当前启用配置、增删改、测试连接），
/// 密钥由 [LlmConfigController] 隔离持久化在安全存储中。
class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key, this.controller, this.client});

  final LlmConfigController? controller;
  final LlmClient? client;

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  static const double _contentMaxWidth = 640;

  late LlmConfigController _controller;
  late LlmClient _client;

  bool _initializing = true;
  bool _testing = false;
  int _keyRefreshGeneration = 0;
  int _testGeneration = 0;
  Map<String, bool> _hasKeyById = const {};
  _ConnectionTestOutcome? _testOutcome;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? LlmConfigController.instance;
    _client = widget.client ?? LlmClient();
    _controller.addListener(_onControllerChanged);
    unawaited(_initialize());
  }

  @override
  void didUpdateWidget(covariant AiSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextController = widget.controller ?? LlmConfigController.instance;
    if (!identical(nextController, _controller)) {
      _controller.removeListener(_onControllerChanged);
      _controller = nextController;
      _controller.addListener(_onControllerChanged);
      _testGeneration++;
      _testing = false;
      _testOutcome = null;
      unawaited(_initialize());
    }
    if (!identical(widget.client, oldWidget.client)) {
      _client = widget.client ?? LlmClient();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      await _controller.init();
      await _refreshKeyStatuses();
    } finally {
      if (mounted) {
        setState(() => _initializing = false);
      }
    }
  }

  void _onControllerChanged() {
    if (!mounted) return;
    _testGeneration++;
    setState(() {
      _testing = false;
      _testOutcome = null;
    });
    unawaited(_refreshKeyStatuses());
  }

  Future<void> _refreshKeyStatuses() async {
    final generation = ++_keyRefreshGeneration;
    final profiles = _controller.profiles;
    final activeId = _controller.activeProfileId;
    final results = await Future.wait<MapEntry<String, bool>>(
      profiles.map((profile) async {
        if (profile.id == activeId) {
          return MapEntry(
            profile.id,
            _controller.activeApiKey.trim().isNotEmpty,
          );
        }
        final key = await _controller.readApiKey(profile.id);
        return MapEntry(profile.id, (key ?? '').trim().isNotEmpty);
      }),
    );
    if (!mounted || generation != _keyRefreshGeneration) return;
    setState(() {
      _hasKeyById = Map<String, bool>.unmodifiable({
        for (final entry in results) entry.key: entry.value,
      });
    });
  }

  bool? _hasKeyFor(LlmProfile profile) {
    if (profile.id == _controller.activeProfileId) {
      return _controller.activeApiKey.trim().isNotEmpty;
    }
    return _hasKeyById[profile.id];
  }

  String _profileSubtitle(LlmProfile profile) {
    final hasKey = _hasKeyFor(profile);
    if (hasKey == null) return profile.model;
    return '${profile.model} · ${hasKey ? '已配置密钥' : '未配置密钥'}';
  }

  Future<void> _activateProfile(String id) async {
    if (id == _controller.activeProfileId) return;
    try {
      await _controller.setActiveProfile(id);
    } catch (_) {
      if (mounted) {
        AppFeedback.toast(context, '切换配置失败，请稍后重试');
      }
    }
  }

  Future<void> _testActiveConnection() async {
    final profile = _controller.activeProfile;
    if (profile == null || _testing) return;
    final generation = ++_testGeneration;
    setState(() {
      _testing = true;
      _testOutcome = null;
    });

    final apiKey = _controller.activeApiKey;
    _ConnectionTestOutcome outcome;
    try {
      final result = await _client.testConnection(profile, apiKey);
      outcome = _ConnectionTestOutcome.success('连接正常 · ${result.latencyMs}ms');
    } on LlmException catch (error) {
      outcome = _ConnectionTestOutcome.error(error.message);
    } catch (_) {
      outcome = const _ConnectionTestOutcome.error('连接测试失败，请稍后重试');
    }

    if (!mounted || generation != _testGeneration) return;
    setState(() {
      _testing = false;
      _testOutcome = outcome;
    });
  }

  Future<void> _openProfileEditor({LlmProfile? profile}) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final saved = await AppFeedback.sheet<bool>(
      context,
      scrollControlled: true,
      constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
      builder: (sheetContext) => _ProfileEditorSheet(
        controller: _controller,
        client: _client,
        profile: profile,
      ),
    );
    if (saved == true && messenger != null) {
      AppFeedback.toastOn(messenger, '配置已保存');
    }
  }

  Future<void> _deleteProfile(LlmProfile profile) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final confirmed = await AppFeedback.confirm(
      context,
      title: '删除配置',
      message: '确定删除「${profile.name}」？已保存的密钥也会一并清除。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _controller.deleteProfile(profile.id);
    if (messenger != null) {
      AppFeedback.toastOn(messenger, '已删除「${profile.name}」');
    }
  }

  @override
  Widget build(BuildContext context) {
    final profiles = _controller.profiles;
    final activeProfile = _controller.activeProfile;
    final outcome = _testOutcome;

    return Scaffold(
      appBar: const AppAppBar(title: Text('AI 模型与接口')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              kPlainListGutter,
              12,
              kPlainListGutter,
              32,
            ),
            children: [
              PlainSectionHeader(
                profiles.isEmpty ? '模型配置' : '模型配置 · ${profiles.length}',
              ),
              if (_initializing && profiles.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (profiles.isEmpty)
                const PlainListGroup(
                  children: [
                    AppEmptyView(
                      title: '暂无 AI 配置',
                      message: '添加一个模型接口配置以启用 AI 功能',
                      icon: Icons.tune_outlined,
                    ),
                  ],
                )
              else
                PlainListGroup(
                  children: [
                    for (final profile in profiles)
                      _buildProfileRow(
                        context,
                        profile: profile,
                        isActive: profile.id == _controller.activeProfileId,
                      ),
                  ],
                ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('ai_test_connection_button'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                      onPressed: activeProfile == null || _testing
                          ? null
                          : () => unawaited(_testActiveConnection()),
                      icon: _testing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.bolt_outlined, size: 18),
                      label: Text(_testing ? '测试中…' : '测试连接'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: FilledButton.icon(
                      key: const Key('ai_add_profile_button'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                      onPressed: () => unawaited(_openProfileEditor()),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('添加配置'),
                    ),
                  ),
                ],
              ),
              if (outcome != null) ...[
                const SizedBox(height: AppSpacing.md),
                _ConnectionResultBanner(
                  key: const Key('ai_connection_test_result'),
                  outcome: outcome,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProfileRow(
    BuildContext context, {
    required LlmProfile profile,
    required bool isActive,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      selected: isActive,
      child: PlainListRow(
        key: Key('ai_profile_row_${profile.id}'),
        leading: Icon(
          isActive ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          size: 20,
          color: isActive ? cs.primary : cs.outline,
        ),
        title: profile.name,
        subtitle: _profileSubtitle(profile),
        showChevron: false,
        onTap: () => unawaited(_activateProfile(profile.id)),
        trailing: PopupMenuButton<_ProfileRowAction>(
          key: Key('ai_profile_menu_${profile.id}'),
          tooltip: '更多操作',
          icon: Icon(Icons.more_vert, size: 20, color: cs.onSurfaceVariant),
          onSelected: (action) {
            switch (action) {
              case _ProfileRowAction.edit:
                unawaited(_openProfileEditor(profile: profile));
              case _ProfileRowAction.delete:
                unawaited(_deleteProfile(profile));
            }
          },
          itemBuilder: (itemContext) => [
            const PopupMenuItem(
              value: _ProfileRowAction.edit,
              child: Text('编辑'),
            ),
            PopupMenuItem(
              value: _ProfileRowAction.delete,
              child: Text(
                '删除',
                style: itemContext.appText.body.copyWith(
                  color: Theme.of(itemContext).colorScheme.error,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionResultBanner extends StatelessWidget {
  const _ConnectionResultBanner({super.key, required this.outcome});

  final _ConnectionTestOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final background = outcome.isError
        ? cs.errorContainer
        : cs.secondaryContainer;
    final foreground = outcome.isError
        ? cs.onErrorContainer
        : cs.onSecondaryContainer;

    return Material(
      color: background,
      shape: RoundedSuperellipseBorder(borderRadius: AppRadius.chipBorder),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(
              outcome.isError
                  ? Icons.error_outline
                  : Icons.check_circle_outline,
              size: 18,
              color: foreground,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                outcome.message,
                style: context.appText.secondary.copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileEditorSheet extends StatefulWidget {
  const _ProfileEditorSheet({
    required this.controller,
    required this.client,
    this.profile,
  });

  final LlmConfigController controller;
  final LlmClient client;
  final LlmProfile? profile;

  @override
  State<_ProfileEditorSheet> createState() => _ProfileEditorSheetState();
}

class _ProfileEditorSheetState extends State<_ProfileEditorSheet> {
  static const Uuid _uuid = Uuid();

  final _formKey = GlobalKey<FormState>();
  late LlmProviderPreset _preset;
  late final TextEditingController _nameController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _modelController;
  late final TextEditingController _apiKeyController;
  late double _temperature;

  bool _obscureApiKey = true;
  bool _saving = false;
  bool _testing = false;
  int _testGeneration = 0;
  _ConnectionTestOutcome? _testOutcome;

  bool get _isEditing => widget.profile != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.profile;
    _preset = existing?.preset ?? LlmProviderPreset.deepseek;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _baseUrlController = TextEditingController(
      text: existing?.baseUrl ?? _preset.defaultBaseUrl,
    );
    _modelController = TextEditingController(
      text: existing?.model ?? _preset.defaultModel,
    );
    _apiKeyController = TextEditingController();
    _temperature = (existing?.temperature ?? 0.7).clamp(0.0, 1.5);
    _modelController.addListener(_onModelTextChanged);
  }

  @override
  void dispose() {
    _modelController.removeListener(_onModelTextChanged);
    _nameController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  void _onModelTextChanged() {
    if (mounted) setState(() {});
  }

  void _onPresetChanged(LlmProviderPreset next) {
    if (next == _preset) return;
    setState(() {
      _preset = next;
      _testOutcome = null;
      if (next == LlmProviderPreset.deepseek) {
        if (_baseUrlController.text.trim().isEmpty) {
          _baseUrlController.text = LlmProviderPreset.deepseek.defaultBaseUrl;
        }
        if (_modelController.text.trim().isEmpty) {
          _modelController.text = LlmProviderPreset.deepseek.defaultModel;
        }
      } else {
        if (_baseUrlController.text.trim() ==
            LlmProviderPreset.deepseek.defaultBaseUrl) {
          _baseUrlController.clear();
        }
        if (LlmProviderPreset.deepseek.commonModels.contains(
          _modelController.text.trim(),
        )) {
          _modelController.clear();
        }
      }
    });
  }

  double get _roundedTemperature =>
      double.parse(_temperature.toStringAsFixed(1));

  LlmProfile _buildProfile({required String id}) {
    return LlmProfile(
      id: id,
      name: _nameController.text.trim(),
      preset: _preset,
      baseUrl: _baseUrlController.text.trim(),
      model: _modelController.text.trim(),
      temperature: _roundedTemperature,
      maxTokens: widget.profile?.maxTokens,
    );
  }

  String? _validateRequired(String? value, String message) {
    if (value == null || value.trim().isEmpty) return message;
    return null;
  }

  String? _validateBaseUrl(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return '请输入 Base URL';
    final uri = Uri.tryParse(text);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.hasQuery) {
      return '请输入有效的 http/https 地址';
    }
    return null;
  }

  Future<void> _testDraftConnection() async {
    if (_testing || _saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final generation = ++_testGeneration;
    setState(() {
      _testing = true;
      _testOutcome = null;
    });

    final draft = _buildProfile(id: widget.profile?.id ?? 'draft');
    var apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty && _isEditing) {
      apiKey = (await widget.controller.readApiKey(widget.profile!.id) ?? '')
          .trim();
    }

    _ConnectionTestOutcome outcome;
    try {
      final result = await widget.client.testConnection(draft, apiKey);
      outcome = _ConnectionTestOutcome.success('连接正常 · ${result.latencyMs}ms');
    } on LlmException catch (error) {
      outcome = _ConnectionTestOutcome.error(error.message);
    } catch (_) {
      outcome = const _ConnectionTestOutcome.error('连接测试失败，请稍后重试');
    }

    if (!mounted || generation != _testGeneration) return;
    setState(() {
      _testing = false;
      _testOutcome = outcome;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _saving = true);
    final profile = _buildProfile(id: widget.profile?.id ?? _uuid.v4());
    final enteredKey = _apiKeyController.text.trim();
    final String? apiKey = enteredKey.isEmpty ? null : enteredKey;

    try {
      await widget.controller.saveProfile(profile, apiKey: apiKey);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _testOutcome = const _ConnectionTestOutcome.error('保存失败，请稍后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final selectedModel = _modelController.text.trim();
    final outcome = _testOutcome;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 4, 20, bottomInset + 20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _isEditing ? '编辑配置' : '添加配置',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: AppSpacing.lg),
              const PlainSectionHeader('服务类型'),
              SegmentedButton<LlmProviderPreset>(
                key: const Key('ai_preset_segmented'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: LlmProviderPreset.deepseek,
                    label: Text('DeepSeek'),
                  ),
                  ButtonSegment(
                    value: LlmProviderPreset.openaiCompatible,
                    label: Text('OpenAI 兼容'),
                  ),
                ],
                selected: {_preset},
                onSelectionChanged: (selection) =>
                    _onPresetChanged(selection.first),
              ),
              const SizedBox(height: AppSpacing.lg),
              TextFormField(
                key: const Key('ai_name_field'),
                controller: _nameController,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '例如：DeepSeek 官方',
                ),
                validator: (value) => _validateRequired(value, '请输入配置名称'),
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                key: const Key('ai_base_url_field'),
                controller: _baseUrlController,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'Base URL',
                  hintText: _preset == LlmProviderPreset.deepseek
                      ? LlmProviderPreset.deepseek.defaultBaseUrl
                      : 'https://.../v1（支持 Magpie / AxonHub）',
                ),
                validator: _validateBaseUrl,
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                key: const Key('ai_model_field'),
                controller: _modelController,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: '模型',
                  hintText: _preset == LlmProviderPreset.deepseek
                      ? LlmProviderPreset.deepseek.defaultModel
                      : '输入模型名称',
                ),
                validator: (value) => _validateRequired(value, '请输入模型名称'),
              ),
              if (_preset.commonModels.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (final model in _preset.commonModels)
                      ChoiceChip(
                        key: Key('ai_model_chip_$model'),
                        label: Text(model),
                        selected: selectedModel == model,
                        onSelected: (_) {
                          _modelController.text = model;
                        },
                      ),
                  ],
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                key: const Key('ai_api_key_field'),
                controller: _apiKeyController,
                obscureText: _obscureApiKey,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  hintText: _isEditing ? '留空保持原密钥' : 'sk-...',
                  suffixIcon: IconButton(
                    key: const Key('ai_api_key_visibility_button'),
                    tooltip: _obscureApiKey ? '显示密钥' : '隐藏密钥',
                    onPressed: () {
                      setState(() => _obscureApiKey = !_obscureApiKey);
                    },
                    icon: Icon(
                      _obscureApiKey
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  Expanded(child: Text('温度', style: context.appText.rowTitle)),
                  Text(
                    _roundedTemperature.toStringAsFixed(1),
                    key: const Key('ai_temperature_value'),
                    style: context.appText.body.copyWith(
                      color: cs.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              SliderTheme(
                data: SliderTheme.of(context)
                    .copyWith(tickMarkShape: SliderTickMarkShape.noTickMark),
                child: Slider(
                  key: const Key('ai_temperature_slider'),
                  value: _temperature,
                  min: 0.0,
                  max: 1.5,
                  divisions: 15,
                  label: _roundedTemperature.toStringAsFixed(1),
                  onChanged: (value) {
                    setState(() => _temperature = value);
                  },
                ),
              ),
              if (outcome != null) ...[
                const SizedBox(height: AppSpacing.sm),
                _ConnectionResultBanner(
                  key: const Key('ai_sheet_connection_test_result'),
                  outcome: outcome,
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  TextButton.icon(
                    key: const Key('ai_sheet_test_connection_button'),
                    onPressed: _testing || _saving
                        ? null
                        : () => unawaited(_testDraftConnection()),
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.bolt_outlined, size: 18),
                    label: Text(_testing ? '测试中…' : '测试连接'),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.of(context).pop(false),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      FilledButton(
                        key: const Key('ai_save_profile_button'),
                        onPressed: _saving ? null : () => unawaited(_save()),
                        child: const Text('保存'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
