# Hissp Scheme Game

Infinite procedurally generated terrain you can walk around in, written in
Scheme on top of `../hissp-scheme`, rendered with Ursina/Panda3D.

```sh
uv run main.py        # new random world each run (seed is printed and in the title)
uv run main.py 1234   # revisit a world by seed
```

Controls: WASD to walk (Shift to sprint), mouse to look, Escape to toggle
mouse lock. You can wade into water up to about thigh deep, slowing as it gets deeper, but no deeper.
You can't walk up cliffs or canyon walls, but you can walk off them, and fall.
Caves open in canyon walls and escarpments. A flashlight follows the mouse,
turning on as it gets dark in caves or outside.
Your position (meters) is shown in the top left corner.

`hissp-scheme` comes from GitHub, pinned to a commit in `uv.lock`
(`uv lock --upgrade-package hissp-scheme` moves it to the latest `main`).
To work against a local checkout instead:

```sh
uv pip install -e ../hissp-scheme
uv run --no-sync main.py   # plain `uv run` reinstalls the locked version
```

- `src/main.scm` — entrypoint
- `src/world_state.sld` — `(world state)`: state that survives reloads (never reloaded)
- `src/world_terrain.sld` — `(world terrain)`: noise, biomes, rivers, canyons and cliffs, forests, heights, chunk mesh data
- `src/world_caves.sld` — `(world caves)`: cave layouts, the combined terrain and cave mesh, cave floors and headroom
- `src/world_plants.sld` — `(world plants)`: cactus, ocotillo, agave, tree, undergrowth and rock meshes
- `src/world_weather.sld` — `(world weather)`: cloud cover, rain and snow, wind, wind lines
- `src/world_life.sld` — `(world life)`: fireflies, bats and birds
- `src/world_game.sld` — `(world game)`: Ursina scene, player, sun, chunk streaming,
  live-reload and REPL (chunks are generated on an SRFI 18 worker thread)
- `src/shaders/` — GLSL for the terrain (biome ground cover, forest floor, rock and its strata, beaches, snow,
  wet ground and cave darkness), water (sky and cloud reflections, noise chop, surf foam, soft
  shoreline that laps up the beach, rain ripples), grass clumps (wind, fade-out), desert plants
  and trees (surface detail, swaying, snow on branches), the moon
  (phase shading), the sky and clouds, rain and snow, wildlife, wind lines, and the
  coordinates readout's text; `clouds.glsl` is
  the cloud layer, spliced into every shader with `#include "clouds.glsl"` (and
  likewise `stars.glsl`, `mist.glsl` and `flashlight.glsl`)
- `assets/textures/` — tiling grass and rock textures, the grass clump sprites, the moon
- `assets/sounds/` — ambient loops (wind, rain, birds, crickets, water, woods, river), owl calls, footsteps and thunder, synthesized by
  `tools/make_sounds.py` (`uv run --no-project --with numpy --with soundfile tools/make_sounds.py`)
- `assets/fonts/` — Lexend Deca (Regular instance of the variable font, SIL Open Font
  License in `OFL.txt`) for the coordinates readout
- `tools/make_grass_clumps.py`, `tools/make_moon.py` — one-off generators for
  `grass_clumps.png` (grass, wildflower and fern sprites) and `moon.png`
  (`uv run --no-project --with pillow --with numpy tools/make_moon.py`)
- `main.py` — launcher only (transpiles the Scheme libraries, then runs `main.scm`,
  or the `.scm` file given first on the command line)
- `tests/` — SRFI 64 test suites in Scheme, one per library (see below)

## Tests

```sh
uv run main.py tests/run.scm             # every suite, including cave topology and offscreen rendering; exits 1 on a failure
uv run main.py tests/test_terrain.scm    # one suite while working on it
```

Before committing, install the repository's pre-commit and pre-push hooks:

```sh
uv sync --dev
uv run pre-commit install --install-hooks
uv run pre-commit run --all-files         # repository checks and Ruff
```

The pre-push hook also runs every Scheme test. GitHub Actions runs the same
pre-commit checks and full test suite on pull requests and pushes to `main`.

The suites need no window and use world seed 4242 so results repeat. The
flashlight shader checks render into a small offscreen OpenGL buffer:

- `test_state.scm`: values and the seed survive in `(world state)`.
- `test_terrain.scm`: noise ranges, seeds giving the same and different worlds,
  walkable ground versus the sea, biome shares, chunk meshes on the grid at
  `terrain-height` with unit normals, upward faces and matching edges between
  neighbors, water only where the ground dips under the sea, grass and its clearings.
- `test_weather.scm`: targets, wind (unit direction, storms harder, nights
  calmer), mist (none in the desert), blooms, rain soaking and drying the
  ground and snow settling and melting, the rain and wind-line meshes.
- `test_precipitation.scm` tracks a particle in the renderer during an uphill
  transition to snow, a fast descent and a wrap of the falling distance.
- `test_life.scm`: when fireflies, bats and birds are out, their mesh, and the
  ground grid fireflies follow.
- `test_plants.scm`: valid plant meshes, the same plants every time, trunks on dry
  ground inside their chunk, nothing in a full clearing.
- `test_caves.scm`: see [Caves](#caves).
- `test_game.scm`: cave sound fading and the flashlight coming on at night
  and in caves, fading at dawn, dusk and entrances, and equipment disabling it.
- `test_flashlight.scm`: the actual shader's main spot, dim directional spill,
  light coming from the hand, distance falloff, range, switching both beams off,
  an object casting a shadow that moves with it, shader-bearing casters,
  and the player camera living outside the world's geometry subtree.

Shared checks (mesh validity, ranges, test names) are in `tests/helpers.scm`.
Each suite is an R7RS program, so its imports come first: `(import (scheme base))`
before `(include "helpers.scm")`, since the helpers use syntax that library brings in.

## Live development

While the game runs, save a file and it reloads within about half a second:

- `src/world_terrain.sld`, `src/world_caves.sld`, `src/world_plants.sld`, `src/world_weather.sld`,
  `src/world_life.sld`, `src/world_game.sld`: the
  libraries are re-evaluated in place. Terrain, cave and plant edits also regenerate
  the chunks.
- `src/shaders/*`: shaders are recompiled and applied to the existing terrain.

Type Scheme into the terminal that started the game, one form per line:

```scheme
(+ 1 2)                    ; prints 3
(set-input! "fog_end" 80.0) ; shader uniform, takes effect immediately
(define FOG-END 40.0)      ; then (apply-scene!) to push it
(set-time-of-day! 18.5)    ; 6:30pm; the clock keeps running
(set-day-length! 0)        ; freeze the clock (60 = a day per minute)
(set-flashlight! #f)       ; disable the automatic flashlight; #t enables it
(flashlight-strength)     ; current automatic brightness, 0 off to 1 on
(moon-phase)               ; day count, phase name, lit fraction
(set-day! 15)              ; jump the moon's cycle (0 new, 7 first quarter, 15 full)
(weather)                  ; cloud cover, precipitation, rain or snow, wetness, snow cover, wind
(set-weather! 1.0)         ; force the cloud cover: 1 storm, 0 clear; #f to let it run
(set-wind! 0)              ; force the wind: 0 dead calm, 1 breeze; #f to let it run
(wind)                     ; wind speed and heading (degrees: 0 toward +x, 90 toward +z)
(set-wind-direction! 90)   ; force the heading; #f to let it wander
(wildlife)                 ; how many fireflies, bats and birds are out, 0 to 1
(biome-here)               ; biome weights under the player
(visit-biome! "desert")    ; go to the nearest desert ("grassland", "dry grassland", "snowy")
(find-river)               ; stand in the nearest river
(find-canyon)              ; go to the nearest canyon floor
(find-cliffs)              ; go to the foot of the nearest escarpment
(find-cave)                ; go to the nearest cave's mouth; says small, medium or large
(visit-cave!)              ; go a few meters into the nearest cave
(cave-size)                ; how big the nearest cave is
(go-to! 500 -200)          ; move the player
(regenerate!)              ; rebuild every chunk
(reload!)                  ; force-reload everything
```

The clock starts at 10:00 and runs a full day in 30 minutes
(`(set-day-length! seconds)` changes it). `scene-at` in
`src/world_game.sld` holds the sun, moon, sky and ambient colours for each hour.

The moon goes through real phases, 29.5 in-game days from new moon to new
moon (about 15 hours of play), starting on day 10. Like the real moon it
trails the sun across the sky by its phase: a full moon rises at sunset and
lights the whole night, a new moon is up by day and leaves the night dark,
and the quarters are up for half the night. At night the shadow-casting light
is the moon, so full moons give soft blue shadows. The moonlight, night sky
and ambient colours (`MOON-COLOR`, `MOON-BRIGHTNESS`, `SKY-MOONLIT`,
`AMBIENT-NEW-MOON`, `AMBIENT-FULL-MOON`) are at the top of
`src/world_game.sld`.

The flashlight fades on as the sun gets low or daylight fades into a cave,
and turns off again in daylight. It follows mouse look in both directions
from a position below and right of the eye, aiming at the view's center
8 m away. Nearby walls receive light from that hand position. A faint, wider
spill reveals rock beyond the main spot; both beams stay directional and
fade with distance, with no all-around player glow. The same light is used
indoors and outside, on terrain, grass, plants, rocks and water.

Rocks, plants, cave formations and the ground cast shadows into both the
spot and its spill. One camera on the flashlight draws a 2048-pixel depth
map; a small filter softens its edges. The shader uses that camera's position
and direction too, so shadows stay with the beam as you look around.
The shadow camera traverses the full scene root, which contains both the
player camera and the chunk subtree; using just the chunks as its scene
leaves the map empty when the player camera is outside that subtree.
The shadow pass is off whenever the flashlight is off. Grass clumps and
water receive shadows but do not cast them, as with the sun's shadows.

The shared beam is in `src/shaders/flashlight.glsl`: `FLASHLIGHT_COLOR` sets
its tint, `FLASHLIGHT_INNER_ANGLE` and `FLASHLIGHT_OUTER_ANGLE` its 6° bright
center and 22° soft outer edge, and `FLASHLIGHT_SPILL` the spill's 12% share.
`FLASHLIGHT_HALF_DISTANCE` sets where distance alone halves the light,
9 m away. The last quarter of the range eases to zero.
The scene constants in `src/world_game.sld` set the actual light:
`FLASHLIGHT-OFFSET`, `FLASHLIGHT-AIM-DISTANCE`, `FLASHLIGHT-REACH` (24 m),
`FLASHLIGHT-SPILL-ANGLE` (65°), and `FLASHLIGHT-SHADOW-SIZE`.
Angles are from the beam's axis.
`(set-flashlight! #f)` disables it everywhere;
`#t` restores automatic lighting. This enable flag survives hot reloads and
can be driven by equipment later; a flashlight is available by default.

Stars and the Milky Way come out as the sky darkens, drawn in `sky.frag`.
They wheel across the sky with the sun's path, rising and setting through the
night, and shift a little further each day through the year. A bright moon
washes most of them out, clouds hide them, and they dim and twinkle low down.

## Weather

Cloud cover drifts between clear and overcast over game time, about twice a
day (every 15 minutes or so of play), different in every world. Deserts get half
the cloud and little rain. When cover is heavy it rains, or snows in the snowy
biome and above 30 m. Clouds cast shadows that drift across the land (by
moonlight too), so overcast is shade everywhere; it also greys the sky, and
rain and snow pull the fog in. Rain rings ripple the water and darken the
ground, which dries over a minute or two; fresh
snow settles on flat ground and brings the snow line down the mountains, then
melts over a few minutes.

The wind (`wind-speed` in `src/world_weather.sld`) has breezy and still spells
of its own, drops at night and picks up in storms. It sets how much the grass
and trees sway and how choppy the water is: on a still, clear night lakes go
glassy and mirror the stars.

Its direction (`wind-direction`) wanders too: it holds for a while, then
swings round over ten minutes or so of play, sometimes most of the way
round, and veers when a storm comes in. Clouds, rain and snow, the grass and
trees, the bird flocks and the wind lines all follow it.

Wind lines, like Wind Waker's, show which way it's blowing: white streaks
that draw themselves out high in the sky (110 to 150 m up, over the
tallest peaks, set by `WIND-LINE-HEIGHTS`), some with a curl, then rub out from the tail and turn
up somewhere else. A breeze brings out one or two in view at a time, only a
windy storm a few more, and none show in a calm; they ride along faster in a
gale. They're one mesh that
follows the camera, moved entirely in `src/shaders/wind.vert`;
`WIND-LINES` and `WIND-LINE-BOX` in `src/world_weather.sld` set how many and
over what area, and `AIR-SPEED` in `src/world_game.sld` how fast they travel.

Thunderstorms (heavy cloud and rain, not snow) throw lightning now and then:
the sky, clouds and light flash in a few quick pulses, brighter for nearer
strikes, and the thunder arrives later the farther off it struck (about 3
seconds a kilometer), with a sharp crack only when it's close. `(strike! 1.0)`
in the REPL sends a bolt a kilometer away.

On calm mornings, some more than others and more after rain, mist gathers in
the small hours and pools in the low ground: it's thickest at sea level and
thins out a few meters up, so from a hilltop the valleys below are filled
with it. It burns off as the sun climbs, and deserts are too dry for it
(`mist-amount` in `src/world_weather.sld`; the fog itself is
`src/shaders/mist.glsl`). `(set-mist! 0.8)` forces it, `#f` undoes.

The sky is two domes around the camera: `sky.frag` (gradient, sun glow, stars)
behind the sun and moon, and `clouds.frag` (noise on a layer at 520 m,
drifting with the wind) over them. The layer itself is in
`src/shaders/clouds.glsl`, which the ground, grass, plant and water shaders
also include: each looks up toward the sun through the same noise to shade
itself. Rain and snow are 12,000 quads in a box
that follows the camera, moved entirely in `precip.vert`. They blow
downwind and gust with the wind (rain slants hard in a storm, snow drifts),
and streaks lean only a little as you walk. Each frame adds the distance
fallen at the current speed, from 9 m/s for rain to 1.2 m/s for snow.
Nine speed bands vary individual drops by up to 20%. Drops fade at the
top and bottom of the box as they recycle. `RAIN-PUSH` and `SNOW-PUSH` in
`src/world_game.sld` set how far the wind pushes them. The weather model
and its rates are in `src/world_weather.sld`; how weather changes the light is
in `scene-at` in `src/world_game.sld`.

## Wildlife

Fireflies blink low over grassland from dusk until a couple of hours past
midnight, and stay down in rain, snow and strong wind. Bats flit overhead in
the twilight after sunset and before sunrise. By day small flocks of birds
circle high up, flapping and gliding, fewer under heavy cloud and none in a
storm. `life-amounts` in `src/world_life.sld` decides how many of each are
out. They're one mesh that follows the camera, moved entirely in
`life.vert`; fireflies hover over a coarse grid of ground heights around the
player, sampled a few rows a frame as you move.

## Sound

Seven seamless ambient loops play all the time, each faded (over a few
seconds) toward a volume set by what's around you:

- **Wind**: a low rush always, gusting and whistling as the wind picks up
- **Rain**: hiss and patter with the rain (snow falls silently)
- **Birds**: songbirds by day in dry weather, loudest at the dawn chorus,
  most in grassland, few in the desert or snow, and fewer in forest
- **Crickets**: on dry nights, except in the snow; quiet when it's windy and
  fewer in forest
- **Woods**: in forest by day, thrushes and the odd woodpecker drumming, in
  a long echo
- **Water**: waves lapping when there's water within about 55 m, louder
  nearer and in the wind. The terrain is checked at points on three rings
  around you, one point a frame. By a river it mostly gives way to:
- **River**: running water, a soft rush under a babble of bubbles, within
  about 45 m of a river (`RIVER-EARSHOT`); dry washes are silent

Owls aren't a loop: in forest on still, dry nights an owl now and then calls
once, "hoo … hoo", near or far, about every three minutes at most
(`OWL-EVERY`), and never over another call.

How wooded it is around you (`forest-here`) is the forest density where you
stand and 12 m off each way, worked out again every few meters.

Footsteps follow the ground underfoot (grass, dirt, sand and forest floor,
rock, snow, shallow water), with four variations of each; strides quicken and land harder
the faster you go.

Deeper in a cave, the outdoor loops, owl calls and thunder fade to silence.
Rock steps and shallow splashes ring in the cave's room underground. Single
drips play with pauses between them, closer and more frequent near pools.

The loops and footsteps are synthesized by `tools/make_sounds.py`; `cave`
alone remakes the cave sounds. The cave steps are the outdoor rock and
shallow-water steps run through one cave room (`cave_space`): a few
reflections at irregular times, then a smooth tail that darkens as it dies.
Evenly spaced echoes were tried first and rattle, so the room never repeats
a copy of the sound. A drip is one drop: a low, round bloop (a 380–800 Hz bubble
that starts a little low and swoops up as it rings), sometimes a smaller
droplet landing after. Drips get a lighter room than the steps, so they
don't smear into noise.
`tests/test_sounds.scm` checks the files the game loads are there.
`(sounds)` in the REPL shows the current outdoor loop volumes.

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

## Rivers, canyons and cliffs

One carver in `src/world_terrain.sld` cuts every channel. A channel's line
is where a slow, warped noise crosses 0.5; those lines wind on for
kilometres, so a river reaches the sea or low ground rather than stopping.
What the cut looks like depends on the land it goes through:

- **Low ground**: a wide valley with a river along it. The bed dips just
  below sea level, so the sea's own water fills it, about thigh deep in the
  middle (`RIVER-DEPTH`), so every river can be waded.
- **Higher ground** (`CANYON-RISE`, 8 to 16 m above the sea): the same cut
  drops over a meter or two instead, a canyon with sheer walls, a sandy
  floor and the river down the middle. In every biome, exposed beds can
  form walkable shelves partway up a tall face. The shelf widens and
  tapers along the bank as the upper wall retreats.
- **Desert and dry grassland**: the bed stays above water as a dry wash.

Cliff country, rarer (about a tenth of the land, `CLIFF-REGIONS`), turns
hills, and flat desert as mesas, into sheer steps of 6 m (`CLIFF-STEP`) with
level ground between: escarpments and buttes. The steps go on before the
carve, so rivers cut through them and stay wet.

Across both escarpments and canyon walls, slabs project along the face and
fallen rock gathers below. A broad ledge can hold an oak, juniper, mesquite
or conifer according to the local biome, elevation and tree line.

Steep rock shows its strata in `terrain.frag`: bands by height, grey-brown
in most places and red and buff like sandstone in dry country. The shader
breaks the beds with vertical joints and uses the triangle's slope to keep
sand off near-vertical faces at the rim and the waterline.

You can walk up anything up to about 63 degrees (`MAX-CLIMB` in
`src/world_game.sld`), which takes in even the steepest ordinary hillsides,
but not cliffs or canyon walls: you slide along their foot instead. Walk off
a rim and you fall (`GRAVITY`) to the ground below.

The slow channel and cliff noises are sampled on an 8 m lattice
(`FEATURE-STEP`) and blended, the same way for chunks and for
`terrain-height`, so the ground you walk on matches the mesh.

The heightfield keeps its 1 m grid for generation and placement. For drawing,
edges touching steep ground and its shoulders (normal y below 0.85) gain
half-meter samples of the actual height field. Neighboring chunks make the
same edge decisions;
triangles beside a refined edge split too, keeping the surface closed.
`terrain-surface-data` builds this optional render mesh on the chunk worker,
including the untouched heightfield around caves. Additional noise is sampled
in a batch. The finer grid reuses the original heights and computes the
land shape only where a new vertex or its normal needs it. Water and plants retain the
original grid. The window requests 4-sample MSAA to soften pixel stair steps
where the graphics driver supports it; restart the game to apply this setting.

The worker packs static drawing meshes for direct upload to Panda. The main
thread resumes its search for missing chunks where it stopped and checks for
distant chunks when the player crosses a chunk boundary. Terrain, plants and
cutout grass draw in the opaque pass.

On the development machine with seed 4242, the median of five warm
`generate-chunk` calls was 106 ms at spawn, 96 ms in canyon chunk
`(-46, -58)` and 1.12 s in formation-heavy cave chunk `(-14, 10)`.
The same high-detail meshes previously took 144 ms, 147 ms and 1.49 s.
These are worker CPU times including plants, with pacing sleeps disabled.

## Caves

Caves open where a canyon wall or an escarpment rises sheer from the
ground. The world is split into 160 m sites (`SITE` in
`src/world_caves.sld`); each looks along a few rays for a wall rising 6 m
within two meters (`WALL-RISE`). The search checks the ground 6 m out
from the entrance so a shelf above a sheer drop doesn't qualify as an
approach. Most sites that find a wall get a cave (`SITE-CHANCE`). Each cave
is one of three sizes, picked at random:

- **Small**: a short burrow of two or three bends ending in a small chamber.
- **Medium**: a longer tunnel with up to three chambers and maybe a side
  passage.
- **Large**: a long winding tunnel, several chambers, side passages, and a
  passage that reaches for the nearest other cave, which becomes a second way out.

Tunnels wind like an ant colony's: they wander left and right, climb and
drop (up to `SLOPE` per meter) on mostly flat floors (`FLOOR-DROP`), and
pass over and under one another.
Where one would run into another it meets it at the same floor, so every
junction can be walked. They keep `ROOF` meters of rock overhead, thinning
out toward a mouth, and stay above the sea. Chambers have flatter floors.

Dripstone grows in patches. Stalactites range from fine points to fluted
curtains with several tips. Stalagmites can form squat, terraced mounds or
tall spires. Where a floor and ceiling join, columns flare at both ends.
The generator measures each opening separately, including stacked tunnels,
and reserves headroom along the passage centerline. The formations pick
up the surrounding rock grain and the player's flashlight beam. You can
walk around stalagmites and columns.

Dripstone uses 12 to 34 sides according to its width and height: slender tips
need fewer than broad, fluted roots. Its 12 vertical intervals gather toward
the ends to round tips and roots; terraced mounds use 28 intervals and keep
five rounded terraces.
Lighting normals follow the generated triangles, including their flutes,
bends and terraces.

Some chambers collect a shallow pool in a depression in the rock floor.
A chamber gets one seeded chance in roughly five. The water level sits
below the surrounding floor and the banks shape its shoreline. The rock
darkens where it gets wet around the pool, like sand at an outdoor shoreline.
One or more ceiling tips hang over the water, where a small ripple spreads
from the drip.

A cave is a distance field: tubes and chambers blended smoothly and roughened
by 3D noise (`ROUGH`). In chunks a cave reaches, surface nets on a 1 m grid
build one continuous surface for the ground, the opening and the cave inside.
This mesh replaces the chunk's heightfield mesh and uses the same terrain
shader. Ground away from the cave keeps the heightfield's vertices so it
meets neighbouring chunks. The original heightfield is kept for placing
plants and grass above ground.

Nothing grows in front of a mouth: no trees, plants or rocks within
`PLANT-CLEARING` meters and no grass clumps within `GRASS-CLEARING`
(`src/world_game.sld`). The work runs on the chunk worker like the rest of the
terrain. Dense formations make cave chunks more expensive to generate.

Daylight reaches about 2 m in from a mouth and is gone by 20 m (`DARK`).
The flashlight comes on as that daylight fades: a bright spot with dimmer
spill across the surrounding rock. Outside both beams the cave stays dark.
The fog closes in dark,
rain and snow stop, and the sound of steps and occasional drips carries
through the chamber.

Walking follows the same solid field used to build the mesh, putting your
feet on the cave floor. Walls and ceilings stop you like cliffs do: you
can't climb a tunnel's side or stand where your head would hit the rock.

`tests/test_caves.scm` (part of `tests/run.scm`) checks eight caves of world
seed 4242 for holes, repeated edges, reversed faces, and walking through
mouths and along the main tunnels; mouths above the sea, daylight and open sky
in front of them, dark and shelter at the end of the main tunnel, the plant
clearing kept, and no cave floor away from caves. It also covers the cliff
mouth at site `(0, 4)` and a cave opening exactly on the terrain surface,
where a thin sheet of rock must not appear. Surface-net
cells keep separate vertices for disconnected surface patches, and mouths
blend smoothly into the ground; both prevent folded rock at an entrance.

## Forests

Forest isn't a biome of its own: woods grow in grassland and the snow where
a slow grove noise is high, from open meadow to forest. Moisture (the same
field that picks biomes) decides what kind: on ordinary ground they're open
groves, and on wet ground (`WET`) they're bigger, run together and grow
denser, so the wettest grassland and snow are deep, dark forest. The stand
density, `woods` in `src/world_terrain.sld` (`GROVES`, `GROVE-FREQUENCY`,
`WET-GROVES`, `DRY-WOODS`, and none above the tree line or by the sea), is
worked out per terrain vertex and carried in the chunk's vertex colour alpha,
so trees, the ground, the grass and sound all agree.

The denser the woods, the more the floor changes:

- **Ground**: the grass gives way to fallen leaves with mossy patches
  (`src/shaders/terrain.frag`).
- **Grass**: thins to `FOREST-GRASS` of its share, and ferns grow in patches
  instead (`FOREST-FLOOR`, `FERN-CHANCE`, `FERNS`).
- **Undergrowth**: bushes, fallen logs lying across the slope and mossy
  stumps (`make-bush`, `make-log`, `make-stump` and `UNDERGROWTH-...` in
  `src/world_plants.sld`). You can't walk through stumps.
- **Sound**: woodland birds by day and owls at night (see Sound).

`(forest-density x z)` in the REPL shows how wooded a spot is, 0 to 1.

## Grass clumps

Grassland and dry grassland grow clumps of grass in four kinds: short tufts,
tall grass with seed heads, tufts with flowers, and dry golden tufts (plus
the wildflowers, below, and ferns on the forest floor). They
grow in meadows with bare ground between, and never on beaches, steep slopes,
the rock band, desert or snow. Clumps are only made for chunks within two of
the player's chunk, and sink into the ground near the edge of that range.

The knobs are in the grass clumps section of `src/world_terrain.sld`:
`GRASS-SPACING` (density), `GRASS-CHANCE`/`DRY-GRASS-CHANCE`, `MEADOW` and
`MEADOW-FREQUENCY` (patch size), `SPRITE-HEIGHTS` and `SPRITE-TINTS`.
`GRASS-RADIUS` and `GRASS-FADE` are in `src/world_game.sld`, and wind is in
`src/shaders/grass.vert`. Saving the terrain file regrows the grass along
with the chunks.

## Wildflowers

Drifts of wildflowers grow among the grass: daisies (white or yellow), tall
spikes like lupine (purple, blue, pink) and poppies (orange, red, yellow),
poppies most in dry grassland. Each kind has bloom spells a couple of days
long that come and go on their own (daisies are seldom all gone), so the
meadows change from one day to the next. Out in the desert, low annuals
(yellow, orange, magenta) come up half a day or so after a storm and fade
over the next couple of days.

They're clumps in the grass mesh (sprites 4 to 7 of `grass_clumps.png`):
each clump has its own bloom threshold, so a drift fills in gradually, and
the grass shader sinks clumps whose kind isn't far enough into bloom and
colors their petals from the kind's palette. Bloom levels come from `blooms`
in `src/world_weather.sld`; placement knobs (`FLOWERS`, `FLOWER-CHANCE`,
`DESERT-FLOWER-CHANCE`, ...) are in the grass clumps section of
`src/world_terrain.sld`. `(wildflowers)` in the REPL shows the bloom, and
`(set-blooms! '(1 1 1 1))` forces it (`#f` undoes).

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
(`TREE-SPACING`). Grassland grows oaks wherever there are woods (see
Forests); going up the mountains conifers take over (`MOUNTAIN-PINES`) until
the tree line (`TREE-LINE`), and the snowy biome's woods are conifers,
narrow dark spruces and broader pines with bare trunks below head height. Dry grassland has scattered junipers and the desert the
odd low, spreading mesquite. `FOREST-CHANCE`, `JUNIPER-CHANCE` and
`MESQUITE-CHANCE` set how many.

Conifers are built by `make-conifer`, tiers of ragged, drooping needle
skirts. Oaks, junipers and mesquite share `make-broadleaf`: trunks under a
crown of overlapping leaf clumps with limbs reaching out to them, and the
`OAK`, `JUNIPER` and `MESQUITE` forms set their proportions. In
`plant.frag` bark gets furrows and needles tufts; leaf clumps are lit
cartoon-style in flat bands of shade, half light and light, their edges
ragged leaf by leaf, with each clump's underside darkening into the gap
beneath (`CLUMP-RINGS`, `CLUMP-STEPS` and `CROWN-ROUNDING` in
`src/world_plants.sld` shape the clumps). Fresh snow settles on the tops of branches; `plant.vert` sways
trees in the wind. You can't walk through trunks: each chunk keeps its
trees' positions for `keep-out-of-trunks!` in `src/world_game.sld`.

## Rocks

Rocks are built by `make-rock` in `src/world_plants.sld`, lumpy shapes
chipped flat by a few random planes and half-buried: grey boulders, crags
and slabs, and warm sandstone in desert and dry grassland. They come in
groups, more on steep slopes, at the waterline, on high ground and in the
odd boulder field; `ROCK-CHANCE`, `FIELD-ROCK-CHANCE`, `SLOPE-ROCK-CHANCE`,
`SHORE-ROCK-CHANCE`, `HIGH-ROCK-CHANCE` and `GROUPS` set how many.
`plant.frag` gives them mottling, granite flecks or sandstone layers,
lichen on top, snow, and a dark wet sheen in rain. Big boulders block the
player like trunks.

Rock templates use 16 vertical intervals and 32 sides, retaining their cut
planes while rounding their silhouettes. Tests bound the longest visible
edges of rocks and dripstone relative to each connected object's size.

Errors are printed without stopping the game; fix the file and save to recover.
`src/world_state.sld` and `main.py` need a restart to change.
