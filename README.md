# 嘉兴大学-校园门户

[![Flutter](https://img.shields.io/badge/Flutter-3.11+-blue.svg)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.0+-blue.svg)](https://dart.dev)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

一款面向嘉兴大学学生的校园服务聚合 App，整合教务系统、校园卡、服务大厅等分散的校园服务，提供一站式便捷体验。

## 功能特性

| 模块 | 功能描述 | 状态 |
|------|----------|------|
| 🏠 首页 | 功能入口导航，快捷访问各模块 | ✅ 已完成 |
| 📅 课表查询 | 查看个人课程表，支持学期切换 | ✅ 已完成 |
| 📊 成绩查询 | 查询各科成绩、绩点、学分统计 | ✅ 已完成 |
| 💳 校园卡 | 校园卡余额查询、消费记录 | 🚧 开发中 |
| 🏢 服务大厅 | 办事指南、在线申请、进度查询 | 🚧 开发中 |
| ⚙️ 设置 | 账号管理、主题切换、关于应用 | ✅ 已完成 |

## 技术栈

- **框架**: Flutter 3.11+ / Dart 3.0+
- **路由**: `go_router` - 声明式路由管理
- **网络**: `dio` + `cookie_jar` - 带 Cookie 持久化的 HTTP 客户端
- **安全存储**: `flutter_secure_storage` - 凭据安全存储
- **加密**: `pointycastle` - RSA 加密（教务系统登录）
- **UI**: Material 3 设计规范，支持浅色/深色主题

## 项目结构

```
lib/
├── main.dart                    # 应用入口
├── app/
│   ├── app.dart                 # MaterialApp 根组件
│   ├── routes.dart              # 路由配置
│   └── theme.dart               # 主题配置（浅色/深色）
├── core/
│   ├── auth/
│   │   ├── credential_store.dart    # 凭据安全存储
│   │   └── zhengfang_auth.dart      # 正方教务系统认证
│   └── network/
│       ├── dio_client.dart          # Dio 单例配置
│       └── cookie_interceptor.dart  # Cookie 拦截器
├── features/                    # 功能模块
│   ├── home/                    # 首页
│   ├── schedule/                # 课表查询
│   ├── grades/                  # 成绩查询
│   ├── campus_card/             # 校园卡
│   ├── service_hall/            # 服务大厅
│   └── settings/                # 设置
└── shared/
    └── widgets/                 # 共享组件
        └── login_widget.dart    # 统一登录组件
```

## 快速开始

### 环境要求

- Flutter SDK ^3.11.0
- Dart SDK ^3.0.0
- Android SDK 21+ (Android 5.0+)

### 安装运行

```bash
# 克隆仓库
git clone https://github.com/FHfanshu/ZJXU-portal.git
cd ZJXU-portal

# 安装依赖
flutter pub get

# 运行应用
flutter run
```

### 构建 APK

```bash
# 调试版本
flutter build apk

# 发布版本
flutter build apk --release
```

## 使用说明

1. **首次登录**: 使用正方教务系统账号（学号）和密码登录
2. **自动登录**: 登录成功后凭据将加密存储，下次打开自动登录
3. **课表查看**: 支持按学期筛选，显示课程名称、教室、时间
4. **成绩查询**: 展示所有学期成绩，自动计算总学分和加权绩点

## 安全说明

- 用户凭据使用 `flutter_secure_storage` 加密存储，安全性由系统 Keychain/Keystore 保障
- 教务系统通信使用 HTTPS，密码采用 RSA 加密传输
- 应用不收集任何用户隐私数据

## 贡献指南

欢迎提交 Issue 和 Pull Request！

1. Fork 本仓库
2. 创建功能分支 (`git checkout -b feature/amazing-feature`)
3. 提交更改 (`git commit -m 'Add amazing feature'`)
4. 推送分支 (`git push origin feature/amazing-feature`)
5. 创建 Pull Request

## 免责声明

本应用为嘉兴大学学生个人开发项目，非学校官方应用。应用数据来源于正方教务系统，仅供学习交流使用。

## License

[Apache-2.0](LICENSE) © FHfanshu
