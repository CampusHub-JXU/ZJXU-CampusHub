import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_feedback.dart';

/// 底部弹出「选择开学日」中文三列滚轮选择器。
///
/// 返回用户确认后的日期（仅保留年月日），点取消或遮罩关闭返回 `null`。
Future<DateTime?> showSemesterStartPickerSheet(
  BuildContext context, {
  required DateTime initialDate,
}) {
  return AppFeedback.sheet<DateTime>(
    context,
    scrollControlled: true,
    builder: (context) => _SemesterStartPickerSheet(initialDate: initialDate),
  );
}

class _SemesterStartPickerSheet extends StatefulWidget {
  const _SemesterStartPickerSheet({required this.initialDate});

  final DateTime initialDate;

  @override
  State<_SemesterStartPickerSheet> createState() =>
      _SemesterStartPickerSheetState();
}

class _SemesterStartPickerSheetState extends State<_SemesterStartPickerSheet> {
  static const double _wheelItemExtent = 44;
  static const int _visibleWheelRows = 5;
  static const List<String> _weekdayLabels = [
    '周一',
    '周二',
    '周三',
    '周四',
    '周五',
    '周六',
    '周日',
  ];

  late List<int> _years;
  late int _year;
  late int _month;
  late int _day;

  late final FixedExtentScrollController _yearController;
  late final FixedExtentScrollController _monthController;
  late final FixedExtentScrollController _dayController;

  bool _isProgrammaticMove = false;

  @override
  void initState() {
    super.initState();
    final initial = DateTime(
      widget.initialDate.year,
      widget.initialDate.month,
      widget.initialDate.day,
    );
    final currentYear = DateTime.now().year;
    final minYear = math.min(currentYear - 2, initial.year);
    final maxYear = math.max(currentYear + 2, initial.year);

    _years = List<int>.generate(
      maxYear - minYear + 1,
      (index) => minYear + index,
    );
    _year = initial.year;
    _month = initial.month;
    _day = initial.day;

    _yearController = FixedExtentScrollController(
      initialItem: _years.indexOf(_year),
    );
    _monthController = FixedExtentScrollController(initialItem: _month - 1);
    _dayController = FixedExtentScrollController(initialItem: _day - 1);
  }

  @override
  void dispose() {
    _yearController.dispose();
    _monthController.dispose();
    _dayController.dispose();
    super.dispose();
  }

  DateTime get _selectedDate => DateTime(_year, _month, _day);

  int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

  String _weekdayLabel(DateTime date) => _weekdayLabels[date.weekday - 1];

  void _onYearChanged(int index) {
    if (_isProgrammaticMove || index < 0 || index >= _years.length) return;
    final nextYear = _years[index];
    if (nextYear == _year) return;
    _updateYearMonth(year: nextYear, month: _month);
  }

  void _onMonthChanged(int index) {
    if (_isProgrammaticMove || index < 0 || index >= 12) return;
    final nextMonth = index + 1;
    if (nextMonth == _month) return;
    _updateYearMonth(year: _year, month: nextMonth);
  }

  void _onDayChanged(int index) {
    if (_isProgrammaticMove) return;
    final maxDay = _daysInMonth(_year, _month);
    final nextDay = (index + 1).clamp(1, maxDay);
    if (nextDay == _day) return;
    setState(() => _day = nextDay);
    HapticFeedback.selectionClick();
  }

  void _updateYearMonth({required int year, required int month}) {
    final maxDay = _daysInMonth(year, month);
    final clampedDay = _day.clamp(1, maxDay);
    final dayClamped = clampedDay != _day;

    setState(() {
      _year = year;
      _month = month;
      _day = clampedDay;
    });
    HapticFeedback.selectionClick();

    if (dayClamped) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_dayController.hasClients) return;
        unawaited(_animateWheelTo(_dayController, clampedDay - 1));
      });
    }
  }

  Future<void> _animateWheelTo(
    FixedExtentScrollController controller,
    int targetIndex,
  ) async {
    if (!controller.hasClients) return;
    _isProgrammaticMove = true;
    try {
      await controller.animateToItem(
        targetIndex,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    } finally {
      _isProgrammaticMove = false;
    }
  }

  void _alignToMonday() {
    final current = _selectedDate;
    if (current.weekday == DateTime.monday) return;

    final monday = current.subtract(
      Duration(days: current.weekday - DateTime.monday),
    );
    var prependedYear = false;
    if (monday.year < _years.first) {
      _years = [for (int y = monday.year; y < _years.first; y++) y, ..._years];
      prependedYear = true;
    }

    setState(() {
      _year = monday.year;
      _month = monday.month;
      _day = monday.day;
    });
    HapticFeedback.selectionClick();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (prependedYear && _yearController.hasClients) {
        _yearController.jumpToItem(
          _years.indexOf(current.year).clamp(0, _years.length - 1),
        );
      }

      _isProgrammaticMove = true;
      try {
        final animations = <Future<void>>[];
        final yearIndex = _years.indexOf(_year);
        if (_yearController.hasClients && yearIndex >= 0) {
          animations.add(
            _yearController.animateToItem(
              yearIndex,
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
            ),
          );
        }
        if (_monthController.hasClients) {
          animations.add(
            _monthController.animateToItem(
              _month - 1,
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
            ),
          );
        }
        if (_dayController.hasClients) {
          animations.add(
            _dayController.animateToItem(
              _day - 1,
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
            ),
          );
        }
        await Future.wait(animations);
      } finally {
        _isProgrammaticMove = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final appText = context.appText;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    final selected = _selectedDate;
    final isMonday = selected.weekday == DateTime.monday;
    final dayCount = _daysInMonth(_year, _month);

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, bottomInset + 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.calendar_today_outlined, color: colors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '选择开学日',
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32),
              child: Row(
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '$_year 年 $_month 月 $_day 日',
                            style: appText.body.copyWith(
                              color: colors.onSurface,
                              fontWeight: FontWeight.w500,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          TextSpan(
                            text: ' · ${_weekdayLabel(selected)}',
                            style: appText.body.copyWith(
                              color: isMonday
                                  ? colors.primary
                                  : colors.onSurfaceVariant,
                              fontWeight: isMonday
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  ExcludeSemantics(
                    excluding: isMonday,
                    child: IgnorePointer(
                      ignoring: isMonday,
                      child: AnimatedOpacity(
                        opacity: isMonday ? 0 : 1,
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOut,
                        child: Padding(
                          key: const ValueKey('align-monday-button'),
                          padding: const EdgeInsets.only(left: 8),
                          child: _AlignMondayCapsule(onTap: _alignToMonday),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: _wheelItemExtent * _visibleWheelRows,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  IgnorePointer(
                    child: Container(
                      height: _wheelItemExtent,
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(
                          alpha: isDark ? 0.16 : 0.08,
                        ),
                        borderRadius: BorderRadius.circular(AppRadius.card),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        flex: 13,
                        child: _WheelColumn(
                          key: const ValueKey('semester-year-wheel'),
                          controller: _yearController,
                          itemCount: _years.length,
                          selectedIndex: _years.indexOf(_year),
                          itemExtent: _wheelItemExtent,
                          labelBuilder: (index) => '${_years[index]} 年',
                          onSelectedItemChanged: _onYearChanged,
                        ),
                      ),
                      Expanded(
                        flex: 10,
                        child: _WheelColumn(
                          key: const ValueKey('semester-month-wheel'),
                          controller: _monthController,
                          itemCount: 12,
                          selectedIndex: _month - 1,
                          itemExtent: _wheelItemExtent,
                          labelBuilder: (index) =>
                              '${(index + 1).toString().padLeft(2, '0')} 月',
                          onSelectedItemChanged: _onMonthChanged,
                        ),
                      ),
                      Expanded(
                        flex: 10,
                        child: _WheelColumn(
                          key: const ValueKey('semester-day-wheel'),
                          controller: _dayController,
                          itemCount: dayCount,
                          selectedIndex: _day - 1,
                          itemExtent: _wheelItemExtent,
                          labelBuilder: (index) =>
                              '${(index + 1).toString().padLeft(2, '0')} 日',
                          onSelectedItemChanged: _onDayChanged,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(selected),
                  child: const Text('确定'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AlignMondayCapsule extends StatelessWidget {
  const _AlignMondayCapsule({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Semantics(
      button: true,
      label: '对齐周一',
      child: Material(
        color: colors.primaryContainer.withValues(alpha: isDark ? 0.55 : 0.78),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              '对齐周一',
              style: context.appText.tag.copyWith(
                color: colors.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WheelColumn extends StatelessWidget {
  const _WheelColumn({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.selectedIndex,
    required this.itemExtent,
    required this.labelBuilder,
    required this.onSelectedItemChanged,
  });

  final FixedExtentScrollController controller;
  final int itemCount;
  final int selectedIndex;
  final double itemExtent;
  final String Function(int index) labelBuilder;
  final ValueChanged<int> onSelectedItemChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appText = context.appText;

    return ListWheelScrollView.useDelegate(
      controller: controller,
      itemExtent: itemExtent,
      physics: const FixedExtentScrollPhysics(),
      diameterRatio: 1.35,
      perspective: 0.003,
      squeeze: 1.04,
      overAndUnderCenterOpacity: 0.38,
      onSelectedItemChanged: onSelectedItemChanged,
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: itemCount,
        builder: (context, index) {
          final isSelected = index == selectedIndex;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (!controller.hasClients || index == selectedIndex) return;
              unawaited(
                controller.animateToItem(
                  index,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                ),
              );
            },
            child: Center(
              child: Text(
                labelBuilder(index),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: (isSelected ? appText.rowTitleStrong : appText.rowTitle)
                    .copyWith(
                      color: isSelected
                          ? colors.onSurface
                          : colors.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
              ),
            ),
          );
        },
      ),
    );
  }
}
