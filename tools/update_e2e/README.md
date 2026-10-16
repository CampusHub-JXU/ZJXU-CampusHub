# 应用内更新模拟器端到端（tools/update_e2e）

用本机模拟器验证「检查更新 → 下载 → 校验 → 系统安装确认 → 覆盖安装」整条链路，不碰真实 GitHub / R2 / EdgeOne。契约见 `docs/in-app-update-state-machine.md` §8。

## 运行

```powershell
pwsh -File .\tools\emulator_zh.ps1                 # 先起 jxu_test 模拟器
pwsh -File .\tools\update_e2e\run_e2e.ps1          # 默认 -Serial emulator-5554 -Port 8765
```

| 参数 | 说明 |
|---|---|
| `-Serial` | adb 序列号，默认 `emulator-5554`；脚本只操作它 |
| `-Port` | 本地静态服务端口（1024–65535，默认 8765），**已烘焙进 APK**，`-SkipBuild` 时须与上次一致 |
| `-SkipBuild` | 复用 `output/update_e2e/app-{A,B}.apk` 与 `meta.json`，仍会重新生成 `www/` 并安装 A |
| `-ServeOnly` | 不构建、不安装、不启动，只起服务并轮询（重跑 / 手动已装 A 时用） |
| `-TimeoutSec` | 等待 versionCode 变为 9999 的最长秒数，默认 600 |
| `-BindAddress` | 服务监听地址，默认 `127.0.0.1`（模拟器的 `10.0.2.2` 就是宿主 loopback） |

退出码：`0` 成功；`2` 超时（versionCode 没到 9999）；`1` 其它错误（设备不在线、构建 / 安装失败、JSON 校验失败等）。

## 脚本做了什么

1. 读 `pubspec.yaml` 的 `version: X.Y.Z+N`。顺序构建两个 debug APK（各需数分钟），都带 `--dart-define=JXU_UPDATE_TEST_ORIGIN=http://10.0.2.2:<Port>`：
   - A：当前版本（`X.Y.Z+N`）→ `output/update_e2e/app-A.apk`
   - B：`--build-number 9999 --build-name X.Y.(Z+1)` → `output/update_e2e/app-B.apk`
   两者同一把本地 debug 签名，B 可覆盖 A。
2. 生成 `output/update_e2e/www/latest.json`（GitHub Release API 同形：`tag_name`、`assets[]` 含 `name` / `size` / `digest=sha256:` / 规范 GitHub `browser_download_url`），B 放在 `www/<tag>/JXU-CampusHub-<tag>-<abi>.apk`。随后用 `check_latest_json.py` 按 `update_source.dart` / `update_model.dart` / `AppUpdateContract.kt` 的规则再核一遍，不通过直接失败。
3. `serve.py`（多线程、1 MiB 分块发送、支持单段 `Range`）服务 `www/`（日志 `server.log`），退出时清理。A / B 只打设备 ABI（`--target-platform`，按 `ro.product.cpu.abi` 选），不再是 200+ MB 的全 ABI debug 包。
4. `adb install -r -t -d` 安装 A（保留数据，`-d` 只为重跑时允许从 B 降回 A；**绝不卸载、不 `pm clear`**），`monkey` 启动 `edu.zjxu.jxucampushub.dev`。
5. 打印手动步骤：**我的 → 设置 → 检查更新 → 更新 → 系统安装确认**；每 3 秒读 `dumpsys package` 的 versionCode，到 9999 即成功。期间 `adb logcat -s AppUpdate:V` 写入 `output/update_e2e/logcat.txt`（启动时会 `logcat -c` 清空该设备日志缓冲）。原生管理器每次阶段转移打一行 `Log.i`（`stage X -> Y (gen N, event E)`，另有 `installer launched`），成功路径应看到 ENQUEUING → DOWNLOADING → AWAITING_VERIFY → READY → INSTALLER_LAUNCHED；日志只含阶段名 / 世代 / 事件类型，不含 URL、文件名、请求键。

## 注意

- 测试源只在 debug 构建且 `JXU_UPDATE_TEST_ORIGIN` 合法（`http://10.0.2.2:<1024–65535>`）时生效；release / profile 不可达。
- 构建覆盖 `build/app/outputs/flutter-apk/app-debug.apk`（最后留下的是 B）。验收结束后若要回到正常包：`flutter build apk --debug --target lib/main.dart`，再 `adb -s <serial> install -r -t <apk>`。
- 改用 `serve.py` 前，`python -m http.server` 小块发送且不支持 `Range`，加上全 ABI debug 包，经模拟器 NAT（`10.0.2.2`）下载可低至 200 kbps 以下。模拟器 NAT 本身仍有吞吐上限，速度只反映测试环境，不代表真实线路。
- 只验证 x86_64 模拟器；arm64 真机、OEM 安装拦截、真实 R2 / EdgeOne 线路不在此覆盖。
- 每次构建前脚本会删除 `build/app/intermediates/apk/debug`、`build/app/outputs/apk/debug` 与 `flutter-apk/app-debug.apk`。原因：AGP（zipflinger）对已有 debug APK 做原地增量更新，旧条目会留下死空间（实测 A 204 MB、条目总量与 B 完全相同的 B 仅 121 MB，A 的 zip 条目间空洞约 87 MB）。现在 A / B 同为全新紧凑打包，大小一致。
- 结束时的「local server saw the APK download」按 `server.log` 中 `GET /<tag>/<asset>` 行判断（共享读打开、显示请求数与状态码，Range 续传会出现 206）。
