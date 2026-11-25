# 贡献指南（Contributing）

感谢关注 **JXU-CampusHub**！本项目是嘉兴大学（ZJXU）学生的非官方校园服务聚合客户端，基于 **GPL-3.0** 协议开源。

为了减少协作摩擦、保护个人隐私并保证主干稳定，请在提交 Issue 或 Pull Request 前阅读以下约定。

---

## 1. 贡献边界与沟通渠道

### 欢迎的贡献
- Bug 修复、崩溃与异常恢复改进
- 教务 / CAS / WebVPN / 校园卡 / 电费等学校接口变更适配
- UI 细节打磨、无障碍与暗色/AMOLED 模式适配
- 单元测试、Widget 测试与诊断覆盖率提升
- 文档纠错与开发体验优化

### 默认不接收的改动
- 引入中心化商业后端、第三方账号托管或任何形式的数据上报/埋点
- 未经事先在 Issue 讨论并达成共识的大型架构/状态管理重写
- 包含真实学生凭证、抓包原始响应或签名密钥的提交

### 开发者交流群
- **QQ 开发协作群：`1129574211`**（用于 PR 对接、教务/WebVPN 接口抓包分析与内测验证；入群请备注 GitHub ID 或拟参与模块）
- 正式 Bug 反馈与功能建议请优先提交至 GitHub Issues，避免技术上下文淹没在群聊中。
- 群内同样严禁发送真实学号、密码、Cookie 及未脱敏抓包原文件。

---

## 2. 开发环境与本地运行

### 工具链基线
请尽量与 CI（`.github/workflows/ci.yml`）保持一致：
- **Flutter**：`3.50.0`
- **Dart**：`3.14.0`
- **Java**：`17`（Temurin）
- **Android SDK / Android Studio**

### 依赖与本地运行
```bash
git clone https://github.com/CampusHub-JXU/ZJXU-CampusHub.git
cd ZJXU-CampusHub
flutter pub get
flutter run
```

> **提示**：`packages/campus_widget_store` 与 `packages/campus_captcha_ocr` 为仓库内的本地 `path` 依赖，`flutter pub get` 会自动解析。

### 无校内网络 / 非嘉大账号时如何测试
- 本仓库单元测试与 Widget 测试不依赖真实校网或真实账号，全部使用本地 Mock / Fake Transport / 内存 SQLite（`sqflite_common_ffi`）。
- 仅端到端真机实测（教务、CAS、WebVPN 等）需要校内账号与对应网络环境。

---

## 3. 架构与代码约定

### 目录分层
- `lib/app/`：应用入口、主题（`theme.dart`）、路由（`routes.dart`）
- `lib/core/`：认证、网络、选路、日志、应用内更新、平台通道/JNI 桥接
- `lib/features/`：按业务划分的功能模块（feature-first）
- `lib/shared/`：跨模块共享组件与反馈工具（`AppFeedback`、`AppDropdown` 等）

### 状态管理与风格约束
- **保持现有的 `StatefulWidget + setState` 与 feature-first 结构**，**请勿擅自引入 `Provider` / `Bloc` / `Riverpod` 等额外状态管理框架**。
- 新页面与弹窗请优先复用 `lib/app/theme.dart` 中的设计 Token 及 `lib/shared/` 现有组件。
- 路由统一在 `lib/app/routes.dart` 注册。
- 代码风格遵循 `flutter_lints`（`analysis_options.yaml`）及 `dart format` 默认规则。

---

## 4. 隐私与安全红线（必读）

1. **严禁提交任何敏感信息**：包括但不限于真实学号、密码、Cookie、Token、CAS/正方/WebVPN 抓包原始 HTML/JSON、签名密钥（`release.jks`、`keystore.properties`、`*.p12`）。
2. **日志与报错脱敏**：新增或修改教务/认证/网络日志时，不得打印明文凭证、Cookie 或完整身份响应体。
3. **测试 Fixture 脱敏**：测试中使用的 HTML/JSON 样例必须为脱敏/虚构数据，禁止出现真实学生姓名、学号或身份证号。
4. **应用内更新与原生通道校验**：涉及 APK 下载或 `android/` 原生更新通道时，必须保留原有的域名/路径/文件名白名单校验逻辑，不得放开为任意 URL。

---

## 5. 分支与提交规范

- 从 `main` 拉取特性分支，单次 PR 聚焦单一问题，避免把无关格式化或跨模块顺手重构混入同一 PR。
- 推荐使用 Conventional Commits 风格前缀：
  - `feat:` 新功能
  - `fix:` Bug 修复
  - `ui:` 界面/交互/样式调整
  - `test:` 测试补充或修复
  - `docs:` 文档改动
  - `chore:` 构建/依赖/CI 维护

---

## 6. 提交前必检清单

以下检查与 `.github/workflows/ci.yml` 保持一致，提交 PR 前请在本地执行并确认通过：

```bash
flutter pub get
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test
```

如环境中已安装 Python 3，建议一并运行测试诊断脚本：

```bash
python tools/test_diagnostics.py --self-test
python tools/test_diagnostics.py --output build/test_diagnostics --fail-on error
```

若改动涉及 `android/` 原生 Kotlin/Java 代码（尤其是更新通道 `platform/update/`）或 JNI 绑定（`lib/core/platform/android_platform_bindings.dart`），请在 PR 中说明本地构建/原生测试情况：

```bash
python tools/update_native_tests/run.py
```

---

## 7. PR 说明要求（真机与接口适配）

由于 GitHub Actions 无法访问嘉兴大学内网及 WebVPN，凡涉及以下模块的 PR，**必须在 PR 描述中补充真机/模拟器实测说明**：
- 教务登录 / CAS / WebVPN / 自动登录 / 验证码识别
- 课表、成绩、考试、空闲教室、校园卡、电费、第二课堂解析
- 应用内更新、桌面小组件、系统日历同步

请至少写明：
1. 对应的 Mock 单元测试通过情况
2. 实测设备与网络环境（**校内直连** / **校外 WebVPN**）
3. 关键界面或日志截图（确保已脱敏）
