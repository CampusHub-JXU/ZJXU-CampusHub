import 'home_presentation.dart';

/// 外观预览 / 桌面 Widget 等非实时场景使用的示例首页数据（PRD 0.7.0 §17）。
///
/// 只提供纯展示模型，接入真实渲染组件时与线上首页共用同一套 Widget，因此
/// 示例数据变化必须与 `HomePresentation` 保持同步。
abstract final class ExampleCampusSnapshot {
  static const presentation = HomePresentation(
    weekLabel: '第 12 周',
    hero: HomeHeroPresentation(
      kind: HomeHeroKind.nextCourseToday,
      headline: '42 分钟后上课',
      timeText: '14:00',
      courseName: '高等数学 C2',
      locationText: '仁和楼 312',
      lessonText: '第 5-6 节',
    ),
    alert: null,
    status: HomeStatusPresentation(
      campusCardBalance: '32.50',
      dormElectricity: '18.4',
      hasCampusCardData: true,
      hasElectricityData: true,
      lowBalance: false,
      lowElectricity: false,
    ),
    today: HomeTodayPresentation(
      title: '今天',
      courses: [
        HomeTodayCourseRow(
          timeText: '10:10',
          lessonText: '第 3-4 节',
          courseName: '微观经济学',
          locationText: '博学楼 208',
          isOngoing: false,
        ),
        HomeTodayCourseRow(
          timeText: '14:00',
          lessonText: '第 5-6 节',
          courseName: '高等数学 C2',
          locationText: '仁和楼 312',
          isOngoing: false,
        ),
        HomeTodayCourseRow(
          timeText: '18:30',
          lessonText: '第 9-10 节',
          courseName: '大学英语',
          locationText: '外语楼 105',
          isOngoing: false,
        ),
      ],
      exams: [],
    ),
  );
}
