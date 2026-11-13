# -*- coding: utf-8 -*-
"""生成 JXU-CampusHub 应用图标母版与多套 Android 桌面自适应图标资源（Nanhu Sail）。

输出：
1) 1024x1024 母版 PNG（Pillow 4x 超采样几何绘制，无字体/平台依赖）：
   - app_icon_master.png            04b 汝窑天青全幅母版
   - app_icon_foreground.png        04b 透明前景层
   - app_icon_monochrome.png        纯黑单色前景（Android 13+ Material You）
   - app_icon_foreground_night.png  05a 烟雨黛瓦夜间前景层
   - assets/brand/app_icon.png      256x256 应用内资源缩略图
2) Android 默认夜间资源（跟随 04b/05a 青瓷·黛瓦）：
   - drawable-night-*/ic_launcher_foreground.png
   - res/values-night/colors.xml（ic_launcher_background = #1C2227）
   - res/mipmap-anydpi-v26/ic_launcher.xml（无 <inset>，兼容 HyperOS 等桌面）
3) Android 动态切换桌面图标（activity-alias 共用 VectorDrawable + colors）：
   - res/drawable/ic_launcher_fg_<variant>.xml
   - res/drawable-night/ic_launcher_fg_<variant>.xml（仅 auto 变体）
   - res/values/ic_launcher_colors.xml
   - res/values-night/ic_launcher_colors.xml
   - res/mipmap-anydpi-v26/ic_launcher_<variant>.xml

重新生成：
  python tools/brand/make_icons.py
  dart run flutter_launcher_icons
  python tools/brand/make_icons.py
"""

from __future__ import annotations

import colorsys
import math
import re
from pathlib import Path

from PIL import Image, ImageDraw

try:
    from material_color_utilities import Hct, TonalPalette
except ImportError as exc:
    raise SystemExit(
        "缺少 material-color-utilities（深色款图标需派生 M3 tonalSpot 色阶）："
        "pip install material-color-utilities"
    ) from exc

SIZE = 1024
SS = 4  # 4x 超采样抗锯齿
ASSET_ICON_SIZE = 256  # assets/brand/app_icon.png
FOREGROUND_FILL = 0.43  # 直接烘焙安全区比例（不依赖 XML <inset>）

# ---------------------------------------------------------------------------
# Nanhu Sail 矢量路径（与 concepts/*.svg 完全一致：帆 + 三层书页波纹）
# ---------------------------------------------------------------------------
SAIL_PATH = (
    "M 408 214 C 410 206, 420 203, 430 206 "
    "C 502 226, 578 245, 650 260 "
    "C 661 262, 668 271, 669 282 "
    "C 684 422, 632 566, 422 590 "
    "C 411 591, 405 582, 413 574 "
    "C 520 498, 518 368, 434 248 "
    "C 424 234, 414 223, 408 214 Z"
)
WAVE1_PATH = (
    "M 244 628 H 428 C 462 628, 488 638, 512 652 "
    "C 536 638, 562 628, 596 628 H 780 "
    "C 790 628, 796 636, 793 645 "
    "C 790 654, 783 660, 773 660 H 592 "
    "C 562 660, 536 670, 512 684 "
    "C 488 670, 462 660, 432 660 H 251 "
    "C 241 660, 234 654, 231 645 "
    "C 228 636, 234 628, 244 628 Z"
)
WAVE2_PATH = (
    "M 276 690 H 434 C 464 690, 489 701, 512 716 "
    "C 535 701, 560 690, 590 690 H 748 "
    "C 758 690, 764 699, 759 708 "
    "C 754 717, 746 722, 736 722 H 586 "
    "C 558 722, 535 733, 512 748 "
    "C 489 733, 466 722, 438 722 H 288 "
    "C 278 722, 270 717, 265 708 "
    "C 260 699, 266 690, 276 690 Z"
)
WAVE3_PATH = (
    "M 326 752 H 442 C 468 752, 491 763, 512 778 "
    "C 533 763, 556 752, 582 752 H 698 "
    "C 709 752, 714 763, 706 772 "
    "C 658 814, 590 836, 512 836 "
    "C 434 836, 366 814, 318 772 "
    "C 310 763, 315 752, 326 752 Z"
)

# 04b 汝窑天青 · 铁胎墨（nanhu-04b-ruyao-sky.svg）
PALETTE_DAY = {
    "bg_top": (221, 229, 233),  # #DDE5E9
    "bg_bottom": (199, 211, 218),  # #C7D3DA
    "sail": (24, 38, 47),  # #18262F
    "wave1": (40, 60, 72),  # #283C48
    "wave2": (78, 101, 115),  # #4E6573
    "wave3": (122, 145, 158),  # #7A919E
    "launcher_bg": "#CFDADF",
}

# 05a 烟雨黛瓦 · 粉墙白（nanhu-05-yanyu-slate.svg）
PALETTE_NIGHT = {
    "sail": (243, 242, 238),  # #F3F2EE
    "wave1": (207, 213, 217),  # #CFD5D9
    "wave2": (146, 156, 164),  # #929CA4
    "wave3": (92, 102, 110),  # #5C666E
    "launcher_bg": "#1C2227",
}

# 与 lib/core/theme/app_theme_palette.dart 完全一致的 8 套预设主题色
THEME_PALETTES = [
    (0x8B, 0x1A, 0x2D),  # 0: 嘉大红
    (0x15, 0x65, 0xC0),  # 1: 嘉大蓝
    (0x00, 0xA6, 0xA6),  # 2: 湖青
    (0x6C, 0x5C, 0xE7),  # 3: 紫罗兰
    (0xE9, 0x4B, 0x9B),  # 4: 樱粉
    (0xFF, 0x8A, 0x00),  # 5: 暖橙
    (0x2E, 0x7D, 0x32),  # 6: 松绿
    (0x45, 0x5A, 0x64),  # 7: 石墨
]

IVORY = (243, 242, 238)  # #F3F2EE
RED_BLACK = (22, 6, 9)  # #160609
CRIMSON = (139, 26, 45)  # #8B1A2D

PATHS = {
    "sail": SAIL_PATH,
    "wave1": WAVE1_PATH,
    "wave2": WAVE2_PATH,
    "wave3": WAVE3_PATH,
}

# Android 自适应前景各密度（与 flutter_launcher_icons 一致：108dp）
NIGHT_DENSITIES = {
    "mdpi": 108,
    "hdpi": 162,
    "xhdpi": 216,
    "xxhdpi": 324,
    "xxxhdpi": 432,
}

_TOKEN_RE = re.compile(r"[MLHVCSQTAZmlhvcsqtaz]|-?\d*\.?\d+(?:e[-+]?\d+)?")


def _rgb_hex(rgb: tuple[int, int, int]) -> str:
    return f"#{rgb[0]:02X}{rgb[1]:02X}{rgb[2]:02X}"


def _lerp_rgb(
    a: tuple[int, int, int], b: tuple[int, int, int], t: float
) -> tuple[int, int, int]:
    return (
        round(a[0] + (b[0] - a[0]) * t),
        round(a[1] + (b[1] - a[1]) * t),
        round(a[2] + (b[2] - a[2]) * t),
    )


def _compute_luminance(rgb: tuple[int, int, int]) -> float:
    def linearize(channel: int) -> float:
        c = channel / 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

    return (
        0.2126 * linearize(rgb[0])
        + 0.7152 * linearize(rgb[1])
        + 0.0722 * linearize(rgb[2])
    )


def _with_lightness(rgb: tuple[int, int, int], lightness: float) -> tuple[int, int, int]:
    h, _, s = colorsys.rgb_to_hls(rgb[0] / 255.0, rgb[1] / 255.0, rgb[2] / 255.0)
    r, g, b = colorsys.hls_to_rgb(h, lightness, s)
    return (round(r * 255), round(g * 255), round(b * 255))


def _tokenize(d: str):
    return _TOKEN_RE.findall(d.replace(",", " "))


def _flatten_cubic(p0, p1, p2, p3):
    """按弦长自适应采样一条三次贝塞尔，返回折线点列（含终点，不含起点）。"""
    chord = math.dist(p0, p3) + math.dist(p0, p1) + math.dist(p1, p2) + math.dist(p2, p3)
    n = max(8, int(chord / 2))
    pts = []
    for i in range(1, n + 1):
        t = i / n
        mt = 1.0 - t
        x = (
            mt**3 * p0[0]
            + 3 * mt * mt * t * p1[0]
            + 3 * mt * t * t * p2[0]
            + t**3 * p3[0]
        )
        y = (
            mt**3 * p0[1]
            + 3 * mt * mt * t * p1[1]
            + 3 * mt * t * t * p2[1]
            + t**3 * p3[1]
        )
        pts.append((x, y))
    return pts


def flatten_path(d: str):
    """把绝对坐标 SVG path（M/L/H/V/C/Z）展平为多边形点列。"""
    tokens = _tokenize(d)
    i = 0
    cur = (0.0, 0.0)
    start = (0.0, 0.0)
    poly = []

    def num():
        nonlocal i
        v = float(tokens[i])
        i += 1
        return v

    while i < len(tokens):
        cmd = tokens[i]
        if cmd.isalpha():
            i += 1
        else:
            cmd = "L"  # 隐式连续线段
        if cmd == "M":
            cur = (num(), num())
            start = cur
            poly.append(cur)
        elif cmd == "L":
            cur = (num(), num())
            poly.append(cur)
        elif cmd == "H":
            cur = (num(), cur[1])
            poly.append(cur)
        elif cmd == "V":
            cur = (cur[0], num())
            poly.append(cur)
        elif cmd == "C":
            p1 = (num(), num())
            p2 = (num(), num())
            p3 = (num(), num())
            poly.extend(_flatten_cubic(cur, p1, p2, p3))
            cur = p3
        elif cmd in ("Z", "z"):
            poly.append(start)
        else:
            raise ValueError(f"不支持的 path 命令 {cmd!r}（应为绝对坐标 M/L/H/V/C/Z）")
    return poly


def _foreground_transform(scale: float, canvas: int = SIZE):
    polys = {name: flatten_path(d) for name, d in PATHS.items()}
    xs = [p[0] for poly in polys.values() for p in poly]
    ys = [p[1] for poly in polys.values() for p in poly]
    min_x, max_x, min_y, max_y = min(xs), max(xs), min(ys), max(ys)
    bw, bh = max_x - min_x, max_y - min_y
    s = canvas * scale / max(bw, bh)
    ox = (canvas - bw * s) / 2 - min_x * s
    oy = (canvas - bh * s) / 2 - min_y * s
    return polys, s, ox, oy


def render_glyph(fill_map, scale=1.0, canvas=SIZE):
    """在透明 RGBA 画布上绘制帆 + 三层书页波。"""
    big = canvas * SS
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    if scale != 1.0:
        polys, s, ox, oy = _foreground_transform(scale, canvas)
        transform = lambda x, y: ((x * s + ox) * SS, (y * s + oy) * SS)
    else:
        polys = {name: flatten_path(d) for name, d in PATHS.items()}
        transform = lambda x, y: (x * SS, y * SS)

    # 先波后帆：与 SVG 一致，帆在最上层
    for name in ("wave3", "wave2", "wave1", "sail"):
        pts = [transform(x, y) for x, y in polys[name]]
        draw.polygon(pts, fill=fill_map[name] + (255,))
    return img.resize((canvas, canvas), Image.LANCZOS)


def paint_gradient(canvas_img: Image.Image, top, bottom):
    """垂直线性渐变背景（等价 SVG linearGradient y:0→1）。"""
    col = Image.new("RGBA", (1, SIZE))
    px = col.load()
    for y in range(SIZE):
        t = y / (SIZE - 1)
        px[0, y] = (
            round(top[0] + (bottom[0] - top[0]) * t),
            round(top[1] + (bottom[1] - top[1]) * t),
            round(top[2] + (bottom[2] - top[2]) * t),
            255,
        )
    canvas_img.alpha_composite(col.resize((SIZE, SIZE)))


def upsert_launcher_color(colors_xml: Path, hex_color: str):
    """幂等写入 <color name=\"ic_launcher_background\">，文件不存在则新建。"""
    line = f'    <color name="ic_launcher_background">{hex_color}</color>'
    if colors_xml.exists():
        text = colors_xml.read_text(encoding="utf-8")
        if 'name="ic_launcher_background"' in text:
            text = re.sub(
                r'<color name="ic_launcher_background">[^<]*</color>', line.strip(), text
            )
        else:
            text = text.replace("</resources>", f"{line}\n</resources>")
    else:
        text = (
            '<?xml version="1.0" encoding="utf-8"?>\n'
            "<resources>\n" + line + "\n</resources>\n"
        )
    colors_xml.parent.mkdir(parents=True, exist_ok=True)
    colors_xml.write_text(text, encoding="utf-8", newline="\n")


def _vector_xml(fills: dict[str, tuple[int, int, int]], s: float, ox: float, oy: float) -> str:
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    android:width="108dp"\n'
        '    android:height="108dp"\n'
        '    android:viewportWidth="1024"\n'
        '    android:viewportHeight="1024">\n'
        '    <group\n'
        f'        android:scaleX="{s:.6f}"\n'
        f'        android:scaleY="{s:.6f}"\n'
        f'        android:translateX="{ox:.3f}"\n'
        f'        android:translateY="{oy:.3f}">\n'
        '        <path\n'
        f'            android:fillColor="{_rgb_hex(fills["wave3"])}"\n'
        f'            android:pathData="{WAVE3_PATH}" />\n'
        '        <path\n'
        f'            android:fillColor="{_rgb_hex(fills["wave2"])}"\n'
        f'            android:pathData="{WAVE2_PATH}" />\n'
        '        <path\n'
        f'            android:fillColor="{_rgb_hex(fills["wave1"])}"\n'
        f'            android:pathData="{WAVE1_PATH}" />\n'
        '        <path\n'
        f'            android:fillColor="{_rgb_hex(fills["sail"])}"\n'
        f'            android:pathData="{SAIL_PATH}" />\n'
        '    </group>\n'
        '</vector>\n'
    )


def _adaptive_xml(bg_color_name: str, fg_drawable_name: str) -> str:
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        f'  <background android:drawable="@color/{bg_color_name}"/>\n'
        f'  <foreground android:drawable="@drawable/{fg_drawable_name}"/>\n'
        '  <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>\n'
        '</adaptive-icon>\n'
    )


def _palette_light_spec(primary: tuple[int, int, int]):
    bg = _lerp_rgb((255, 255, 255), primary, 0.06)
    sail = (
        _with_lightness(primary, 0.35)
        if _compute_luminance(primary) > 0.65
        else primary
    )
    return bg, {
        "sail": sail,
        "wave1": sail,
        "wave2": _lerp_rgb(sail, bg, 0.24),
        "wave3": _lerp_rgb(sail, bg, 0.48),
    }


def _hex_to_rgb(hex_color: str) -> tuple[int, int, int]:
    return tuple(
        int(hex_color.lstrip("#")[i : i + 2], 16) for i in (0, 2, 4)
    )


def _dark_seed_tone(
    rgb: tuple[int, int, int], lightness: float
) -> tuple[int, int, int]:
    """与 AppThemeBuilder._darkSeedTone 一致：HSL 饱和 ×0.72 夹紧到目标明度。"""
    h, _l, s = colorsys.rgb_to_hls(rgb[0] / 255.0, rgb[1] / 255.0, rgb[2] / 255.0)
    s = min(max(s * 0.72, 0.28), 0.78)
    r, g, b = colorsys.hls_to_rgb(h, lightness, s)
    return (round(r * 255), round(g * 255), round(b * 255))


def _tonal_spot_primary_dark(rgb: tuple[int, int, int]) -> tuple[int, int, int]:
    """Flutter `ColorScheme.fromSeed`（tonalSpot）深色 primary = 种子色相 + 色度36 的 T80。"""
    hct = Hct(0xFF000000 | (rgb[0] << 16) | (rgb[1] << 8) | rgb[2])
    return _hex_to_rgb(TonalPalette(hct.hue, 36.0).get(80.0))


def _palette_dark_spec(primary: tuple[int, int, int]):
    """深色款 = 色彩系统派生（非粗暴反色）：帆用种子色 dark tonal primary，
    底用 _dark_seed_tone 种子调暗面，波纹与浅色款同一条 sail→bg 渐变带。
    与 lib/core/theme/app_icon_style.dart AppIconColors._themeDark 保持同步。"""
    sail = _tonal_spot_primary_dark(primary)
    bg = _dark_seed_tone(primary, 0.14)
    return bg, {
        "sail": sail,
        "wave1": sail,
        "wave2": _lerp_rgb(sail, bg, 0.24),
        "wave3": _lerp_rgb(sail, bg, 0.48),
    }


def _write_alias_resources(res_dir: Path, day_fills: dict[str, tuple[int, int, int]]):
    _, s, ox, oy = _foreground_transform(FOREGROUND_FILL)

    variants_day: dict[str, tuple[tuple[int, int, int], dict[str, tuple[int, int, int]]]] = {
        "celadon_day": ((207, 218, 223), day_fills),
        "crimson": (
            CRIMSON,
            {
                "sail": IVORY,
                "wave1": IVORY,
                "wave2": _lerp_rgb(IVORY, CRIMSON, 0.24),
                "wave3": _lerp_rgb(IVORY, CRIMSON, 0.48),
            },
        ),
        "red_black": (
            RED_BLACK,
            {
                "sail": IVORY,
                "wave1": IVORY,
                "wave2": _lerp_rgb(IVORY, RED_BLACK, 0.24),
                "wave3": _lerp_rgb(IVORY, RED_BLACK, 0.48),
            },
        ),
    }
    variants_night: dict[str, tuple[tuple[int, int, int], dict[str, tuple[int, int, int]]]] = {}

    for idx, primary in enumerate(THEME_PALETTES):
        light_bg, light_fg = _palette_light_spec(primary)
        dark_bg, dark_fg = _palette_dark_spec(primary)

        variants_day[f"theme_{idx}"] = (light_bg, light_fg)
        variants_day[f"theme_{idx}_dark"] = (dark_bg, dark_fg)
        variants_day[f"theme_{idx}_auto"] = (light_bg, light_fg)
        variants_night[f"theme_{idx}_auto"] = (dark_bg, dark_fg)

    drawable_dir = res_dir / "drawable"
    drawable_night_dir = res_dir / "drawable-night"
    mipmap_dir = res_dir / "mipmap-anydpi-v26"
    values_dir = res_dir / "values"
    values_night_dir = res_dir / "values-night"
    for d in (drawable_dir, drawable_night_dir, mipmap_dir, values_dir, values_night_dir):
        d.mkdir(parents=True, exist_ok=True)

    color_lines_day = ['<?xml version="1.0" encoding="utf-8"?>', "<resources>"]
    for key, (bg_rgb, fg_fills) in variants_day.items():
        bg_name = f"ic_launcher_bg_{key}"
        fg_name = f"ic_launcher_fg_{key}"
        color_lines_day.append(f'    <color name="{bg_name}">{_rgb_hex(bg_rgb)}</color>')
        (drawable_dir / f"{fg_name}.xml").write_text(
            _vector_xml(fg_fills, s, ox, oy), encoding="utf-8", newline="\n"
        )
        (mipmap_dir / f"ic_launcher_{key}.xml").write_text(
            _adaptive_xml(bg_name, fg_name), encoding="utf-8", newline="\n"
        )
    color_lines_day.append("</resources>\n")
    (values_dir / "ic_launcher_colors.xml").write_text(
        "\n".join(color_lines_day), encoding="utf-8", newline="\n"
    )

    color_lines_night = ['<?xml version="1.0" encoding="utf-8"?>', "<resources>"]
    for key, (bg_rgb, fg_fills) in variants_night.items():
        bg_name = f"ic_launcher_bg_{key}"
        fg_name = f"ic_launcher_fg_{key}"
        color_lines_night.append(f'    <color name="{bg_name}">{_rgb_hex(bg_rgb)}</color>')
        (drawable_night_dir / f"{fg_name}.xml").write_text(
            _vector_xml(fg_fills, s, ox, oy), encoding="utf-8", newline="\n"
        )
    color_lines_night.append("</resources>\n")
    (values_night_dir / "ic_launcher_colors.xml").write_text(
        "\n".join(color_lines_night), encoding="utf-8", newline="\n"
    )


def main():
    out_dir = Path(__file__).resolve().parent
    repo = out_dir.parent.parent
    res_dir = repo / "android" / "app" / "src" / "main" / "res"

    day_fills = {k: PALETTE_DAY[k] for k in ("sail", "wave1", "wave2", "wave3")}
    night_fills = {k: PALETTE_NIGHT[k] for k in ("sail", "wave1", "wave2", "wave3")}

    # 1) 04b 全幅母版：渐变底 + 原坐标图形
    master = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 255))
    paint_gradient(master, PALETTE_DAY["bg_top"], PALETTE_DAY["bg_bottom"])
    master.alpha_composite(render_glyph(day_fills, scale=1.0))
    master.convert("RGB").save(out_dir / "app_icon_master.png")

    # 2) 04b 自适应前景：安全区直接烘焙（占 108dp 画布 ~43%，无 <inset> 兼容全桌面）
    fg = render_glyph(day_fills, scale=FOREGROUND_FILL)
    fg.save(out_dir / "app_icon_foreground.png")

    # 3) Android 13+ 单色前景：透明底 + 纯黑（系统按主题着色）
    mono_fills = {k: (0, 0, 0) for k in ("sail", "wave1", "wave2", "wave3")}
    mono = render_glyph(mono_fills, scale=FOREGROUND_FILL)
    mono.save(out_dir / "app_icon_monochrome.png")

    # 4) 05a 夜间前景母版（1024，便于检查）
    fg_night = render_glyph(night_fills, scale=FOREGROUND_FILL)
    fg_night.save(out_dir / "app_icon_foreground_night.png")

    # 5) assets/brand/app_icon.png（母版 256 缩略）
    asset_dir = repo / "assets" / "brand"
    asset_dir.mkdir(parents=True, exist_ok=True)
    master.resize((ASSET_ICON_SIZE, ASSET_ICON_SIZE), Image.LANCZOS).convert("RGB").save(
        asset_dir / "app_icon.png"
    )

    # 6) Android 夜间资源：drawable-night-*/ic_launcher_foreground.png
    for density, px in NIGHT_DENSITIES.items():
        d = res_dir / f"drawable-night-{density}"
        d.mkdir(parents=True, exist_ok=True)
        fg_night.resize((px, px), Image.LANCZOS).save(d / "ic_launcher_foreground.png")

    # 7) 夜间自适应底色（values-night 只覆盖 ic_launcher_background，
    #    不合并既有 values-night/campus_widget_colors.xml）
    upsert_launcher_color(
        res_dir / "values-night" / "colors.xml", PALETTE_NIGHT["launcher_bg"]
    )

    # 8) 写回无 <inset> 的自适应图标 XML（HyperOS 等国产桌面会忽略 <inset>）
    adaptive_xml = res_dir / "mipmap-anydpi-v26" / "ic_launcher.xml"
    adaptive_xml.parent.mkdir(parents=True, exist_ok=True)
    adaptive_xml.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '  <background android:drawable="@color/ic_launcher_background"/>\n'
        '  <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
        '  <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>\n'
        '</adaptive-icon>\n',
        encoding="utf-8",
        newline="\n",
    )

    # 9) 多套动态切换桌面图标的矢量前景、背景色与自适应 XML
    _write_alias_resources(res_dir, day_fills)

    print(f"OK -> {out_dir}")
    print(f"OK -> {asset_dir / 'app_icon.png'}")
    print(f"OK -> {res_dir} (default + 27 alias variants)")


if __name__ == "__main__":
    main()
