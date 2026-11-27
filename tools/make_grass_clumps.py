"""Draw the grass clump sprite atlas: assets/textures/grass_clumps.png.

One-off asset tool, not part of the game. Nine 256x256 sprites side by side:
  0 short green tuft, 1 tall grass with seed heads,
  2 green tuft with flowers, 3 dry golden tuft,
  4 daisies, 5 flower spikes, 6 poppies, 7 desert annual, 8 fern.
Sprites stand on the bottom edge and fade to transparent around the blades.
The wildflowers' (4-7) petals are drawn near-white so the grass shader can
color each patch; see `petal_color` in src/shaders/grass.frag.

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


PETAL = (238, 238, 238)  # wildflower petals: tinted in the shader


def shade(col, rng, lo, hi):
    """A grey petal color: `col` darkened by a random amount."""
    k = rng.uniform(lo, hi)
    return tuple(int(c * k) for c in col)


def stem(draw, rng, x, top, lean, width, col=(52, 84, 30), tip=(80, 120, 44)):
    s = TILE * SS
    blade(draw, rng, x, (s - 1) - top, lean, width * s, col, tip, segments=8)
    return x + lean, top


def daisy(draw, rng, x, y, r):
    for k in range(9):
        a = k / 9 * math.tau + rng.uniform(-0.15, 0.15)
        px, py = x + math.cos(a) * r * 0.8, y + math.sin(a) * r * 0.45
        col = shade(PETAL, rng, 0.82, 1.0)
        draw.ellipse([px - r * 0.42, py - r * 0.22, px + r * 0.42, py + r * 0.22], fill=col + (255,))
    c = r * 0.32
    draw.ellipse([x - c, y - c * 0.7, x + c, y + c * 0.7], fill=(222, 170, 40, 255))


def cup(draw, rng, x, y, r):
    """A poppy-like cup seen from the side: overlapping rounded petals."""
    for k, dx in enumerate((-0.55, 0.55, -0.2, 0.2)):
        col = shade(PETAL, rng, 0.72 if k < 2 else 0.88, 0.95 if k < 2 else 1.0)
        draw.ellipse([x + dx * r - r * 0.6, y - r * 0.9, x + dx * r + r * 0.6, y + r * 0.35], fill=col + (255,))
    draw.ellipse([x - r * 0.25, y - r * 0.85, x + r * 0.25, y - r * 0.55], fill=(40, 34, 30, 255))


def frond(draw, rng, base_x, length, angle, droop, col_base, col_tip):
    """An arching fern frond from (base_x, bottom): a curved stalk lined with
    pairs of leaflets that shrink toward the tip."""
    s = TILE * SS
    steps = 22
    pts = []
    for i in range(steps + 1):
        t = i / steps
        a = angle + droop * t * t
        x = base_x + math.sin(a) * length * t
        y = (s - 1) - math.cos(a) * length * t
        pts.append((x, y))
    for i in range(steps):
        draw.line([pts[i], pts[i + 1]], fill=lerp(col_base, col_tip, i / steps) + (255,),
                  width=max(1, int((1.0 - i / steps) * 2.2 * SS)))
    for i in range(2, steps):
        t = i / steps
        (x0, y0), (x1, y1) = pts[i - 1], pts[i + 1]
        dx, dy = x1 - x0, y1 - y0
        n = math.hypot(dx, dy) or 1.0
        dx, dy = dx / n, dy / n
        leaf = length * 0.13 * math.sin(math.pi * min(1.0, t * 1.15)) * (1.0 - 0.25 * t)
        width = leaf * 0.28
        col = jitter(lerp(col_base, col_tip, 0.3 + 0.6 * t), rng, 10) + (255,)
        cx, cy = pts[i]
        for side in (-1, 1):
            # Leaflets angle forward along the frond and sag a little.
            ox, oy = -dy * side * 0.85 + dx * 0.5, dx * side * 0.85 + dy * 0.5 + 0.25
            tip = (cx + ox * leaf, cy + oy * leaf)
            mid = (cx + ox * leaf * 0.5, cy + oy * leaf * 0.5)
            draw.polygon([(cx, cy), (mid[0] + dx * width, mid[1] + dy * width), tip,
                          (mid[0] - dx * width, mid[1] - dy * width)], fill=col)


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
    elif kind == 4:  # daisies over short grass
        heads = []
        for _ in range(11):
            x = s / 2 + rng.gauss(0, 0.16 * s)
            x = min(max(x, 0.18 * s), 0.82 * s)
            heads.append(stem(d, rng, x, s - 1 - rng.uniform(0.3, 0.7) * s, rng.uniform(-0.05, 0.05) * s, 0.005))
        tuft(d, rng, 30, (0.18, 0.4), 0.15, (0.04, 0.2), (0.009, 0.014), green_base, green_tip)
        for x, y in sorted(heads, key=lambda h: h[1]):
            daisy(d, rng, x, y, rng.uniform(13, 18) * SS)
    elif kind == 5:  # tall spikes of small florets, like lupine
        spikes = []
        for _ in range(5):
            x = s / 2 + rng.gauss(0, 0.12 * s)
            x = min(max(x, 0.22 * s), 0.78 * s)
            spikes.append(stem(d, rng, x, s - 1 - rng.uniform(0.75, 0.95) * s, rng.uniform(-0.03, 0.03) * s, 0.007))
        tuft(d, rng, 26, (0.2, 0.45), 0.14, (0.04, 0.2), (0.010, 0.016), green_base, green_tip)
        for x, top in spikes:
            length = rng.uniform(0.3, 0.42) * s
            for k in range(26):
                t = k / 25
                w = (1.0 - 0.75 * t) * 9 * SS
                cy = top + length * (1.0 - t)
                for side in (-1, 1):
                    cx = x + side * w * rng.uniform(0.3, 0.9)
                    r = (1.0 - 0.5 * t) * 4.2 * SS
                    col = shade(PETAL, rng, 0.75 + 0.2 * t, 1.0)
                    d.ellipse([cx - r, cy - r * 0.8, cx + r, cy + r * 0.8], fill=col + (255,))
    elif kind == 6:  # poppies on thin stems
        heads = []
        for _ in range(5):
            x = s / 2 + rng.gauss(0, 0.15 * s)
            x = min(max(x, 0.2 * s), 0.8 * s)
            heads.append(stem(d, rng, x, s - 1 - rng.uniform(0.5, 0.85) * s, rng.uniform(-0.07, 0.07) * s, 0.004,
                              (70, 100, 50), (96, 128, 64)))
        tuft(d, rng, 20, (0.15, 0.35), 0.13, (0.05, 0.25), (0.008, 0.013), (60, 90, 44), (120, 150, 80))
        for x, y in heads:
            cup(d, rng, x, y, rng.uniform(13, 18) * SS)
    elif kind == 7:  # a low desert annual: grey-green leaves, small bright flowers
        heads = []
        for _ in range(14):
            x = s / 2 + rng.gauss(0, 0.18 * s)
            x = min(max(x, 0.16 * s), 0.84 * s)
            heads.append(stem(d, rng, x, s - 1 - rng.uniform(0.3, 0.75) * s, rng.uniform(-0.1, 0.1) * s, 0.007,
                              (84, 98, 66), (130, 146, 104)))
        tuft(d, rng, 22, (0.12, 0.35), 0.15, (0.08, 0.3), (0.012, 0.02), (84, 98, 66), (140, 156, 116))
        for x, y in sorted(heads, key=lambda h: h[1]):
            daisy(d, rng, x, y, rng.uniform(11, 15) * SS)
    elif kind == 8:  # fern: a rosette of arching fronds
        fronds = []
        for k in range(9):
            side = -1 if k % 2 else 1
            angle = side * rng.uniform(0.05, 0.5)
            fronds.append((abs(angle), angle))
        # The most upright last, in front.
        for _, angle in sorted(fronds, reverse=True):
            frond(d, rng, s / 2 + rng.gauss(0, 0.02 * s), rng.uniform(0.6, 0.85) * s, angle,
                  (1 if angle > 0 else -1) * rng.uniform(0.35, 0.75), (34, 62, 22), (96, 140, 52))
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
    atlas = Image.new("RGBA", (TILE * 9, TILE), (0, 0, 0, 0))
    for kind in range(9):
        atlas.paste(sprite(kind, 1000 + kind), (kind * TILE, 0))
    atlas = bleed(atlas)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    atlas.save(OUT)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
