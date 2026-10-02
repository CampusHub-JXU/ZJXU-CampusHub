#!/usr/bin/env python3
"""Download real captcha samples for OCR accuracy evaluation.

Sources (plain GET, no login, no credentials, nothing is POSTed):
  cas: https://newca.zjxu.edu.cn/cas/captcha.html?t=<ms>   (Referer: CAS login page)
  zf : https://jwzx.zjxu.edu.cn/jwglxt/kaptcha?time=<ms>   (Referer: login page)

Output goes to .ocr_work/samples/{cas,zf}/ (git-ignored). Stdlib only.

Usage: python tools/ocr_slim/collect_captchas.py [--count 200] [--out .ocr_work/samples]
"""
import argparse
import http.cookiejar
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/124.0 Mobile Safari/537.36")

SOURCES = {
    "cas": {
        "prefix": "cas",
        "warmup": "https://newca.zjxu.edu.cn/cas/login",
        "referer": "https://newca.zjxu.edu.cn/cas/login",
        "url": "https://newca.zjxu.edu.cn/cas/captcha.html?t={ms}",
    },
    "zf": {
        "prefix": "zf",
        "warmup": "https://jwzx.zjxu.edu.cn/jwglxt/xtgl/login_slogin.html",
        "referer": "https://jwzx.zjxu.edu.cn/jwglxt/xtgl/login_slogin.html",
        "url": "https://jwzx.zjxu.edu.cn/jwglxt/kaptcha?time={ms}",
    },
}

MIN_GAP = 0.8          # seconds between requests
TIMEOUT = 15
MAX_RETRIES = 2
MAX_CONSEC_FAIL = 6
REFRESH_SESSION_EVERY = 5  # fresh cookie session every N images


def new_opener():
    jar = http.cookiejar.CookieJar()
    # Ignore system proxy, same as the app (ignoreSystemProxy=true).
    return urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(jar),
    )


def get(opener, url, referer, accept):
    req = urllib.request.Request(url, headers={
        "User-Agent": UA, "Referer": referer, "Accept": accept})
    with opener.open(req, timeout=TIMEOUT) as r:
        return r.status, r.headers.get("Content-Type", ""), r.read()


def is_image(data):
    return data[:3] == b"\xff\xd8\xff" or data[:8] == b"\x89PNG\r\n\x1a\n" or data[:4] == b"GIF8"


def collect(name, count, out_root):
    cfg = SOURCES[name]
    out_dir = os.path.join(out_root, name)
    os.makedirs(out_dir, exist_ok=True)
    got = 0
    consec_fail = 0
    opener = None
    last = 0.0
    idx = 0
    # resume: count existing files
    existing = sorted(f for f in os.listdir(out_dir) if f.startswith(cfg["prefix"] + "_"))
    idx = len(existing)
    got = idx
    seen = set()
    for f in existing:
        with open(os.path.join(out_dir, f), "rb") as fh:
            seen.add(hash(fh.read()))
    while got < count:
        if consec_fail >= MAX_CONSEC_FAIL:
            print(f"[{name}] too many consecutive failures, stopping at {got}")
            break
        if opener is None or (got % REFRESH_SESSION_EVERY == 0 and got != 0 and opener_age >= REFRESH_SESSION_EVERY):
            opener = new_opener()
            opener_age = 0
            try:
                time.sleep(max(0, MIN_GAP - (time.time() - last)))
                last = time.time()
                get(opener, cfg["warmup"], cfg["warmup"], "text/html,*/*")
            except Exception as e:  # warmup is best-effort
                print(f"[{name}] warmup failed: {e}")
        ok = False
        for attempt in range(MAX_RETRIES + 1):
            time.sleep(max(0, MIN_GAP - (time.time() - last)))
            last = time.time()
            try:
                ms = int(time.time() * 1000)
                status, ctype, data = get(opener, cfg["url"].format(ms=ms),
                                          cfg["referer"], "image/*,*/*;q=0.8")
                if status == 200 and "html" not in ctype.lower() and is_image(data):
                    h = hash(data)
                    opener_age += 1
                    if h in seen:
                        ok = True  # duplicate bytes: not counted, not a failure
                        print(f"[{name}] duplicate image skipped")
                        break
                    seen.add(h)
                    idx += 1
                    got += 1
                    path = os.path.join(out_dir, f"{cfg['prefix']}_{idx:04d}.jpg")
                    with open(path, "wb") as fh:
                        fh.write(data)
                    ok = True
                    if got % 20 == 0 or got == count:
                        print(f"[{name}] {got}/{count}")
                    break
                print(f"[{name}] bad response status={status} ctype={ctype} len={len(data)}")
            except (urllib.error.URLError, OSError) as e:
                print(f"[{name}] request error (attempt {attempt + 1}): {e}")
        consec_fail = 0 if ok else consec_fail + 1
    return got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=200)
    ap.add_argument("--out", default=os.path.join(".ocr_work", "samples"))
    ap.add_argument("--only", choices=list(SOURCES))
    args = ap.parse_args()
    names = [args.only] if args.only else list(SOURCES)
    for n in names:
        total = collect(n, args.count, args.out)
        print(f"[{n}] done: {total} images")
    return 0


if __name__ == "__main__":
    sys.exit(main())
