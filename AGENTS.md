# Agents working on this repo

A 3D world written in R7RS Scheme on [hissp-scheme](https://github.com/vidjuheffex/hissp-scheme),
drawn with Ursina/Panda3D. The README describes every system; read the
section for what you're touching before changing it.

## Scheme only

- Game logic, tests and tools for the game are Scheme (`src/*.sld`, `src/main.scm`,
  `tests/*.scm`). Do not write Python to get around Scheme: no Python test
  harnesses, no logic in Python files, no Python strings evaluated from Scheme.
- The only Python is `main.py` (the launcher) and the one-off asset generators in
  `tools/`. Change `main.py` only for launching; ask before adding Python anywhere.
- `(scheme python)` and imports of Python modules are for reaching the engine
  (Ursina, Panda3D) and the standard library, not for writing logic in Python.
- Throwaway scripts used to investigate (screenshots, probes) stay out of the
  repo. If a check is worth keeping, it's a SRFI 64 test.

## Test first, with SRFI 64

- New features and bug fixes start with a failing test in `tests/test_<library>.scm`
  that states the behavior, then the code that makes it pass. A bug fix's test
  fails without the fix.
- Test what the code promises (its comments, the README), not its internals.
  Export a procedure for testing only when there's no other way to reach it.
- A new suite is added to the `include` list in `tests/run.scm`. Suites are R7RS
  programs: imports first, then `(include "helpers.scm")`.
- Tests use world seed 4242 so results repeat. Generation must be deterministic
  for a seed.
- Never weaken, skip, delete or loosen a test, its thresholds or what it counts,
  to get a pass. If a test is wrong, say why and ask first. Small failures are
  not noise: "a few flipped triangles" turned out to be a real mesher bug.
- Check a new test can fail: break the code briefly, see it fail, restore it.

## hissp-scheme bugs: surface them

- When hissp-scheme doesn't do what R7RS or the SRFI says, stop and report it:
  a minimal `.scm` that reproduces it, what R7RS expects, what happens. Don't
  quietly work around it.
- Check the standard first. Code that isn't valid R7RS (say, an `include`
  before a program's imports) failing isn't a bug.
- If you can't continue without a workaround, ask. If one goes in, keep it
  small, comment it with the issue it waits on, and mention it in your summary
  so it's removed when hissp-scheme is fixed.
- Upgrading hissp-scheme: `uv lock --upgrade-package hissp-scheme`, `uv sync`,
  `rm -rf .scheme-build`, then run the tests. Remove workarounds the upgrade fixes.

## Finishing a task

1. Run every suite: `uv run main.py tests/run.scm` (about a minute and a half).
   It must exit 0. Report the pass and fail counts.
2. If the change is visible, show it: screenshots of the same view before
   and after, in the game's own renderer.
3. Update the README section for what changed (systems, REPL helpers, constants).
4. Say plainly what isn't done, what you couldn't check, and any workaround added.

Don't call a task done with failing tests, and don't commit or push unless asked.

## Things that bite

- Chunks are generated on a worker thread (SRFI 18). No shared mutable state
  between the worker and the main thread outside `(world state)` and its lock.
- Libraries hot-reload on save, re-running their top-level forms; anything
  that must survive lives in `(world state)`, which never reloads.
- hissp-scheme compiles to Python: Scheme names are munged (`cave-ground`
  becomes `caveQzH_ground`), `vector` is a Python list, and a local named after
  a procedure (`floor`, `list`) shadows it inside its scope.
- Chunk generation has a budget: plain chunks build in about 30 ms, cave chunks
  in about 200 ms. Don't slow them noticeably without saying so.
- Comments state constraints the code can't show, in the README's plain style.
  Match the surrounding code.
- `handoff/` is gitignored scratch space for handoff notes and images.
