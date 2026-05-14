#!/usr/bin/env python3
"""Extensible repository diagnostics for CI and local troubleshooting.

The script focuses on project-specific risks that ordinary Flutter tests do not
see: route/catalog drift, navigation typos, missing feature tests, oversized
files, naming drift, and known architecture smells.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable


ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class DiagnosticIssue:
    severity: str
    check_id: str
    message: str
    path: Path | None = None
    line: int | None = None
    help: str = ""

    def to_dict(self) -> dict[str, object]:
        result: dict[str, object] = {
            "severity": self.severity,
            "check_id": self.check_id,
            "message": self.message,
        }
        if self.path is not None:
            result["path"] = str(self.path.as_posix())
        if self.line is not None:
            result["line"] = self.line
        if self.help:
            result["help"] = self.help
        return result


@dataclass(frozen=True)
class DiagnosticCheck:
    check_id: str
    title: str
    description: str
    run: Callable[["RepoView"], list[DiagnosticIssue]]


@dataclass
class CheckResult:
    check: DiagnosticCheck
    issues: list[DiagnosticIssue] = field(default_factory=list)

    @property
    def status(self) -> str:
        if any(issue.severity == "error" for issue in self.issues):
            return "error"
        if self.issues:
            return "warning"
        return "pass"


class RepoView:
    def __init__(self, root: Path) -> None:
        self.root = root

    def read_text(self, relative: str) -> str:
        return (self.root / relative).read_text(encoding="utf-8")

    def dart_files(self, *roots: str) -> list[Path]:
        files: list[Path] = []
        for root in roots:
            base = self.root / root
            if not base.exists():
                continue
            files.extend(path for path in base.rglob("*.dart") if path.is_file())
        return sorted(files)

    def relative(self, path: Path) -> Path:
        return path.relative_to(self.root)


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def line_at(path: Path, needle: str) -> int | None:
    try:
        for index, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if needle in line:
                return index
    except UnicodeDecodeError:
        return None
    return None


def extract_route_names(routes_source: str) -> set[str]:
    return set(re.findall(r"\bname:\s*'([^']+)'", routes_source))


def extract_feature_entries(catalog_source: str) -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []
    for match in re.finditer(r"FeatureEntryDefinition\s*\((.*?)\n\s*\)", catalog_source, re.S):
        block = match.group(1)
        entry_id = re.search(r"\bid:\s*'([^']+)'", block)
        route_name = re.search(r"\brouteName:\s*'([^']+)'", block)
        title = re.search(r"\btitle:\s*'([^']+)'", block)
        entries.append(
            {
                "id": entry_id.group(1) if entry_id else "",
                "routeName": route_name.group(1) if route_name else "",
                "title": title.group(1) if title else "",
            }
        )
    return entries


def check_route_catalog_consistency(repo: RepoView) -> list[DiagnosticIssue]:
    routes_path = repo.root / "lib/app/routes.dart"
    catalog_path = repo.root / "lib/core/config/feature_entry_catalog.dart"
    if not routes_path.exists() or not catalog_path.exists():
        return [
            DiagnosticIssue(
                "error",
                "route_catalog_consistency",
                "Missing route or feature catalog file.",
                help="Both lib/app/routes.dart and lib/core/config/feature_entry_catalog.dart are required.",
            )
        ]

    routes_source = routes_path.read_text(encoding="utf-8")
    catalog_source = catalog_path.read_text(encoding="utf-8")
    route_names = extract_route_names(routes_source)
    entries = extract_feature_entries(catalog_source)
    issues: list[DiagnosticIssue] = []

    seen_ids: dict[str, int] = {}
    seen_routes: dict[str, int] = {}
    for entry in entries:
        entry_id = entry["id"]
        route_name = entry["routeName"]
        if not entry_id:
            issues.append(
                DiagnosticIssue(
                    "error",
                    "route_catalog_consistency",
                    "Feature entry is missing id.",
                    repo.relative(catalog_path),
                )
            )
        elif entry_id in seen_ids:
            issues.append(
                DiagnosticIssue(
                    "error",
                    "route_catalog_consistency",
                    f"Duplicate feature entry id: {entry_id}",
                    repo.relative(catalog_path),
                    line_at(catalog_path, f"id: '{entry_id}'"),
                    "Feature ids must remain stable and unique for caching, sorting, and UI tests.",
                )
            )
        else:
            seen_ids[entry_id] = 1

        if not route_name:
            issues.append(
                DiagnosticIssue(
                    "error",
                    "route_catalog_consistency",
                    f"Feature entry {entry_id or '<unknown>'} is missing routeName.",
                    repo.relative(catalog_path),
                    line_at(catalog_path, f"id: '{entry_id}'") if entry_id else None,
                )
            )
            continue

        if route_name not in route_names:
            issues.append(
                DiagnosticIssue(
                    "error",
                    "route_catalog_consistency",
                    f"Feature entry {entry_id} points to missing route '{route_name}'.",
                    repo.relative(catalog_path),
                    line_at(catalog_path, f"routeName: '{route_name}'"),
                    "Add a matching GoRoute name in lib/app/routes.dart or fix the catalog routeName.",
                )
            )

        if route_name in seen_routes:
            issues.append(
                DiagnosticIssue(
                    "warning",
                    "route_catalog_consistency",
                    f"Multiple feature entries point to route '{route_name}'.",
                    repo.relative(catalog_path),
                    line_at(catalog_path, f"routeName: '{route_name}'"),
                    "This is allowed only when the duplicate entries intentionally expose the same destination.",
                )
            )
        seen_routes[route_name] = 1

    return issues


def check_navigation_named_routes(repo: RepoView) -> list[DiagnosticIssue]:
    routes_source = repo.read_text("lib/app/routes.dart")
    route_names = extract_route_names(routes_source)
    issues: list[DiagnosticIssue] = []
    pattern = re.compile(r"\b(?:pushNamed|goNamed)\s*(?:<[^>]+>)?\s*\(\s*'([^']+)'")

    for path in repo.dart_files("lib"):
        source = path.read_text(encoding="utf-8")
        for match in pattern.finditer(source):
            route_name = match.group(1)
            if route_name not in route_names:
                issues.append(
                    DiagnosticIssue(
                        "error",
                        "navigation_named_routes",
                        f"Named navigation points to missing route '{route_name}'.",
                        repo.relative(path),
                        line_number(source, match.start()),
                        "Fix the route name or register it in lib/app/routes.dart.",
                    )
                )
    return issues


def check_dart_file_naming(repo: RepoView) -> list[DiagnosticIssue]:
    issues: list[DiagnosticIssue] = []
    valid = re.compile(r"^[a-z][a-z0-9_]*\.dart$")
    for path in repo.dart_files("lib", "test", "integration_test"):
        if valid.match(path.name):
            continue
        issues.append(
            DiagnosticIssue(
                "error",
                "dart_file_naming",
                f"Dart file name is not snake_case: {path.name}",
                repo.relative(path),
                help="Rename Dart files to snake_case.dart to keep imports and tests predictable.",
            )
        )
    return issues


def check_test_file_naming(repo: RepoView) -> list[DiagnosticIssue]:
    issues: list[DiagnosticIssue] = []
    for path in repo.dart_files("test"):
        relative = repo.relative(path)
        if relative.parts[:2] == ("test", "helpers"):
            continue
        if path.name.endswith("_test.dart"):
            continue
        issues.append(
            DiagnosticIssue(
                "error",
                "test_file_naming",
                f"Test file must end with _test.dart: {path.name}",
                relative,
                help="The Flutter test runner and CI diagnostics assume *_test.dart naming.",
            )
        )
    return issues


def check_large_dart_files(repo: RepoView) -> list[DiagnosticIssue]:
    issues: list[DiagnosticIssue] = []
    for path in repo.dart_files("lib"):
        line_count = len(path.read_text(encoding="utf-8").splitlines())
        if line_count > 1600:
            severity = "error"
        elif line_count >= 800:
            severity = "warning"
        else:
            continue
        issues.append(
            DiagnosticIssue(
                severity,
                "large_dart_files",
                f"Dart file has {line_count} lines.",
                repo.relative(path),
                help="Files above 800 lines are hard to review; above 1600 lines block CI diagnostics.",
            )
        )
    return issues


def check_feature_test_presence(repo: RepoView) -> list[DiagnosticIssue]:
    features_root = repo.root / "lib/features"
    tests_root = repo.root / "test/features"
    if not features_root.exists():
        return []
    issues: list[DiagnosticIssue] = []
    for feature_dir in sorted(path for path in features_root.iterdir() if path.is_dir()):
        test_dir = tests_root / feature_dir.name
        direct_test = tests_root / f"{feature_dir.name}_test.dart"
        has_tests = test_dir.exists() and any(test_dir.rglob("*_test.dart"))
        has_tests = has_tests or direct_test.exists()
        if not has_tests:
            issues.append(
                DiagnosticIssue(
                    "warning",
                    "feature_test_presence",
                    f"Feature '{feature_dir.name}' has no dedicated test under test/features.",
                    repo.relative(feature_dir),
                    help="Add parser/service/widget coverage before relying on manual checks for this feature.",
                )
            )
    return issues


def check_feature_network_discipline(repo: RepoView) -> list[DiagnosticIssue]:
    issues: list[DiagnosticIssue] = []
    pattern = re.compile(r"\bDio\s*\(")
    for path in repo.dart_files("lib/features"):
        source = path.read_text(encoding="utf-8")
        for match in pattern.finditer(source):
            issues.append(
                DiagnosticIssue(
                    "warning",
                    "feature_network_discipline",
                    "Feature code creates a Dio client directly.",
                    repo.relative(path),
                    line_number(source, match.start()),
                    "Prefer DioClient.instance.dio unless the feature has a documented binary/legacy edge case.",
                )
            )
    return issues


def check_debug_output_discipline(repo: RepoView) -> list[DiagnosticIssue]:
    issues: list[DiagnosticIssue] = []
    pattern = re.compile(r"\b(?:print|debugPrint)\s*\(")
    allowed = {
        Path("lib/core/logging/app_logger.dart"),
    }
    for path in repo.dart_files("lib"):
        relative = repo.relative(path)
        if relative in allowed:
            continue
        source = path.read_text(encoding="utf-8")
        for match in pattern.finditer(source):
            issues.append(
                DiagnosticIssue(
                    "warning",
                    "debug_output_discipline",
                    "Library code writes directly to print/debugPrint.",
                    relative,
                    line_number(source, match.start()),
                    "Use AppLogger so log levels, categories, and scrubbing stay centralized.",
                )
            )
    return issues


CHECKS: tuple[DiagnosticCheck, ...] = (
    DiagnosticCheck(
        "route_catalog_consistency",
        "Feature catalog routes resolve",
        "Visible feature entries must point to registered GoRouter names.",
        check_route_catalog_consistency,
    ),
    DiagnosticCheck(
        "navigation_named_routes",
        "Named navigation routes resolve",
        "Literal context.pushNamed/goNamed calls must reference registered routes.",
        check_navigation_named_routes,
    ),
    DiagnosticCheck(
        "dart_file_naming",
        "Dart files use snake_case",
        "File names under lib, test, and integration_test must stay predictable.",
        check_dart_file_naming,
    ),
    DiagnosticCheck(
        "test_file_naming",
        "Test files use *_test.dart",
        "Test files must follow Flutter test discovery naming.",
        check_test_file_naming,
    ),
    DiagnosticCheck(
        "large_dart_files",
        "Large Dart files are visible",
        "Warns on files above 800 lines and errors above 1600 lines.",
        check_large_dart_files,
    ),
    DiagnosticCheck(
        "feature_test_presence",
        "Features have dedicated tests",
        "Every lib/features module should have a matching test/features area.",
        check_feature_test_presence,
    ),
    DiagnosticCheck(
        "feature_network_discipline",
        "Feature networking stays centralized",
        "Flags direct Dio construction inside lib/features.",
        check_feature_network_discipline,
    ),
    DiagnosticCheck(
        "debug_output_discipline",
        "Logging uses AppLogger",
        "Flags direct print/debugPrint in library code outside the logger.",
        check_debug_output_discipline,
    ),
)


def run_checks(repo: RepoView, only: set[str] | None = None, skip: set[str] | None = None) -> list[CheckResult]:
    results: list[CheckResult] = []
    for check in CHECKS:
        if only is not None and check.check_id not in only:
            continue
        if skip is not None and check.check_id in skip:
            continue
        results.append(CheckResult(check=check, issues=check.run(repo)))
    return results


def write_json_report(results: list[CheckResult], output_dir: Path) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / "test_diagnostics.json"
    payload = {
        "summary": summarize(results),
        "checks": [
            {
                "id": result.check.check_id,
                "title": result.check.title,
                "status": result.status,
                "description": result.check.description,
                "issues": [issue.to_dict() for issue in result.issues],
            }
            for result in results
        ],
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return path


def write_markdown_report(results: list[CheckResult], output_dir: Path) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / "test_diagnostics.md"
    summary = summarize(results)
    lines = [
        "# Test Diagnostics Report",
        "",
        f"- Checks: {summary['checks']}",
        f"- Errors: {summary['errors']}",
        f"- Warnings: {summary['warnings']}",
        f"- Passed checks: {summary['passed_checks']}",
        "",
        "| Status | Check | Issues |",
        "| --- | --- | ---: |",
    ]
    for result in results:
        lines.append(f"| {result.status} | `{result.check.check_id}` - {result.check.title} | {len(result.issues)} |")
    lines.append("")

    for result in results:
        if not result.issues:
            continue
        lines.append(f"## {result.check.check_id}")
        lines.append("")
        lines.append(result.check.description)
        lines.append("")
        for issue in result.issues:
            location = ""
            if issue.path is not None:
                location = str(issue.path.as_posix())
                if issue.line is not None:
                    location += f":{issue.line}"
            lines.append(f"- **{issue.severity}** {location} - {issue.message}")
            if issue.help:
                lines.append(f"  - {issue.help}")
        lines.append("")

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def summarize(results: list[CheckResult]) -> dict[str, int]:
    errors = 0
    warnings = 0
    for result in results:
        for issue in result.issues:
            if issue.severity == "error":
                errors += 1
            elif issue.severity == "warning":
                warnings += 1
    return {
        "checks": len(results),
        "errors": errors,
        "warnings": warnings,
        "passed_checks": sum(1 for result in results if result.status == "pass"),
    }


def print_console_summary(results: list[CheckResult]) -> None:
    summary = summarize(results)
    print(
        "test diagnostics: "
        f"{summary['passed_checks']}/{summary['checks']} checks passed, "
        f"{summary['errors']} errors, {summary['warnings']} warnings"
    )
    for result in results:
        print(f"- {result.status.upper():7} {result.check.check_id}: {len(result.issues)} issue(s)")
        for issue in result.issues[:8]:
            location = ""
            if issue.path is not None:
                location = str(issue.path.as_posix())
                if issue.line is not None:
                    location += f":{issue.line}"
                location += " "
            print(f"  [{issue.severity}] {location}{issue.message}")
        if len(result.issues) > 8:
            print(f"  ... {len(result.issues) - 8} more")


def parse_id_list(values: Iterable[str] | None) -> set[str] | None:
    if not values:
        return None
    result: set[str] = set()
    for value in values:
        result.update(part.strip() for part in value.split(",") if part.strip())
    return result


def validate_check_ids(ids: set[str] | None) -> None:
    if ids is None:
        return
    known = {check.check_id for check in CHECKS}
    unknown = sorted(ids - known)
    if unknown:
        raise SystemExit(f"Unknown diagnostic check id(s): {', '.join(unknown)}")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        (root / "lib/app").mkdir(parents=True)
        (root / "lib/core/config").mkdir(parents=True)
        (root / "lib/features/demo").mkdir(parents=True)
        (root / "test/features/demo").mkdir(parents=True)
        (root / "lib/app/routes.dart").write_text(
            "GoRoute(path: '/demo', name: 'demo', builder: (_, __) => DemoPage());\n"
            "void nav(context) => context.pushNamed('missing-route');\n",
            encoding="utf-8",
        )
        (root / "lib/core/config/feature_entry_catalog.dart").write_text(
            "FeatureEntryDefinition(\n"
            "  id: 'demo',\n"
            "  title: 'Demo',\n"
            "  routeName: 'missing-route',\n"
            ")\n",
            encoding="utf-8",
        )
        (root / "lib/features/demo/demo_page.dart").write_text("void main() {}\n", encoding="utf-8")
        (root / "test/features/demo/demo_test.dart").write_text("void main() {}\n", encoding="utf-8")

        repo = RepoView(root)
        results = run_checks(repo, only={"route_catalog_consistency", "navigation_named_routes"})
        issues = [issue for result in results for issue in result.issues]
        assert any(issue.check_id == "route_catalog_consistency" for issue in issues), issues
        assert any(issue.check_id == "navigation_named_routes" for issue in issues), issues
    print("test diagnostics self-test passed")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Run project-specific test diagnostics.")
    parser.add_argument("--root", type=Path, default=ROOT, help="Repository root. Defaults to this script's parent repo.")
    parser.add_argument("--output", type=Path, default=ROOT / "build/test_diagnostics", help="Report output directory.")
    parser.add_argument("--fail-on", choices=("error", "warning", "never"), default="error")
    parser.add_argument("--only", action="append", help="Comma-separated check ids to run.")
    parser.add_argument("--skip", action="append", help="Comma-separated check ids to skip.")
    parser.add_argument("--list-checks", action="store_true", help="Print available checks and exit.")
    parser.add_argument("--self-test", action="store_true", help="Run internal parser self-test and exit.")
    args = parser.parse_args(argv)

    if args.self_test:
        run_self_test()
        return 0

    if args.list_checks:
        for check in CHECKS:
            print(f"{check.check_id}: {check.title}")
        return 0

    only = parse_id_list(args.only)
    skip = parse_id_list(args.skip)
    validate_check_ids(only)
    validate_check_ids(skip)

    repo = RepoView(args.root.resolve())
    results = run_checks(repo, only=only, skip=skip)
    json_path = write_json_report(results, args.output)
    markdown_path = write_markdown_report(results, args.output)
    print_console_summary(results)
    print(f"wrote {json_path}")
    print(f"wrote {markdown_path}")

    summary = summarize(results)
    if args.fail_on == "error" and summary["errors"] > 0:
        return 1
    if args.fail_on == "warning" and (summary["errors"] > 0 or summary["warnings"] > 0):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
