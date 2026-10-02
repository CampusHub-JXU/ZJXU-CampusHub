#!/usr/bin/env python3
"""Dump preprocessed sample tensors + Python ORT reference logits for OrtJavaCheck.

Format (little-endian): int32 n, then per sample: int32 width, int32 frames,
float32[64*width] input, float32[frames*classes] logits.

Usage: dump_reference.py <model.ort> <charset.txt> <samples dir> <out.bin>
"""
import os
import struct
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import ocr_eval  # noqa: E402


def main():
    model, charset_path, samples, out = sys.argv[1:5]
    charset = ocr_eval.load_charset(charset_path)
    sess = ocr_eval.make_session(model)
    files = []
    for sub in sorted(os.listdir(samples)):
        d = os.path.join(samples, sub)
        if os.path.isdir(d):
            files += [os.path.join(d, f) for f in sorted(os.listdir(d)) if f.lower().endswith((".jpg", ".png"))]
    with open(out, "wb") as fh:
        fh.write(struct.pack("<i", len(files)))
        for f in files:
            with Image.open(f) as im:
                t = ocr_eval.to_input_tensor(np.asarray(im.convert("RGB"), dtype=np.uint8))
            logits = ocr_eval.run_model(sess, t, len(charset))
            fh.write(struct.pack("<ii", t.shape[3], logits.shape[0]))
            fh.write(t.astype("<f4").tobytes())
            fh.write(logits.astype("<f4").tobytes())
    print(f"wrote {len(files)} samples to {out}")


if __name__ == "__main__":
    main()
