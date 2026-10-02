#!/usr/bin/env python3
"""Mirror ONNX Runtime's CMake FetchContent dependencies via `git` and point
`cmake/deps.txt` at the local copies.

Why: some build hosts can reach GitHub over git but not its archive/release
download endpoints (codeload / objects.githubusercontent). This script clones
the *exact* commit / tag that `deps.txt` pins, packs it as
`<name>-<ref>.tar.gz` with a single top-level directory (FetchContent strips
it), and rewrites the deps.txt entry to `<local path>;<sha1 of that tarball>`.
Only the packaging differs from the upstream archive, the tree is the same
commit. Patches in `cmake/patches/` still apply because FetchContent runs them
on the extracted tree as usual. Hosts that *can* download the upstream archives
do not need this script at all.

Usage: mirror_ort_deps.py <onnxruntime checkout> <mirror dir> <dep name>...
"""
import hashlib
import os
import re
import subprocess
import sys
import tarfile


def parse_github(url):
    m = re.match(r"https://(?:github\.com|codeload\.github\.com)/([^/]+)/([^/]+)/(.*)$", url)
    if not m:
        raise ValueError(f"not a GitHub URL: {url}")
    owner, repo, rest = m.groups()
    if rest.startswith("releases/download/"):
        ref = rest.split("/")[2]
    elif rest.startswith("archive/") or rest.startswith("tar.gz/") or rest.startswith("zip/"):
        ref = rest.split("/", 1)[1]
        ref = ref[len("refs/tags/"):] if ref.startswith("refs/tags/") else ref
        ref = ref.split("/")[0]  # eigen-mirror style: <sha>/<name>.zip
        ref = re.sub(r"\.(zip|tar\.gz)$", "", ref)
    else:
        raise ValueError(f"unsupported GitHub URL form: {url}")
    return f"https://github.com/{owner}/{repo}.git", ref


def git(*args, cwd=None):
    subprocess.check_call(["git", *args], cwd=cwd)


def mirror(name, url, mirror_dir):
    remote, ref = parse_github(url)
    src = os.path.join(mirror_dir, "src", name)
    if not os.path.isdir(os.path.join(src, ".git")):
        os.makedirs(src, exist_ok=True)
        git("init", "-q", cwd=src)
        git("remote", "add", "origin", remote, cwd=src)
        # A tag name or a full commit SHA; GitHub serves both shallowly.
        target = ref if re.fullmatch(r"[0-9a-f]{40}", ref) else f"refs/tags/{ref}"
        git("fetch", "-q", "--depth", "1", "origin", target, cwd=src)
        git("checkout", "-q", "FETCH_HEAD", cwd=src)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=src, text=True).strip()
    out = os.path.join(mirror_dir, f"{name}-{ref}.tar.gz")
    if not os.path.exists(out):
        prefix = f"{name}-{ref}/"
        tmp = out + ".tmp"
        with open(tmp, "wb") as fh:
            subprocess.check_call(["git", "archive", "--format=tar.gz", f"--prefix={prefix}", "HEAD"], cwd=src, stdout=fh)
        os.replace(tmp, out)
    with open(out, "rb") as fh:
        sha1 = hashlib.sha1(fh.read()).hexdigest()
    return out, sha1, commit


def main():
    ort, mirror_dir, names = sys.argv[1], os.path.abspath(sys.argv[2]), sys.argv[3:]
    os.makedirs(mirror_dir, exist_ok=True)
    deps_path = os.path.join(ort, "cmake", "deps.txt")
    with open(deps_path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    wanted = set(names)
    done = set()
    for i, line in enumerate(lines):
        if not line or line.startswith("#"):
            continue
        name, url, _sha1 = line.split(";")
        if name not in wanted:
            continue
        if not url.startswith("https://"):
            done.add(name)  # already rewritten by an earlier run
            continue
        path, sha1, commit = mirror(name, url, mirror_dir)
        lines[i] = f"{name};{path};{sha1}"
        print(f"{name}: {url} -> {commit}", flush=True)
        done.add(name)
    missing = wanted - done
    if missing:
        raise SystemExit(f"not found in deps.txt: {sorted(missing)}")
    with open(deps_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
