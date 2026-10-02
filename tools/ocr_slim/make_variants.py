#!/usr/bin/env python3
"""Build captcha OCR model variants from the shipped ddddocr `common_old.onnx`.

Finding that drives this script: `common_old.onnx` is *already* dynamically
int8-quantized (ConvInteger / MatMulInteger / DynamicQuantizeLSTM, uint8/int8
weights), so another dynamic int8 pass is not applicable. 8.4M of its 13.5M
weights are the final 1024x8210 classifier `135_quantized` (+ bias `136`), and
the app only ever keeps ASCII letters/digits from it (CtcDecoder.kt).

Source: `ddddocr/common_old.onnx` from the official ddddocr 1.6.1 wheel
(downloaded from PyPI and SHA-256 verified, or --source <path>), plus
tools/ocr_slim/charset_old.txt (the 8209-char charset the app shipped before).

Variants written to --out:
  common_old.onnx / .ort      unchanged graph, plus its ORT-format conversion
  alnum.onnx / alnum.ort      classifier sliced to blank + the 62 ASCII alnum
                              classes (shipped as captcha_ocr/common_old_alnum.ort)
  charset_alnum.txt           the matching charset (index 0 = blank is implicit)
  *.required_operators_and_types.config
                              ops/types for the minimal ORT build
                              (alnum's copy lives at tools/ocr_slim/)

The classifier weight is quantized per-tensor (scalar scale / zero point) and
the class axis is independent in MatMulInteger + bias Add, so every kept class
logit is bit-identical to the original model. Only the argmax domain shrinks:
frames whose original argmax was a non-alnum class now pick blank or the best
alnum class (see ocr_eval.py `nonalnum` column for how often that happens).

Usage: python tools/ocr_slim/make_variants.py [--out .ocr_work/variants] [--install]
  --install copies alnum.ort / charset_alnum.txt into the plugin assets and the
  ops config into tools/ocr_slim/.
Requires: onnx, onnxruntime==1.30.0 (same version as the Android runtime, so the
.ort format version matches).
"""
import argparse
import hashlib
import io
import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile

import numpy as np
import onnx
from onnx import numpy_helper

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
ASSETS = os.path.join(REPO, "packages", "campus_captcha_ocr", "android", "src", "main", "assets", "captcha_ocr")
WHEEL_URL = ("https://files.pythonhosted.org/packages/0e/48/cbaed3981b8d8d51141b9b4779b811f4728e65d952a1e3e2e5e929539183/"
             "ddddocr-1.6.1-py3-none-any.whl")
WHEEL_SHA256 = "c7c70f4ae2d0335440ae8b272eea48c9f6888ecef46785fe2311f0c97a133935"
MODEL_SHA256 = "b8f2ad9cbc1f2e3922a6cb9459e30824e7e2467f3fb4fd61420640e34ea0bf68"
CHARSET_SHA256 = "2ad1d606078ede388943ef28b2cab3ce2ee50f81d42ff275572a69a814d136f0"
CLASSIFIER_W = "135_quantized"
CLASSIFIER_B = "136"


def is_ascii_alnum(ch):
    return ("0" <= ch <= "9") or ("a" <= ch <= "z") or ("A" <= ch <= "Z")


def prune(src_model, src_charset, dst_model, dst_charset):
    model = onnx.load(src_model)
    with open(src_charset, "rb") as fh:
        charset = fh.read().decode("utf-8")
    table = ["\0"] + list(charset)
    keep = [0] + [i for i, ch in enumerate(table) if i > 0 and is_ascii_alnum(ch)]
    assert len(keep) == 63, len(keep)
    inits = {t.name: t for t in model.graph.initializer}
    w = numpy_helper.to_array(inits[CLASSIFIER_W])
    b = numpy_helper.to_array(inits[CLASSIFIER_B])
    assert w.shape == (1024, len(table)) and b.shape == (len(table),), (w.shape, b.shape)
    for scalar in ("135_scale", "135_zero_point"):
        assert numpy_helper.to_array(inits[scalar]).shape == (), f"{scalar} must be per-tensor"
    inits[CLASSIFIER_W].CopyFrom(numpy_helper.from_array(np.ascontiguousarray(w[:, keep]), CLASSIFIER_W))
    inits[CLASSIFIER_B].CopyFrom(numpy_helper.from_array(np.ascontiguousarray(b[keep]), CLASSIFIER_B))
    onnx.checker.check_model(model)
    onnx.save(model, dst_model)
    with open(dst_charset, "wb") as fh:
        fh.write("".join(table[i] for i in keep[1:]).encode("utf-8"))
    return keep


def sha256(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def fetch_model(dst):
    print(f"downloading {WHEEL_URL}", flush=True)
    data = urllib.request.urlopen(WHEEL_URL).read()
    if hashlib.sha256(data).hexdigest() != WHEEL_SHA256:
        raise SystemExit("ddddocr wheel SHA-256 mismatch")
    with zipfile.ZipFile(io.BytesIO(data)) as zf, open(dst, "wb") as fh:
        fh.write(zf.read("ddddocr/common_old.onnx"))


def to_ort(onnx_path, out_dir):
    # Writes <name>.ort plus <name>.required_operators_and_types.config (type-reduced).
    subprocess.check_call([
        sys.executable, "-m", "onnxruntime.tools.convert_onnx_models_to_ort",
        "--output_dir", out_dir,
        "--optimization_style", "Fixed",
        # Avoid x86-only fusions (NCHWc etc.): the .ort runs on arm64/armv7
        # devices and the x86_64 emulator alike.
        "--target_platform", "arm",
        # Also emit the per-type config consumed by
        # --enable_reduced_operator_type_support.
        "--enable_type_reduction",
        onnx_path,
    ])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(".ocr_work", "variants"))
    ap.add_argument("--source", help="local common_old.onnx instead of downloading the wheel")
    ap.add_argument("--install", action="store_true")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    base = os.path.join(args.out, "common_old.onnx")
    if args.source:
        shutil.copyfile(args.source, base)
    elif not os.path.exists(base) or sha256(base) != MODEL_SHA256:
        fetch_model(base)
    if sha256(base) != MODEL_SHA256:
        raise SystemExit("common_old.onnx SHA-256 mismatch")
    charset = os.path.join(HERE, "charset_old.txt")
    if sha256(charset) != CHARSET_SHA256:
        raise SystemExit("charset_old.txt SHA-256 mismatch")
    alnum = os.path.join(args.out, "alnum.onnx")
    prune(base, charset, alnum, os.path.join(args.out, "charset_alnum.txt"))
    to_ort(base, args.out)
    to_ort(alnum, args.out)
    for f in sorted(os.listdir(args.out)):
        p = os.path.join(args.out, f)
        print(f"{os.path.getsize(p):>10}  {sha256(p)[:16]}  {f}")
    if args.install:
        shutil.copyfile(os.path.join(args.out, "alnum.ort"), os.path.join(ASSETS, "common_old_alnum.ort"))
        shutil.copyfile(os.path.join(args.out, "charset_alnum.txt"), os.path.join(ASSETS, "charset_alnum.txt"))
        with open(os.path.join(args.out, "alnum.required_operators_and_types.config"), encoding="utf-8") as fh:
            lines = fh.read().splitlines()
        # Drop the absolute local path the converter writes into the header.
        lines = [l if not l.startswith("# - ") else "# - captcha_ocr/common_old_alnum.ort (tools/ocr_slim/make_variants.py)" for l in lines]
        with open(os.path.join(HERE, "required_operators_and_types.config"), "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
