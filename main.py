"""Launcher for the Scheme game (same shape as ../hy-app/main.py).

1. Put `.scheme-build/` on `sys.path` so generated modules are importable.
2. Transpile the hissp-scheme core libraries plus the app `.sld` files.
3. Evaluate `src/main.scm` as the entrypoint, or the `.scm` file given
   first on the command line (`uv run main.py tests/test_caves.scm`).

All game logic lives in Scheme under `src/`.
"""

from __future__ import annotations

import sys
from pathlib import Path

import hissp.repl

from hissp_scheme import core_library_files
from hissp_scheme.reader import SchemeLissp, transpile_scheme_file

PROJECT_ROOT = Path(__file__).resolve().parent
SRC_DIR = PROJECT_ROOT / "src"
BUILD_DIR = PROJECT_ROOT / ".scheme-build"

SCHEME_ENTRYPOINT = SRC_DIR / "main.scm"

# App libraries, in dependency order.
APP_SCHEME_LIBRARIES = (
    SRC_DIR / "world_state.sld",  # never hot-reloaded; keeps state across reloads
    SRC_DIR / "world_terrain.sld",
    SRC_DIR / "world_caves.sld",
    SRC_DIR / "world_plants.sld",
    SRC_DIR / "world_weather.sld",
    SRC_DIR / "world_life.sld",
    SRC_DIR / "world_game.sld",
)


def main():
    build_dir = str(BUILD_DIR)
    if build_dir not in sys.path:
        sys.path.insert(0, build_dir)

    for module in (*core_library_files(), *APP_SCHEME_LIBRARIES):
        transpile_scheme_file(module, output_dir=BUILD_DIR)

    args = sys.argv[1:]
    entrypoint = SCHEME_ENTRYPOINT
    if args and args[0].endswith(".scm"):
        entrypoint = Path(args.pop(0)).resolve()

    main_module = hissp.repl.force_main()
    main_module.__dict__.setdefault("__file__", str(entrypoint))
    sys.argv = [str(entrypoint), *args]

    SchemeLissp(
        env=main_module.__dict__, evaluate=True, filename=str(entrypoint)
    ).compile(entrypoint.read_text(encoding="utf8"))


if __name__ == "__main__":
    main()
