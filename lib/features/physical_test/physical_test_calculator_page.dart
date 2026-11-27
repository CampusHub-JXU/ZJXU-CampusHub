import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_dropdown.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/glass_dialog_route.dart';
import '../../shared/widgets/plain_list.dart';
import 'physical_test_calculator.dart';
import 'physical_test_input.dart';

class PhysicalTestCalculatorPage extends StatefulWidget {
  const PhysicalTestCalculatorPage({super.key});

  static const title = '体测计算器';

  @override
  State<PhysicalTestCalculatorPage> createState() =>
      _PhysicalTestCalculatorPageState();
}

class _PhysicalTestCalculatorPageState
    extends State<PhysicalTestCalculatorPage> {
  final _form = GlobalKey<FormState>();
  final _gradeSelector = GlobalKey();
  final _height = GlobalKey<FormFieldState<double>>();
  final _weight = GlobalKey<FormFieldState<double>>();
  final _lungCapacity = GlobalKey<FormFieldState<double>>();
  final _sprint = GlobalKey<FormFieldState<double>>();
  final _reach = GlobalKey<FormFieldState<double>>();
  final _longJump = GlobalKey<FormFieldState<double>>();
  var _strength = GlobalKey<FormFieldState<int>>();
  var _endurance = GlobalKey<FormFieldState<double>>();
  PhysicalTestGrade? _grade;
  PhysicalTestGender? _gender;

  void _selectGender(PhysicalTestGender? gender) {
    if (_gender == gender) return;
    setState(() {
      _gender = gender;
      // 这两个输入在切换性别后对应不同项目。
      _strength = GlobalKey<FormFieldState<int>>();
      _endurance = GlobalKey<FormFieldState<double>>();
    });
  }

  Future<void> _calculate() async {
    FocusScope.of(context).unfocus();
    final grade = _grade;
    final gender = _gender;
    if (grade == null || gender == null) {
      AppFeedback.toast(context, '请选择年级和性别');
      await Scrollable.ensureVisible(
        _gradeSelector.currentContext!,
        duration: AppMotion.quick,
      );
      return;
    }

    final invalid = _form.currentState!.validateGranularly();
    if (invalid.isNotEmpty) {
      await Scrollable.ensureVisible(
        invalid.first.context,
        duration: AppMotion.quick,
        alignment: 0.2,
      );
      return;
    }

    final result = calculatePhysicalTest(
      grade: grade,
      gender: gender,
      heightCm: _height.currentState!.value!,
      weightKg: _weight.currentState!.value!,
      lungCapacityMl: _lungCapacity.currentState!.value!,
      sprintSeconds: _sprint.currentState!.value!,
      sitAndReachCm: _reach.currentState!.value!,
      standingLongJumpCm: _longJump.currentState!.value!,
      strengthReps: _strength.currentState!.value!,
      enduranceSeconds: _endurance.currentState!.value!,
    );

    await showGlassDialog<void>(
      context: context,
      insetPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xl,
        vertical: AppSpacing.lg,
      ),
      builder: (dialogContext) {
        final text = dialogContext.appText;
        final colors = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrollable: true,
          title: const Text('体测计算结果'),
          content: SizedBox(
            width: 380,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('总分', style: text.meta),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: result.totalScore.toStringAsFixed(2),
                          style: text.numStat.copyWith(color: colors.primary),
                        ),
                        TextSpan(text: ' / 100', style: text.numUnit),
                      ],
                    ),
                    maxLines: 1,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                PlainListGroup(
                  children: [
                    for (final item in result.items)
                      PlainListRow(
                        title: item.name,
                        subtitle:
                            '${item.weightPercent}% · 折算 ${item.weightedScore.toStringAsFixed(2)} 分',
                        trailing: Text('${item.score} 分', style: text.rowValue),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('完成'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final gender = _gender;
    return Scaffold(
      appBar: const AppAppBar(title: Text(PhysicalTestCalculatorPage.title)),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.all(AppSpacing.pageMargin),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppDropdown<PhysicalTestGrade>(
                      key: _gradeSelector,
                      label: '年级',
                      hint: '请选择年级',
                      value: _grade,
                      items: [
                        for (final grade in PhysicalTestGrade.values)
                          AppDropdownItem(value: grade, label: grade.label),
                      ],
                      onChanged: (grade) => setState(() => _grade = grade),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppDropdown<PhysicalTestGender>(
                      label: '性别',
                      hint: '请选择性别',
                      value: gender,
                      items: [
                        for (final gender in PhysicalTestGender.values)
                          AppDropdownItem(value: gender, label: gender.label),
                      ],
                      onChanged: _selectGender,
                    ),
                    const SizedBox(height: AppSpacing.listGroupGap),
                    const PlainSectionHeader('原始成绩'),
                    _measurementField(
                      _height,
                      '身高（厘米）',
                      parsePhysicalTestPositiveNumber,
                      error: '请输入大于 0 的身高',
                    ),
                    _measurementField(
                      _weight,
                      '体重（千克）',
                      parsePhysicalTestPositiveNumber,
                      error: '请输入大于 0 的体重',
                    ),
                    _measurementField(
                      _lungCapacity,
                      '肺活量（毫升）',
                      parsePhysicalTestNonNegativeNumber,
                    ),
                    _measurementField(
                      _sprint,
                      '50 米跑（秒）',
                      parsePhysicalTestPositiveNumber,
                      error: '请输入大于 0 的秒数',
                    ),
                    _measurementField(
                      _reach,
                      '坐位体前屈（厘米）',
                      parsePhysicalTestNumber,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                    ),
                    _measurementField(
                      _longJump,
                      '立定跳远（厘米）',
                      parsePhysicalTestNonNegativeNumber,
                    ),
                    if (gender != null) ...[
                      _measurementField(
                        _strength,
                        '${gender.strengthEvent}（次）',
                        parsePhysicalTestRepetitions,
                        error: '请输入非负整数',
                        keyboardType: TextInputType.number,
                      ),
                      _measurementField(
                        _endurance,
                        gender.enduranceEvent,
                        parsePhysicalTestEndurance,
                        helper: '4.30 表示 4 分 30 秒，4 表示 4 分钟',
                        error: '请输入两位秒数，如 4.30，或一位分钟数，如 4',
                        inputAction: TextInputAction.done,
                      ),
                    ],
                    const SizedBox(height: AppSpacing.sm),
                    FilledButton(
                      onPressed: _calculate,
                      child: const Text('计算成绩'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _measurementField<T extends num>(
    GlobalKey<FormFieldState<T>> key,
    String label,
    T? Function(String) parse, {
    String error = '请输入有效数值',
    String? helper,
    TextInputType keyboardType = const TextInputType.numberWithOptions(
      decimal: true,
    ),
    TextInputAction inputAction = TextInputAction.next,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: FormField<T>(
        key: key,
        autovalidateMode: AutovalidateMode.onUserInteractionIfError,
        validator: (value) => value == null ? error : null,
        builder: (field) => TextField(
          keyboardType: keyboardType,
          textInputAction: inputAction,
          onChanged: (value) => field.didChange(parse(value.trim())),
          decoration: InputDecoration(
            labelText: label,
            helperText: helper,
            helperMaxLines: 2,
            errorText: field.errorText,
            errorMaxLines: 2,
          ),
        ),
      ),
    );
  }
}
