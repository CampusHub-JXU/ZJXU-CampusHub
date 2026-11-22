// 生成刷题助手原生移植的「黄金样本」：把语料交给 **PWA 原始 TypeScript 源码** 运行，
// 记录其输出，供 Dart 侧 test/features/shuati/golden_parity_test.dart 逐条比对。
//
// 用法（需 Node >= 22.18，自带 TypeScript 类型剥离；不需要 npm install）：
//   node tools/shuati_golden/generate_golden.mjs <shuatipwa 源码根目录> [输出路径]
//
// 输入语料：test/fixtures/shuati/golden_corpus.json
// 默认输出：test/fixtures/shuati/golden_expected.json
//
// 只读 PWA 源码，不修改它；importService.ts 里依赖 IndexedDB / xlsx / mammoth 的部分被裁掉，
// 只保留纯函数（parseCSV / parseRows / parseTextQuestions / normalizeQuestion 及其辅助）。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const root = path.resolve(process.argv[2] ?? '');
if (!process.argv[2] || !fs.existsSync(path.join(root, 'src/domain/questionParser.ts'))) {
  console.error('用法: node generate_golden.mjs <shuatipwa 源码根目录> [输出路径]');
  process.exit(2);
}
const here = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const corpusPath = path.resolve(here, '../../test/fixtures/shuati/golden_corpus.json');
const outPath = path.resolve(process.argv[3] ?? path.resolve(here, '../../test/fixtures/shuati/golden_expected.json'));
const corpus = JSON.parse(fs.readFileSync(corpusPath, 'utf8'));

const url = (rel) => pathToFileURL(path.join(root, rel)).href;
const parser = await import(url('src/domain/questionParser.ts'));
const fp = await import(url('src/domain/questionFingerprint.ts'));
const judge = await import(url('src/domain/answerJudge.ts'));
const wrong = await import(url('src/domain/wrongQuestion.ts'));

// ---- 裁剪 importService.ts 为纯函数模块 ----
let src = fs.readFileSync(path.join(root, 'src/services/importService.ts'), 'utf8');
src = src.slice(0, src.indexOf('// ============ 主导入函数'));
src = src.replace(/^import .*$/gm, '');
const prelude = `
import { parseTextToQuestions, inferQuestionType } from '${url('src/domain/questionParser.ts')}';
let __n = 0;
const uuidv4 = () => 'GEN-' + (++__n);
export function __resetIds() { __n = 0; }
`;
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'shuati-golden-'));
const modPath = path.join(tmp, 'import_pure.ts');
fs.writeFileSync(
  modPath,
  prelude + src + '\nexport { parseCSV, parseCSVRows, parseRows, parseTextQuestions, normalizeQuestion, parseAnswerText };\n',
);
const pure = await import(pathToFileURL(modPath).href);

const out = {};

// 1) parseTextToQuestions
out.textParse = corpus.textCases.map((c) => ({ name: c.name, result: parser.parseTextToQuestions(c.text) }));

// 2) CSV 全链路：parseCSVRows → parseRows
out.csvRows = corpus.csvCases.map((c) => ({ name: c.name, rows: pure.parseCSVRows(c.text) }));
out.csv = corpus.csvCases.map((c) => ({ name: c.name, result: pure.parseCSV(c.text) }));

// 3) 旧文本兜底
out.legacyText = corpus.legacyCases.map((c) => ({ name: c.name, result: pure.parseTextQuestions(c.text) }));

// 4) normalizeQuestion + hashes（输入为 JSON 导入的 raw 题目）
out.normalize = [];
for (const c of corpus.rawCases) {
  pure.__resetIds();
  const q = pure.normalizeQuestion(c.raw, 'BANK');
  const [h] = await fp.attachQuestionHashes([q]);
  out.normalize.push({ name: c.name, result: h });
}

// 5) 判分
out.judge = corpus.judgeCases.map((c) => ({
  name: c.name,
  result: judge.checkAnswer(c.question, c.user),
}));

// 6) 派生错题
out.wrongIds = corpus.wrongCases.map((c) => ({ name: c.name, result: wrong.getCurrentWrongQuestionIds(c.records) }));

// 7) 指纹原始键
out.fingerprint = [];
for (const c of corpus.fingerprintCases) {
  const [h] = await fp.attachQuestionHashes([c.question]);
  out.fingerprint.push({
    name: c.name,
    contentKey: fp.buildContentKey(c.question),
    answerKey: fp.buildAnswerKey(c.question),
    contentHash: h.contentHash,
    answerHash: h.answerHash,
  });
}

// 8) inferQuestionType
out.infer = corpus.inferCases.map((c) => ({
  name: c.name,
  result: parser.inferQuestionType(c.answer, c.options ?? undefined, c.question ?? ''),
}));

fs.rmSync(tmp, { recursive: true, force: true });
fs.writeFileSync(outPath, JSON.stringify(out, null, 1) + '\n');
console.log('wrote', outPath);
