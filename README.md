# Hissp Scheme Game

Infinite procedurally generated terrain you can walk around in, written in
Scheme on top of `../hissp-scheme`, rendered with Ursina/Panda3D.

```sh
uv run main.py        # new random world each run (seed is printed and in the title)
uv run main.py 1234   # revisit a world by seed
```

Controls: WASD to walk, mouse to look, Escape to toggle mouse lock.

`hissp-scheme` comes from GitHub, pinned to a commit in `uv.lock`
(`uv lock --upgrade-package hissp-scheme` moves it to the latest `main`).
To work against a local checkout instead:

```sh
uv pip install -e ../hissp-scheme
uv run --no-sync main.py   # plain `uv run` reinstalls the locked version
```

- `src/main.scm` — entrypoint
- `src/world_state.sld` — `(world state)`: state that survives reloads (never reloaded)
- `src/world_terrain.sld` — `(world terrain)`: noise, biomes, heights, chunk mesh data
- `src/world_game.sld` — `(world game)`: Ursina scene, player, sun, chunk streaming,
  live-reload and REPL (chunks are generated on an SRFI 18 worker thread)
- `src/shaders/` — GLSL for the terrain (biome ground cover, rock, beaches, snow) and water
- `assets/textures/` — tiling grass and rock textures
- `main.py` — launcher only (transpiles the Scheme libraries, then runs `main.scm`)

## Live development

While the game runs, save a file and it reloads within about half a second:

- `src/world_terrain.sld`, `src/world_game.sld`: the libraries are re-evaluated
  in place. Terrain edits also regenerate the chunks.
- `src/shaders/*`: shaders are recompiled and applied to the existing terrain.

Type Scheme into the terminal that started the game, one form per line:

```scheme
(+ 1 2)                    ; prints 3
(set-input! "fog_end" 80.0) ; shader uniform, takes effect immediately
(define FOG-END 40.0)      ; then (apply-scene!) to push it
(set-time-of-day! 18.5)    ; 6:30pm; the clock keeps running
(set-day-length! 0)        ; freeze the clock (60 = a day per minute)
(biome-here)               ; biome weights under the player
(visit-biome! "desert")    ; go to the nearest desert ("grassland", "dry grassland", "snowy")
(go-to! 500 -200)          ; move the player
(regenerate!)              ; rebuild every chunk
(reload!)                  ; force-reload everything
```

The clock starts at 10:00 and runs a full day in 4 minutes. `scene-at` in
`src/world_game.sld` holds the sun, sky and ambient colours for each hour.

## Biomes

Grassland, dry grassland, desert and snowy. Two slow noise fields,
temperature and moisture, decide the biome; deserts need heat as well as
dryness, so dry grassland usually sits between desert and snow. Each biome
reshapes the terrain (deserts are low with dunes, snowy ground is taller),
and the shapes blend across borders. Sizes vary from a few hundred units to
several kilometres.

The knobs are at the top of the biomes section in `src/world_terrain.sld`:
`CLIMATE-FREQUENCY` (biome size), `WARP-AMOUNT` (how wiggly borders are),
the `COLD`/`HOT`/`ARID`/`SEMI-ARID` thresholds (how much of each biome), and
the per-biome height functions. Saving the file regenerates the world.

Errors are printed without stopping the game; fix the file and save to recover.
`src/world_state.sld` and `main.py` need a restart to change.
