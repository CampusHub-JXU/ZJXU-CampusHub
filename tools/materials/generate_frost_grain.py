#!/usr/bin/env python3
"""Offline generator for the sparse acrylic grain texture (Issue #47).

Produces ONE tileable grayscale+alpha PNG (white specks, thresholded peaks) that is
bundled as `assets/textures/frost_grain_peaks.png` and tiled by
`lib/shared/widgets/frost_grain.dart` through `DecorationImage`.

Reference (read from public source, no secondary model):
  FHfanshu/Pulse-Windows @ main = 6941446340733ddd79e3742bf95d3d549814a19b
  (2026-10-10), Apache-2.0 — `ui/src/panel/glass.tsx` (SVG feTurbulence glitter),
  `ui/src/panel/panel.css` (5.2 s counter-phase opacity), `src-tauri/src/backdrop.rs`
  (native Windows.UI.Composition HostBackdrop, NOT portable to Android).

This is an independent re-implementation of the *idea* (thresholded sparse peaks from a
band-limited field, two independent seeds), NOT a port of SVG feTurbulence, NOT a copy of
the native Composition path, and it does NOT claim numeric equivalence to the reference's
`baseFrequency=0.42` / `threshold=0.66` (those live on feTurbulence's own alpha channel,
whose distribution we do not reproduce).

Recipe
------
field    = sum over octaves of tileable value noise (smoothstep interpolation)
octaves  = lattice 16/32/64 px-cell (feature 32/16/8 raster px), amplitudes 1.0/0.5/0.25
norm     = (field - mean) / std                       (z, unit variance)
alpha    = clamp((z - T) / R, 0, 1)                   (T threshold, R ramp; sigma units)
soften   = separable gaussian, integer kernel (2,5,10,14,10,5,2)/48, WRAPPING
compose  = max(map_seed_11, map_seed_29)              (union, no additive brightening)
output   = 8-bit grayscale+alpha PNG, gray=255 (white specks), alpha=peak

Everything is integer or IEEE-double arithmetic with no libm transcendentals, so the
output bytes are reproducible on this host (see --verify).

Stdlib only. No numpy / PIL / new dependency.

Usage
-----
  python tools/materials/generate_frost_grain.py                     # write default asset + stats
  python tools/materials/generate_frost_grain.py --variant sparse    # try another sparsity
  python tools/materials/generate_frost_grain.py --verify            # determinism check
  python tools/materials/generate_frost_grain.py --out /tmp/x.png --stats /tmp/x.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import zlib
from pathlib import Path

# ── Fixed recipe constants ──────────────────────────────────────────────────

SIZE = 512  # raster pixels per tile edge
LOGICAL_SCALE = 2.0  # DecorationImage scale -> 512 raster px = 256 logical dp period
OCTAVES = ((16, 1.0), (32, 0.5), (64, 0.25))  # (lattice cells, amplitude)
KERNEL = (2, 5, 10, 14, 10, 5, 2)  # gaussian-ish, sum = 48
KERNEL_SUM = sum(KERNEL)
MAP_SEEDS = (11, 29)  # the reference's two feTurbulence seeds

# Threshold + ramp in sigma units: only pixels above the threshold contribute a peak, and
# alpha ramps linearly from 0 at the threshold to 1 at (threshold + ramp). A SHORT ramp keeps
# peak brightness fairly even (a handful of blown-out points would read as stars) while the
# threshold sets sparsity. Sparsity presets, for the comparison table:
VARIANTS = {"sparse": (1.95, 0.55), "medium": (1.70, 0.60), "dense": (1.45, 0.65)}
DEFAULT_VARIANT = "sparse"

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = REPO_ROOT / "assets" / "textures" / "frost_grain_peaks.png"
DEFAULT_STATS = REPO_ROOT / "output" / "issue47" / "raw" / "02-generator-stats.json"


# ── Deterministic lattice noise ─────────────────────────────────────────────


def _hash32(seed: int, octave: int, i: int, j: int) -> int:
    """Integer hash of a lattice cell; independent of call order."""
    h = (
        seed * 0x9E3779B1
        + octave * 0x85EBCA6B
        + i * 0xC2B2AE35
        + j * 0x27D4EB2F
    ) & 0xFFFFFFFF
    h ^= h >> 15
    h = (h * 0x2C1B3C6D) & 0xFFFFFFFF
    h ^= h >> 12
    h = (h * 0x297A2D39) & 0xFFFFFFFF
    h ^= h >> 15
    return h


def _lattice(seed: int, octave: int, cells: int) -> list[list[float]]:
    return [
        [_hash32(seed, octave, i, j) / 4294967296.0 for j in range(cells)]
        for i in range(cells)
    ]


def _smooth(t: float) -> float:
    return t * t * (3.0 - 2.0 * t)


def _field(seed: int) -> list[float]:
    """Tileable multi-octave value noise, one float per raster pixel."""
    out = [0.0] * (SIZE * SIZE)
    for octave, (cells, amp) in enumerate(OCTAVES):
        lat = _lattice(seed, octave, cells)
        step = cells / SIZE
        for y in range(SIZE):
            fy = y * step
            j0 = int(fy)
            ty = _smooth(fy - j0)
            row0 = lat[j0 % cells]
            row1 = lat[(j0 + 1) % cells]
            base = y * SIZE
            for x in range(SIZE):
                fx = x * step
                i0 = int(fx)
                tx = _smooth(fx - i0)
                i1 = (i0 + 1) % cells
                v00 = row0[i0 % cells]
                v10 = row0[i1]
                v01 = row1[i0 % cells]
                v11 = row1[i1]
                top = v00 + (v10 - v00) * tx
                bot = v01 + (v11 - v01) * tx
                out[base + x] += amp * (top + (bot - top) * ty)
    return out


def _to_alpha(field: list[float], threshold_sigma: float, ramp_sigma: float) -> list[int]:
    n = len(field)
    mean = sum(field) / n
    var = sum((v - mean) * (v - mean) for v in field) / n
    std = math.sqrt(var)
    if std <= 0.0 or ramp_sigma <= 0.0:
        return [0] * n
    out = [0] * n
    for k, v in enumerate(field):
        a = ((v - mean) / std - threshold_sigma) / ramp_sigma
        if a <= 0.0:
            out[k] = 0
        elif a >= 1.0:
            out[k] = 255
        else:
            out[k] = int(a * 255.0 + 0.5)
    return out


def _blur_wrap(a: list[int]) -> list[int]:
    """Separable gaussian with circular (tileable) wrap; pure integer arithmetic."""
    radius = len(KERNEL) // 2
    tmp = [0] * (SIZE * SIZE)
    for y in range(SIZE):
        base = y * SIZE
        for x in range(SIZE):
            acc = 0
            for k, w in enumerate(KERNEL):
                acc += a[base + ((x + k - radius) % SIZE)] * w
            tmp[base + x] = acc
    out = [0] * (SIZE * SIZE)
    for x in range(SIZE):
        for y in range(SIZE):
            acc = 0
            for k, w in enumerate(KERNEL):
                acc += tmp[((y + k - radius) % SIZE) * SIZE + x] * w
            out[y * SIZE + x] = acc
    return out


def _rescale(a: list[int]) -> list[int]:
    """Normalise so the brightest peak reaches 255 (integer, deterministic)."""
    peak = max(a)
    if peak <= 0:
        return [0] * len(a)
    return [min(255, (v * 255 + peak // 2) // peak) for v in a]


def build_maps(threshold_sigma: float, ramp_sigma: float) -> list[list[int]]:
    maps = []
    for seed in MAP_SEEDS:
        alpha = _to_alpha(_field(seed), threshold_sigma, ramp_sigma)
        maps.append(_rescale(_blur_wrap(alpha)))
    return maps


def composite(maps: list[list[int]]) -> list[int]:
    """Union of the two peak maps: never additive, so peaks do not double in brightness."""
    a, b = maps
    return [a[i] if a[i] >= b[i] else b[i] for i in range(len(a))]


# ── PNG (grayscale + alpha, colour type 4) ──────────────────────────────────

_CRC_TABLE = []
for _n in range(256):
    _c = _n
    for _k in range(8):
        _c = (0xEDB88320 ^ (_c >> 1)) if (_c & 1) else (_c >> 1)
    _CRC_TABLE.append(_c)


def _crc32(data: bytes) -> int:
    c = 0xFFFFFFFF
    for b in data:
        c = _CRC_TABLE[(c ^ b) & 0xFF] ^ (c >> 8)
    return c ^ 0xFFFFFFFF


def _chunk(out: bytearray, kind: bytes, data: bytes) -> None:
    out += struct.pack(">I", len(data))
    out += kind
    out += data
    out += struct.pack(">I", _crc32(kind + data))


def encode_png(alpha: list[int]) -> bytes:
    raw = bytearray()
    for y in range(SIZE):
        raw.append(0)  # filter: None
        base = y * SIZE
        for x in range(SIZE):
            raw.append(255)  # gray: white speck
            raw.append(alpha[base + x])
    out = bytearray(b"\x89PNG\r\n\x1a\n")
    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 4, 0, 0, 0)
    _chunk(out, b"IHDR", ihdr)
    _chunk(out, b"IDAT", zlib.compress(bytes(raw), 9))
    _chunk(out, b"IEND", b"")
    return bytes(out)


# ── Measurement ─────────────────────────────────────────────────────────────


def _mean(values) -> float:
    values = list(values)
    return sum(values) / len(values) if values else 0.0


def measure(maps: list[list[int]], alpha: list[int]) -> dict:
    n = len(alpha)
    covered = sum(1 for v in alpha if v > 0)
    bright = sum(1 for v in alpha if v >= 128)
    # Mean horizontal run length of covered pixels -> speck size.
    runs: list[int] = []
    for y in range(SIZE):
        base = y * SIZE
        run = 0
        for x in range(SIZE):
            if alpha[base + x] > 0:
                run += 1
            elif run:
                runs.append(run)
                run = 0
        if run:
            runs.append(run)
    # Edge-wrap continuity: |last column - first column| vs interior neighbour delta.
    seam = _mean(abs(alpha[y * SIZE + SIZE - 1] - alpha[y * SIZE]) for y in range(SIZE))
    interior = _mean(
        abs(alpha[y * SIZE + x + 1] - alpha[y * SIZE + x])
        for y in range(SIZE)
        for x in range(SIZE - 1)
    )
    a, b = maps
    seed_diff = sum(1 for i in range(n) if abs(a[i] - b[i]) > 8) / n
    return {
        "size_px": SIZE,
        "logical_period_dp": SIZE / LOGICAL_SCALE,
        "scale": LOGICAL_SCALE,
        "octaves": [[cells, amp] for cells, amp in OCTAVES],
        "kernel": list(KERNEL),
        "seeds": list(MAP_SEEDS),
        "coverage_fraction": covered / n,
        "bright_fraction_alpha_ge_128": bright / n,
        "mean_alpha": _mean(alpha),
        "max_alpha": max(alpha),
        "mean_peak_run_px": _mean(runs),
        "mean_peak_run_dp": _mean(runs) / LOGICAL_SCALE,
        "peak_runs": len(runs),
        "edge_wrap_seam_delta": seam,
        "interior_neighbour_delta": interior,
        "seam_over_interior": (seam / interior) if interior else None,
        "seeds_differ_fraction_gt8": seed_diff,
        "sha256": None,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--variant", choices=sorted(VARIANTS), default=DEFAULT_VARIANT)
    ap.add_argument("--threshold-sigma", type=float, default=None,
                    help="override the variant's threshold (sigma units)")
    ap.add_argument("--ramp-sigma", type=float, default=None,
                    help="override the variant's alpha ramp width (sigma units)")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--stats", type=Path, default=DEFAULT_STATS)
    ap.add_argument("--verify", action="store_true",
                    help="generate twice and assert byte-identical output")
    args = ap.parse_args()

    base_threshold, base_ramp = VARIANTS[args.variant]
    threshold = args.threshold_sigma if args.threshold_sigma is not None else base_threshold
    ramp = args.ramp_sigma if args.ramp_sigma is not None else base_ramp
    maps = build_maps(threshold, ramp)
    alpha = composite(maps)
    png = encode_png(alpha)

    if args.verify:
        again = encode_png(composite(build_maps(threshold, ramp)))
        same = png == again
        print(f"verify: second run byte-identical = {same}")
        if not same:
            return 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(png)

    stats = measure(maps, alpha)
    stats["variant"] = args.variant
    stats["threshold_sigma"] = threshold
    stats["ramp_sigma"] = ramp
    stats["sha256"] = hashlib.sha256(png).hexdigest()
    stats["bytes"] = len(png)
    stats["out"] = str(args.out)
    args.stats.parent.mkdir(parents=True, exist_ok=True)
    args.stats.write_text(json.dumps(stats, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(f"variant={args.variant} threshold_sigma={threshold} ramp_sigma={ramp}")
    print(f"wrote {args.out} ({len(png)} bytes)")
    print(f"sha256 {stats['sha256']}")
    print(f"coverage={stats['coverage_fraction']:.4f} bright={stats['bright_fraction_alpha_ge_128']:.4f} "
          f"mean_alpha={stats['mean_alpha']:.2f} peak_run={stats['mean_peak_run_px']:.2f}px "
          f"({stats['mean_peak_run_dp']:.2f}dp)")
    print(f"seam/interior={stats['seam_over_interior']:.3f} seeds_differ={stats['seeds_differ_fraction_gt8']:.3f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
