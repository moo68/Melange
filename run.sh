#!/usr/bin/env bash
# Build and run Melange from the project root.
#
# Usage:
#   ./run.sh              debug build + run
#   ./run.sh release      optimized build + run
#   ./run.sh check        type-check only (no binary)
#   ./run.sh test         run tests in tests/
#   ./run.sh build        debug build, don't run
#   ./run.sh profile      release build with Spall profiling + run; writes build/trace.spall
#   ./run.sh terrain-preview [--seed N] [--out DIR]
#                         render the terrain to build/terrain-preview/*.png + stats
#   Extra args after the mode are passed to the game, e.g. ./run.sh debug --seed 42
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"   # assets are loaded relative to the project root

MODE="${1:-debug}"
[[ $# -gt 0 ]] && shift

OUT="build/melange"
# raylib is vendored in third_party/raylib (Odin bindings + raylib 6.0
# libraylib.a) and linked statically, so system raylib/odin updates can't break it.
COMMON=(
    -collection:melange=src
    -collection:third_party=third_party
    -vet -strict-style
)
RAYLIB=(-define:RAYLIB_SHARED=false)  # only for targets that import raylib

mkdir -p build

if ! ls src/*.odin >/dev/null 2>&1; then
    echo "run.sh: no .odin files in src/ yet — nothing to build." >&2
    exit 1
fi

case "$MODE" in
    debug|build)
        odin build src -out:"$OUT" -debug "${COMMON[@]}" "${RAYLIB[@]}"
        [[ "$MODE" == build ]] && exit 0
        ;;
    release)
        odin build src -out:"$OUT" -o:speed -no-bounds-check "${COMMON[@]}" "${RAYLIB[@]}"
        ;;
    profile)
        # Same optimizations as release, plus melange:prof compiled in.
        OUT="build/melange-profile"
        odin build src -out:"$OUT" -o:speed -no-bounds-check -define:PROFILE=true "${COMMON[@]}" "${RAYLIB[@]}"
        ;;
    check)
        odin check src "${COMMON[@]}" "${RAYLIB[@]}"
        odin check src -define:PROFILE=true "${COMMON[@]}" "${RAYLIB[@]}"
        odin check tools/terrainviz "${COMMON[@]}" "${RAYLIB[@]}"
        exit 0
        ;;
    test)
        odin test tests -all-packages -out:build/tests "${COMMON[@]}"
        # melange:prof with profiling compiled in (tests/prof isn't imported by tests/).
        odin test tests/prof -out:build/tests-prof -define:PROFILE=true "${COMMON[@]}"
        exit 0
        ;;
    terrain-preview)
        odin build tools/terrainviz -out:build/terrainviz -o:speed "${COMMON[@]}" "${RAYLIB[@]}"
        exec ./build/terrainviz "$@"
        ;;
    *)
        echo "run.sh: unknown mode '$MODE' (use debug|release|profile|build|check|test|terrain-preview)" >&2
        exit 1
        ;;
esac

exec "./$OUT" "$@"
