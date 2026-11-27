import assert from 'node:assert/strict';
import {test, beforeEach, afterEach} from 'node:test';
import worker, {validatePayload, buildIssueBody, buildIssueTitle} from '../src/index.js';

const env = {GITHUB_OWNER: 'CampusHub-JXU', GITHUB_REPO: 'ZJXU-CampusHub', GITHUB_TOKEN: 'fake-test-token'};
const payload = {type: 'bug', title: '反馈测试', description: '可复现的测试反馈', contact: 'test@example.invalid'};
const originalFetch = globalThis.fetch;
const originalCaches = globalThis.caches;
let calls;
beforeEach(() => {
  calls = [];
  const cache = new Map();
  globalThis.caches = {default: {
    match: async key => cache.get(key)?.clone(),
    put: async (key, value) => {cache.set(key, value.clone());},
  }};
  globalThis.fetch = async (url, init) => {
    calls.push({url, init});
    return Response.json({number: 42, html_url: 'https://github.com/CampusHub-JXU/ZJXU-CampusHub/issues/42'}, {status: 201});
  };
});
afterEach(() => {globalThis.fetch = originalFetch; globalThis.caches = originalCaches;});
function request(body = payload, headers = {}) {
  return new Request('https://feedback.example.invalid/api/feedback', {
    method: 'POST', headers: {'Content-Type': 'application/json', 'X-App-Client': 'jxu-campushub', 'CF-Connecting-IP': '192.0.2.1', ...headers},
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

test('stateless submission creates exactly one Issue and returns its link', async () => {
  const response = await worker.fetch(request(), env);
  assert.equal(response.status, 201);
  assert.deepEqual(await response.json(), {ok: true, issueNumber: 42, issueUrl: 'https://github.com/CampusHub-JXU/ZJXU-CampusHub/issues/42'});
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://api.github.com/repos/CampusHub-JXU/ZJXU-CampusHub/issues');
  const body = JSON.parse(calls[0].init.body);
  assert.equal(body.title, '[Bug] 反馈测试');
  assert.match(body.body, /test@example.invalid/);
  assert.deepEqual(body.labels, ['from-app', 'bug']);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
});

test('checks client header, optional shared key, content type and maintenance switch', async () => {
  assert.equal((await worker.fetch(request(payload, {'X-App-Client': ''}), env)).status, 403);
  assert.equal((await worker.fetch(request(), {...env, FEEDBACK_CLIENT_KEY: 'key'})).status, 403);
  assert.equal((await worker.fetch(request(payload, {'Content-Type': 'text/application/json'}), env)).status, 400);
  assert.equal((await worker.fetch(request(), {...env, PAUSE_SUBMISSIONS: 'true'})).status, 503);
  assert.equal(calls.length, 0);
  assert.equal((await worker.fetch(request(payload, {'X-Client-Key': 'key'}), {...env, FEEDBACK_CLIENT_KEY: 'key'})).status, 201);
});

test('validates fields without silently truncating, and rejects malformed JSON', async () => {
  let index = 0;
  for (const body of [[], null, {}, {...payload, title: 'x'}, {...payload, description: 'short'.repeat(801)}, {...payload, contact: 123}, {...payload, diagnostics: 'x'.repeat(25001)}]) {
    assert.equal((await worker.fetch(request(JSON.stringify(body), {'CF-Connecting-IP': `192.0.2.${++index}`}), env)).status, 400);
  }
  assert.equal((await worker.fetch(request('{'), env)).status, 400);
  assert.equal(calls.length, 0);
  assert.equal(validatePayload({...payload, diagnostics: 'x'.repeat(25000)}).value.diagnostics.length, 25000);
});

test('enforces actual UTF-8 body size with or without Content-Length', async () => {
  const oversized = JSON.stringify({...payload, diagnostics: '中'.repeat(40000)});
  assert.ok(oversized.length < 100 * 1024);
  assert.equal((await worker.fetch(request(oversized), env)).status, 413);
  assert.equal((await worker.fetch(request(payload, {'Content-Length': '102401'}), env)).status, 413);
  assert.equal(calls.length, 0);
});

test('diagnostics cannot escape a Markdown fence', () => {
  const report = 'line\n``````\nlog';
  const body = buildIssueBody({...payload, diagnostics: report});
  assert.ok(body.includes('```````\n' + report + '\n```````'));
  assert.equal(buildIssueTitle('bug', '[Bug] 已有前缀'), '[Bug] 已有前缀');
  assert.equal(buildIssueTitle('feature', '新功能'), '[建议] 新功能');
});

test('best effort cache limits an IP to five requests, keys do not contain the raw IP', async () => {
  for (let i = 0; i < 5; i++) assert.equal((await worker.fetch(request(), env)).status, 201);
  assert.equal((await worker.fetch(request(), env)).status, 429);
  assert.equal(calls.length, 5);
  let cacheKey;
  globalThis.caches = {default: {match: async key => {cacheKey = key;}, put: async () => {}}};
  await worker.fetch(request(), env);
  assert.ok(!cacheKey.includes('192.0.2.1'));
});

test('missing server token never calls GitHub', async () => {
  const response = await worker.fetch(request(), {...env, GITHUB_TOKEN: ''});
  assert.equal(response.status, 500);
  assert.equal(calls.length, 0);
});

test('network errors and GitHub 5xx are uncertain; no automatic replay or response leakage', async () => {
  for (const mode of ['network', '5xx', 'invalid']) {
    let attempts = 0;
    globalThis.fetch = async () => {
      attempts++;
      if (mode === 'network') throw new Error('fake-test-token');
      if (mode === '5xx') return new Response('private upstream response', {status: 503});
      return Response.json({number: 42, html_url: 'https://evil.example/42'});
    };
    const response = await worker.fetch(request(), env);
    assert.equal(response.status, 502);
    const text = await response.text();
    assert.match(text, /无法确认/);
    assert.ok(!text.includes('fake-test-token') && !text.includes('private upstream'));
    assert.equal(attempts, 1);
  }
});

test('explicit GitHub rejection returns an actionable generic error', async () => {
  globalThis.fetch = async () => new Response('sensitive details', {status: 403});
  const response = await worker.fetch(request(), env);
  assert.equal(response.status, 502);
  assert.match(await response.text(), /GitHub 拒绝/);
});

test('health and CORS work without storage; removed V2 APIs are unavailable', async () => {
  assert.equal((await worker.fetch(new Request('https://feedback.example.invalid/health'), {})).status, 200);
  assert.equal((await worker.fetch(new Request('https://feedback.example.invalid/api/feedback', {method: 'OPTIONS'}), {})).status, 204);
  assert.equal((await worker.fetch(new Request('https://feedback.example.invalid/api/v2/updates'), {})).status, 404);
});
