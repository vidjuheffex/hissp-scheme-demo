# Hissp Scheme Game

Infinite procedurally generated terrain you can walk around in, written in
Scheme on top of `../hissp-scheme`, rendered with Ursina/Panda3D.

```sh
uv run main.py        # new random world each run (seed is printed and in the title)
uv run main.py 1234   # revisit a world by seed
```

Controls: WASD to walk, mouse to look, Escape to toggle mouse lock.

- `src/main.scm` — entrypoint
- `src/world_terrain.sld` — `(world terrain)`: noise, heights, chunk mesh data
- `src/world_game.sld` — `(world game)`: Ursina scene, player, sun, chunk streaming
  (chunks are generated on an SRFI 18 worker thread)
- `src/shaders/` — GLSL for the terrain (grass/rock/sand/snow blending) and water
- `assets/textures/` — tiling grass and rock textures
- `main.py` — launcher only (transpiles the Scheme libraries, then runs `main.scm`)
