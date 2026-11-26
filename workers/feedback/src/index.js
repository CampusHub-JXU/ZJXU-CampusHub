/**
 * CampusHub 反馈收集 Worker
 *
 * 接口：
 *   GET  /health        健康检查
 *   POST /api/feedback  接收 App 内反馈，自动创建 GitHub Issue
 *
 * 密钥（通过 Cloudflare Dashboard 配置 Secret）：
 *   GITHUB_TOKEN          必填，Fine-grained PAT（Issues: Read and write）
 *   FEEDBACK_CLIENT_KEY   可选，设置后客户端需额外携带 X-Client-Key
 */

import {readBytes} from './http.js';
const APP_CLIENT_HEADER = 'jxu-campushub';
const MAX_BODY_BYTES = 100 * 1024; // 100 KB

// 轻量防刷：固定窗口，每 IP 每 10 分钟最多 5 次
const RATE_LIMIT_WINDOW_MS = 10 * 60 * 1000;
const RATE_LIMIT_MAX = 5;

const JSON_HEADERS = {
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
};

/** 统一 JSON 响应（附带宽松 CORS，便于本地/网页调试） */
function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      ...JSON_HEADERS,
      'Access-Control-Allow-Origin': '*',
    },
  });
}

/** CORS 预检 */
function handleOptions() {
  return new Response(null, {
    status: 204,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, X-App-Client, X-Client-Key',
      'Access-Control-Max-Age': '86400',
    },
  });
}

/**
 * 基于 caches.default 的固定窗口限流。
 * 说明：Cache API 作用域为单个数据中心（colo），并非全局强一致，
 * 仅作为轻量防刷手段，不作为精确配额。
 * @returns {Promise<boolean>} true 表示放行，false 表示超限
 */
async function checkRateLimit(ip) {
  try {
    const window = Math.floor(Date.now() / RATE_LIMIT_WINDOW_MS);
    const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(ip));
    const keyHash = Array.from(new Uint8Array(hash), b => b.toString(16).padStart(2, '0')).join('');
    const key = `https://ratelimit.internal/jxuc-feedback/${keyHash}/${window}`;
    const cache = caches.default;

    let count = 0;
    const hit = await cache.match(key);
    if (hit) {
      count = parseInt(await hit.text(), 10) || 0;
    }
    if (count >= RATE_LIMIT_MAX) {
      return false;
    }

    count += 1;
    const response = new Response(String(count), {
      headers: {
        // 缓存略长于一个窗口，窗口切换后 key 变化自然失效
        'Cache-Control': `max-age=${Math.ceil((RATE_LIMIT_WINDOW_MS * 1.5) / 1000)}`,
      },
    });
    await cache.put(key, response);
    return true;
  } catch {
    // 限流组件异常时放行，避免误伤正常反馈
    return true;
  }
}

/** 字段长度先校验，此处清理首尾空白。 */
function clean(value, maxLen) {
  if (typeof value !== 'string') return '';
  return value.trim().slice(0, maxLen);
}

/**
 * 校验并清洗反馈字段。
 * @returns {{ error?: string, value?: object }}
 */
export function validatePayload(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return { error: '请求体格式不正确' };
  }

  const type = body.type;
  if (type !== 'bug' && type !== 'feature') {
    return { error: '反馈类型不正确' };
  }

  for (const [field, limit] of Object.entries({title:100, description:4000, campus:40, contact:80, appVersion:40, osInfo:120, buildMode:20, diagnostics:25000})) {
    if (body[field] != null && (typeof body[field] !== 'string' || body[field].length > limit)) {
      return {error: `${field} 格式或长度不符合要求（最多 ${limit} 字符）`};
    }
  }
  const title = clean(body.title, 100);
  if (title.length < 2) {
    return { error: '标题长度需在 2~100 字之间' };
  }

  const description = clean(body.description, 4000);
  if (description.length < 5) {
    return { error: '描述长度需在 5~4000 字之间' };
  }

  return {
    value: {
      type,
      title,
      description,
      campus: clean(body.campus, 40),
      contact: clean(body.contact, 80),
      appVersion: clean(body.appVersion, 40),
      osInfo: clean(body.osInfo, 120),
      buildMode: clean(body.buildMode, 20),
      diagnostics: typeof body.diagnostics === 'string'
        ? body.diagnostics.slice(0, 25000)
        : '',
    },
  };
}

/** 构造 Issue 标题，避免与已有前缀重复 */
export function buildIssueTitle(type, title) {
  const prefix = type === 'bug' ? '[Bug] ' : '[建议] ';
  if (/^\[(bug|建议|feature)\]\s*/i.test(title)) {
    return title;
  }
  return prefix + title;
}

/** 构造结构化 Markdown Issue 正文 */
export function buildIssueBody(f) {
  const lines = [
    `## 反馈类型`,
    '',
    f.type === 'bug' ? '🐛 Bug 反馈' : '💡 功能建议',
    '',
  ];

  if (f.campus) {
    lines.push(`**校区**：${f.campus}`, '');
  }

  lines.push('## 描述', '', f.description, '');

  if (f.contact) {
    lines.push('## 联系方式', '', f.contact, '');
  }

  const envRows = [];
  if (f.appVersion) envRows.push(`| App 版本 | ${f.appVersion} |`);
  if (f.osInfo) envRows.push(`| 系统信息 | ${f.osInfo} |`);
  if (f.buildMode) envRows.push(`| 构建模式 | ${f.buildMode} |`);
  if (envRows.length > 0) {
    lines.push('## 运行环境', '', '| 项目 | 值 |', '| --- | --- |', ...envRows, '');
  }

  if (f.diagnostics) {
    lines.push(
      '<details><summary>展开脱敏诊断日志</summary>',
      '',
      fenceFor(f.diagnostics),
      f.diagnostics,
      fenceFor(f.diagnostics),
      '',
      '</details>',
      '',
    );
  }

  lines.push('---', '*本 Issue 由 CampusHub App 内反馈自动创建*');
  return lines.join('\n');
}

/** 调用 GitHub API 创建 Issue */
async function createGithubIssue(env, payload) {
  const url = `https://api.github.com/repos/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/issues`;
  const resp = await fetch(url, {
    method: 'POST',
    signal: AbortSignal.timeout(15000),
    headers: {
      'Authorization': `Bearer ${env.GITHUB_TOKEN}`,
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'jxuc-feedback-worker',
      'X-GitHub-Api-Version': '2022-11-28',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      title: buildIssueTitle(payload.type, payload.title),
      labels: ['from-app', payload.type === 'bug' ? 'bug' : 'enhancement'],
      body: buildIssueBody(payload),
    }),
  });

  if (!resp.ok) {
    // 仅记录状态码与摘要，不把 GitHub 响应原文（可能含内部信息）透给客户端
    console.error('GitHub 创建 Issue 失败', resp.status);
    if (resp.status >= 500) throw new Error('GitHub result uncertain');
    return null;
  }

  const data = await resp.json();
  if (!Number.isSafeInteger(data.number) || data.number <= 0 ||
      data.html_url !== `https://github.com/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/issues/${data.number}`) {
    throw new Error('GitHub result invalid');
  }
  return { issueNumber: data.number, issueUrl: data.html_url };
}

/** 处理 POST /api/feedback */
async function handleFeedback(request, env) {
  // 1. Content-Type 校验
  const contentType = request.headers.get('Content-Type') || '';
  if (contentType.split(';')[0].trim().toLowerCase() !== 'application/json') {
    return json({ ok: false, error: 'Content-Type 必须为 application/json' }, 400);
  }

  // 2. 请求体大小校验（优先 Content-Length，兜底在实际解析时检查）
  const contentLength = parseInt(request.headers.get('Content-Length') || '0', 10);
  if (contentLength > MAX_BODY_BYTES) {
    return json({ ok: false, error: '请求体过大，请缩减内容后重试' }, 413);
  }

  // 3. 客户端身份校验
  if (request.headers.get('X-App-Client') !== APP_CLIENT_HEADER) {
    return json({ ok: false, error: '无效的客户端标识' }, 403);
  }
  if (env.FEEDBACK_CLIENT_KEY) {
    if (request.headers.get('X-Client-Key') !== env.FEEDBACK_CLIENT_KEY) {
      return json({ ok: false, error: '客户端密钥不正确' }, 403);
    }
  }

  // 4. 轻量防刷：按 IP 固定窗口限流
  const ip = request.headers.get('CF-Connecting-IP') || 'unknown';
  if (env.PAUSE_SUBMISSIONS === 'true') return json({ok:false,error:'反馈通道维护中，请稍后重试'}, 503);
  const allowed = await checkRateLimit(ip);
  if (!allowed) {
    return json({ ok: false, error: '提交过于频繁，请稍后再试（10 分钟内最多提交 5 次）' }, 429);
  }

  // 5. 读取并解析请求体
  let rawBody;
  try {
    rawBody = new TextDecoder('utf-8', {fatal:true}).decode(await readBytes(request, MAX_BODY_BYTES));
  } catch (error) {
    if (error.status === 413) return json({ok:false,error:error.message}, 413);
    return json({ ok: false, error: '请求体读取失败' }, 400);
  }

  let bodyJson;
  try {
    bodyJson = JSON.parse(rawBody);
  } catch {
    return json({ ok: false, error: '请求体不是合法的 JSON' }, 400);
  }

  // 6. 字段校验与清洗
  const { error, value } = validatePayload(bodyJson);
  if (error) {
    return json({ ok: false, error }, 400);
  }

  // 7. Token 缺失时直接 500（属于服务端配置问题）
  if (!env.GITHUB_TOKEN || !env.GITHUB_OWNER || !env.GITHUB_REPO) {
    console.error('缺少反馈服务配置，请在 Cloudflare Dashboard 检查 Secret 和仓库配置');
    return json({ ok: false, error: '服务端未配置反馈通道，请稍后重试' }, 500);
  }

  // 8. 创建 GitHub Issue
  let result;
  try { result = await createGithubIssue(env, value); }
  catch { return json({ok:false,error:'无法确认 GitHub 是否已接收，请先检查仓库再重试'}, 502); }
  if (!result) {
    return json({ ok: false, error: 'GitHub 拒绝接收反馈，请复制文本备份并联系开发者' }, 502);
  }

  return json({ ok: true, issueNumber: result.issueNumber, issueUrl: result.issueUrl }, 201);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const { pathname } = url;

    if (request.method === 'OPTIONS') {
      return handleOptions();
    }

    if (pathname === '/health' && request.method === 'GET') {
      return json({ ok: true, service: 'jxuc-feedback-worker' });
    }

    if (pathname === '/api/feedback' && request.method === 'POST') {
      return handleFeedback(request, env);
    }

    return json({ ok: false, error: 'Not Found' }, 404);
  },
};

function fenceFor(text) {
  return '`'.repeat(Math.max(3, ...Array.from(text.matchAll(/`+/g), m => m[0].length)) + 1);
}
