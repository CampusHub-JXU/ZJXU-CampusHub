/// 稳定的 CampusAction ID 命名空间（PRD 0.7.0 §5）。
///
/// Action ID 一旦发布不得重命名：Widget / Shortcut / Deep Link 均引用它。
abstract final class CampusActionIds {
  static const scheduleOpen = 'schedule.open';
  static const scheduleToday = 'schedule.today';

  static const gradesOpen = 'grades.open';
  static const examOpen = 'exam.open';
  static const academicProgressOpen = 'academic-progress.open';
  static const academicWebOpen = 'academic-web.open';

  static const shuatiOpen = 'shuati.open';
  static const secondClassroomOpen = 'second-classroom.open';

  static const campusCardOpen = 'campus-card.open';
  static const campusCardPayment = 'campus-card.payment';
  static const campusCardRecharge = 'campus-card.recharge';
  static const campusCardResetPassword = 'campus-card.reset-password';

  static const electricityOpen = 'electricity.open';
  static const electricityRecharge = 'electricity.recharge';

  static const libraryOpen = 'library.open';

  static const noticeInbox = 'notice.inbox';
  static const notificationCenter = 'notification.center';

  static const serviceHallOpen = 'service-hall.open';
  static const changxingJiadaOpen = 'changxing-jiada.open';
  static const sjjxNoticeOpen = 'sjjx-notice.open';

  static const oneStopServiceOpen = 'one-stop-service.open';
  static const microLifeOpen = 'micro-life.open';
  static const physicalTestOpen = 'physical-test.open';
}
