import 'package:flutter/material.dart';

import '../../../core/theme/personalization_controller.dart';
import '../../../shared/widgets/plain_list.dart';

/// 个性化 — 「首页内容」分组：首页正文内容的显隐开关。
///
/// 状态由 [PersonalizationController] 持久化并被首页实时消费。
class PersonalizationHomeSection extends StatelessWidget {
  const PersonalizationHomeSection({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = PersonalizationController.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PlainSectionHeader('首页内容'),
        PlainListGroup(
          children: [
            _switch(
              key: const Key('personalization_emblem'),
              listenable: controller.emblemWatermarkEnabled,
              title: '校徽水印',
              subtitle: '状态区右下角',
              onChanged: controller.setEmblemWatermarkEnabled,
            ),
            _switch(
              key: const Key('personalization_full_day'),
              listenable: controller.fullDayCoursesEnabled,
              title: '今日全部课程',
              subtitle: '已结束的课不显示；开启最多 6 条，关闭最多 3 条',
              onChanged: controller.setFullDayCoursesEnabled,
            ),
            _switch(
              key: const Key('personalization_campus_notice'),
              listenable: controller.homeCampusNoticeEnabled,
              title: '校园公告',
              subtitle: '不影响通知中心与提醒',
              onChanged: controller.setHomeCampusNoticeEnabled,
            ),
          ],
        ),
      ],
    );
  }

  Widget _switch({
    required Key key,
    required ValueNotifier<bool> listenable,
    required String title,
    required String subtitle,
    required ValueChanged<bool> onChanged,
  }) {
    return ValueListenableBuilder<bool>(
      valueListenable: listenable,
      builder: (context, enabled, _) => PlainSwitchRow(
        switchKey: key,
        title: title,
        subtitle: subtitle,
        value: enabled,
        onChanged: onChanged,
      ),
    );
  }
}
