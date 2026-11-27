import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_dropdown.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/app_filter_chips.dart';
import '../../shared/widgets/app_status_tag.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/plain_list.dart';
import '../../shared/widgets/refresh_status_line.dart';
import '../../shared/widgets/skeleton_box.dart';
import 'physical_test_calculator.dart';
import 'physical_test_input.dart';
import 'physical_test_model.dart';
import 'physical_test_service.dart';

part 'physical_test_calculator_view.dart';

typedef PhysicalTestSnapshotFetcher = Future<PhysicalTestSnapshot> Function();

/// 体测页展示模式：「我的成绩」与「成绩计算」。
enum PhysicalTestPageMode { scores, calculator }

/// 体测成绩原生页面（成绩查询 + 离线体测计算器二合一）。
///
/// 接入 [PhysicalTestService] 原生数据服务，只做表现层重排，不改登录 / 网络 /
/// 解析口径 / 缓存与各类守卫：
/// * 顶部提供「我的成绩」|「成绩计算」模式切换器，「成绩计算」完全离线可用；
/// * 未登录：在「我的成绩」模式展示统一认证原生登录引导 [AuthRequiredView]，
///   唤起登录弹窗 [showUnifiedAuthLoginModal]；
/// * 登录成功 / 账号切换：自动拉取对应账号体测成绩，登出立即清除历史成绩；
/// * 有数据：第一屏单列「最新学年总分 + 等级」读数，历史学年用轻量年份选择器切换，
///   选中学年下方是单列项目明细（项目名在左、原始测量值在右、得分 / 评价为次级带标签信息）；
/// * 首次从「我的成绩」切换到「成绩计算」且计算器无输入时，自动提取选中记录中的测量值与性别；
/// * 严禁挂载任何 WebView、CAS H5 页面或凭据快速填充。
class PhysicalTestPage extends StatefulWidget {
  const PhysicalTestPage({
    super.key,
    this.snapshotFetcher,
    this.initialMode = PhysicalTestPageMode.scores,
  });

  static const titleText = '体测成绩';

  /// 测试注入；为空时走 [PhysicalTestService.fetchSnapshot]。
  final PhysicalTestSnapshotFetcher? snapshotFetcher;

  /// 初始模式；兼容 `/physical-test/calculator` 直达「成绩计算」。
  final PhysicalTestPageMode initialMode;

  @override
  State<PhysicalTestPage> createState() => _PhysicalTestPageState();
}

class _PhysicalTestPageState extends State<PhysicalTestPage> {
  static const _maxContentWidth = 640.0;

  late PhysicalTestPageMode _mode;

  bool _loading = true;
  bool _authRequired = false;
  String? _error;
  PhysicalTestSnapshot? _snapshot;
  String? _currentAccount;

  /// 当前在读数与明细区展示的记录下标。默认指向服务返回顺序里的最新学年，
  /// 快照（认证 / 记录）变化时重置，避免残留上一份数据的选中项。
  int _selectedIndex = 0;

  int _authEpoch = 0;
  int _loadId = 0;

  // ── 成绩计算器状态 ──────────────────────────────────────────────────────────
  PhysicalTestGrade? _grade;
  PhysicalTestGender? _gender;

  final _heightCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();
  final _lungCtrl = TextEditingController();
  final _sprintCtrl = TextEditingController();
  final _reachCtrl = TextEditingController();
  final _jumpCtrl = TextEditingController();
  var _strengthCtrl = TextEditingController();
  var _enduranceCtrl = TextEditingController();

  double? _height;
  double? _weight;
  double? _lungCapacity;
  double? _sprint;
  double? _reach;
  double? _longJump;
  int? _strength;
  double? _endurance;

  bool _heightTouched = false;
  bool _weightTouched = false;
  bool _lungTouched = false;
  bool _sprintTouched = false;
  bool _reachTouched = false;
  bool _jumpTouched = false;
  bool _strengthTouched = false;
  bool _enduranceTouched = false;

  /// 是否已执行过「首次切入自动预填」或用户已手动编辑，防止后续来回切换覆盖输入。
  bool _hasAutoPrefilledOnSwitch = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _currentAccount = UnifiedAuthService.instance.currentAccount;
    UnifiedAuthService.instance.addListener(_onAuthChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    UnifiedAuthService.instance.removeListener(_onAuthChanged);
    _heightCtrl.dispose();
    _weightCtrl.dispose();
    _lungCtrl.dispose();
    _sprintCtrl.dispose();
    _reachCtrl.dispose();
    _jumpCtrl.dispose();
    _strengthCtrl.dispose();
    _enduranceCtrl.dispose();
    super.dispose();
  }

  void _onAuthChanged() {
    _authEpoch++;
    final auth = UnifiedAuthService.instance;
    final isLoggedIn = auth.isLoggedIn;
    final newAccount = auth.currentAccount;

    if (!isLoggedIn || newAccount == null || newAccount.isEmpty) {
      _currentAccount = null;
      if (mounted) {
        setState(() {
          _snapshot = null;
          _authRequired = true;
          _loading = false;
          _error = null;
          _selectedIndex = 0;
        });
      }
      return;
    }

    if (newAccount != _currentAccount) {
      _currentAccount = newAccount;
      if (mounted) {
        setState(() {
          _snapshot = null;
          _authRequired = false;
          _error = null;
          _selectedIndex = 0;
        });
        unawaited(_load(forceRefresh: true));
      }
      return;
    }

    if (_authRequired && mounted) {
      unawaited(_load());
    }
  }

  Future<void> _presentLoginPrompt() async {
    final loggedIn = await showUnifiedAuthLoginModal(
      context,
      title: '登录统一认证',
      description: '登录后可查看体测成绩',
    );
    if (loggedIn && mounted) {
      await _load(forceRefresh: true);
    }
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final loadId = ++_loadId;
    final currentEpoch = _authEpoch;
    // 刷新前用户选中的学年；仅当旧快照仍在（身份变化会先清空快照）时才有值。
    final previousYear = _selectedAcademicYear();

    setState(() {
      _loading = true;
      _error = null;
      _authRequired = false;
    });

    try {
      final snapshot = widget.snapshotFetcher != null
          ? await widget.snapshotFetcher!()
          : await PhysicalTestService.instance.fetchSnapshot(
              forceRefresh: forceRefresh,
            );

      if (!mounted || loadId != _loadId || currentEpoch != _authEpoch) {
        return;
      }

      setState(() {
        _snapshot = snapshot;
        _authRequired = false;
        _error = null;
        _selectedIndex = _restoreSelectedIndex(snapshot.records, previousYear);
      });
    } on CasAuthExpiredException {
      if (!mounted || loadId != _loadId || currentEpoch != _authEpoch) {
        return;
      }
      setState(() {
        _snapshot = null;
        _authRequired = true;
        _error = null;
        _selectedIndex = 0;
      });
    } catch (error, stackTrace) {
      AppLogger.instance.network(
        LogLevel.warn,
        '体测成绩加载失败',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted || loadId != _loadId || currentEpoch != _authEpoch) {
        return;
      }
      setState(() {
        _error = '体测成绩加载失败，请稍后重试';
      });
    } finally {
      if (mounted && loadId == _loadId && currentEpoch == _authEpoch) {
        setState(() => _loading = false);
      }
    }
  }

  /// 当前选中记录的学年；无快照 / 越界返回 null。
  String? _selectedAcademicYear() {
    final records = _snapshot?.records;
    if (records == null ||
        _selectedIndex < 0 ||
        _selectedIndex >= records.length) {
      return null;
    }
    return records[_selectedIndex].academicYear;
  }

  PhysicalTestRecord? _selectedRecordOrNull() {
    final records = _snapshot?.records;
    if (records == null || records.isEmpty) return null;
    final index = _selectedIndex.clamp(0, records.length - 1);
    return records[index];
  }

  /// 刷新后沿用用户选中的学年（按学年字符串匹配、取第一条）；
  /// 新快照里已没有该学年（或此前无选择）则回到最新学年。
  int _restoreSelectedIndex(
    List<PhysicalTestRecord> records,
    String? previousYear,
  ) {
    if (previousYear != null) {
      final index = records.indexWhere((r) => r.academicYear == previousYear);
      if (index >= 0) return index;
    }
    return _latestRecordIndex(records);
  }

  void _switchMode(PhysicalTestPageMode nextMode) {
    if (_mode == nextMode) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _mode = nextMode;
      if (nextMode == PhysicalTestPageMode.calculator &&
          !_hasAutoPrefilledOnSwitch &&
          !_hasAnyCalculatorInput) {
        final record = _selectedRecordOrNull();
        if (record != null) {
          final prefill = _PhysicalTestPrefill.fromRecord(record);
          if (!prefill.isEmpty) {
            _applyPrefill(prefill);
            _hasAutoPrefilledOnSwitch = true;
          }
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(
        title: const Text(PhysicalTestPage.titleText),
        actions: [
          if (_mode == PhysicalTestPageMode.scores) ...[
            if (!_loading && !_authRequired && _error == null)
              IconButton(
                icon: const Icon(Icons.refresh_rounded),
                tooltip: '刷新',
                onPressed: () => _load(forceRefresh: true),
              ),
          ] else
            TextButton(onPressed: _resetCalculator, child: const Text('重置')),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.pageMargin,
              AppSpacing.sm,
              AppSpacing.pageMargin,
              AppSpacing.xs,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxContentWidth),
                child: _PhysicalTestModeSwitch(
                  key: const Key('physical_test_mode_switch'),
                  mode: _mode,
                  onChanged: _switchMode,
                ),
              ),
            ),
          ),
          Expanded(
            child: _mode == PhysicalTestPageMode.scores
                ? _buildScoresBody()
                : _buildCalculatorBody(),
          ),
        ],
      ),
    );
  }

  Widget _buildScoresBody() {
    if (_loading && _snapshot == null && !_authRequired && _error == null) {
      return _buildSkeleton();
    }

    if (_authRequired) {
      return AuthRequiredView(
        title: '需要统一认证后继续',
        message: '登录统一身份认证后可查看体测成绩',
        buttonLabel: '登录统一认证',
        icon: Icons.directions_run_outlined,
        onAction: _presentLoginPrompt,
      );
    }

    final error = _error;
    if (error != null) {
      return AppErrorView(
        message: error,
        onRetry: () => _load(forceRefresh: true),
      );
    }

    final records = _snapshot?.records ?? const <PhysicalTestRecord>[];
    if (records.isEmpty) {
      return AppEmptyView(
        title: '暂无体测成绩',
        icon: Icons.directions_run_outlined,
        message: _snapshot?.message,
        actionLabel: '刷新',
        onAction: () => _load(forceRefresh: true),
      );
    }

    return _buildRecords(records);
  }

  /// 有数据：无框主读数 + 历史学年选择器 + 选中学年的单列项目明细。
  Widget _buildRecords(List<PhysicalTestRecord> records) {
    final maxIndex = records.length - 1;
    final selectedIndex = _selectedIndex < 0
        ? 0
        : (_selectedIndex > maxIndex ? maxIndex : _selectedIndex);
    final latestIndex = _latestRecordIndex(records);
    final selected = records[selectedIndex];

    return RefreshIndicator(
      onRefresh: () => _load(forceRefresh: true),
      child: ListView(
        key: const PageStorageKey('physical_test_scores_scroll'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageMargin,
          AppSpacing.md,
          AppSpacing.pageMargin,
          AppSpacing.xl,
        ),
        children: [
          _buildReadout(selected, isLatest: selectedIndex == latestIndex),
          if (records.length > 1) ...[
            const SizedBox(height: AppSpacing.lg),
            const PlainSectionHeader('历年'),
            _buildYearSelector(records, selectedIndex),
          ],
          const SizedBox(height: AppSpacing.lg),
          _buildItems(selected),
        ],
      ),
    );
  }

  /// 主读数：学年（+「最新」标签）在上；「总分」大数字与「等级」状态标签分行分层，
  /// 不把总分与等级拼成一串等权文本。缺失值如实占位，不伪造 0。
  Widget _buildReadout(PhysicalTestRecord record, {required bool isLatest}) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final year = record.academicYear.isEmpty ? '学年未知' : record.academicYear;
    final totalMissing = record.totalScore.isEmpty;
    final gradeMissing = record.grade.isEmpty;

    return Column(
      key: const Key('physical_test_primary_readout'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                year,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.rowTitle,
              ),
            ),
            if (isLatest) ...[
              const SizedBox(width: AppSpacing.sm),
              const AppStatusTag('最新'),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('总分', style: text.meta),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      totalMissing ? '--' : record.totalScore,
                      style: text.overview.copyWith(
                        color: totalMissing ? cs.outlineVariant : cs.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('等级', style: text.meta),
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: gradeMissing
                        ? Text(
                            '暂无等级',
                            style: text.secondary.copyWith(
                              color: cs.outlineVariant,
                            ),
                          )
                        : AppStatusTag(record.grade),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 历史学年选择器：共享的 [AppFilterChips]（与成绩页学期 chip 同款），
  /// 值是记录下标；每个记录一格，重复学年也不合并。
  Widget _buildYearSelector(
    List<PhysicalTestRecord> records,
    int selectedIndex,
  ) {
    return AppFilterChips<int>(
      key: const Key('physical_test_year_chips'),
      padding: EdgeInsets.zero,
      options: [
        for (var i = 0; i < records.length; i++)
          AppFilterOption<int>(
            i,
            records[i].academicYear.isEmpty ? '学年未知' : records[i].academicYear,
          ),
      ],
      selected: selectedIndex,
      onSelected: (i) => setState(() => _selectedIndex = i),
    );
  }

  /// 选中学年的项目明细：单列行列表，用留白分隔（无 Divider / 竖线 / 描边）。
  Widget _buildItems(PhysicalTestRecord record) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    if (record.items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
        child: Center(
          child: Text(
            '暂无项目数据',
            style: text.secondary.copyWith(color: cs.outlineVariant),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PlainSectionHeader('项目明细 · ${record.items.length}'),
        PlainListGroup(
          children: [
            for (var i = 0; i < record.items.length; i++)
              _buildItemRow(record.items[i], i),
          ],
        ),
      ],
    );
  }

  /// 单项行：项目名在左（第一视觉锚点）；最重要的原始测量值在右；得分 / 评价
  /// 作为次级信息在固定位置单独一行、各自带标签，绝不 `join(' · ')` 成等权串。
  Widget _buildItemRow(PhysicalTestItem item, int index) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final name = item.name.isEmpty ? '未命名项目' : item.name;
    final resultMissing = item.result.isEmpty;
    final metrics = <Widget>[
      if (item.score.isNotEmpty) _buildMetric('得分', item.score),
      if (item.level.isNotEmpty) _buildMetric('评价', item.level),
    ];

    return LayoutBuilder(
      key: ValueKey('physical_test_item_row_$index'),
      builder: (context, constraints) {
        final maxTrailing = constraints.maxWidth * 0.52;
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kPlainListRowInset,
            vertical: AppSpacing.md,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(name, style: text.rowTitle)),
              const SizedBox(width: AppSpacing.md),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxTrailing),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        resultMissing ? '--' : item.result,
                        style: resultMissing
                            ? text.rowValue.copyWith(color: cs.outlineVariant)
                            : text.rowValue,
                      ),
                    ),
                    if (metrics.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: AppSpacing.lg,
                        runSpacing: 2,
                        children: metrics,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 带标签的次级指标（`得分 90` / `评价 优秀`）：标签用 `meta`，值用同字号但
  /// 更重的 `onSurface`，与项目名 / 原始测量值拉开层次。
  Widget _buildMetric(String label, String value) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: text.meta),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.meta.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  /// 无缓存首次加载：一组结构化骨架卡片，替代整页空白/spinner。
  Widget _buildSkeleton() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.sm,
        AppSpacing.pageMargin,
        AppSpacing.xl,
      ),
      children: const [
        RefreshStatusLine(refreshing: true, loadingLabel: '正在获取体测成绩…'),
        SizedBox(height: AppSpacing.md),
        SkeletonCard(lines: 2, showTrailing: true),
        SizedBox(height: AppSpacing.md),
        Row(
          children: [
            SkeletonBox(width: 82, height: 34, radius: 17),
            SizedBox(width: AppSpacing.sm),
            SkeletonBox(width: 82, height: 34, radius: 17),
            SizedBox(width: AppSpacing.sm),
            SkeletonBox(width: 82, height: 34, radius: 17),
          ],
        ),
        SizedBox(height: AppSpacing.lg),
        SkeletonCard(lines: 2, showTrailing: true),
        SizedBox(height: AppSpacing.sm),
        SkeletonCard(lines: 2, showTrailing: true),
        SizedBox(height: AppSpacing.sm),
        SkeletonCard(lines: 2, showTrailing: true),
      ],
    );
  }
}

/// 已知学年格式：`YYYY-YYYY`，可带学期后缀 `-N`。只解析这一种格式，格式不认识
/// 时回退到服务返回的稳定顺序，绝不猜测用户学业状态。
final _academicYearPattern = RegExp(r'(\d{4})-(\d{4})(?:-(\d+))?');

/// 学年可比较键；格式不认识返回 null（调用方回退源顺序）。
int? _academicYearKey(String raw) {
  final match = _academicYearPattern.firstMatch(raw.trim());
  if (match == null) return null;
  final start = int.tryParse(match.group(1)!);
  if (start == null) return null;
  final term = int.tryParse(match.group(3) ?? '1') ?? 1;
  return start * 10 + term.clamp(0, 9);
}

/// 最新学年下标：仅在能解析出已知学年格式的记录里取最大者；全部无法解析时按
/// 服务返回顺序取第一条（服务把当前 / 最新记录放在最前）。
int _latestRecordIndex(List<PhysicalTestRecord> records) {
  var best = 0;
  int? bestKey;
  for (var i = 0; i < records.length; i++) {
    final key = _academicYearKey(records[i].academicYear);
    if (key == null) continue;
    if (bestKey == null || key > bestKey) {
      bestKey = key;
      best = i;
    }
  }
  return bestKey == null ? 0 : best;
}
