# -*- coding: utf-8 -*-
"""生成 JXU-CampusHub 应用图标母版。

输出（1024x1024）：
- app_icon_master.png     全幅方形母版（旧式 mipmap 与 iOS/桌面通用）
- app_icon_foreground.png 透明前景（Android 自适应图标 glyph 层，
                          字形收在中央安全区内）

设计：嘉大红平底 + 右上极淡亮红径向光晕（呼应首页环境背景）
     + 居中白色「嘉」字（黑体，笔画均匀，小尺寸可读）。
重新生成：python tools/brand/make_icons.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

BRAND_RED = (139, 26, 45)  # #8B1A2D 嘉大红
GLOW_RED = (196, 84, 106)  # 亮一档的红，仅用于光晕
WHITE = (255, 255, 255)
SIZE = 1024

GLYPH = "嘉"
FONT_CANDIDATES = [
    (r"C:\Windows\Fonts\msyhbd.ttc", 0),  # 雅黑 Bold：笔画更粗，小尺寸可读
    r"C:\Windows\Fonts\simhei.ttf",
    (r"C:\Windows\Fonts\msyh.ttc", 0),
]


def load_font(px: int):
    for candidate in FONT_CANDIDATES:
        path, index = candidate if isinstance(candidate, tuple) else (candidate, 0)
        try:
            return ImageFont.truetype(path, px, index=index)
        except OSError:
            continue
    raise SystemExit("未找到可用的中文字体（simhei/msyh）")


def draw_glyph(canvas: Image.Image, px: int):
    font = load_font(px)
    draw = ImageDraw.Draw(canvas)
    left, top, right, bottom = draw.textbbox((0, 0), GLYPH, font=font)
    x = (SIZE - (right - left)) / 2 - left
    y = (SIZE - (bottom - top)) / 2 - top
    draw.text((x, y), GLYPH, font=font, fill=WHITE)


def paint_base(canvas: Image.Image):
    draw = ImageDraw.Draw(canvas)
    draw.rectangle([0, 0, SIZE, SIZE], fill=BRAND_RED)
    # 右上光晕：与首页环境背景同款参数（中心 0.78W/-0.12H，半径 0.9W）。
    center = (SIZE * 0.78, -SIZE * 0.12)
    radius = SIZE * 0.9
    peak_alpha = 66  # ~0.26，仅在红底上加一点层次，保持扁平观感
    for r in range(int(radius), 0, -4):
        alpha = int(peak_alpha * (1 - r / radius))
        if alpha <= 0:
            continue
        overlay = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        ImageDraw.Draw(overlay).ellipse(
            [center[0] - r, center[1] - r, center[0] + r, center[1] + r],
            fill=GLOW_RED + (alpha,),
        )
        canvas.alpha_composite(overlay)


def main():
    out_dir = Path(__file__).resolve().parent

    master = Image.new("RGBA", (SIZE, SIZE), BRAND_RED + (255,))
    paint_base(master)
    draw_glyph(master, px=int(SIZE * 0.56))
    master.convert("RGB").save(out_dir / "app_icon_master.png")

    # 自适应前景：字形缩到中央 ~44%，落在 66% 安全区内。
    foreground = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw_glyph(foreground, px=int(SIZE * 0.42))
    foreground.save(out_dir / "app_icon_foreground.png")

    print(f"OK -> {out_dir}")


if __name__ == "__main__":
    main()
