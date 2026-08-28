import '../../core/wechat/wechat_launcher.dart';

class SecondClassroomWechatLauncher {
  SecondClassroomWechatLauncher._();

  static final SecondClassroomWechatLauncher instance =
      SecondClassroomWechatLauncher._();

  Future<bool> openUrl(String url) async {
    return WechatLauncher.instance.openUrl(url);
  }
}
