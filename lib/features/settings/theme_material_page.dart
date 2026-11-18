import 'package:material_ui/material_ui.dart';

import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/plain_list.dart';
import 'widgets/theme_settings_sections.dart';

/// 「主题与材质」设置页：普通滚动列表承载主题模式、色彩、纯黑模式
/// 与文本缩放（顶部实时样张已下线）。
class ThemeMaterialPage extends StatelessWidget {
  const ThemeMaterialPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const AppAppBar(title: Text('主题与材质')),
      body: CustomScrollView(
        key: const Key('theme_material_scroll'),
        slivers: const [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              kPlainListGutter,
              12,
              kPlainListGutter,
              32,
            ),
            sliver: SliverList(
              delegate: SliverChildListDelegate.fixed([
                ThemeSettingsSections(),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
