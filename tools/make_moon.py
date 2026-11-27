"""Generate assets/textures/moon.png: the moon's near side, face on.

One-off asset tool (the game itself doesn't run Python). The moon shader
looks it up by the sphere's surface position across the face, so the image is
the visible disc as seen from far away; outside the disc is unused.

    uv run --no-project --with pillow --with numpy tools/make_moon.py
"""
from pathlib import Path

import numpy as np
from PIL import Image

SIZE = 1024
OUT = Path(__file__).resolve().parent.parent / "assets" / "textures" / "moon.png"
rng = np.random.default_rng(29)


def value_noise(size, cells):
    """Smooth noise in [0, 1) with `cells` lattice cells across."""
    grid = rng.random((cells + 1, cells + 1))
    t = np.linspace(0, cells, size, endpoint=False)
    i = t.astype(int)
    f = t - i
    f = f * f * (3 - 2 * f)
    a = grid[i][:, i]
    b = grid[i][:, i + 1]
    c = grid[i + 1][:, i]
    d = grid[i + 1][:, i + 1]
    fx, fy = f[None, :], f[:, None]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def fbm(size, cells, octaves):
    total, amp, norm = np.zeros((size, size)), 1.0, 0.0
    for o in range(octaves):
        total += amp * value_noise(size, cells * 2 ** o)
        norm += amp
        amp *= 0.5
    return total / norm


# Coordinates across the face, -1..1, and the sphere surface behind them.
y, x = np.mgrid[0:SIZE, 0:SIZE]
u = (x + 0.5) / SIZE * 2 - 1
v = 1 - (y + 0.5) / SIZE * 2
r2 = np.minimum(u * u + v * v, 1.0)
z = np.sqrt(1 - r2)

# Highlands: bright, rough.
height = fbm(SIZE, 6, 6)
albedo = 0.78 + 0.18 * (height - 0.5)

# Seas (maria): broad dark basins with soft, irregular shores, mostly on one
# side like the real near side.
# Warped coordinates make the basins' outlines irregular.
wu = u + 0.22 * (fbm(SIZE, 4, 4) - 0.5)
wv = v + 0.22 * (fbm(SIZE, 4, 4) - 0.5)
seas = np.zeros((SIZE, SIZE))
for cx, cy, rad in ((-0.25, 0.35, 0.33), (0.18, 0.42, 0.22), (0.35, 0.05, 0.25),
                    (-0.45, -0.05, 0.28), (-0.1, -0.25, 0.2), (0.15, -0.45, 0.13),
                    (0.55, 0.38, 0.12)):
    d = np.sqrt((wu - cx) ** 2 + (wv - cy) ** 2) / rad
    seas = np.maximum(seas, 1 - d)
shore = fbm(SIZE, 14, 4) - 0.5
seas = np.clip((seas + 0.6 * shore) * 1.5, 0, 1)
seas = seas * seas * (3 - 2 * seas)
albedo = albedo * (1 - 0.36 * seas * (0.8 + 0.4 * fbm(SIZE, 8, 3)))


def add_crater(cx, cy, rad, depth, rays=0.0):
    """Darker floor, bright raised rim, faint ejecta and optional rays."""
    global albedo
    d = np.sqrt((u - cx) ** 2 + (v - cy) ** 2) / rad
    near = d < 3.5
    dd = d[near]
    floor = np.clip(1 - dd, 0, 1) ** 0.5
    rim = np.exp(-((dd - 1) / 0.12) ** 2)
    ejecta = np.exp(-np.maximum(dd - 1, 0) * 2.5) * (dd > 1)
    # Light from the upper left: the rim catches it on one side, the floor
    # is shadowed on the other.
    side = ((u[near] - cx) * -0.6 + (v[near] - cy) * 0.8) / rad
    change = -depth * 0.06 * floor * (1 + 0.6 * np.clip(side, -1, 1)) \
        + depth * 0.05 * rim * (1 + 0.5 * np.clip(-side, -1, 1)) \
        + depth * 0.03 * ejecta
    if rays:
        angle = np.arctan2(v[near] - cy, u[near] - cx)
        streak = np.clip(np.sin(angle * 23 + 1.7) * np.sin(angle * 37), 0, 1) ** 3
        change += rays * streak * np.exp(-np.maximum(dd - 1, 0) / 6.0) * (dd > 1)
    albedo[near] += change


# Many small craters, few big ones (a power law), fewer on the seas.
for _ in range(600):
    rad = 0.006 * (1 - rng.random()) ** -0.8
    if rad > 0.06:
        continue
    cx, cy = rng.uniform(-1, 1, 2)
    if cx * cx + cy * cy > 0.98:
        continue
    px = int((cx + 1) / 2 * (SIZE - 1))
    py = int((1 - cy) / 2 * (SIZE - 1))
    if seas[py, px] > 0.5 and rng.random() < 0.7:
        continue
    add_crater(cx, cy, rad, rng.uniform(0.6, 1.0))

# Two young craters with bright ray systems (like Tycho and Copernicus).
add_crater(-0.12, -0.62, 0.03, 2.0, rays=0.12)
add_crater(-0.28, 0.12, 0.025, 2.0, rays=0.07)

grain = fbm(SIZE, 96, 2) - 0.5
albedo += 0.04 * grain

# Seen face on, a sphere's edge is foreshortened; darken slightly there.
albedo *= 0.88 + 0.12 * z
albedo = np.clip(albedo, 0, 1)

# Slightly warm grey, as the moon looks.
rgb = np.stack([albedo * 1.0, albedo * 0.98, albedo * 0.93], axis=-1)
alpha = (r2 < 0.999).astype(float)
img = np.concatenate([rgb, alpha[..., None]], axis=-1)
OUT.parent.mkdir(parents=True, exist_ok=True)
Image.fromarray((img * 255).astype(np.uint8), "RGBA").resize((512, 512), Image.LANCZOS).save(OUT)
print("wrote", OUT)
