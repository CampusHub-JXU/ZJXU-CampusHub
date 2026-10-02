#!/usr/bin/env python3
"""Estimate the release APK size after the OCR slimming, from a published APK.

Takes an existing release APK (e.g. JXU-CampusHub-v0.9.3-arm64-v8a.apk), swaps
in the minimal ONNX Runtime native libraries and the new captcha assets, drops
the old model / charset, and writes an unsigned, 16 KiB-aligned APK whose size
is the estimate. Entries keep the original storage mode (native libs stored,
assets deflated), like AGP packaging.

What it does NOT model (all small next to the ~30 MB native delta): dex
changes (the ORT Java API is the same upstream source; the official AAR's
telemetry bridge classes disappear), resources.arsc and the v2/v3 signature
block. The output is never installed or published: it only exists to measure.

Calibration: pass `-` as <aar> to repack the APK unchanged (minus signature);
the difference to the original size is the packaging error of this estimate.

Usage: repack_apk_size.py <release.apk> <aar|-> <assets dir> <abi> <out.apk>
"""
import os
import sys
import zipfile

ALIGN_SO = 16384
ALIGN_OTHER = 4
# META-INF/LICENSE-1DS ships with the official AAR's telemetry (1DS) SDK, which
# the minimal build (--no_telemetry) does not contain.
DROP = {"assets/captcha_ocr/common_old.onnx", "assets/captcha_ocr/charset_old.txt", "META-INF/LICENSE-1DS"}
NEW_ASSETS = ["common_old_alnum.ort", "charset_alnum.txt"]


def main():
    apk, aar, assets_dir, abi, out = sys.argv[1:6]
    identity = aar == "-"
    libs = {}
    if not identity:
        with zipfile.ZipFile(aar) as za:
            libs = {f"lib/{abi}/{n}": za.read(f"jni/{abi}/{n}") for n in ("libonnxruntime.so", "libonnxruntime4j_jni.so")}
    entries = []
    with zipfile.ZipFile(apk) as zin:
        for info in zin.infolist():
            if not identity and info.filename in DROP:
                continue
            data = libs.pop(info.filename, None)
            if data is None:
                data = zin.read(info.filename)
            entries.append((info.filename, info.compress_type, data))
    assert not libs, f"ORT libs not found in APK: {sorted(libs)}"
    for name in [] if identity else NEW_ASSETS:
        with open(os.path.join(assets_dir, name), "rb") as fh:
            entries.append((f"assets/captcha_ocr/{name}", zipfile.ZIP_DEFLATED, fh.read()))

    with open(out, "wb") as raw:
        with zipfile.ZipFile(raw, "w") as zout:
            for name, ctype, data in entries:
                zi = zipfile.ZipInfo(name, date_time=(1981, 1, 1, 1, 1, 0))
                zi.compress_type = ctype
                if ctype == zipfile.ZIP_STORED:
                    align = ALIGN_SO if name.endswith(".so") else ALIGN_OTHER
                    # local header = 30 bytes + name + extra; pad extra so data offset aligns
                    offset = raw.tell() + 30 + len(name.encode())
                    pad = (-offset) % align
                    zi.extra = b"\0" * pad
                zout.writestr(zi, data, compresslevel=9 if ctype == zipfile.ZIP_DEFLATED else None)
    print(f"{os.path.basename(apk)} {os.path.getsize(apk)} -> {os.path.basename(out)} {os.path.getsize(out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
