# 反馈收集 Worker 部署文档（feedback.fhfanshu.xyz）

CampusHub App 内反馈通过 Cloudflare Worker 中转，自动在 `CampusHub-JXU/ZJXU-CampusHub` 创建 GitHub Issue。Worker 代码位于 `workers/feedback/`，纯 ES Module JavaScript，无 npm 依赖、无构建步骤。

## 一、接口契约

| 接口 | 方法 | 说明 |
| --- | --- | --- |
| `/health` | GET | 健康检查，返回 `{ ok: true, service: "jxuc-feedback-worker" }` |
| `/api/feedback` | POST | 提交反馈并创建 GitHub Issue |

### POST /api/feedback

**请求头**：

- `Content-Type: application/json`（必需）
- `X-App-Client: jxu-campushub`（必需）
- `X-Client-Key: <密钥>`（仅当 Worker 配置了 `FEEDBACK_CLIENT_KEY` 时必需）

**请求体**（JSON，≤ 100 KB）：

| 字段 | 必填 | 约束 |
| --- | --- | --- |
| `type` | 是 | `"bug"` 或 `"feature"` |
| `title` | 是 | trim 后 2~100 字 |
| `description` | 是 | trim 后 5~4000 字 |
| `campus` | 否 | ≤ 40 字 |
| `contact` | 否 | ≤ 80 字 |
| `appVersion` | 否 | ≤ 40 字 |
| `osInfo` | 否 | ≤ 120 字 |
| `buildMode` | 否 | ≤ 20 字 |
| `diagnostics` | 否 | ≤ 25000 字，写入 Issue 折叠区块 |

**响应**：

- `201` `{ ok: true, issueNumber, issueUrl }` —— 创建成功
- `400` —— 字段/格式校验失败
- `403` —— 客户端标识或密钥错误
- `413` —— 请求体超限
- `429` —— 触发限流（每 IP 每 10 分钟最多 5 次，Cache API 按数据中心计数，为轻量防刷非精确配额）
- `500` —— 服务端未配置 `GITHUB_TOKEN`
- `502` —— GitHub API 调用失败

支持 `OPTIONS` 预检与宽松 CORS，便于本地或网页调试。

## 二、首次部署步骤

### 1. 创建 GitHub Fine-grained PAT

1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token。
2. **Resource owner** 选 `CampusHub-JXU`（组织），**Repository access** 选 Only select repositories → `ZJXU-CampusHub`。
3. **Permissions** 仅勾选 Repository permissions → **Issues: Read and write**，其余全部 No access。
4. 建议设置 1 年有效期并记下过期时间，生成后立即复制 token。

### 2. 安装并登录 Wrangler

```powershell
npm install -g wrangler
wrangler login
```

### 3. 注入密钥并部署

```powershell
cd workers/feedback
wrangler secret put GITHUB_TOKEN   # 粘贴 PAT
# 可选：启用客户端密钥（启用后 App 需额外携带 X-Client-Key）
# wrangler secret put FEEDBACK_CLIENT_KEY

wrangler deploy
```

部署成功后会得到 `https://jxuc-feedback-worker.<账号子域>.workers.dev`。

### 4. 绑定自定义域名 feedback.fhfanshu.xyz

`fhfanshu.xyz` 的 DNS 已托管在 Cloudflare 时：

1. Cloudflare Dashboard → Workers & Pages → `jxuc-feedback-worker` → **Settings → Triggers → Custom Domains** → Add Custom Domain。
2. 填入 `feedback.fhfanshu.xyz`，确认后 Cloudflare 自动创建 DNS 记录并签发证书，数分钟内生效。

也可以在 `wrangler.toml` 中改用 `routes` 绑定（文件内已附注释示例），推荐二选一，不要同时使用。

### 5. 验证

```powershell
curl https://feedback.fhfanshu.xyz/health
# {"ok":true,"service":"jxuc-feedback-worker"}

curl -X POST https://feedback.fhfanshu.xyz/api/feedback `
  -H "Content-Type: application/json" `
  -H "X-App-Client: jxu-campushub" `
  -d '{"type":"feature","title":"部署联调测试","description":"这是一条来自部署文档的验证反馈"}'
# 应返回 201 与 issueUrl，请到仓库 Issues 核对后手动关闭测试 Issue
```

## 三、本地联调

```powershell
cd workers/feedback
# 本地 dev 也需要 token 才会真正调 GitHub；可用 .dev.vars 文件（勿提交）：
#   echo GITHUB_TOKEN=ghp_xxx > .dev.vars
wrangler dev
```

默认监听 `http://127.0.0.1:8787`，将 App 或 curl 指向该地址即可联调。`.dev.vars` 记得加入忽略列表（`workers/feedback/.gitignore` 可按需自行添加）。

## 四、运维说明

- **Token 轮换**：PAT 到期或泄露时重新执行 `wrangler secret put GITHUB_TOKEN`，无需重新部署。
- **日志排查**：`wrangler tail` 实时查看日志；Worker 不会把 GitHub 响应原文或 token 返回给客户端。
- **限流调整**：修改 `src/index.js` 中的 `RATE_LIMIT_WINDOW_MS` / `RATE_LIMIT_MAX`。
- **标签**：Issue 自动带 `from-app` 与 `bug`/`enhancement` 标签；若仓库尚无这两个标签，GitHub 会忽略不存在的标签（`from-app` 除外——不存在时创建会失败），建议预先在仓库创建 `from-app` 标签。
