#!/usr/bin/env python3
"""Check an e2e `latest.json` against the app's real parsing rules.

Mirrors, rule for rule:
  - lib/core/update/update_source.dart  GitHubReleaseUpdateSource._parseRelease
    (tag_name / html_url / assets[] selection / id / name / size / digest)
  - lib/core/update/update_model.dart   AppRelease.normalizeVersion / isVersionNewer /
    normalizeSha256
  - android/.../platform/update/AppUpdateContract.kt  parseGithubAsset
    (the canonical asset URL the native layer re-validates)

It is a hand port (no Dart toolchain needed), so keep it in lockstep with those
files. Usage:

  python check_latest_json.py latest.json --current-version 0.11.5 \
      [--apk app-B.apk] [--abi x86_64] [--release-file <served path>]

Exit 0 and print a summary when the JSON would be accepted as a newer release
with a trusted canonical asset URL; exit 1 with the reasons otherwise.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

OWNER, REPO = "CampusHub-JXU", "ZJXU-CampusHub"
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")


def normalize_version(value: str) -> str:
    v = value.strip()
    if v[:1] in ("v", "V"):
        v = v[1:]
    if "+" in v:
        v = v[: v.index("+")]
    return v.strip()


def segments(value: str):
    if not value:
        return None
    out = []
    for part in value.split("."):
        part = part.strip()
        if not re.fullmatch(r"[+-]?\d+", part):
            return None
        out.append(int(part))
    return out or None


def is_version_newer(candidate: str, current: str) -> bool:
    a, b = normalize_version(candidate), normalize_version(current)
    sa, sb = segments(a), segments(b)
    if sa is None or sb is None:
        return a > b
    for i in range(max(len(sa), len(sb))):
        x = sa[i] if i < len(sa) else 0
        y = sb[i] if i < len(sb) else 0
        if x != y:
            return x > y
    return False


def normalize_sha256(raw) -> str | None:
    if not isinstance(raw, str):
        return None
    v = raw.strip()
    if v.lower().startswith("sha256:"):
        v = v[len("sha256:"):].strip()
    return v.lower() if SHA256_RE.match(v) else None


def safe_segment(seg: str) -> bool:
    return bool(seg) and seg not in (".", "..") and len(seg) <= 256 and not any(
        c in "/\\" or ord(c) < 0x20 or ord(c) == 0x7F for c in seg
    )


def safe_apk_name(name: str) -> bool:
    return (
        safe_segment(name)
        and name.lower().endswith(".apk")
        and ".." not in name
    )


def canonical_github_asset(raw: str):
    """AppUpdateContract.parseGithubAsset -> (tag, fileName) or None."""
    parts = urlsplit(raw)
    if parts.scheme.lower() != "https" or parts.username or parts.password:
        return None
    if parts.port is not None or parts.query or parts.fragment:
        return None
    if (parts.hostname or "").lower() != "github.com":
        return None
    segs = [unquote(s) for s in parts.path.split("/")[1:]]
    if len(segs) != 6 or segs[0] != OWNER or segs[1] != REPO:
        return None
    if segs[2] != "releases" or segs[3] != "download":
        return None
    tag, name = segs[4], segs[5]
    if not safe_segment(tag) or not safe_apk_name(name):
        return None
    return tag, name


def best_apk(assets: list[dict], device_abi: str | None):
    apks = [a for a in assets if str(a.get("name") or "").lower().endswith(".apk")]
    if not apks:
        return None
    if device_abi:
        for a in apks:
            if device_abi in str(a.get("name") or "").lower():
                return a
    return apks[0]


def str_field(asset, key):
    v = (asset or {}).get(key)
    if not isinstance(v, str):
        return None
    v = v.strip()
    return v or None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("json_file", type=Path)
    ap.add_argument("--current-version", required=True, help="installed versionName, e.g. 0.11.5")
    ap.add_argument("--apk", type=Path, help="APK whose size / sha256 must match the asset")
    ap.add_argument("--abi", default=None,
                    help="ABI suffix the Dart side would use (arm64-v8a / armeabi-v7a); "
                         "default none, which is what x86_64 emulators report")
    ap.add_argument("--served-root", type=Path,
                    help="www root; asserts <root>/<tag>/<asset name> exists")
    args = ap.parse_args()

    problems: list[str] = []
    data = json.loads(args.json_file.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        print("latest.json root is not an object", file=sys.stderr)
        return 1

    tag = (data.get("tag_name") or "").strip() if isinstance(data.get("tag_name"), str) else ""
    if not tag:
        problems.append("tag_name missing (Dart: GitHub Release 缺少 tag_name)")
    assets = [a for a in data.get("assets", []) if isinstance(a, dict)] if isinstance(data.get("assets"), list) else []
    selected = best_apk(assets, args.abi)
    chosen = selected or (assets[0] if assets else None)
    download_url = (str_field(chosen, "browser_download_url") or "")
    release_url = (data.get("html_url") or "").strip() if isinstance(data.get("html_url"), str) else ""
    if not download_url and not release_url:
        problems.append("no download url and no html_url")
    if selected is None:
        problems.append("no .apk asset selected")

    canonical = str_field(selected, "browser_download_url")
    name = str_field(selected, "name")
    size = selected.get("size") if selected else None
    asset_id = selected.get("id") if selected else None
    sha = normalize_sha256(selected.get("digest") if selected else None)

    if not isinstance(asset_id, int) or isinstance(asset_id, bool):
        problems.append("asset id is not an int (optional for Dart, but requestKey uses it)")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        problems.append("asset size is not a positive int")
    if sha is None:
        problems.append("asset digest is not sha256:<64 hex>")
    if not canonical:
        problems.append("asset browser_download_url missing")
    else:
        parsed = canonical_github_asset(canonical)
        if parsed is None:
            problems.append(f"native would reject canonical url: {canonical}")
        else:
            if parsed[0] != tag:
                problems.append(f"canonical url tag {parsed[0]!r} != tag_name {tag!r}")
            if parsed[1] != name:
                problems.append(f"canonical url file {parsed[1]!r} != asset name {name!r}")
    if tag and not is_version_newer(tag, args.current_version):
        problems.append(f"{tag} is not newer than {args.current_version}")
    if not data.get("published_at"):
        problems.append("published_at missing (Dart falls back to epoch 0)")

    if args.apk:
        blob = args.apk.read_bytes()
        if size != len(blob):
            problems.append(f"asset size {size} != {args.apk.name} size {len(blob)}")
        if sha != hashlib.sha256(blob).hexdigest():
            problems.append(f"asset digest != sha256({args.apk.name})")
    if args.served_root and tag and name:
        if not (args.served_root / tag / name).is_file():
            problems.append(f"{args.served_root / tag / name} is not served")

    if problems:
        print("latest.json would NOT work:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1
    print(f"latest.json OK: tag={tag} asset={name} size={size} sha256={sha}")
    print(f"  canonical={canonical}")
    print(f"  newer than {args.current_version}: yes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
