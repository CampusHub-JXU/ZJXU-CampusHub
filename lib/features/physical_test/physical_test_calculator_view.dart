part of 'physical_test_page.dart';

/// 顶部二合一模式切换器：对齐设计稿 `.seg` 风格（`surfaceContainerHighest` 圆角底槽 +
/// 选中胶囊滑块）。
class _PhysicalTestModeSwitch extends StatelessWidget {
  const _PhysicalTestModeSwitch({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  final PhysicalTestPageMode mode;
  final ValueChanged<PhysicalTestPageMode> onChanged;

  static const _segments = <(PhysicalTestPageMode, String)>[
    (PhysicalTestPageMode.scores, '我的成绩'),
    (PhysicalTestPageMode.calculator, '成绩计算'),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final reduced = AppMotion.reduced(context);

    final trackColor = isDark
        ? cs.surfaceContainerHighest.withValues(alpha: 0.72)
        : cs.surfaceContainerHighest;
    final activeThumbColor = isDark
        ? Color.alphaBlend(
            cs.onSurface.withValues(alpha: 0.14),
            cs.surfaceContainerHighest,
          )
        : cs.surfaceContainerLowest;

    return AppTextScaleGuard.chrome(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: trackColor,
          borderRadius: BorderRadius.circular(AppRadius.segment),
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Row(
            children: [
              for (final (value, label) in _segments)
                Expanded(
                  child: _ModeSegmentItem(
                    label: label,
                    selected: mode == value,
                    activeColor: activeThumbColor,
                    reduced: reduced,
                    onTap: () => onChanged(value),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeSegmentItem extends StatelessWidget {
  const _ModeSegmentItem({
    required this.label,
    required this.selected,
    required this.activeColor,
    required this.reduced,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color activeColor;
  final bool reduced;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: reduced ? Duration.zero : AppMotion.quick,
          curve: AppMotion.standard,
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? activeColor : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                style: AppChromeType.segment.copyWith(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? cs.onSurface : cs.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 从体测成绩记录 [PhysicalTestRecord] 提取出的计算器预填快照。
class _PhysicalTestPrefill {
  const _PhysicalTestPrefill({
    this.gender,
    this.heightText,
    this.height,
    this.weightText,
    this.weight,
    this.lungText,
    this.lungCapacity,
    this.sprintText,
    this.sprint,
    this.reachText,
    this.reach,
    this.jumpText,
    this.longJump,
    this.strengthText,
    this.strength,
    this.enduranceText,
    this.endurance,
  });

  final PhysicalTestGender? gender;
  final String? heightText;
  final double? height;
  final String? weightText;
  final double? weight;
  final String? lungText;
  final double? lungCapacity;
  final String? sprintText;
  final double? sprint;
  final String? reachText;
  final double? reach;
  final String? jumpText;
  final double? longJump;
  final String? strengthText;
  final int? strength;
  final String? enduranceText;
  final double? endurance;

  bool get isEmpty =>
      gender == null &&
      heightText == null &&
      weightText == null &&
      lungText == null &&
      sprintText == null &&
      reachText == null &&
      jumpText == null &&
      strengthText == null &&
      enduranceText == null;

  static final _numberPattern = RegExp(r'-?\d+(?:\.\d+)?');
  static final _minuteSecondPattern = RegExp(
    r"(\d+)\s*(?:分|′|\'|:)\s*(\d+(?:\.\d+)?)",
  );
  static final _decimalMinutePattern = RegExp(r'^(\d+)\.([0-5]\d)$');

  static _PhysicalTestPrefill fromRecord(
    PhysicalTestRecord record, {
    PhysicalTestGender? fallbackGender,
  }) {
    PhysicalTestGender? inferredGender;
    for (final item in record.items) {
      final norm = item.name.replaceAll(RegExp(r'\s+'), '');
      if (norm.contains('引体向上') || norm.contains('1000米')) {
        inferredGender = PhysicalTestGender.male;
        break;
      }
      if (norm.contains('仰卧起坐') || norm.contains('800米')) {
        inferredGender = PhysicalTestGender.female;
        break;
      }
    }

    final effectiveGender = inferredGender ?? fallbackGender;

    String? heightText;
    double? height;
    String? weightText;
    double? weight;
    String? lungText;
    double? lungCapacity;
    String? sprintText;
    double? sprint;
    String? reachText;
    double? reach;
    String? jumpText;
    double? longJump;
    String? strengthText;
    int? strength;
    String? enduranceText;
    double? endurance;

    for (final item in record.items) {
      final norm = item.name.replaceAll(RegExp(r'\s+'), '');
      final raw = item.result.trim();
      if (raw.isEmpty) continue;

      if (norm.contains('身高')) {
        final parsed = _parseLengthCm(raw, positiveOnly: true);
        if (parsed != null) {
          heightText = parsed.$1;
          height = parsed.$2;
        }
      } else if (norm.contains('体重') &&
          !norm.contains('指数') &&
          !norm.toLowerCase().contains('bmi')) {
        final token = _firstNumberToken(raw);
        final val = token == null
            ? null
            : parsePhysicalTestPositiveNumber(token);
        if (val != null) {
          weightText = token;
          weight = val;
        }
      } else if (norm.contains('肺活量')) {
        final token = _firstNumberToken(raw);
        final val = token == null
            ? null
            : parsePhysicalTestNonNegativeNumber(token);
        if (val != null) {
          lungText = token;
          lungCapacity = val;
        }
      } else if (norm.contains('50米')) {
        final token = _firstNumberToken(raw);
        final val = token == null
            ? null
            : parsePhysicalTestPositiveNumber(token);
        if (val != null) {
          sprintText = token;
          sprint = val;
        }
      } else if (norm.contains('体前屈')) {
        final token = _firstNumberToken(raw);
        final val = token == null ? null : parsePhysicalTestNumber(token);
        if (val != null) {
          reachText = token;
          reach = val;
        }
      } else if (norm.contains('立定跳远') || norm.contains('跳远')) {
        final parsed = _parseLengthCm(raw, positiveOnly: false);
        if (parsed != null) {
          jumpText = parsed.$1;
          longJump = parsed.$2;
        }
      } else if (norm.contains('引体向上') || norm.contains('仰卧起坐')) {
        final token = _firstNumberToken(raw);
        if (token != null) {
          var reps = parsePhysicalTestRepetitions(token);
          String? formatted = token;
          if (reps == null) {
            final asDouble = parsePhysicalTestNonNegativeNumber(token);
            if (asDouble != null &&
                (asDouble - asDouble.roundToDouble()).abs() < 1e-9) {
              reps = asDouble.round();
              formatted = reps.toString();
            }
          }
          if (reps != null) {
            strengthText = formatted;
            strength = reps;
          }
        }
      } else if (norm.contains('1000米') || norm.contains('800米')) {
        final targetGender = norm.contains('1000米')
            ? PhysicalTestGender.male
            : PhysicalTestGender.female;
        final parsed = _parseEndurance(raw, targetGender);
        if (parsed != null &&
            (effectiveGender == null || effectiveGender == targetGender)) {
          enduranceText = parsed.$1;
          endurance = parsed.$2;
        }
      }
    }

    return _PhysicalTestPrefill(
      gender: inferredGender,
      heightText: heightText,
      height: height,
      weightText: weightText,
      weight: weight,
      lungText: lungText,
      lungCapacity: lungCapacity,
      sprintText: sprintText,
      sprint: sprint,
      reachText: reachText,
      reach: reach,
      jumpText: jumpText,
      longJump: longJump,
      strengthText: strengthText,
      strength: strength,
      enduranceText: enduranceText,
      endurance: endurance,
    );
  }

  static String? _firstNumberToken(String raw) =>
      _numberPattern.firstMatch(raw)?.group(0);

  static String _formatNumber(double value) {
    if ((value - value.roundToDouble()).abs() < 1e-9) {
      return value.round().toString();
    }
    return value
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  static (String, double)? _parseLengthCm(
    String raw, {
    required bool positiveOnly,
  }) {
    final token = _firstNumberToken(raw);
    if (token == null) return null;
    final val = positiveOnly
        ? parsePhysicalTestPositiveNumber(token)
        : parsePhysicalTestNonNegativeNumber(token);
    if (val == null) return null;
    // 兼容部分记录以「米」为单位（如 `2.35 米`），换算为计算器所需的厘米。
    final isMetersOnly =
        raw.contains('米') && !raw.contains('厘米') && !raw.contains('毫米');
    if (isMetersOnly && val < 10) {
      final cm = val * 100;
      return (_formatNumber(cm), cm);
    }
    return (token, val);
  }

  static (String, double)? _parseEndurance(
    String raw,
    PhysicalTestGender gender,
  ) {
    final msMatch = _minuteSecondPattern.firstMatch(raw);
    if (msMatch != null) {
      final minutes = int.tryParse(msMatch.group(1)!);
      final secVal = double.tryParse(msMatch.group(2)!);
      if (minutes != null && secVal != null && secVal >= 0 && secVal < 60) {
        final secs = secVal.round().clamp(0, 59);
        final formatted = gender == PhysicalTestGender.male
            ? '$minutes.${secs.toString().padLeft(2, '0')}'
            : '$minutes:${secs.toString().padLeft(2, '0')}';
        final parsed = parsePhysicalTestEndurance(formatted, gender);
        if (parsed != null) return (formatted, parsed);
      }
    }

    final token = _firstNumberToken(raw);
    if (token == null) return null;

    if (gender == PhysicalTestGender.male) {
      if (raw.contains('秒') && !raw.contains('分')) {
        final totalSecs = parsePhysicalTestPositiveNumber(token);
        if (totalSecs != null) {
          final rounded = totalSecs.round();
          final m = rounded ~/ 60;
          final s = rounded % 60;
          final formatted = '$m.${s.toString().padLeft(2, '0')}';
          final parsed = parsePhysicalTestEndurance(formatted, gender);
          if (parsed != null) return (formatted, parsed);
        }
      }
      final parsed = parsePhysicalTestEndurance(token, gender);
      if (parsed != null) return (token, parsed);
    } else {
      // 女生 800 米跑在学校系统常表示为 `3.56 分钟`（即 3 分 56 秒）；
      // 计算器女生解析器把带小数点的单串当作总秒数，需转为 `3:56`。
      final dmMatch = _decimalMinutePattern.firstMatch(token);
      if (dmMatch != null && (raw.contains('分') || !raw.contains('秒'))) {
        final formatted = '${dmMatch.group(1)}:${dmMatch.group(2)}';
        final parsed = parsePhysicalTestEndurance(formatted, gender);
        if (parsed != null) return (formatted, parsed);
      }
      final parsed = parsePhysicalTestEndurance(token, gender);
      if (parsed != null) return (token, parsed);
    }
    return null;
  }
}

extension _PhysicalTestCalculatorState on _PhysicalTestPageState {
  bool get _hasAnyCalculatorInput =>
      _grade != null ||
      _gender != null ||
      _heightCtrl.text.trim().isNotEmpty ||
      _weightCtrl.text.trim().isNotEmpty ||
      _lungCtrl.text.trim().isNotEmpty ||
      _sprintCtrl.text.trim().isNotEmpty ||
      _reachCtrl.text.trim().isNotEmpty ||
      _jumpCtrl.text.trim().isNotEmpty ||
      _strengthCtrl.text.trim().isNotEmpty ||
      _enduranceCtrl.text.trim().isNotEmpty;

  void _selectGender(PhysicalTestGender? gender) {
    if (_gender == gender) return;
    final oldStrength = _strengthCtrl;
    final oldEndurance = _enduranceCtrl;
    // ignore: invalid_use_of_protected_member
    setState(() {
      _gender = gender;
      _strength = null;
      _endurance = null;
      _strengthTouched = false;
      _enduranceTouched = false;
      _strengthCtrl = TextEditingController();
      _enduranceCtrl = TextEditingController();
      _hasAutoPrefilledOnSwitch = true;
    });
    oldStrength.dispose();
    oldEndurance.dispose();
  }

  void _resetCalculator() {
    FocusScope.of(context).unfocus();
    // ignore: invalid_use_of_protected_member
    setState(() {
      _heightCtrl.clear();
      _weightCtrl.clear();
      _lungCtrl.clear();
      _sprintCtrl.clear();
      _reachCtrl.clear();
      _jumpCtrl.clear();
      _strengthCtrl.clear();
      _enduranceCtrl.clear();
      _height = null;
      _weight = null;
      _lungCapacity = null;
      _sprint = null;
      _reach = null;
      _longJump = null;
      _strength = null;
      _endurance = null;
      _heightTouched = false;
      _weightTouched = false;
      _lungTouched = false;
      _sprintTouched = false;
      _reachTouched = false;
      _jumpTouched = false;
      _strengthTouched = false;
      _enduranceTouched = false;
      _hasAutoPrefilledOnSwitch = true;
    });
  }

  void _applyPrefill(_PhysicalTestPrefill prefill) {
    if (prefill.gender != null && _gender != prefill.gender) {
      final oldStrength = _strengthCtrl;
      final oldEndurance = _enduranceCtrl;
      _gender = prefill.gender;
      _strength = null;
      _endurance = null;
      _strengthTouched = false;
      _enduranceTouched = false;
      _strengthCtrl = TextEditingController();
      _enduranceCtrl = TextEditingController();
      oldStrength.dispose();
      oldEndurance.dispose();
    }

    void setField(TextEditingController ctrl, String? text) {
      final next = text ?? '';
      ctrl.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    }

    if (prefill.heightText != null) {
      setField(_heightCtrl, prefill.heightText);
      _height = prefill.height;
      _heightTouched = false;
    }
    if (prefill.weightText != null) {
      setField(_weightCtrl, prefill.weightText);
      _weight = prefill.weight;
      _weightTouched = false;
    }
    if (prefill.lungText != null) {
      setField(_lungCtrl, prefill.lungText);
      _lungCapacity = prefill.lungCapacity;
      _lungTouched = false;
    }
    if (prefill.sprintText != null) {
      setField(_sprintCtrl, prefill.sprintText);
      _sprint = prefill.sprint;
      _sprintTouched = false;
    }
    if (prefill.reachText != null) {
      setField(_reachCtrl, prefill.reachText);
      _reach = prefill.reach;
      _reachTouched = false;
    }
    if (prefill.jumpText != null) {
      setField(_jumpCtrl, prefill.jumpText);
      _longJump = prefill.longJump;
      _jumpTouched = false;
    }
    if (prefill.strengthText != null) {
      setField(_strengthCtrl, prefill.strengthText);
      _strength = prefill.strength;
      _strengthTouched = false;
    }
    if (prefill.enduranceText != null) {
      setField(_enduranceCtrl, prefill.enduranceText);
      _endurance = prefill.endurance;
      _enduranceTouched = false;
    }
  }

  void _importFromSelectedRecord() {
    final record = _selectedRecordOrNull();
    if (record == null) return;
    final prefill = _PhysicalTestPrefill.fromRecord(
      record,
      fallbackGender: _gender,
    );
    if (prefill.isEmpty) return;
    FocusScope.of(context).unfocus();
    // ignore: invalid_use_of_protected_member
    setState(() {
      _applyPrefill(prefill);
      _hasAutoPrefilledOnSwitch = true;
    });
  }

  bool _canImportSelectedRecord() {
    final record = _selectedRecordOrNull();
    if (record == null) return false;
    final prefill = _PhysicalTestPrefill.fromRecord(
      record,
      fallbackGender: _gender,
    );
    if (prefill.isEmpty) return false;

    bool differs(String? expected, TextEditingController ctrl) =>
        expected != null && ctrl.text.trim() != expected;

    return (prefill.gender != null && prefill.gender != _gender) ||
        differs(prefill.heightText, _heightCtrl) ||
        differs(prefill.weightText, _weightCtrl) ||
        differs(prefill.lungText, _lungCtrl) ||
        differs(prefill.sprintText, _sprintCtrl) ||
        differs(prefill.reachText, _reachCtrl) ||
        differs(prefill.jumpText, _jumpCtrl) ||
        differs(prefill.strengthText, _strengthCtrl) ||
        differs(prefill.enduranceText, _enduranceCtrl);
  }

  PhysicalTestCalculation? _computeIfReady() {
    final grade = _grade;
    final gender = _gender;
    if (grade == null ||
        gender == null ||
        _height == null ||
        _weight == null ||
        _lungCapacity == null ||
        _sprint == null ||
        _reach == null ||
        _longJump == null ||
        _strength == null ||
        _endurance == null) {
      return null;
    }
    return calculatePhysicalTest(
      grade: grade,
      gender: gender,
      heightCm: _height!,
      weightKg: _weight!,
      lungCapacityMl: _lungCapacity!,
      sprintSeconds: _sprint!,
      sitAndReachCm: _reach!,
      standingLongJumpCm: _longJump!,
      strengthReps: _strength!,
      enduranceSeconds: _endurance!,
    );
  }

  /// 实时计算当前已有效填报的单项得分（需先选定年级与性别）。
  Map<String, int> _computeItemScores() {
    final grade = _grade;
    final gender = _gender;
    if (grade == null || gender == null) return const <String, int>{};

    final sample = calculatePhysicalTest(
      grade: grade,
      gender: gender,
      heightCm: _height ?? 170,
      weightKg: _weight ?? 60,
      lungCapacityMl: _lungCapacity ?? 3000,
      sprintSeconds: _sprint ?? 8.0,
      sitAndReachCm: _reach ?? 10.0,
      standingLongJumpCm: _longJump ?? 200,
      strengthReps: _strength ?? 10,
      enduranceSeconds: _endurance ?? 240,
    );

    final scores = <String, int>{};
    for (final item in sample.items) {
      final hasInput = switch (item.name) {
        '体重指数（BMI）' => _height != null && _weight != null,
        '肺活量' => _lungCapacity != null,
        '50 米跑' => _sprint != null,
        '坐位体前屈' => _reach != null,
        '立定跳远' => _longJump != null,
        _ when item.name == gender.strengthEvent => _strength != null,
        _ when item.name == gender.enduranceEvent => _endurance != null,
        _ => false,
      };
      if (hasInput) {
        scores[item.name] = item.score;
      }
    }
    return scores;
  }

  (String, AppStatusTone) _levelTag(double score) {
    if (score >= 90) return ('优秀', AppStatusTone.positive);
    if (score >= 80) return ('良好', AppStatusTone.positive);
    if (score >= 60) return ('及格', AppStatusTone.attention);
    return ('不及格', AppStatusTone.danger);
  }

  Widget _buildCalculatorBody() {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final gender = _gender;
    final result = _computeIfReady();
    final itemScores = _computeItemScores();
    final canImport = _canImportSelectedRecord();

    final bmiValue = _height != null && _weight != null && _height! > 0
        ? _weight! / ((_height! / 100) * (_height! / 100))
        : null;

    final (levelLabel, levelTone) = result == null
        ? ('待完善', AppStatusTone.neutral)
        : _levelTag(result.totalScore);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: _PhysicalTestPageState._maxContentWidth,
        ),
        child: Column(
          children: [
            // 顶部无框预估总分 Readout：与「我的成绩」主读数同构，输入即实时重算。
            Padding(
              key: const Key('physical_test_calculator_readout'),
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.pageMargin,
                AppSpacing.md,
                AppSpacing.pageMargin,
                AppSpacing.md,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    flex: 6,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('预估总分', style: text.meta),
                        const SizedBox(height: 2),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                result == null
                                    ? '--'
                                    : result.totalScore.toStringAsFixed(2),
                                style: text.overview.copyWith(
                                  color: result == null
                                      ? cs.outlineVariant
                                      : cs.primary,
                                ),
                              ),
                              if (result != null) ...[
                                const SizedBox(width: AppSpacing.xs),
                                Text('分', style: text.numUnit),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    flex: 4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('等级', style: text.meta),
                        const SizedBox(height: 4),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: AppStatusTag(levelLabel, tone: levelTone),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                key: const PageStorageKey('physical_test_calc_scroll'),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.pageMargin,
                  AppSpacing.xs,
                  AppSpacing.pageMargin,
                  AppSpacing.xl,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: AppDropdown<PhysicalTestGrade>(
                            expanded: true,
                            value: _grade,
                            hint: '请选择年级',
                            items: PhysicalTestGrade.values
                                .map(
                                  (g) =>
                                      AppDropdownItem(value: g, label: g.label),
                                )
                                .toList(),
                            // ignore: invalid_use_of_protected_member
                            onChanged: (value) => setState(() {
                              _grade = value;
                              _hasAutoPrefilledOnSwitch = true;
                            }),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: AppDropdown<PhysicalTestGender>(
                            expanded: true,
                            value: gender,
                            hint: '请选择性别',
                            items: PhysicalTestGender.values
                                .map(
                                  (g) =>
                                      AppDropdownItem(value: g, label: g.label),
                                )
                                .toList(),
                            onChanged: _selectGender,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Semantics(
                            header: true,
                            child: Text('原始成绩', style: text.label),
                          ),
                        ),
                        if (canImport)
                          GestureDetector(
                            onTap: _importFromSelectedRecord,
                            behavior: HitTestBehavior.opaque,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 4,
                              ),
                              child: Text(
                                '带入成绩',
                                style: text.label.copyWith(color: cs.primary),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    PlainListGroup(
                      children: [
                        _InlineScoreRow(
                          fieldKey: const Key('physical_test_input_height'),
                          controller: _heightCtrl,
                          label: '身高',
                          subtitle: '厘米',
                          hint: '176',
                          showScoreBadge: false,
                          reserveScoreSlot: true,
                          errorText: _heightTouched && _height == null
                              ? '请输入大于 0 的身高'
                              : null,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          // ignore: invalid_use_of_protected_member
                          onChanged: (raw) => setState(() {
                            _hasAutoPrefilledOnSwitch = true;
                            _heightTouched = raw.trim().isNotEmpty;
                            _height = parsePhysicalTestPositiveNumber(
                              raw.trim(),
                            );
                          }),
                        ),
                        _InlineScoreRow(
                          fieldKey: const Key('physical_test_input_weight'),
                          controller: _weightCtrl,
                          label: '体重',
                          subtitle: '公斤',
                          hint: '66',
                          showScoreBadge: false,
                          reserveScoreSlot: true,
                          errorText: _weightTouched && _weight == null
                              ? '请输入大于 0 的体重'
                              : null,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          // ignore: invalid_use_of_protected_member
                          onChanged: (raw) => setState(() {
                            _hasAutoPrefilledOnSwitch = true;
                            _weightTouched = raw.trim().isNotEmpty;
                            _weight = parsePhysicalTestPositiveNumber(
                              raw.trim(),
                            );
                          }),
                        ),
                        _ComputedScoreRow(
                          label: '体重指数（BMI）',
                          subtitle: bmiValue == null
                              ? '权重 15% · 填身高体重自动算'
                              : 'BMI ${bmiValue.toStringAsFixed(1)} · 权重 15%',
                          score: itemScores['体重指数（BMI）'],
                        ),
                        _InlineScoreRow(
                          fieldKey: const Key('physical_test_input_lung'),
                          controller: _lungCtrl,
                          label: '肺活量',
                          subtitle: '权重 15% · 毫升',
                          hint: '4650',
                          score: itemScores['肺活量'],
                          errorText: _lungTouched && _lungCapacity == null
                              ? '请输入有效数值'
                              : null,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          // ignore: invalid_use_of_protected_member
                          onChanged: (raw) => setState(() {
                            _hasAutoPrefilledOnSwitch = true;
                            _lungTouched = raw.trim().isNotEmpty;
                            _lungCapacity = parsePhysicalTestNonNegativeNumber(
                              raw.trim(),
                            );
                          }),
                        ),
                        _InlineScoreRow(
                          fieldKey: const Key('physical_test_input_sprint'),
                          controller: _sprintCtrl,
                          label: '50 米跑',
                          subtitle: '权重 20% · 秒',
                          hint: '7.1',
                          score: itemScores['50 米跑'],
                          errorText: _sprintTouched && _sprint == null
                              ? '请输入大于 0 的秒数'
                              : null,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          // ignore: invalid_use_of_protected_member
                          onChanged: (raw) => setState(() {
                            _hasAutoPrefilledOnSwitch = true;
                            _sprintTouched = raw.trim().isNotEmpty;
                            _sprint = parsePhysicalTestPositiveNumber(
                              raw.trim(),
                            );
                          }),
                        ),
                        _InlineScoreRow(
                          fieldKey: const Key('physical_test_input_reach'),
                          controller: _reachCtrl,
                          label: '坐位体前屈',
                          subtitle: '权重 10% · 厘米',
                          hint: '15.5',
                          score: itemScores['坐位体前屈'],
                          errorText: _reachTouched && _reach == null
                              ? '请输入有效数值'
                              : null,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                            signed: true,
                          ),
                          // ignore: invalid_use_of_protected_member
                          onChanged: (raw) => setState(() {
                            _hasAutoPrefilledOnSwitch = true;
                            _reachTouched = raw.trim().isNotEmpty;
                            _reach = parsePhysicalTestNumber(raw.trim());
                          }),
                        ),
                        _InlineScoreRow(
                          fieldKey: const Key('physical_test_input_jump'),
                          controller: _jumpCtrl,
                          label: '立定跳远',
                          subtitle: '权重 10% · 厘米',
                          hint: '248',
                          score: itemScores['立定跳远'],
                          errorText: _jumpTouched && _longJump == null
                              ? '请输入有效数值'
                              : null,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          // ignore: invalid_use_of_protected_member
                          onChanged: (raw) => setState(() {
                            _hasAutoPrefilledOnSwitch = true;
                            _jumpTouched = raw.trim().isNotEmpty;
                            _longJump = parsePhysicalTestNonNegativeNumber(
                              raw.trim(),
                            );
                          }),
                        ),
                        if (gender != null) ...[
                          _InlineScoreRow(
                            fieldKey: const Key('physical_test_input_strength'),
                            controller: _strengthCtrl,
                            label: gender.strengthEvent,
                            subtitle: '权重 10% · 次',
                            hint: gender == PhysicalTestGender.male
                                ? '12'
                                : '42',
                            score: itemScores[gender.strengthEvent],
                            errorText: _strengthTouched && _strength == null
                                ? '请输入非负整数'
                                : null,
                            keyboardType: TextInputType.number,
                            // ignore: invalid_use_of_protected_member
                            onChanged: (raw) => setState(() {
                              _hasAutoPrefilledOnSwitch = true;
                              _strengthTouched = raw.trim().isNotEmpty;
                              _strength = parsePhysicalTestRepetitions(
                                raw.trim(),
                              );
                            }),
                          ),
                          _InlineScoreRow(
                            fieldKey: const Key(
                              'physical_test_input_endurance',
                            ),
                            controller: _enduranceCtrl,
                            label: gender.enduranceEvent,
                            subtitle: gender == PhysicalTestGender.male
                                ? '权重 20% · 分.秒（如 4.30）'
                                : '权重 20% · 分:秒或秒',
                            hint: gender == PhysicalTestGender.male
                                ? '4.30'
                                : '4:10',
                            score: itemScores[gender.enduranceEvent],
                            errorText: _enduranceTouched && _endurance == null
                                ? (gender == PhysicalTestGender.male
                                      ? '请输入两位秒数，如 4.30，或一位分钟数，如 4'
                                      : '请输入有效的分:秒或总秒数')
                                : null,
                            keyboardType: gender == PhysicalTestGender.male
                                ? const TextInputType.numberWithOptions(
                                    decimal: true,
                                  )
                                : TextInputType.datetime,
                            textInputAction: TextInputAction.done,
                            // ignore: invalid_use_of_protected_member
                            onChanged: (raw) => setState(() {
                              _hasAutoPrefilledOnSwitch = true;
                              _enduranceTouched = raw.trim().isNotEmpty;
                              _endurance = parsePhysicalTestEndurance(
                                raw.trim(),
                                gender,
                              );
                            }),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.xs,
                      ),
                      child: Text(
                        gender == null
                            ? '请先选择年级与性别；选定后即可显示力量与耐力跑项目及各单项得分。'
                            : (_grade == null
                                  ? '请选择年级以实时计算各单项得分与预估总分。'
                                  : '依据《国家学生体质健康标准》标准分权重实时测算，不含加分项。'),
                        style: text.meta,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScoreBadge extends StatelessWidget {
  const _ScoreBadge({this.score});

  final int? score;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final content = score == null
        ? Text(
            '-- 分',
            maxLines: 1,
            style: text.meta.copyWith(
              color: cs.outlineVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          )
        : Text(
            '$score 分',
            maxLines: 1,
            style: text.rowTitleStrong.copyWith(
              fontSize: 13.5,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: score! >= 80
                  ? cs.primary
                  : (score! >= 60 ? cs.onSurface : cs.error),
            ),
          );

    return SizedBox(
      width: 48,
      child: Align(
        alignment: Alignment.centerRight,
        child: FittedBox(fit: BoxFit.scaleDown, child: content),
      ),
    );
  }
}

class _ComputedScoreRow extends StatelessWidget {
  const _ComputedScoreRow({
    required this.label,
    required this.subtitle,
    required this.score,
  });

  final String label;
  final String subtitle;
  final int? score;

  @override
  Widget build(BuildContext context) {
    final text = context.appText;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kPlainListRowInset,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: text.rowTitle),
                const SizedBox(height: 2),
                Text(subtitle, style: text.meta),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          AppTextScaleGuard(max: 1.35, child: _ScoreBadge(score: score)),
        ],
      ),
    );
  }
}

class _InlineScoreRow extends StatelessWidget {
  const _InlineScoreRow({
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.hint,
    required this.keyboardType,
    required this.onChanged,
    this.subtitle,
    this.score,
    this.showScoreBadge = true,
    this.reserveScoreSlot = false,
    this.errorText,
    this.textInputAction = TextInputAction.next,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final String hint;
  final String? subtitle;
  final int? score;
  final bool showScoreBadge;
  final bool reserveScoreSlot;
  final String? errorText;
  final TextInputType keyboardType;
  final TextInputAction textInputAction;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final text = context.appText;
    final hasError = errorText != null;

    final fieldBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.control),
      borderSide: BorderSide(
        color: hasError
            ? cs.error
            : cs.outlineVariant.withValues(alpha: isDark ? 0.35 : 0.25),
        width: hasError ? 1.0 : 0.7,
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kPlainListRowInset,
        vertical: AppSpacing.sm + 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, style: text.rowTitle),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!, style: text.meta),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              AppTextScaleGuard(
                max: 1.35,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 82,
                      child: Semantics(
                        label: label,
                        textField: true,
                        child: TextField(
                          key: fieldKey,
                          controller: controller,
                          keyboardType: keyboardType,
                          textInputAction: textInputAction,
                          textAlign: TextAlign.right,
                          onChanged: onChanged,
                          style: text.rowTitleStrong.copyWith(
                            fontSize: 14,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                          decoration: InputDecoration(
                            hintText: hint,
                            hintStyle: text.meta.copyWith(
                              color: cs.outlineVariant,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 7,
                            ),
                            filled: true,
                            fillColor: cs.surfaceContainerHighest.withValues(
                              alpha: isDark ? 0.55 : 0.6,
                            ),
                            border: fieldBorder,
                            enabledBorder: fieldBorder,
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadius.control,
                              ),
                              borderSide: BorderSide(
                                color: hasError ? cs.error : cs.primary,
                                width: 1.2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (showScoreBadge) ...[
                      const SizedBox(width: AppSpacing.sm),
                      _ScoreBadge(score: score),
                    ] else if (reserveScoreSlot)
                      const SizedBox(width: AppSpacing.sm + 48),
                  ],
                ),
              ),
            ],
          ),
          if (errorText != null) ...[
            const SizedBox(height: 4),
            Text(
              errorText!,
              style: text.meta.copyWith(color: cs.error, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}
