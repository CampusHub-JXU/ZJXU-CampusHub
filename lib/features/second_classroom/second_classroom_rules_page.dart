import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/app_list_tile.dart';
import '../../shared/widgets/plain_list.dart';
import 'second_classroom_matcher.dart';
import 'second_classroom_subscription_service.dart';

/// 第二课堂关键词订阅管理页。
///
/// 规则按 AND 匹配活动名：空格分隔的多个词需全部命中（含学院简称别名，
/// 见 `second_classroom_matcher.dart`），如「经院 开跑」。「命中后直接
/// 自动报名」开关读写真实存储值（默认关，开启后命中直接提交报名）。
class SecondClassroomRulesPage extends StatefulWidget {
  const SecondClassroomRulesPage({super.key, this.service});

  final SecondClassroomSubscriptionService? service;

  @override
  State<SecondClassroomRulesPage> createState() =>
      _SecondClassroomRulesPageState();
}

class _SecondClassroomRulesPageState extends State<SecondClassroomRulesPage> {
  final _inputController = TextEditingController();

  SecondClassroomSubscriptionService get _service =>
      widget.service ?? SecondClassroomSubscriptionService.instance;

  List<SecondClassroomRuleSubscription>? _rules;
  bool _autoEnroll = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final rules = await _service.loadRuleSubscriptions();
    final autoEnroll = await _service.isAutoEnrollEnabled();
    if (!mounted) return;
    setState(() {
      _rules = rules;
      _autoEnroll = autoEnroll;
    });
  }

  Future<void> _addRule() async {
    final keywords = secondClassroomKeywords(_inputController.text);
    if (keywords.isEmpty) return;

    final signature = keywords.map(normalizeSecondClassroomTag).join(' ');
    final duplicated = (_rules ?? []).any(
      (rule) =>
          rule.keywords.map(normalizeSecondClassroomTag).join(' ') == signature,
    );
    if (duplicated) {
      AppFeedback.toast(context, '已存在相同的关键词规则');
      return;
    }

    await _service.addRuleSubscription(_inputController.text);
    _inputController.clear();
    if (!mounted) return;
    setState(() {
      _rules = [
        ...?_rules,
        SecondClassroomRuleSubscription(
          keywords: keywords,
          createdAt: DateTime.now(),
        ),
      ];
    });
    AppFeedback.toast(context, '已添加，命中活动名将提醒');
  }

  Future<void> _removeRule(SecondClassroomRuleSubscription rule) async {
    setState(() {
      _rules = _rules
          ?.where(
            (item) =>
                item.createdAt != rule.createdAt ||
                item.keywords.join(' ') != rule.keywords.join(' '),
          )
          .toList();
    });
    await _service.removeRuleSubscription(rule);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rules = _rules;
    return Theme(
      data: Theme.of(context).copyWith(splashFactory: InkRipple.splashFactory),
      child: Scaffold(
        appBar: const AppAppBar(title: Text('订阅管理')),
        body: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.listGutter,
            AppSpacing.md,
            AppSpacing.listGutter,
            AppSpacing.xl,
          ),
          children: [
            const PlainSectionHeader('关键词规则'),
            if (rules == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (rules.isEmpty)
              const AppEmptyView(
                title: '暂无关键词规则',
                message: '添加后，活动名命中即推送提醒',
                icon: Icons.notifications_off_outlined,
              )
            else
              Column(
                children: [
                  for (final rule in rules) ...[
                    _DismissibleRuleTile(
                      key: ValueKey(
                        '${rule.createdAt.millisecondsSinceEpoch}:'
                        '${rule.keywords.join(' ')}',
                      ),
                      rule: rule,
                      onRemoved: () => unawaited(_removeRule(rule)),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                ],
              ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '按关键词匹配活动名，空格分隔多个词需全部命中，如「经院 开跑」',
              style: context.appText.meta.copyWith(
                color: cs.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            _AddRuleRow(controller: _inputController, onAdd: _addRule),
            const SizedBox(height: AppSpacing.listGroupGap),
            const PlainSectionHeader('命中动作'),
            PlainListGroup(
              children: [
                PlainSwitchRow(
                  title: '命中后直接自动报名',
                  subtitle: '开启后命中活动直接提交报名；关闭则只发提醒，点通知进详情页确认',
                  value: _autoEnroll,
                  onChanged: (v) async {
                    setState(() => _autoEnroll = v);
                    await _service.setAutoEnrollEnabled(v);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 一条规则：左滑删除。行本体仍用 `AppListTile` 卡面。
class _DismissibleRuleTile extends StatelessWidget {
  const _DismissibleRuleTile({
    super.key,
    required this.rule,
    required this.onRemoved,
  });

  final SecondClassroomRuleSubscription rule;
  final VoidCallback onRemoved;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Dismissible(
      key: key!,
      direction: DismissDirection.endToStart,
      background: ClipRRect(
        borderRadius: AppRadius.cardBorder,
        child: ColoredBox(
          color: cs.errorContainer,
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 20),
              child: Icon(
                Icons.delete_outline_rounded,
                color: cs.onErrorContainer,
              ),
            ),
          ),
        ),
      ),
      onDismissed: (_) => onRemoved(),
      child: AppListTile(
        title: rule.keywords.join(' '),
        meta: '添加于 ${_formatCreatedAt(rule.createdAt)}',
      ),
    );
  }

  static String _formatCreatedAt(DateTime value) {
    final now = DateTime.now();
    final sameYear = value.year == now.year;
    final date = sameYear
        ? '${value.month}月${value.day}日'
        : '${value.year}年${value.month}月${value.day}日';
    final time =
        '${value.hour.toString().padLeft(2, '0')}:'
        '${value.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }
}

/// 底部输入行：文本框 + 填充「添加」按钮，键盘提交同样添加。
class _AddRuleRow extends StatelessWidget {
  const _AddRuleRow({required this.controller, required this.onAdd});

  final TextEditingController controller;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onAdd(),
            decoration: InputDecoration(
              hintText: '输入关键词，如「经院 开跑」',
              filled: true,
              fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.5),
              border: OutlineInputBorder(
                borderRadius: AppRadius.inputBorder,
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: AppRadius.inputBorder,
                borderSide: BorderSide(
                  color: cs.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: AppRadius.inputBorder,
                borderSide: BorderSide(color: cs.primary, width: 1.4),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) => FilledButton(
            onPressed: value.text.trim().isEmpty ? null : onAdd,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            ),
            child: const Text('添加'),
          ),
        ),
      ],
    );
  }
}
