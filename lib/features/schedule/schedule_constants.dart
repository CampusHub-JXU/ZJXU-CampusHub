const scheduleWeekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];
const scheduleWeekCount = 20;
const scheduleSlotCount = 13;
const scheduleGridSlotColumnWidth = 48.0;
const scheduleGridSlotHeight = 68.0;
const scheduleUnknownText = '待定';
const scheduleUnknownTimeText = '??';
const scheduleInactiveWeekTag = '非本周';
const scheduleTermLabelPrefix = '第';
const scheduleWeekLabelSuffix = '周';
const scheduleCurrentWeekLabel = '本周';
const scheduleNonCurrentWeekLabel = '非本周';
const scheduleNotStartedLabel = '未开学';
const scheduleSlotTimes = [
  ['08:00', '08:40'],
  ['08:45', '09:25'],
  ['09:45', '10:25'],
  ['10:30', '11:10'],
  ['11:15', '11:55'],
  ['13:30', '14:10'],
  ['14:15', '14:55'],
  ['15:15', '15:55'],
  ['16:00', '16:40'],
  ['16:45', '17:25'],
  ['18:30', '19:10'],
  ['19:15', '19:55'],
  ['20:00', '20:40'],
];

const scheduleCourseTypeLabels = {
  '★': '实践',
  '◆': '理论',
  '□': '线上',
  '●': '上机',
  '◇': '实验',
};

String scheduleCourseTypeLabel(String typeSymbol) {
  return scheduleCourseTypeLabels[typeSymbol] ?? '未知类型';
}
