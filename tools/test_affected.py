#!/usr/bin/env python3
"""Run only the Flutter tests affected by the current change.

改完代码不必每次都跑全量：本脚本解析 `lib/` 与 `test/` 的 import / export / part
依赖图，找出传递依赖了改动文件的 `*_test.dart`，只跑这些。全量门禁仍由 CI 负责。

用法：
  python tools/test_affected.py                 # 工作区（含未跟踪）相对 HEAD 的改动
  python tools/test_affected.py --base origin/main   # 整个分支相对 main 的改动
  python tools/test_affected.py --list          # 只列出受影响的测试，不运行
  python tools/test_affected.py -- --plain-name foo  # `--` 之后的参数透传给 flutter test

规则：
- 改动的 `*_test.dart` 本身一定会跑；
- `test/helpers/test_setup.dart` 只在自身改动时展开，不作为传递中转；
- 改动 `lib/` 下 Dart 文件时，`test/structure/`（分层 / 设计棘轮等扫源码的守卫）一并跑；
- 改动 `test/fixtures/` 下文件时，跑源码里提到该文件名的测试；
- 改动 `pubspec.yaml` / `pubspec.lock` / `analysis_options.yaml` / `test/flutter_test_config.dart`
  时无法静态判断影响范围，退化为全量。
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "jxu_campus_hub"
FULL_SUITE_TRIGGERS = {
    "pubspec.yaml",
    "pubspec.lock",
    "analysis_options.yaml",
    "test/flutter_test_config.dart",
}
# 只为「重置单例」而 import 全部服务的测试枢纽：经它传递会把几乎所有测试拉进来。
# 它本身被改动时照常展开；只是不作为中转（签名破坏由 flutter analyze 兜底）。
NON_PROPAGATING_HUBS = {"test/helpers/test_setup.dart"}
_DIRECTIVE = re.compile(r"""^\s*(?:import|export|part)\s+['"]([^'"]+)['"]""", re.M)
_PROXY_VARS = ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy")


def _git_lines(*args: str) -> list[str]:
    out = subprocess.run(
        ["git", *args], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout
    return [line.strip() for line in out.splitlines() if line.strip()]


def changed_files(base: str) -> set[str]:
    files = set(_git_lines("diff", "--name-only", base))
    files.update(_git_lines("ls-files", "--others", "--exclude-standard"))
    return {f.replace("\\", "/") for f in files}


def _resolve(source: Path, uri: str) -> Path | None:
    if uri.startswith("dart:"):
        return None
    if uri.startswith("package:"):
        prefix = f"package:{PACKAGE}/"
        return ROOT / "lib" / uri[len(prefix):] if uri.startswith(prefix) else None
    return (source.parent / uri).resolve()


def build_reverse_graph() -> dict[Path, set[Path]]:
    """被依赖文件 -> 直接依赖它的文件。"""
    reverse: dict[Path, set[Path]] = {}
    for top in ("lib", "test"):
        for source in (ROOT / top).rglob("*.dart"):
            source = source.resolve()
            text = source.read_text(encoding="utf-8", errors="replace")
            for uri in _DIRECTIVE.findall(text):
                target = _resolve(source, uri)
                if target is not None:
                    reverse.setdefault(target, set()).add(source)
    return reverse


def _is_test(path: Path) -> bool:
    return path.name.endswith("_test.dart") and (ROOT / "test") in path.parents


def affected_tests(changed: set[str]) -> list[str] | None:
    """返回受影响测试的相对路径；返回 None 表示需要全量。"""
    if changed & FULL_SUITE_TRIGGERS:
        return None

    reverse = build_reverse_graph()
    all_tests = [p.resolve() for p in (ROOT / "test").rglob("*_test.dart")]
    result: set[Path] = set()

    hubs = {(ROOT / h).resolve() for h in NON_PROPAGATING_HUBS}
    seeds = [
        (ROOT / f).resolve()
        for f in changed
        if f.endswith(".dart") and f.startswith(("lib/", "test/"))
    ]
    seen = set(seeds)
    queue = list(seeds)
    while queue:
        current = queue.pop()
        if _is_test(current) and current.exists():
            result.add(current)
        if current in hubs and current not in seeds:
            continue
        for dependent in reverse.get(current, ()):
            if dependent not in seen:
                seen.add(dependent)
                queue.append(dependent)

    if any(f.startswith("lib/") and f.endswith(".dart") for f in changed):
        result.update(p for p in all_tests if (ROOT / "test/structure") in p.parents)

    fixtures = [Path(f).name for f in changed if f.startswith("test/fixtures/")]
    if fixtures:
        for test in all_tests:
            text = test.read_text(encoding="utf-8", errors="replace")
            if any(name in text for name in fixtures):
                result.add(test)

    return sorted(p.relative_to(ROOT).as_posix() for p in result)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", default="HEAD", help="对比的 git 基线（默认 HEAD）")
    parser.add_argument("--list", action="store_true", help="只列出，不运行")
    parser.add_argument("flutter_args", nargs="*", help="`--` 之后透传给 flutter test")
    args = parser.parse_args()

    changed = changed_files(args.base)
    if not changed:
        print(f"相对 {args.base} 没有改动。")
        return 0

    tests = affected_tests(changed)
    if tests is None:
        print("改动涉及全局配置（pubspec / analysis_options / flutter_test_config），跑全量。")
    elif not tests:
        print("改动没有影响任何测试。")
        return 0
    else:
        print(f"受影响的测试（{len(tests)} 个）：")
        for test in tests:
            print(f"  {test}")
    if args.list:
        return 0

    flutter = shutil.which("flutter") or shutil.which("flutter.bat") or "flutter"
    command = [flutter, "test", *(tests or []), *args.flutter_args]
    # flutter_tester 与本机的 WebSocket 握手会被本地代理劫持（docs/agents/testing.md）。
    env = {k: v for k, v in os.environ.items() if k not in _PROXY_VARS}
    return subprocess.run(command, cwd=ROOT, env=env).returncode


if __name__ == "__main__":
    sys.exit(main())
