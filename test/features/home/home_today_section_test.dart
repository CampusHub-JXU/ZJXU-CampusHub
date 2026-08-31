import 'package:flutter/material.dart';
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
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeTodaySection(today: today, onOpenSchedule: onOpenSchedule),
        ),
      ),
    );
  }

  testWidgets('renders all rows and title when within cap', (tester) async {
    await pumpSection(
      tester,
      today: HomeTodayPresentation(
        title: '开学首日 · 9月1日 周二',
        courses: [row('高等数学 B'), row('大学英语')],
        exams: const [],
      ),
    );

    expect(find.text('开学首日 · 9月1日 周二'), findsOneWidget);
    expect(find.text('高等数学 B'), findsOneWidget);
    expect(find.text('大学英语'), findsOneWidget);
    expect(find.text('查看全部'), findsNothing);
  });

  testWidgets('caps at 3 rows with overflow footer', (tester) async {
    await pumpSection(
      tester,
      today: HomeTodayPresentation(
        courses: [row('课程一'), row('课程二'), row('课程三'), row('课程四'), row('课程五')],
        exams: const [],
      ),
      onOpenSchedule: () {},
    );

    expect(find.text('今天'), findsOneWidget);
    expect(find.text('课程一'), findsOneWidget);
    expect(find.text('课程三'), findsOneWidget);
    expect(find.text('课程四'), findsNothing);
    expect(find.text('课程五'), findsNothing);
    expect(find.text('查看全部'), findsOneWidget);
    expect(find.text('还有 2 条 · 见课表'), findsOneWidget);
  });

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

  testWidgets('renders ongoing badge and exam rows first', (tester) async {
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
    expect(find.text('进行中'), findsOneWidget);
    // 考试行在前、课程行在后。
    expect(
      tester.getTopLeft(find.text('微观经济学')).dy,
      lessThan(tester.getTopLeft(find.text('大学英语')).dy),
    );
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
