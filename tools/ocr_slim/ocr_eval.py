#!/usr/bin/env python3
"""Offline evaluation of captcha OCR model variants with the Android pipeline.

Line-by-line port of the on-device pipeline so that model variants can be
compared against the shipped model before any of them goes into the APK:

  packages/campus_captcha_ocr/android/src/main/kotlin/edu/zjxu/campus_captcha_ocr/
    OcrSizeBudget.kt         -> size_budget()
    DdddocrPreprocessor.kt   -> to_input_tensor()   (luma -> Lanczos-3 H -> V)
    DdddocrEngine.kt         -> run_model()          (1,1,64,W'), (T,1,C) logits
    CtcDecoder.kt            -> ctc_decode(), mean_max_softmax()
    CampusCaptchaOcrPlugin.kt-> plugin_candidates()  (empty text -> no candidate)
  lib/core/captcha/captcha_recognizer.dart
                             -> dart_select()        (length / [A-Za-z0-9] /
                                                      confidence >= 0.5, else None)

Known, unavoidable deviation: JPEG decoding uses Pillow (libjpeg-turbo) instead
of Android BitmapFactory; both are libjpeg-derived but IDCT rounding can differ
by +-1 gray level on some pixels.

Only reads local files; never touches the network and never logs answers
anywhere except the git-ignored output directory you pass in.

Usage:
  python tools/ocr_slim/ocr_eval.py \
      --variant base=path/to/common_old.onnx \
      --variant pruned=path/to/x.ort:path/to/charset.txt \
      --samples .ocr_work/samples --labels .ocr_work/labels.csv \
      --out .ocr_work/eval

The first --variant is the baseline. Sample sub-directories map to expected
lengths via --source (default cas=4, zf=6). labels.csv has `file,label`
rows (file relative to --samples, e.g. cas/cas_0001.jpg); unlabeled samples
only count toward the agreement / null-rate columns.
"""
import argparse
import csv
import math
import os
import sys

import numpy as np
import onnxruntime as ort
from PIL import Image

# ---------------------------------------------------------------- OcrSizeBudget.kt
TARGET_HEIGHT = 64
MAX_SOURCE_PIXELS = 2_000_000
MAX_NORMALIZED_WIDTH = 1024
MAX_INTERMEDIATE_PIXELS = 2_000_000


def size_budget(w, h):
    """OcrSizeBudget.evaluate -> target width, or None when rejected."""
    if w <= 0 or h <= 0:
        return None
    if w * h > MAX_SOURCE_PIXELS:
        return None
    tw = max(1, w * TARGET_HEIGHT // h)  # Long integer division, then max(1, .)
    if tw > MAX_NORMALIZED_WIDTH:
        return None
    if tw * h > MAX_INTERMEDIATE_PIXELS:
        return None
    return tw


# --------------------------------------------------------- DdddocrPreprocessor.kt
LANCZOS_A = 3.0


def kotlin_round(x):
    """Kotlin Double.roundToInt() == Math.round(): floor(x + 0.5)."""
    return np.floor(x + 0.5)


def lanczos(x):
    if x == 0.0:
        return 1.0
    a = abs(x)
    if a >= LANCZOS_A:
        return 0.0
    pix = math.pi * x
    pid = pix / LANCZOS_A
    return (math.sin(pix) / pix) * (math.sin(pid) / pid)


def resample_matrix(src_len, dst_len):
    """Weights M (src_len, dst_len) and weight sums (dst_len,) of resizeH/V.

    Mirrors the Kotlin loop exactly: taps i in [ceil(c - s), floor(c + s)],
    zero weights skipped, out-of-range taps clamped to the edge (so edge
    pixels may receive several taps), then sum / weightSum.
    """
    m = np.zeros((src_len, dst_len), dtype=np.float64)
    wsum = np.zeros(dst_len, dtype=np.float64)
    scale = src_len / dst_len
    filter_scale = 1.0 if scale < 1.0 else scale
    support = LANCZOS_A * filter_scale
    for x in range(dst_len):
        center = (x + 0.5) * scale - 0.5
        left = math.ceil(center - support)
        right = math.floor(center + support)
        for i in range(left, right + 1):
            w = lanczos((i - center) / filter_scale)
            if w == 0.0:
                continue
            m[min(max(i, 0), src_len - 1), x] += w
            wsum[x] += w
    return m, wsum


_MATRIX_CACHE = {}


def _resample(src, src_len, dst_len, axis):
    key = (src_len, dst_len)
    if key not in _MATRIX_CACHE:
        _MATRIX_CACHE[key] = resample_matrix(src_len, dst_len)
    m, wsum = _MATRIX_CACHE[key]
    if axis == 0:  # resizeVertical: same kernel along columns
        return _resample(src.T, src_len, dst_len, axis=1).T
    acc = src @ m
    with np.errstate(divide="ignore", invalid="ignore"):
        val = np.where(wsum != 0.0, acc / wsum, 0.0)
    return np.clip(kotlin_round(val), 0, 255)


def to_input_tensor(rgb):
    """rgb: uint8 (H, W, 3) -> float32 (1, 1, 64, W') or None (budget reject)."""
    h, w = rgb.shape[:2]
    tw = size_budget(w, h)
    if tw is None:
        return None
    r = rgb[..., 0].astype(np.int64)
    g = rgb[..., 1].astype(np.int64)
    b = rgb[..., 2].astype(np.int64)
    gray = np.clip(kotlin_round((r * 299 + g * 587 + b * 114) / 1000.0), 0, 255)
    horizontal = gray if tw == w else _resample(gray, w, tw, axis=1)
    resized = horizontal if TARGET_HEIGHT == h else _resample(horizontal, h, TARGET_HEIGHT, axis=0)
    tensor = resized.astype(np.float32) / np.float32(255.0)
    return tensor.reshape(1, 1, TARGET_HEIGHT, tw)


# ---------------------------------------------------------------- DdddocrEngine.kt
def load_charset(path):
    with open(path, "rb") as fh:
        raw = fh.read().decode("utf-8")
    return ["\0"] + list(raw)  # index 0 == blank


def make_session(model_path):
    so = ort.SessionOptions()
    so.intra_op_num_threads = 1
    so.inter_op_num_threads = 1
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    so.log_severity_level = 3  # (T,1,C) output vs declared [1, seqlen] warning is expected
    return ort.InferenceSession(model_path, so, providers=["CPUExecutionProvider"])


def run_model(session, tensor, classes):
    name = session.get_inputs()[0].name
    out = session.run(None, {name: tensor})[0]
    flat = np.asarray(out, dtype=np.float32).reshape(-1)
    if flat.size == 0 or flat.size % classes:
        raise ValueError(f"output size {flat.size} not divisible by {classes}")
    frames = flat.size // classes
    if frames > max(1, tensor.shape[3]) * 4:
        raise ValueError(f"frame count {frames} too large")
    return flat.reshape(frames, classes)


# ------------------------------------------------------------------ CtcDecoder.kt
def is_ascii_alnum(ch):
    return ("0" <= ch <= "9") or ("a" <= ch <= "z") or ("A" <= ch <= "Z")


def ctc_decode(logits, charset):
    # np.argmax returns the first maximum, same as the strict `>` Kotlin loop.
    idx = np.argmax(logits, axis=1)
    out, prev = [], -1
    for i in idx.tolist():
        if i != prev and i != 0:
            out.append(i)
        prev = i
    text = "".join(charset[i] for i in out if 0 < i < len(charset) and is_ascii_alnum(charset[i]))
    non_alnum_frames = sum(
        1 for i in idx.tolist() if i != 0 and not is_ascii_alnum(charset[i])
    )
    return text, non_alnum_frames


def mean_max_softmax(logits):
    if logits.shape[0] == 0:
        return 0.0
    x = logits.astype(np.float64)
    mx = x.max(axis=1, keepdims=True)
    denom = np.exp(x - mx).sum(axis=1)
    return float(np.mean(1.0 / denom))


# ------------------------------------------- plugin + captcha_recognizer.dart gate
def plugin_candidates(text, confidence):
    return [(text, confidence)] if text else []


def dart_select(candidates, expected_length, minimum_confidence=0.5):
    selected = None
    for text, conf in candidates:
        norm = "".join(text.split())
        if len(norm) != expected_length:
            continue
        if not norm or not all(is_ascii_alnum(c) for c in norm):
            continue
        if conf is not None and conf < minimum_confidence:
            continue
        if selected is None:
            selected = norm
        elif selected.lower() != norm.lower():
            return None
    return selected


# ------------------------------------------------------------------------- driver
def parse_variant(spec, default_charset):
    name, _, rest = spec.partition("=")
    # path[:charset]; Windows drive letters are not supported here on purpose.
    model, _, charset = rest.partition(":")
    return name, model, charset or default_charset


def load_labels(path):
    """`file,label[,note]`; note == "targeted" marks hand-picked samples (e.g. the
    ones where variants disagree): they count toward the paired right/wrong
    columns but are kept out of the accuracy column, which must stay a random
    sample to be an unbiased anchor."""
    labels, targeted = {}, set()
    if path and os.path.exists(path):
        with open(path, newline="", encoding="utf-8") as fh:
            for row in csv.reader(fh):
                if len(row) >= 2 and row[0] and not row[0].startswith("#") and row[0] != "file":
                    key = row[0].replace("\\", "/")
                    labels[key] = row[1].strip()
                    if len(row) >= 3 and row[2].strip() == "targeted":
                        targeted.add(key)
    return labels, targeted


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(os.path.dirname(here))
    asset_dir = os.path.join(repo, "packages", "campus_captcha_ocr", "android", "src", "main", "assets", "captcha_ocr")
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", action="append", required=True, help="name=model[:charset]; first is baseline")
    ap.add_argument("--samples", default=os.path.join(".ocr_work", "samples"))
    ap.add_argument("--source", action="append", default=None, help="subdir=expectedLength (default cas=4, zf=6)")
    ap.add_argument("--labels", default=None)
    ap.add_argument("--charset", default=os.path.join(asset_dir, "charset_old.txt"))
    ap.add_argument("--out", default=os.path.join(".ocr_work", "eval"))
    args = ap.parse_args()

    sources = dict(s.split("=") for s in (args.source or ["cas=4", "zf=6"]))
    sources = {k: int(v) for k, v in sources.items()}
    variants = [parse_variant(v, args.charset) for v in args.variant]
    labels, targeted = load_labels(args.labels)
    os.makedirs(args.out, exist_ok=True)

    files = []
    for src in sources:
        d = os.path.join(args.samples, src)
        for f in sorted(os.listdir(d)):
            if f.lower().endswith((".jpg", ".jpeg", ".png", ".gif")):
                files.append((src, f"{src}/{f}"))

    tensors = {}
    for src, rel in files:
        with Image.open(os.path.join(args.samples, rel)) as im:
            rgb = np.asarray(im.convert("RGB"), dtype=np.uint8)
        tensors[rel] = to_input_tensor(rgb)

    results = {}  # variant -> rel -> dict
    for name, model, charset_path in variants:
        charset = load_charset(charset_path)
        sess = make_session(model)
        res = {}
        for src, rel in files:
            t = tensors[rel]
            if t is None:
                res[rel] = dict(raw="", conf=None, final=None, nonalnum=0, err="image_too_large")
                continue
            logits = run_model(sess, t, len(charset))
            text, nonalnum = ctc_decode(logits, charset)
            conf = mean_max_softmax(logits)
            final = dart_select(plugin_candidates(text, conf), sources[src])
            res[rel] = dict(raw=text, conf=conf, final=final, nonalnum=nonalnum, err="")
        results[name] = res

    base = variants[0][0]
    with open(os.path.join(args.out, "per_sample.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["file", "label"] + [f"{n}_{k}" for n, _, _ in variants for k in ("raw", "conf", "final", "nonalnum")])
        for src, rel in files:
            row = [rel, labels.get(rel, "")]
            for n, _, _ in variants:
                r = results[n][rel]
                row += [r["raw"], "" if r["conf"] is None else f"{r['conf']:.4f}", "" if r["final"] is None else r["final"], r["nonalnum"]]
            w.writerow(row)

    def correct(ans, label):
        # Both captcha servers compare case-insensitively in practice; we report
        # case-insensitive accuracy and keep the raw strings in per_sample.csv.
        return ans is not None and ans.lower() == label.lower()

    lines = []
    hdr = ("| 变体 | 模型大小 | 来源 | 样本 | 与基准一致率 | raw 一致率 | null 率 | "
           "标注数(随机+定向) | 随机抽查准确率 | 基准对→变体错(非null) | 基准错→变体对 | 非字母数字 argmax 帧 |")
    lines.append(hdr)
    lines.append("|" + "---|" * (hdr.count("|") - 1))
    for name, model, _ in variants:
        size = os.path.getsize(model)
        for src in list(sources) + ["all"]:
            rels = [r for s, r in files if src in ("all", s)]
            n = len(rels)
            agree = sum(results[name][r]["final"] == results[base][r]["final"] for r in rels)
            raw_agree = sum(results[name][r]["raw"] == results[base][r]["raw"] for r in rels)
            nulls = sum(results[name][r]["final"] is None for r in rels)
            lab = [r for r in rels if r in labels]
            rand = [r for r in lab if r not in targeted]
            acc = sum(correct(results[name][r]["final"], labels[r]) for r in rand)
            worse = sum(correct(results[base][r]["final"], labels[r]) and not correct(results[name][r]["final"], labels[r])
                        and results[name][r]["final"] is not None for r in lab)
            better = sum(not correct(results[base][r]["final"], labels[r]) and correct(results[name][r]["final"], labels[r]) for r in lab)
            nonalnum = sum(results[name][r]["nonalnum"] for r in rels)
            acc_s = f"{acc}/{len(rand)} = {100.0 * acc / len(rand):.1f}%" if rand else "-"
            lines.append(
                f"| {name} | {size / 1e6:.2f}MB | {src} | {n} | {100.0 * agree / n:.1f}% | {100.0 * raw_agree / n:.1f}% | "
                f"{100.0 * nulls / n:.1f}% | {len(rand)}+{len(lab) - len(rand)} | {acc_s} | {worse} | {better} | {nonalnum} |"
            )
    table = "\n".join(lines)
    with open(os.path.join(args.out, "summary.md"), "w", encoding="utf-8") as fh:
        fh.write(table + "\n")
    print(table)
    return 0


if __name__ == "__main__":
    sys.exit(main())
