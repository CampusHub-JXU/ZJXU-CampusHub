# App 反馈：免费 Worker 转交 GitHub Issue

当前路径：App 表单 → Cloudflare Worker `POST /api/feedback` → GitHub Issue。学生提交时无需 GitHub 账号；GitHub 凭据只放在 Worker Secret 中，不放入客户端。

## 成本与功能取舍

- 仅保留一个 Worker 请求处理器，不绑定 D1、R2、KV、Durable Objects，不注册 Cron，不配置 GitHub Webhook。不租用自建服务器，不接入图床。
- **部署前在 Cloudflare 控制台核对账号使用 Workers Free 计划。不要为此功能开通 Workers Paid 或付费存储。** 仓库配置不会替你改变账号计划；已在付费账号上的请求是否计费取决于该账号。免费额度、超限行为和计划条款以部署时的[官方说明](https://developers.cloudflare.com/workers/platform/pricing/)及控制台为准，不承诺永久免费。
- 只在用户点击提交并确认公开后请求 Worker。不进行启动同步、后台轮询或定时重发。超限或网络失败时保留表单，可复制文本备份。
- 草稿和成功提交的标题、Issue 编号、链接、提交时间仅存在本机 SQLite 中。没有匿名身份注册、服务端队列和回复缓存。卸载、清除数据或换机后无法恢复本机记录。
- 回复、状态在 GitHub 页面查看；追加评论和补充截图需登录 GitHub。App 不上传截图，避免产生图片托管成本。原两期方案中的 App 内追问和后台提醒已取消。

## 数据与公开范围

- 反馈正文、所在校区、版本和系统信息、自愿填写的 QQ／邮箱会进入公开 Issue；联系方式在输入处和提交前均提示公开。
- 脱敏诊断日志默认关闭。用户先预览报告，再选择“确认附带并公开”；提交只使用这份报告，不重新采集。恢复草稿后必须重新预览，草稿不保存诊断报告。
- 自动脱敏是辅助措施，用户仍需检查报告和正文，勿填写校园账号、密码、Cookie 或其他敏感信息。反馈使用独立 HTTP 客户端，不带校园会话 Cookie。
- Worker 不持久化反馈内容，不在日志输出请求体、PAT、诊断报告或 GitHub 原始错误响应。处理期间的内容会经过 Cloudflare；最终公开内容保存在 GitHub。删除公开内容需在 GitHub 处理，已被他人复制的内容无法收回。
- 轻量防刷使用 Cache API：IP 经 SHA-256 后加入窗口键，计数缓存约 15 分钟。每 IP 每 10 分钟最多 5 次；仅为数据中心内的尽力限制，并发、跨数据中心和缓存故障时不能保证精确执行。`X-App-Client` 和可选的 `FEEDBACK_CLIENT_KEY` 不是用户认证，客户端内置值也不能作为安全秘密。

## 部署

沿用 PR #2 的 `cf` CLI 方案，锁定 `cf@1.0.0-rc.6`，由 Wrangler 委托构建。所有命令在 `workers/feedback` 目录执行：

```powershell
npm ci
npm test
npx cf build
npx cf auth login
```

登录后先核对账号计划与目标 Worker，确认使用 Workers Free。`cloudflare.config.ts` 包含 Worker 名称 `jxuc-feedback-worker`、`workersDev: true`、目标仓库及 `PAUSE_SUBMISSIONS=true`，没有任何存储绑定或定时触发器。默认先部署为维护状态，避免在密钥尚未配置时接受提交。

在 Cloudflare Dashboard → Worker → Settings → Variables and Secrets 配置 **Secret**：

| 名称 | 配置 |
| --- | --- |
| `GITHUB_TOKEN` | Fine-grained PAT，仅授权 `CampusHub-JXU/ZJXU-CampusHub`，仅需 Issues 读写权限 |
| `FEEDBACK_CLIENT_KEY` | 可选；若配置，App 需用 `JXU_FEEDBACK_CLIENT_KEY` 编译参数携带相同值 |

不要将 Secret 写入版本库、客户端或命令行历史。PAT 所属账号需要目标仓库写 Issue 的权限；如组织要求审批，先完成审批。仓库预先创建 `from-app`、`bug`、`enhancement` 标签。

确认以上配置后部署（首次部署可先不配置 Secret，入口会保持维护状态）：

```powershell
npm run deploy
```

当前正式接口地址为 `https://feedback.fhfanshu.xyz`（自定义域名，绕开 `workers.dev` 国内直连阻断）。`wrangler.toml` 保留兼容配置，使用 Wrangler 时也需保持仓库和暂停开关一致。

维护者配置好 `GITHUB_TOKEN` 后，在两份配置中将 `PAUSE_SUBMISSIONS` 改为 `false` 并重新部署，再用一条明确标记为验收的反馈确认 Issue 创建成功。不要只在控制台改暂停开关，否则下次部署会恢复仓库里的值。令牌应由有目标仓库权限的维护者生成并直接填入 Cloudflare Secret，不经聊天、代码或构建参数传递。若使用其他账号部署，同步修改 App 的 `JXU_FEEDBACK_URL`，平台子域名以实际部署结果为准。

2026-11-26 已完成 workers.dev 初次部署；当前 `PAUSE_SUBMISSIONS=true`，尚未配置 `GITHUB_TOKEN`，尚未进行真实 Issue 创建验收。旧 `feedback.fhfanshu.xyz` 服务属于其他账号，本次没有修改它。

部署 API 已确认新 Worker 和 workers.dev 路由存在；本机访问该域名时出现 DNS／TLS 连接异常，HTTP 健康检查尚未通过。正式开放前应在校园 Wi-Fi、移动网络分别验证可达性。若 workers.dev 在目标网络不可用，可由已有域名的维护者绑定自定义域名并更新 App 接口，无需新购域名；不要把部署成功等同于学生网络已能访问。

如果曾手动部署过旧 V2 方案，需要额外到平台停用旧 Cron、移除 Webhook，并核对旧 D1/R2 是否仍被使用；本仓库不会自动删除线上数据或资源。仅修改代码不会自动停止其他已部署版本或其他服务的费用。

## App 配置与本地验证

默认接口：`https://feedback.fhfanshu.xyz/api/feedback`。可用 `--dart-define=JXU_FEEDBACK_URL=...` 覆盖。只接受 HTTPS；调试构建额外允许 `localhost`、`127.0.0.1`、Android 模拟器 `10.0.2.2` 的 HTTP 接口。

```powershell
npm test
npx cf build
npm run dev
# 在 Flutter 项目根目录运行：
flutter run --dart-define=JXU_FEEDBACK_URL=http://10.0.2.2:8787/api/feedback
```

本地可把测试 Secret 放在已忽略的 `.dev.vars`，不要使用生产 PAT 运行自动测试。自动测试模拟 GitHub，不会创建真实 Issue。真实验收应检查公开确认、诊断报告快照、成功链接、断网保留草稿、超时提示与本机记录；查看 `/health` 只证明 Worker 可响应，不代表 GitHub 权限有效。当前 App 校验返回的 Issue 必须属于本仓库，切换测试仓库时也需同步客户端链接校验。

## 可靠性与运维

- 只有 GitHub 返回有效 Issue 编号及目标仓库链接，Worker 才返回 201；App 收到有效结果才显示“提交成功”和保存本机链接。草稿删除和链接写入使用本地事务。
- **没有服务端幂等记录，也没有自动重试。** GitHub 已创建 Issue 但响应丢失时，App 无法确认结果，会保留表单并提示先查看 GitHub 反馈列表。用户手动重试仍可能重复，请先核对再操作。不要宣称“绝不重复”或“断网自动补交”。
- Worker 对 GitHub 请求设超时，只记录失败状态码。PAT 过期、权限不足、GitHub 限流时不会向客户端透出上游原始响应。需要维护时将 `PAUSE_SUBMISSIONS` 设为 `true` 并部署，或在平台暂停 Worker。
- 以实际账号控制台核对请求量和计划；不要依赖客户端固定密钥或 Cache API 充当全局配额。免费通道不可用时允许失败，不自动升级套餐、不切换到付费服务。

## API

| 方法与路径 | 行为 |
| --- | --- |
| `GET /health` | 健康检查 |
| `POST /api/feedback` | JSON 表单，成功返回 201 与 `issueNumber`、`issueUrl` |
| `OPTIONS` | CORS 预检 |

请求头含 `X-App-Client: jxu-campushub`；可选 `X-Client-Key`。JSON 实际 UTF-8 请求体上限 100 KiB。字段上限：标题 100、描述 4000、校区 40、联系方式 80、版本 40、系统信息 120、构建模式 20、诊断日志 25000 字符。超长字段拒绝接收，不静默截断用户反馈。`/api/v2/*` 和图片上传接口已移除。
