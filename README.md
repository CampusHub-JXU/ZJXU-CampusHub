# JXU CampusHub

嘉兴大学 CampusHub 是一个非官方校园服务聚合 App，把课表、成绩、考试、校园卡、电费、通知、第二课堂等常用校园功能放进同一个 Flutter 客户端。

> 本项目不是学校官方应用，仅供学习与交流使用。学校系统接口变化可能导致部分功能失效。

## 数据与隐私

- 纯本地客户端：没有独立业务后端，也不通过第三方服务器代收或代存学号、密码。
- 登录凭据和会话数据保存在用户自己的设备上；应用直接连接学校相关服务。
- 仓库不包含签名密钥、发布凭据或真实学生数据。

## 开发环境

- Flutter 3.50.0
- Dart 3.14.0
- Java 17
- Android Studio / Android SDK

## Quick Start

```bash
git clone https://github.com/CampusHub-JXU/ZJXU-CampusHub.git
cd ZJXU-CampusHub
flutter pub get
flutter run
```

构建 APK：

```bash
flutter build apk --release
```

构建产物默认位于 `build/app/outputs/flutter-apk/app-release.apk`。

## 项目结构

```text
lib/
  app/         # 应用入口、主题、路由
  core/        # 认证、网络、日志、更新、系统能力
  features/    # 业务模块
  shared/      # 共享组件
android/       # Android 工程与原生通道
packages/      # 本地 Flutter/Dart 包
assets/        # 静态资源
test/          # 单元与组件测试
integration_test/ # 设备集成测试
tools/         # 构建、诊断与测试辅助脚本
```

## 贡献

欢迎 Issue 和 Pull Request。提交前请至少运行：

```bash
flutter pub get
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test
```

涉及学校认证、写操作、验证码、设备数据或发布链路的改动，请在 PR 中明确说明验证范围与风险。

## License

[GPL-3.0](LICENSE)
