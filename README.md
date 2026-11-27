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
- `src/world_plants.sld` — `(world plants)`: cactus, ocotillo, agave and tree meshes
- `src/world_weather.sld` — `(world weather)`: cloud cover, rain and snow
- `src/world_game.sld` — `(world game)`: Ursina scene, player, sun, chunk streaming,
  live-reload and REPL (chunks are generated on an SRFI 18 worker thread)
- `src/shaders/` — GLSL for the terrain (biome ground cover, rock, beaches, snow,
  wet ground), water (sky and cloud reflections, noise chop, surf foam, soft
  shoreline that laps up the beach, rain ripples), grass clumps (wind, fade-out), desert plants
  and trees (surface detail, swaying, snow on branches), the moon
  (phase shading), the sky and clouds, and rain and snow; `clouds.glsl` is
  the cloud layer, spliced into every shader with `#include "clouds.glsl"`
- `assets/textures/` — tiling grass and rock textures, the grass clump sprites, the moon
- `tools/make_grass_clumps.py`, `tools/make_moon.py` — one-off generators for
  `grass_clumps.png` and `moon.png`
  (`uv run --no-project --with pillow --with numpy tools/make_moon.py`)
- `main.py` — launcher only (transpiles the Scheme libraries, then runs `main.scm`)

## Live development

While the game runs, save a file and it reloads within about half a second:

- `src/world_terrain.sld`, `src/world_plants.sld`, `src/world_weather.sld`,
  `src/world_game.sld`: the
  libraries are re-evaluated in place. Terrain and plant edits also regenerate
  the chunks.
- `src/shaders/*`: shaders are recompiled and applied to the existing terrain.

Type Scheme into the terminal that started the game, one form per line:

```scheme
(+ 1 2)                    ; prints 3
(set-input! "fog_end" 80.0) ; shader uniform, takes effect immediately
(define FOG-END 40.0)      ; then (apply-scene!) to push it
(set-time-of-day! 18.5)    ; 6:30pm; the clock keeps running
(set-day-length! 0)        ; freeze the clock (60 = a day per minute)
(moon-phase)               ; day count, phase name, lit fraction
(set-day! 15)              ; jump the moon's cycle (0 new, 7 first quarter, 15 full)
(weather)                  ; cloud cover, precipitation, rain or snow, wetness, snow cover
(set-weather! 1.0)         ; force the cloud cover: 1 storm, 0 clear; #f to let it run
(biome-here)               ; biome weights under the player
(visit-biome! "desert")    ; go to the nearest desert ("grassland", "dry grassland", "snowy")
(go-to! 500 -200)          ; move the player
(regenerate!)              ; rebuild every chunk
(reload!)                  ; force-reload everything
```

The clock starts at 10:00 and runs a full day in 4 minutes. `scene-at` in
`src/world_game.sld` holds the sun, moon, sky and ambient colours for each hour.

The moon goes through real phases, 29.5 in-game days from new moon to new
moon (about two hours of play), starting on day 10. Like the real moon it
trails the sun across the sky by its phase: a full moon rises at sunset and
lights the whole night, a new moon is up by day and leaves the night dark,
and the quarters are up for half the night. At night the shadow-casting light
is the moon, so full moons give soft blue shadows. The moonlight, night sky
and ambient colours (`MOON-COLOR`, `MOON-BRIGHTNESS`, `SKY-MOONLIT`,
`AMBIENT-NEW-MOON`, `AMBIENT-FULL-MOON`) are at the top of
`src/world_game.sld`.

## Weather

Cloud cover drifts between clear and overcast over game time, about twice a
day (a couple of minutes of play), different in every world. Deserts get half
the cloud and little rain. When cover is heavy it rains, or snows in the snowy
biome and above 30 m. Clouds cast shadows that drift across the land (by
moonlight too), so overcast is shade everywhere; it also greys the sky, and
rain and snow pull the fog in. Rain rings ripple the water and darken the
ground, which dries over a minute or two; fresh
snow settles on flat ground and brings the snow line down the mountains, then
melts over a few minutes.

The sky is two domes around the camera: `sky.frag` (gradient and sun glow)
behind the sun and moon, and `clouds.frag` (noise on a layer at 520 m,
drifting with the wind) over them. The layer itself is in
`src/shaders/clouds.glsl`, which the ground, grass, plant and water shaders
also include: each looks up toward the sun through the same noise to shade
itself. Rain and snow are 12,000 quads in a box
that follows the camera, moved entirely in `precip.vert`. The weather model
and its rates are in `src/world_weather.sld`; how weather changes the light is
in `scene-at` in `src/world_game.sld`.

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

## Grass clumps

Grassland and dry grassland grow clumps of grass in four kinds: short tufts,
tall grass with seed heads, tufts with flowers, and dry golden tufts. They
grow in meadows with bare ground between, and never on beaches, steep slopes,
the rock band, desert or snow. Clumps are only made for chunks within two of
the player's chunk, and sink into the ground near the edge of that range.

The knobs are in the grass clumps section of `src/world_terrain.sld`:
`GRASS-SPACING` (density), `GRASS-CHANCE`/`DRY-GRASS-CHANCE`, `MEADOW` and
`MEADOW-FREQUENCY` (patch size), `SPRITE-HEIGHTS` and `SPRITE-TINTS`.
`GRASS-RADIUS` and `GRASS-FADE` are in `src/world_game.sld`, and wind is in
`src/shaders/grass.vert`. Saving the terrain file regrows the grass along
with the chunks.

## Desert plants

Deserts grow a Chihuahuan mix: prickly pear (some purple, with magenta
fruit), barrel cactus (some doubled, with a crown of yellow fruit), cholla,
ocotillo (leafy or bare, some with red tips) and agave (big blue-grey ones,
some with a tall flower stalk, and small green lechuguilla). Dry grassland
gets a sparse scatter of prickly pear, ocotillo and agave. They grow in
patches, and not on beaches or steep slopes.

They are real 3D meshes, unlike the grass sprites: each species is modeled a
few ways when the game starts, and every chunk merges turned, scaled and
tinted copies into one mesh. They are made with the chunk, so they are
visible as far as the terrain and cast shadows.

The species shapes and colours are the `make-...` functions in
`src/world_plants.sld`; density and mix are in its placement section
(`PLANT-SPACING`, `DESERT-PLANT-CHANCE`, `DRY-PLANT-CHANCE`, `PATCHES`,
`DESERT-MIX`, `DRY-MIX`), and sizes are in `SPECIES`. Saving the file
regrows them. Surface detail is drawn by `src/shaders/plant.frag` rather
than textures: areoles on pads, spines on barrels and cholla, thorns on
ocotillo, waxy agave leaves with dark margins, darkening near the ground and
a glow when backlit.

## Trees

Trees are made the same way as the desert plants, on their own coarser grid
(`TREE-SPACING`). Grassland grows oak groves with open meadows between them
(`GROVES`, `GROVE-FREQUENCY`); going up the mountains conifers take over
(`MOUNTAIN-PINES`) until the tree line (`TREE-LINE`), and the snowy biome is
all conifer forest, narrow dark spruces and broader pines with bare trunks
below head height. Dry grassland has scattered junipers and the desert the
odd low, spreading mesquite. `FOREST-CHANCE`, `JUNIPER-CHANCE` and
`MESQUITE-CHANCE` set how many.

Conifers are built by `make-conifer`, tiers of ragged, drooping needle
skirts. Oaks, junipers and mesquite share `make-broadleaf`: trunks under a
crown of overlapping leaf clumps with limbs reaching out to them, and the
`OAK`, `JUNIPER` and `MESQUITE` forms set their proportions. In
`plant.frag` bark gets furrows, needles tufts and leaves clusters with dark
gaps, and fresh snow settles on the tops of branches; `plant.vert` sways
trees in the wind. You can't walk through trunks: each chunk keeps its
trees' positions for `keep-out-of-trunks!` in `src/world_game.sld`.

Errors are printed without stopping the game; fix the file and save to recover.
`src/world_state.sld` and `main.py` need a restart to change.
