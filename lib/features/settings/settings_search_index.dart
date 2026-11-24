import '../../core/perf/frame_timing_collector.dart';

/// 设置搜索索引：覆盖各设置子页面里的具体设置项，使设置页搜索框可以
/// 直达子页面。主页自身的条目在 `settings_page.dart` 内定义（需要页内
/// 状态与动作）；本表只负责「跳转到某个子页面」的叶子项。
///
/// 每个条目命中后渲染为一行：`title` 为设置项名称，`breadcrumb` 为
/// 「子页面 › 分组」路径；点击统一 `context.pushNamed(routeName)`。
class SettingsSearchChild {
  const SettingsSearchChild({
    required this.title,
    required this.keywords,
    required this.breadcrumb,
    required this.routeName,
    this.androidOnly = false,
    this.visible = true,
  });

  /// 行标题：子页面里设置项的名称。
  final String title;

  /// 可检索文本（含同义词、选项值），小写比较；`title` 与 `breadcrumb`
  /// 会一并纳入匹配，不需重复写入。
  final String keywords;

  /// 路径副标题，例如「主题与材质 › 显示与排版」。
  final String breadcrumb;

  /// `context.pushNamed` 目标路由名。
  final String routeName;

  /// 仅 Android 平台展示（该子页面本身或设置项只在 Android 存在）。
  final bool androidOnly;

  /// 条件可见（如编译期开关控制的内部入口）。
  final bool visible;

  /// 参与匹配的完整小写文本：标题 + 路径 + 关键词。
  String get searchText => '$title $breadcrumb $keywords'.toLowerCase();
}

/// 设置子页面检索树（按主页入口顺序排列）。
const List<SettingsSearchChild> kSettingsSearchIndex = [
  // ── 主题与材质（appearance-theme）──────────────────────────────────────
  SettingsSearchChild(
    title: '主题模式',
    keywords: '跟随系统 浅色 深色 夜间 暗黑 自动 theme mode dark light',
    breadcrumb: '主题与材质',
    routeName: 'appearance-theme',
  ),
  SettingsSearchChild(
    title: '主题色彩',
    keywords:
        '嘉大红 嘉大蓝 湖青 紫罗兰 樱粉 暖橙 松绿 石墨 自定义主题色 配色 颜色 种子色 色卡 color palette seed',
    breadcrumb: '主题与材质',
    routeName: 'appearance-theme',
  ),
  SettingsSearchChild(
    title: '纯黑模式',
    keywords: 'oled 纯黑 背景 黑色 省电 amoled black dark',
    breadcrumb: '主题与材质 › 显示与排版',
    routeName: 'appearance-theme',
  ),
  SettingsSearchChild(
    title: '文本缩放',
    keywords: '字体大小 缩放比例 恢复默认缩放 字号 文字 排版 font size scale text',
    breadcrumb: '主题与材质 › 显示与排版',
    routeName: 'appearance-theme',
  ),

  // ── 首页个性化（appearance-personalization）───────────────────────────
  SettingsSearchChild(
    title: '壁纸',
    keywords: '更换壁纸 铺满 适应 居中 填充方式 位置 缩放 移除壁纸 背景图片 wallpaper background image',
    breadcrumb: '首页个性化 › 壁纸',
    routeName: 'appearance-personalization',
  ),
  SettingsSearchChild(
    title: '流体 Shader',
    keywords: '动态背景 效果 流体 动画 shader 耗电 液态',
    breadcrumb: '首页个性化 › 效果',
    routeName: 'appearance-personalization',
  ),
  SettingsSearchChild(
    title: '校徽水印',
    keywords: '校徽 水印 状态区 logo watermark badge',
    breadcrumb: '首页个性化 › 首页内容',
    routeName: 'appearance-personalization',
  ),
  SettingsSearchChild(
    title: '今日全部课程',
    keywords: '今日课程 全部课程 首页课程 课程卡片',
    breadcrumb: '首页个性化 › 首页内容',
    routeName: 'appearance-personalization',
  ),
  SettingsSearchChild(
    title: '教务处公告',
    keywords: '公告 教务 通知 首页公告 jw 教务处',
    breadcrumb: '首页个性化 › 首页内容',
    routeName: 'appearance-personalization',
  ),
  SettingsSearchChild(
    title: '应用图标',
    keywords: '黑白互换 跟随主题色 嘉大红 图标样式 icon launcher',
    breadcrumb: '首页个性化 › 应用图标',
    routeName: 'appearance-personalization',
  ),

  // ── 桌面与后台（desktop-background，仅 Android）───────────────────────
  SettingsSearchChild(
    title: '桌面组件',
    keywords: '2×2 4×2 4×4 下一节课 今日课表 校园总览 小组件 widget 添加到桌面',
    breadcrumb: '桌面组件与后台 › 桌面组件',
    routeName: 'desktop-background',
    androidOnly: true,
  ),
  SettingsSearchChild(
    title: '今日课表快捷方式',
    keywords: '快捷方式 桌面 shortcut 固定 课表',
    breadcrumb: '桌面组件与后台 › 快捷方式',
    routeName: 'desktop-background',
    androidOnly: true,
  ),
  SettingsSearchChild(
    title: '桌面快捷方式权限',
    keywords: '快捷方式 权限 创建 shortcut permission 小米 hyperos',
    breadcrumb: '桌面组件与后台 › 快捷方式',
    routeName: 'desktop-background',
    androidOnly: true,
  ),
  SettingsSearchChild(
    title: '通知权限',
    keywords: '通知 权限 notification 开启通知',
    breadcrumb: '桌面组件与后台 › 后台运行',
    routeName: 'desktop-background',
    androidOnly: true,
  ),
  SettingsSearchChild(
    title: '精确闹钟',
    keywords: '闹钟 精确 alarm 提醒 exact',
    breadcrumb: '桌面组件与后台 › 后台运行',
    routeName: 'desktop-background',
    androidOnly: true,
  ),
  SettingsSearchChild(
    title: '电池优化',
    keywords: '电池 优化 后台 保活 省电 battery optimization 无限制',
    breadcrumb: '桌面组件与后台 › 后台运行',
    routeName: 'desktop-background',
    androidOnly: true,
  ),
  SettingsSearchChild(
    title: '自启动',
    keywords: '自启动 开机启动 小米 autostart 后台',
    breadcrumb: '桌面组件与后台 › 后台运行',
    routeName: 'desktop-background',
    androidOnly: true,
  ),
  SettingsSearchChild(
    title: '系统应用信息',
    keywords: '应用信息 系统设置 app info 应用详情',
    breadcrumb: '桌面组件与后台 › 后台运行',
    routeName: 'desktop-background',
    androidOnly: true,
  ),

  // ── AI 模型与接口（ai-settings）───────────────────────────────────────
  SettingsSearchChild(
    title: 'AI 服务配置',
    keywords:
        'deepseek openai 兼容 base url 模型 api key 密钥 温度 测试连接 '
        '大模型 接口 配置 服务 llm provider apikey temperature',
    breadcrumb: 'AI 模型与接口',
    routeName: 'ai-settings',
  ),

  // ── 关于与诊断（about）────────────────────────────────────────────────
  SettingsSearchChild(
    title: '开发者与发布页',
    keywords: '开发者 github 发布页 作者 主页 项目地址 release',
    breadcrumb: '关于与诊断 › 开发者',
    routeName: 'about',
  ),
  SettingsSearchChild(
    title: '联系邮箱',
    keywords: '邮箱 联系 反馈 邮件 email mail 作者',
    breadcrumb: '关于与诊断 › 开发者',
    routeName: 'about',
  ),
  SettingsSearchChild(
    title: '复制登录诊断日志',
    keywords: '复制 登录 诊断 日志 脱敏 排障 copy log',
    breadcrumb: '关于与诊断 › 诊断',
    routeName: 'about',
  ),
  SettingsSearchChild(
    title: '导出诊断日志',
    keywords: '导出 诊断 日志 markdown 报告 登录轨迹 export log report',
    breadcrumb: '关于与诊断 › 诊断',
    routeName: 'about',
  ),
  SettingsSearchChild(
    title: '记录完整诊断日志',
    keywords: '记录 完整 诊断 日志 详细 capture',
    breadcrumb: '关于与诊断 › 诊断',
    routeName: 'about',
  ),
  SettingsSearchChild(
    title: '性能诊断',
    keywords: '性能 诊断 帧时 掉帧 卡顿 perf performance frame',
    breadcrumb: '关于与诊断 › 诊断',
    routeName: 'about',
    // 与 about 页一致：未以 --dart-define 启用 JXU_PERF_DIAGNOSTICS 时不出现在索引。
    visible: kPerfDiagnosticsEnabled,
  ),
];
