import '../auth/cas_auth_broker.dart';
import '../config/app_config.dart';
import '../epay100/epay100_gateway.dart';
import 'campus_action.dart';
import 'campus_action_ids.dart';

/// Action Registry：稳定 Action ID → 启动目标（PRD 0.7.0 §5、§7）。
///
/// 平台启动细节全部集中在这里，Feature Catalog 只保存 action id，不理解
/// Route / WeChat / WebView。
class CampusActionRegistry {
  CampusActionRegistry._();

  static final CampusActionRegistry instance = CampusActionRegistry._();

  static const _resetPasswordUrl =
      'https://webvpn.zjxu.edu.cn/https/77726476706e69737468656265737421fef2569f267e725a661dc7a99c406d362a/security/start/index.html#/business/security/mResetPassword';

  static const _oneStopServiceUrl =
      'https://webvpn.zjxu.edu.cn/https/77726476706e69737468656265737421e3e05b84692a62486b468ca88d1b203b/';

  static const _microLifeUrl =
      'http://jdhq.wap.zjxu.edu.cn/Base/Center/center/account_id/6';

  late final Map<String, CampusAction> _byId = {
    for (final action in _build()) action.id: action,
  };

  CampusAction? findById(String id) => _byId[id.trim()];

  Iterable<CampusAction> get all => _byId.values;

  bool contains(String id) => _byId.containsKey(id.trim());

  static List<CampusAction> _build() => [
    const CampusAction(
      id: CampusActionIds.scheduleOpen,
      title: '课表',
      target: RouteActionTarget('schedule'),
    ),
    const CampusAction(
      id: CampusActionIds.scheduleToday,
      title: '今日课表',
      target: RouteActionTarget('schedule'),
    ),
    const CampusAction(
      id: CampusActionIds.gradesOpen,
      title: '成绩查询',
      target: RouteActionTarget('grades'),
    ),
    const CampusAction(
      id: CampusActionIds.examOpen,
      title: '考试安排',
      target: RouteActionTarget('exam'),
    ),
    const CampusAction(
      id: CampusActionIds.shuatiOpen,
      title: '刷题助手',
      target: RouteActionTarget('shuati-practice'),
    ),
    const CampusAction(
      id: CampusActionIds.secondClassroomOpen,
      title: '第二课堂',
      target: RouteActionTarget('second-classroom'),
    ),
    const CampusAction(
      id: CampusActionIds.campusCardOpen,
      title: '一卡通',
      target: RouteActionTarget('campus-card'),
    ),
    const CampusAction(
      id: CampusActionIds.campusCardPayment,
      title: '付款码',
      target: RouteActionTarget('campus-card-payment'),
    ),
    CampusAction(
      id: CampusActionIds.campusCardRecharge,
      title: '一卡通充值',
      target: WechatActionTarget(AppConfig.xiaofubaoRechargeUri.toString()),
    ),
    const CampusAction(
      id: CampusActionIds.campusCardResetPassword,
      title: '忘记密码',
      target: ProtectedWebActionTarget(_resetPasswordUrl),
    ),
    const CampusAction(
      id: CampusActionIds.electricityOpen,
      title: '宿舍电费',
      target: RouteActionTarget('dorm-electricity'),
    ),
    const CampusAction(
      id: CampusActionIds.electricityRecharge,
      title: '电费充值',
      target: WechatActionTarget(HeadlessEpay100Gateway.rechargeUrl),
    ),
    CampusAction(
      id: CampusActionIds.libraryOpen,
      title: '图书馆',
      target: WechatActionTarget(CasService.librarySso.serviceUrl),
    ),
    const CampusAction(
      id: CampusActionIds.noticeInbox,
      title: '校园公告',
      target: RouteActionTarget('notice-list'),
    ),
    const CampusAction(
      id: CampusActionIds.notificationCenter,
      title: '通知中心',
      target: RouteActionTarget('notification-center'),
    ),
    const CampusAction(
      id: CampusActionIds.serviceHallOpen,
      title: '服务大厅',
      target: RouteActionTarget('service-hall'),
    ),
    const CampusAction(
      id: CampusActionIds.changxingJiadaOpen,
      title: '畅行嘉大',
      target: RouteActionTarget('changxing-jiada'),
    ),
    const CampusAction(
      id: CampusActionIds.sjjxNoticeOpen,
      title: '实践通知',
      target: RouteActionTarget('sjjx-notice-list'),
    ),
    const CampusAction(
      id: CampusActionIds.oneStopServiceOpen,
      title: '校务服务',
      target: ProtectedWebActionTarget(_oneStopServiceUrl),
    ),
    const CampusAction(
      id: CampusActionIds.microLifeOpen,
      title: '嘉大微生活',
      target: WebActionTarget(_microLifeUrl),
    ),
  ];
}
