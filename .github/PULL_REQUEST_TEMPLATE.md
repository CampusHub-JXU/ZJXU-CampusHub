## 变更摘要

<!-- 简述本次 PR 解决的问题或新增的能力，如有对应 Issue 请使用 Closes #编号 -->

## 变更类型

- [ ] `fix` Bug 修复
- [ ] `feat` 新功能 / 校园服务适配
- [ ] `ui` 界面 / 交互调整
- [ ] `test` 测试补充或修复
- [ ] `docs` / `chore` 文档或工程维护

## 本地检查清单

- [ ] `flutter pub get`
- [ ] `dart format --output=none --set-exit-if-changed lib test integration_test`
- [ ] `flutter analyze`
- [ ] `flutter test`
- [ ] 如修改了 `android/` 原生更新逻辑，已运行 `python tools/update_native_tests/run.py`

## 隐私与红线自查

- [ ] 确认未提交真实学号、密码、Cookie、抓包原文件或签名密钥
- [ ] 确认新增日志、报错文案与测试样例均已脱敏
- [ ] 确认未引入 `Provider` / `Bloc` / `Riverpod` 等额外状态管理框架，也未引入中心化后端或数据上报

## 真机与网络环境实测（涉及教务/认证/WebVPN/更新/原生功能时填写）

- **测试设备 / 系统版本**：
- **网络环境**：`[ ] 校内直连` / `[ ] 校外 WebVPN` / `[ ] 不适用（纯本地逻辑）`
- **实测结果与截图（请确保已脱敏）**：
