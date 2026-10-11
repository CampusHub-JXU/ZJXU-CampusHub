import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/app_design_tokens.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_builder.dart';

/// Issue #51：`SegmentedButton` 统一外观（主题级 `segmentedButtonTheme`）契约。
///
/// 目标（见 issue #51 / docs/segmented-control-style.md）：
/// * 扁平、紧凑、低对比的圆角矩形分段，**不是** MD3 默认的 StadiumBorder 胶囊；
/// * **无**显眼外框、**无**段间分隔线（两者都由 `ButtonStyle.side` 驱动）；
/// * 选中用 `surfaceContainerHigh`、未选中用 `surfaceContainer`（中性面阶），
///   字色以 `onSurface` / `onSurfaceVariant` 区分主次；
/// * 视觉高度 40，移动端命中区由框架补到 48；大字号自然增高、不裁剪；
/// * 保留 `SegmentedButton<T>` 原生语义（keys / selected / emptySelectionAllowed /
///   multiSelectionEnabled / disabled 段不可点）。

const Color _brandRed = Color(0xFF8B1A2D);
const Color _graphite = Color(0xFF455A64);
const Color _customBlue = Color(0xFF1565C0);

const Set<WidgetState> _none = <WidgetState>{};
const Set<WidgetState> _selected = <WidgetState>{WidgetState.selected};
const Set<WidgetState> _disabled = <WidgetState>{WidgetState.disabled};
const Set<WidgetState> _hovered = <WidgetState>{WidgetState.hovered};
const Set<WidgetState> _pressed = <WidgetState>{WidgetState.pressed};
const Set<WidgetState> _focused = <WidgetState>{WidgetState.focused};

/// 主题级内建索引：绕开 SegmentedButton 的 build，直接读 `ThemeData` 里的
/// `segmentedButtonTheme.style`（与线上同一份数据）。
Map<String, ThemeData> _themes() => <String, ThemeData>{
  'light-red': AppThemeBuilder.light(_brandRed),
  'dark-red': AppThemeBuilder.dark(_brandRed),
  'light-graphite': AppThemeBuilder.light(_graphite),
  'dark-graphite': AppThemeBuilder.dark(_graphite),
  'light-blue': AppThemeBuilder.light(_customBlue),
  'dark-blue': AppThemeBuilder.dark(_customBlue),
  'dark-pureBlack': AppThemeBuilder.dark(_brandRed, pureBlack: true),
};

BorderRadius _shapeRadius(OutlinedBorder border) {
  expect(border, isA<RoundedRectangleBorder>());
  final radius = (border as RoundedRectangleBorder).borderRadius;
  expect(radius, isA<BorderRadius>());
  return radius as BorderRadius;
}

EdgeInsets _padding(ButtonStyle style) {
  final value = style.padding!.resolve(_none);
  expect(value, isA<EdgeInsets>());
  return value as EdgeInsets;
}

void main() {
  group('主题契约（浅 / 深 / 纯黑 × 中性 / 自定义种子）', () {
    for (final entry in _themes().entries) {
      final name = entry.key;
      final theme = entry.value;
      final scheme = theme.colorScheme;
      final style = theme.segmentedButtonTheme.style!;

      test('$name：注册了 segmentedButtonTheme', () {
        expect(theme.segmentedButtonTheme.style, isNotNull);
      });

      test('$name：圆角矩形替代 StadiumBorder，无外框 / 无分隔线', () {
        for (final states in [_none, _selected, _hovered, _pressed, _focused]) {
          final shape = style.shape!.resolve(states)!;
          expect(shape, isA<RoundedRectangleBorder>(), reason: '$states');
          expect(shape, isNot(isA<StadiumBorder>()), reason: '$states');
          expect(
            _shapeRadius(shape).topLeft.x,
            AppRadius.segment,
            reason: '$states',
          );
          expect(_shapeRadius(shape).bottomRight.x, AppRadius.segment);
        }
        expect(style.shape!.resolve(_disabled), isA<RoundedRectangleBorder>());

        // side == BorderSide.none：外框不画，段间分隔线同样不可见
        // （渲染盒用 side 画分隔线，见 segmented_button.dart paint）。
        for (final states in [
          _none,
          _selected,
          _hovered,
          _pressed,
          _focused,
          _disabled,
        ]) {
          final side = style.side!.resolve(states)!;
          expect(side.width, 0, reason: '$states');
          expect(side.style, BorderStyle.none, reason: '$states');
          expect(
            side.copyWith(strokeAlign: 0).toPaint().color.a,
            0,
            reason: '分隔线 paint 必须完全透明 @ $states',
          );
        }
      });

      test('$name：面阶 = surfaceContainer / 选中 surfaceContainerHigh', () {
        expect(
          style.backgroundColor!.resolve(_selected),
          scheme.surfaceContainerHigh,
        );
        expect(style.backgroundColor!.resolve(_none), scheme.surfaceContainer);
        expect(
          style.backgroundColor!.resolve(_hovered),
          scheme.surfaceContainer,
        );
        // 选中与未选中不是同一块面（可辨识）。
        expect(
          style.backgroundColor!.resolve(_selected),
          isNot(style.backgroundColor!.resolve(_none)),
        );
      });

      test('$name：字色主次分明、disabled 降低对比但不透明', () {
        expect(style.foregroundColor!.resolve(_selected), scheme.onSurface);
        expect(style.foregroundColor!.resolve(_none), scheme.onSurfaceVariant);
        expect(
          style.foregroundColor!.resolve(_selected),
          isNot(style.foregroundColor!.resolve(_none)),
        );

        final disabledFg = style.foregroundColor!.resolve(_disabled)!;
        expect(disabledFg.a, closeTo(0.38, 0.001));
        expect(disabledFg.a, greaterThan(0.0), reason: 'disabled 也必须可见');
        // disabled 不等于正常态字色。
        expect(disabledFg, isNot(style.foregroundColor!.resolve(_none)));
      });

      test('$name：hover / pressed / focus 有反馈，disabled 无叠加', () {
        final hover = style.overlayColor!.resolve(_hovered);
        final pressed = style.overlayColor!.resolve(_pressed);
        final focused = style.overlayColor!.resolve(_focused);

        for (final overlay in [hover, pressed, focused]) {
          expect(overlay, isNotNull);
          expect(overlay!.a, greaterThan(0.0));
        }
        // 三态互不相同（反馈清晰）。
        expect(hover, isNot(pressed));
        expect(focused, isNot(pressed));
        // 键盘 focus 用主色淡化，功能性焦点提示（非装饰性描边）。
        expect(focused!.r, closeTo(scheme.primary.r, 0.02));
        expect(focused.g, closeTo(scheme.primary.g, 0.02));
        expect(focused.b, closeTo(scheme.primary.b, 0.02));

        expect(style.overlayColor!.resolve(_disabled)!.a, 0);
      });

      test('$name：紧凑尺寸语义（视觉 40 / 命中由框架补到 48）', () {
        expect(style.minimumSize!.resolve(_none)!.height, 40);
        expect(_padding(style).vertical, 16, reason: '上下各 8');
        expect(_padding(style).horizontal, 32);
        expect(style.elevation!.resolve(_none), 0);
        expect(style.surfaceTintColor!.resolve(_none), Colors.transparent);
        expect(style.iconSize!.resolve(_none), 18);

        // 标签字号决定框架的视觉高度算式（fontSize + padding.vertical 与 40 取 max）。
        final label = style.textStyle!.resolve(_none)!;
        expect(label.fontSize, 14);
        expect(label.fontWeight, FontWeight.w500);
        expect(
          style.textStyle!.resolve(_selected)!.fontWeight,
          FontWeight.w600,
        );
        expect(label.fontFamily, 'Inter');
      });
    }
  });

  group('布局 / 行为（真实主题下渲染）', () {
    final light = AppThemeBuilder.light(_brandRed);
    final dark = AppThemeBuilder.dark(_brandRed);

    Future<void> pump(
      WidgetTester tester,
      Widget child, {
      ThemeData? theme,
      Size size = const Size(400, 400),
      double scale = 1.0,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme ?? light,
          builder: (context, widget) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: widget!,
          ),
          home: Scaffold(
            body: Center(child: SizedBox(width: 360, child: child)),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('2 段：命中高度 ≥ 48、视觉高度 40、无溢出', (tester) async {
      await pump(
        tester,
        SegmentedButton<bool>(
          segments: const <ButtonSegment<bool>>[
            ButtonSegment<bool>(value: false, label: Text('借阅中')),
            ButtonSegment<bool>(value: true, label: Text('历史借阅')),
          ],
          selected: const <bool>{false},
          onSelectionChanged: (_) {},
        ),
      );

      expect(tester.takeException(), isNull);
      final size = tester.getSize(find.byType(SegmentedButton<bool>));
      // 移动端 padded 命中区补到 48；渲染盒把可视框内缩 8 → 视觉 40。
      expect(size.height, greaterThanOrEqualTo(48.0));
      expect(size.height - 8.0, closeTo(40.0, 0.001));
      expect(find.text('借阅中'), findsOneWidget);
      expect(find.text('历史借阅'), findsOneWidget);
    });

    testWidgets('3 段：命中高度 ≥ 48、无溢出（浅 / 深）', (tester) async {
      for (final theme in [light, dark]) {
        await pump(
          tester,
          SegmentedButton<int>(
            segments: const <ButtonSegment<int>>[
              ButtonSegment<int>(value: 0, label: Text('正常报到')),
              ButtonSegment<int>(value: 1, label: Text('暂缓报到')),
              ButtonSegment<int>(value: 2, label: Text('不报到')),
            ],
            selected: const <int>{},
            emptySelectionAllowed: true,
            onSelectionChanged: (_) {},
          ),
          theme: theme,
        );
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byType(SegmentedButton<int>)).height,
          greaterThanOrEqualTo(48.0),
        );
      }
    });

    testWidgets('字号 1.5 / 2.0 + 360 宽 + 横屏：不截断、不溢出', (tester) async {
      for (final scale in [1.5, 2.0]) {
        for (final size in [const Size(360, 720), const Size(780, 360)]) {
          await pump(
            tester,
            SegmentedButton<int>(
              segments: const <ButtonSegment<int>>[
                ButtonSegment<int>(value: 0, label: Text('课程成绩')),
                ButtonSegment<int>(value: 1, label: Text('学业进度')),
                ButtonSegment<int>(value: 2, label: Text('第二课堂')),
              ],
              selected: const <int>{1},
              onSelectionChanged: (_) {},
            ),
            size: size,
            scale: scale,
          );
          expect(
            tester.takeException(),
            isNull,
            reason: 'scale=$scale size=$size',
          );
          for (final label in ['课程成绩', '学业进度', '第二课堂']) {
            expect(find.text(label), findsOneWidget, reason: 'scale=$scale');
            final box = tester.getSize(find.text(label));
            expect(box.width, greaterThan(0));
            expect(box.height, greaterThan(0));
          }
          // 大字号下按钮自然增高，命中区不会反而缩小。
          expect(
            tester.getSize(find.byType(SegmentedButton<int>)).height,
            greaterThanOrEqualTo(48.0),
            reason: 'scale=$scale size=$size',
          );
        }
      }
    });

    testWidgets('2/3 段 + icon（设置主题模式同款）：无溢出', (tester) async {
      for (final scale in [1.0, 1.5, 2.0]) {
        await pump(
          tester,
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const <ButtonSegment<int>>[
              ButtonSegment<int>(
                value: 0,
                icon: Icon(Icons.sync),
                label: Text('自动'),
              ),
              ButtonSegment<int>(
                value: 1,
                icon: Icon(Icons.light_mode),
                label: Text('浅色'),
              ),
              ButtonSegment<int>(
                value: 2,
                icon: Icon(Icons.dark_mode),
                label: Text('深色'),
              ),
            ],
            selected: const <int>{0},
            onSelectionChanged: (_) {},
          ),
          size: const Size(360, 600),
          scale: scale,
        );
        expect(tester.takeException(), isNull, reason: 'scale=$scale');
      }
    });

    testWidgets('选择语义：点击切换、emptySelectionAllowed 可清空', (tester) async {
      Set<int>? last;
      Widget build(Set<int> selected) => SegmentedButton<int>(
        segments: const <ButtonSegment<int>>[
          ButtonSegment<int>(value: 0, label: Text('A')),
          ButtonSegment<int>(value: 1, label: Text('B')),
        ],
        selected: selected,
        emptySelectionAllowed: true,
        onSelectionChanged: (value) => last = value,
      );

      await pump(tester, build(const <int>{0}));
      await tester.tap(find.text('B'));
      await tester.pump();
      expect(last, <int>{1});

      // 再点已选中的一段：emptySelectionAllowed → 清空。
      await pump(tester, build(const <int>{1}));
      await tester.tap(find.text('B'));
      await tester.pump();
      expect(last, isEmpty);
    });

    testWidgets('多选语义保持不变', (tester) async {
      Set<int>? last;
      await pump(
        tester,
        SegmentedButton<int>(
          multiSelectionEnabled: true,
          segments: const <ButtonSegment<int>>[
            ButtonSegment<int>(value: 0, label: Text('A')),
            ButtonSegment<int>(value: 1, label: Text('B')),
          ],
          selected: const <int>{0},
          onSelectionChanged: (value) => last = value,
        ),
      );
      await tester.tap(find.text('B'));
      await tester.pump();
      expect(last, <int>{0, 1});
    });

    testWidgets('disabled 段不可点', (tester) async {
      var calls = 0;
      await pump(
        tester,
        SegmentedButton<int>(
          segments: const <ButtonSegment<int>>[
            ButtonSegment<int>(value: 0, label: Text('已显示 0'), enabled: false),
            ButtonSegment<int>(value: 1, label: Text('待确认 2')),
          ],
          selected: const <int>{1},
          onSelectionChanged: (_) => calls++,
        ),
      );
      await tester.tap(find.text('已显示 0'), warnIfMissed: false);
      await tester.pump();
      expect(calls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('键盘 focus 可达分段内部且不抛异常', (tester) async {
      await pump(
        tester,
        SegmentedButton<bool>(
          segments: const <ButtonSegment<bool>>[
            ButtonSegment<bool>(value: false, label: Text('借阅中')),
            ButtonSegment<bool>(value: true, label: Text('历史借阅')),
          ],
          selected: const <bool>{false},
          onSelectionChanged: (_) {},
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(tester.takeException(), isNull);
      final focus = FocusManager.instance.primaryFocus;
      expect(focus, isNotNull);
    });

    testWidgets('真实调用方配置在真实主题下均无溢出（浅 / 深）', (tester) async {
      for (final theme in [light, dark]) {
        for (final config in _callerConfigs()) {
          await pump(tester, config, theme: theme, size: const Size(360, 640));
          expect(tester.takeException(), isNull);
        }
      }
    });
  });
}

/// 复刻线上各调用点的 `SegmentedButton` 配置（仅 UI 形状，不含业务回调）。
List<Widget> _callerConfigs() => <Widget>[
  // grades_page.dart:460
  SegmentedButton<int>(
    key: const Key('grades_view_switch'),
    showSelectedIcon: false,
    segments: const <ButtonSegment<int>>[
      ButtonSegment<int>(value: 0, label: Text('课程成绩')),
      ButtonSegment<int>(value: 1, label: Text('学业进度')),
    ],
    selected: const <int>{0},
    onSelectionChanged: (_) {},
  ),
  // library_borrows_page.dart:195
  SegmentedButton<bool>(
    segments: const <ButtonSegment<bool>>[
      ButtonSegment<bool>(value: false, label: Text('借阅中')),
      ButtonSegment<bool>(value: true, label: Text('历史借阅')),
    ],
    selected: const <bool>{false},
    onSelectionChanged: (_) {},
  ),
  // schedule_change_sheet.dart:145
  SegmentedButton<int>(
    key: const Key('schedule_change_segments'),
    showSelectedIcon: false,
    segments: const <ButtonSegment<int>>[
      ButtonSegment<int>(value: 0, label: Text('已显示 2'), enabled: false),
      ButtonSegment<int>(value: 1, label: Text('待确认 3')),
    ],
    selected: const <int>{1},
    onSelectionChanged: (_) {},
  ),
  // theme_settings_sections.dart:77
  SegmentedButton<int>(
    showSelectedIcon: false,
    segments: const <ButtonSegment<int>>[
      ButtonSegment<int>(value: 0, icon: Icon(Icons.sync), label: Text('自动')),
      ButtonSegment<int>(
        value: 1,
        icon: Icon(Icons.light_mode),
        label: Text('浅色'),
      ),
      ButtonSegment<int>(
        value: 2,
        icon: Icon(Icons.dark_mode),
        label: Text('深色'),
      ),
    ],
    selected: const <int>{0},
    onSelectionChanged: (_) {},
  ),
  // theme_settings_sections.dart:188（跟随系统 / 深色文字 / 浅色文字）
  SegmentedButton<int>(
    showSelectedIcon: false,
    segments: const <ButtonSegment<int>>[
      ButtonSegment<int>(value: 0, label: Text('跟随系统')),
      ButtonSegment<int>(value: 1, label: Text('深色文字')),
      ButtonSegment<int>(value: 2, label: Text('浅色文字')),
    ],
    selected: const <int>{0},
    onSelectionChanged: (_) {},
  ),
  // personalization_page.dart:122（带本地 compact 覆盖）
  SegmentedButton<int>(
    key: const Key('personalization_scene_segments'),
    showSelectedIcon: false,
    style: const ButtonStyle(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    segments: const <ButtonSegment<int>>[
      ButtonSegment<int>(value: 0, label: Text('主页')),
      ButtonSegment<int>(value: 1, label: Text('功能')),
      ButtonSegment<int>(value: 2, label: Text('我的')),
    ],
    selected: const <int>{0},
    onSelectionChanged: (_) {},
  ),
  // personalization_background_section.dart:182（可空选）
  SegmentedButton<int>(
    key: const Key('personalization_fit_segments'),
    showSelectedIcon: false,
    emptySelectionAllowed: true,
    segments: const <ButtonSegment<int>>[
      ButtonSegment<int>(value: 0, label: Text('铺满')),
      ButtonSegment<int>(value: 1, label: Text('适应')),
      ButtonSegment<int>(value: 2, label: Text('居中')),
    ],
    selected: const <int>{},
    onSelectionChanged: (_) {},
  ),
  // changxing_back_school_form_page.dart:286（可空选，只读校验不修改）
  SegmentedButton<int>(
    emptySelectionAllowed: true,
    segments: const <ButtonSegment<int>>[
      ButtonSegment<int>(value: 0, label: Text('正常报到')),
      ButtonSegment<int>(value: 1, label: Text('暂缓报到')),
      ButtonSegment<int>(value: 2, label: Text('不报到')),
    ],
    selected: const <int>{},
    onSelectionChanged: (_) {},
  ),
];
