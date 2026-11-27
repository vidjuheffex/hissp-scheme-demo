"""Draw the grass clump sprite atlas: assets/textures/grass_clumps.png.

One-off asset tool, not part of the game. Four 256x256 sprites side by side:
  0 short green tuft, 1 tall grass with seed heads,
  2 green tuft with flowers, 3 dry golden tuft.
Sprites stand on the bottom edge and fade to transparent around the blades.

    uv run --no-project --with pillow --with numpy tools/make_grass_clumps.py
"""

import math
import random
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

TILE = 256
SS = 4  # supersampling for smooth edges
OUT = Path(__file__).resolve().parent.parent / "assets" / "textures" / "grass_clumps.png"


def lerp(a, b, t):
    return tuple(int(x + (y - x) * t) for x, y in zip(a, b))


def blade(draw, rng, base_x, height, lean, width, base_col, tip_col, segments=10):
    """A tapered, curved blade from (base_x, bottom) bending by `lean`."""
    s = TILE * SS
    bottom = s - 1
    pts_l, pts_r = [], []
    for i in range(segments + 1):
        t = i / segments
        # Bend grows toward the tip.
        x = base_x + lean * (t ** 1.8)
        y = bottom - height * t
        w = width * (1.0 - t) ** 0.85
        pts_l.append((x - w, y))
        pts_r.append((x + w, y))
    for i in range(segments):
        t = (i + 0.5) / segments
        col = lerp(base_col, tip_col, t) + (255,)
        quad = [pts_l[i], pts_r[i], pts_r[i + 1], pts_l[i + 1]]
        draw.polygon(quad, fill=col)


def jitter(col, rng, amount):
    return tuple(max(0, min(255, c + rng.randint(-amount, amount))) for c in col)


def tuft(draw, rng, count, h_range, spread, lean_range, width_range, base_col, tip_col, col_jitter=14):
    s = TILE * SS
    blades = []
    for _ in range(count):
        base_x = s / 2 + rng.gauss(0, spread * s)
        height = rng.uniform(*h_range) * s
        lean = rng.uniform(*lean_range) * s * (1 if base_x > s / 2 else -1) * rng.uniform(0.3, 1.0)
        if rng.random() < 0.25:
            lean = -lean
        width = rng.uniform(*width_range) * s
        # Keep every blade inside its tile so atlas neighbours don't bleed.
        base_x = min(max(base_x, 0.2 * s), 0.8 * s)
        lean = min(max(base_x + lean, 0.06 * s), 0.94 * s) - base_x
        blades.append((height, base_x, lean, width))
    # Tall blades at the back, short ones in front.
    for height, base_x, lean, width in sorted(blades, reverse=True):
        blade(draw, rng, base_x, height, lean, width,
              jitter(base_col, rng, col_jitter), jitter(tip_col, rng, col_jitter))
    return blades


def seed_head(draw, rng, x, y, length, col):
    s = SS
    for i in range(7):
        t = i / 6
        cx = x + rng.uniform(-1.5, 1.5) * s
        cy = y + t * length
        r = (2.6 - 1.4 * t) * s
        draw.ellipse([cx - r, cy - r * 1.8, cx + r, cy + r * 1.8], fill=jitter(col, rng, 12) + (255,))


def flower(draw, rng, x, y, petal_col):
    s = SS
    r = rng.uniform(5.0, 7.5) * s
    for k in range(5):
        a = k / 5 * math.tau + rng.uniform(-0.2, 0.2)
        px, py = x + math.cos(a) * r * 0.75, y + math.sin(a) * r * 0.6
        draw.ellipse([px - r * 0.55, py - r * 0.45, px + r * 0.55, py + r * 0.45], fill=petal_col + (255,))
    c = r * 0.35
    draw.ellipse([x - c, y - c, x + c, y + c], fill=(235, 190, 60, 255))


def sprite(kind, seed):
    rng = random.Random(seed)
    s = TILE * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    green_base, green_tip = (38, 70, 22), (118, 160, 58)
    if kind == 0:  # short tuft
        tuft(d, rng, 44, (0.35, 0.72), 0.13, (0.04, 0.22), (0.010, 0.017), green_base, green_tip)
    elif kind == 1:  # tall grass with seed heads
        blades = tuft(d, rng, 24, (0.70, 0.97), 0.10, (0.03, 0.16), (0.007, 0.011),
                      (44, 72, 26), (138, 162, 70))
        tuft(d, rng, 20, (0.25, 0.5), 0.12, (0.05, 0.2), (0.010, 0.015), green_base, green_tip)
        for height, base_x, lean, width in blades[:7]:
            tip_x = base_x + lean
            tip_y = s - 1 - height
            seed_head(d, rng, tip_x, tip_y, 26 * SS, (196, 176, 112))
    elif kind == 2:  # tuft with flowers
        petal = rng.choice([(250, 236, 120), (245, 245, 240), (176, 140, 220)])
        stems = []
        for _ in range(6):
            x = s / 2 + rng.gauss(0, 0.13 * s)
            top = s - 1 - rng.uniform(0.45, 0.75) * s
            lean = rng.uniform(-0.06, 0.06) * s
            stems.append((x, top, lean))
            blade(d, rng, x, (s - 1) - top, lean, 0.006 * s, (52, 84, 30), (80, 120, 44), segments=8)
        tuft(d, rng, 36, (0.25, 0.55), 0.13, (0.04, 0.22), (0.010, 0.016), green_base, green_tip)
        for x, top, lean in stems:
            flower(d, rng, x + lean, top, jitter(petal, rng, 10))
    elif kind == 3:  # dry tuft
        tuft(d, rng, 38, (0.30, 0.78), 0.13, (0.06, 0.30), (0.009, 0.016),
             (122, 98, 52), (222, 196, 128), col_jitter=18)
    img = img.resize((TILE, TILE), Image.LANCZOS)
    return img


def bleed(img):
    """Give transparent pixels the colour of nearby blades, so texture
    filtering and mipmaps don't pull in a black fringe."""
    a = np.asarray(img).astype(np.float32)
    alpha = a[..., 3:4] / 255.0
    rgb = a[..., :3]
    weighted = Image.fromarray((rgb * alpha).astype(np.uint8))
    mask = Image.fromarray((alpha[..., 0] * 255).astype(np.uint8))
    blur = 24
    num = np.asarray(weighted.filter(ImageFilter.GaussianBlur(blur))).astype(np.float32)
    den = np.asarray(mask.filter(ImageFilter.GaussianBlur(blur))).astype(np.float32)[..., None] / 255.0
    fill = num / np.maximum(den, 1e-3)
    mean = (rgb * alpha).sum((0, 1)) / max(alpha.sum(), 1.0)
    fill = np.where(den > 0.002, fill, mean)
    out = rgb * alpha + fill * (1.0 - alpha)
    return Image.fromarray(np.concatenate([out, a[..., 3:4]], axis=2).clip(0, 255).astype(np.uint8), "RGBA")


def main():
    atlas = Image.new("RGBA", (TILE * 4, TILE), (0, 0, 0, 0))
    for kind in range(4):
        atlas.paste(sprite(kind, 1000 + kind), (kind * TILE, 0))
    atlas = bleed(atlas)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    atlas.save(OUT)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
