import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/home/models/home_presentation.dart';
import 'package:jxu_campus_hub/features/home/widgets/home_today_section.dart';

void main() {
  HomeTodayCourseRow row(String name, {bool ongoing = false}) =>
      HomeTodayCourseRow(
        timeText: '18:30',
        lessonText: '第 11-12 节',
        courseName: name,
        locationText: '梁林校区 外B-305',
        isOngoing: ongoing,
      );

  Future<void> pumpSection(
    WidgetTester tester, {
    required HomeTodayPresentation today,
    VoidCallback? onOpenSchedule,
    double textScale = 1.0,
    double width = 390,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 844),
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: HomeTodaySection(
                today: today,
                onOpenSchedule: onOpenSchedule,
              ),
            ),
          ),
        ),
      ),
    );
  }

  test('formatTodayLocation keeps campus-first order like the hero', () {
    expect(formatTodayLocation('梁林校区 铭德楼240'), '梁林校区 铭德楼240');
    expect(formatTodayLocation('越秀校区 外B-305'), '越秀校区 外B-305');
    expect(formatTodayLocation('铭德楼240'), '铭德楼240');
    expect(formatTodayLocation('梁林校区'), '梁林校区');
    expect(formatTodayLocation('  实验楼 204  '), '实验楼 204');
    expect(formatTodayLocation(''), '');
  });

  test('formatTodayLesson strips 第 prefix and whitespace', () {
    expect(formatTodayLesson('第 3-5 节'), '3-5节');
    expect(formatTodayLesson('第 11-12 节'), '11-12节');
    expect(formatTodayLesson('1-2节'), '1-2节');
    expect(formatTodayLesson(''), '');
  });

  testWidgets(
    'renders preview title and campus-first location when within cap',
    (tester) async {
      await pumpSection(
        tester,
        today: HomeTodayPresentation(
          title: '开学首日 · 9月1日 周二',
          isPreview: true,
          courses: [row('高等数学 B'), row('大学英语')],
          exams: const [],
        ),
      );

      expect(find.text('开学首日 · 9月1日 周二'), findsOneWidget);
      expect(find.text('高等数学 B'), findsOneWidget);
      expect(find.text('大学英语'), findsOneWidget);
      expect(find.text('梁林校区 外B-305'), findsNWidgets(2));
      expect(find.text('11-12节'), findsNWidgets(2));
      expect(find.text('查看全部'), findsNothing);
      // 多条时渲染时间轴导轨列。
      expect(find.byType(CustomPaint), findsAtLeastNWidgets(2));
    },
  );

  testWidgets('single entry omits the timeline rail column', (tester) async {
    await pumpSection(
      tester,
      today: HomeTodayPresentation(courses: [row('高等数学 B')], exams: const []),
    );

    expect(find.text('高等数学 B'), findsOneWidget);
    // 单条时不画时间轴（无 _TimelineRailPainter 的 CustomPaint）。
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            '${widget.painter.runtimeType}' == '_TimelineRailPainter',
      ),
      findsNothing,
    );
  });

  testWidgets(
    'omits internal 今天 title and caps at 3 rows with overflow footer',
    (tester) async {
      await pumpSection(
        tester,
        today: HomeTodayPresentation(
          courses: [row('课程一'), row('课程二'), row('课程三'), row('课程四'), row('课程五')],
          exams: const [],
        ),
        onOpenSchedule: () {},
      );

      expect(find.text('今天'), findsNothing);
      expect(find.text('课程一'), findsOneWidget);
      expect(find.text('课程三'), findsOneWidget);
      expect(find.text('课程四'), findsNothing);
      expect(find.text('课程五'), findsNothing);
      expect(find.text('查看全部'), findsOneWidget);
      expect(find.text('还有 2 条 · 见课表'), findsOneWidget);
    },
  );

  testWidgets('overflow footer triggers callback on tap', (tester) async {
    var tapped = false;
    await pumpSection(
      tester,
      today: HomeTodayPresentation(
        courses: [row('一'), row('二'), row('三'), row('四')],
        exams: const [],
      ),
      onOpenSchedule: () => tapped = true,
    );

    await tester.tap(find.text('查看全部'));
    expect(tapped, isTrue);
  });

  testWidgets('full-day form renders done rows and raises cap to 6', (
    tester,
  ) async {
    HomeTodayCourseRow namedRow(String name, {bool done = false}) =>
        HomeTodayCourseRow(
          timeText: '08:00',
          lessonText: '第 1-2 节',
          courseName: name,
          locationText: '梁林校区 教B-102',
          isOngoing: false,
          isDone: done,
        );
    await pumpSection(
      tester,
      today: HomeTodayPresentation(
        isFullDay: true,
        courses: [
          namedRow('课程一', done: true),
          namedRow('课程二', done: true),
          namedRow('课程三', done: true),
          namedRow('课程四', done: true),
          namedRow('课程五'),
          namedRow('课程六'),
          namedRow('课程七'),
        ],
        exams: const [],
      ),
      onOpenSchedule: () {},
    );

    expect(find.text('今天'), findsNothing);
    // 全天上限 6 行：前 6 门可见，第 7 门折叠进「查看全部」。
    expect(find.text('课程六'), findsOneWidget);
    expect(find.text('课程七'), findsNothing);
    expect(find.text('梁林校区 教B-102'), findsNWidgets(6));
    expect(find.text('查看全部'), findsOneWidget);
  });

  testWidgets('renders exam rows first with 今天考试 tag, no 进行中 badge', (
    tester,
  ) async {
    await pumpSection(
      tester,
      today: HomeTodayPresentation(
        exams: [
          const HomeTodayExamRow(
            timeText: '09:00-11:00',
            courseName: '微观经济学',
            locationText: '梁林校区 1教302',
          ),
        ],
        courses: [row('大学英语', ongoing: true)],
      ),
    );

    expect(find.text('微观经济学'), findsOneWidget);
    expect(find.text('今天考试'), findsOneWidget);
    expect(find.text('09:00'), findsOneWidget);
    expect(find.text('–11:00'), findsOneWidget);
    expect(find.text('梁林校区 1教302'), findsOneWidget);
    expect(find.text('进行中'), findsNothing);
    // 考试行在前、课程行在后。
    expect(
      tester.getTopLeft(find.text('微观经济学')).dy,
      lessThan(tester.getTopLeft(find.text('大学英语')).dy),
    );
  });

  testWidgets('does not overflow at 1.5x text scale on 360dp width', (
    tester,
  ) async {
    await pumpSection(
      tester,
      textScale: 1.5,
      width: 360,
      today: HomeTodayPresentation(
        exams: const [
          HomeTodayExamRow(
            timeText: '09:00-11:00',
            courseName: '宏观经济学原理与政策分析',
            locationText: '梁林校区 铭德楼240',
          ),
        ],
        courses: [
          const HomeTodayCourseRow(
            timeText: '14:00',
            lessonText: '第 6-8 节',
            courseName: '数据结构与算法设计进阶',
            locationText: '梁林校区 兴文楼308',
            isOngoing: true,
          ),
          row('大学英语视听说'),
          row('离散数学'),
        ],
      ),
      onOpenSchedule: () {},
    );

    expect(find.text('梁林校区 铭德楼240'), findsOneWidget);
    expect(find.text('梁林校区 兴文楼308'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapsed form renders single summary row without title', (
    tester,
  ) async {
    var tapped = false;
    await pumpSection(
      tester,
      today: HomeTodayPresentation(
        title: '明天',
        isPreview: true,
        isCollapsed: true,
        courses: [row('数字经济概论'), row('宏观经济学')],
        exams: const [],
      ),
      onOpenSchedule: () => tapped = true,
    );

    expect(find.text('之后还有 2 门课'), findsOneWidget);
    expect(find.text('下一门 18:30 数字经济概论'), findsOneWidget);
    // 折叠形态不渲染标题与课程行。
    expect(find.text('明天'), findsNothing);
    expect(find.text('数字经济概论'), findsNothing);
    expect(find.text('宏观经济学'), findsNothing);

    // 整行可点进课表。
    await tester.tap(find.text('之后还有 2 门课'));
    expect(tapped, isTrue);
  });

  testWidgets('collapsed form with single course omits 下一门 prefix', (
    tester,
  ) async {
    await pumpSection(
      tester,
      today: HomeTodayPresentation(
        title: '明天',
        isPreview: true,
        isCollapsed: true,
        courses: [row('宏观经济学')],
        exams: const [],
      ),
    );

    expect(find.text('之后还有 1 门课'), findsOneWidget);
    expect(find.text('18:30 宏观经济学'), findsOneWidget);
  });
}
