import 'package:flutter/material.dart';

import 'appearance_page.dart';

/// 兼容保留的个性化入口：已与 [AppearancePage] 合并为「外观与个性化」。
class PersonalizationPage extends StatelessWidget {
  const PersonalizationPage({super.key, this.homeSceneBuilder});

  final WidgetBuilder? homeSceneBuilder;

  @override
  Widget build(BuildContext context) {
    return AppearancePage(homeSceneBuilder: homeSceneBuilder);
  }
}
