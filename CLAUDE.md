# Melange

A Minecraft-style voxel engine written in **Odin** using **Raylib** 6.0 (vendored as `third_party:raylib`).

## Build & run

Always build from the project root via `run.sh`:

| Command              | What it does                                   |
|----------------------|------------------------------------------------|
| `./run.sh`           | Debug build to `build/melange`, then run it    |
| `./run.sh release`   | Optimized build (`-o:speed -no-bounds-check`) + run |
| `./run.sh build`     | Debug build only                               |
| `./run.sh profile`   | Release build with Spall profiling (`build/melange-profile`) + run; writes `build/trace.spall` |
| `./run.sh check`     | Type-check only (both normal and `PROFILE=true` builds) — use this after every edit |
| `./run.sh test`      | Run `odin test` on `tests/`, then `tests/prof/` with `-define:PROFILE=true` |
| `./run.sh terrain-preview [--seed N] [--out DIR]` | Render the terrain to `build/terrain-preview/{map,profile}.png` + print stats (no window) |

Args after the mode go to the game: `./run.sh debug --seed 42`. Game args: `--seed N`, `--frames N` (quit cleanly after N frames — for repeatable profiling runs).

- All builds use `-vet -strict-style`; code must pass both (no unused vars/imports, Odin's brace/indent style).
- **Raylib is vendored** in `third_party/raylib/`: Odin's raylib bindings plus the official raylib **6.0** `linux/libraylib.a`, linked statically (`-define:RAYLIB_SHARED=false`). Import it as `import rl "third_party:raylib"` — **never `vendor:raylib`**; the system Odin's copy is broken (Arch's package symlinks to a raylib 6.0 .so that pacman replaced with 6.2). If upgrading raylib, replace the bindings and `libraylib.a` together so versions match.
- The working directory at runtime is the project root, so load assets with paths like `assets/shaders/chunk.vs`.

## Layout

```
src/            package main — entry point, game loop, top-level state
src/world/      chunks, block types/registry, world storage, terrain generation
src/mesh/       chunk meshing (face culling, later greedy meshing), vertex data
src/render/     camera, shaders, texture atlas, draw calls, debug overlay
src/player/     input, movement, physics/collision against voxels, block picking
src/geom/       pure math, no raylib (frustum, AABB; later ray/voxel DDA) — testable without linking raylib
src/prof/       Spall profiling scopes (leaf; compiled out unless -define:PROFILE=true)
assets/shaders/ GLSL shaders (GLSL 330 — raylib's default desktop GL)
assets/textures/ block texture atlas and other images
tests/          odin test package(s); tests/prof/ is built separately with PROFILE=true
tools/          dev tools, each its own package (tools/terrainviz: terrain preview)
third_party/    vendored dependencies (raylib bindings + static lib); don't edit
build/          build output (gitignored)
```

Each `src/` subdirectory is its own Odin package. Import them through the `melange` collection, e.g. `import "melange:world"`. Keep dependencies one-directional: `main → player, render → mesh → world`; `geom` and `prof` are leaves any package may import. Tests don't link raylib, so code that needs tests must not live in a package that imports raylib. `world` must not import raylib rendering code (math types like `[3]f32` are fine).

## Working style

The user wants to build this **one step at a time**: for a new feature, explain the plan and tradeoffs (with a recommendation, and numbers when relevant) and wait for agreement before writing code; then implement only that step, with tests, and stop for review. Don't bundle roadmap items. Verify with tests (plus mutation checks for new tests), `./run.sh check`/`build`, a short run checking raylib's log, and offscreen renders (e.g. `./run.sh terrain-preview`) — don't capture the user's screen; ask them to check visuals. Update this file as decisions are made.

## Status & roadmap (as of 2026-11-22)

- **Done — phase 1:** chunk meshing with face culling (in-chunk and inter-chunk), fly camera.
- **Done — phase 2:** regions + world storage, streaming, frustum culling, noise terrain (plains + mountains), per-column height cache, quick perf wins.
- **Done — phase 3:** texture atlas (seamless, `texelFetch`), chunk shader, fog, ambient occlusion.
- **Done — Spall profiling** (see "Profiling" below).
- **Next — phase 4 (on hold until the user says go):**
  1. Block picking: voxel DDA raycast (Amanatides–Woo) in `geom` → hit block + face; outline the targeted block.
  2. Break (left click → AIR) / place (right click, against the hit face) via `world_set_block` (exercises the 26-neighbor dirty marking).
  3. Walking physics in `player/`: AABB player, gravity, jump, per-axis swept collision; key to toggle back to fly mode.
- **Later:** phase 5 worker threads for gen/meshing (not needed yet per measurements); phase 6 compact `rlgl` vertex format, light propagation, water/transparent pass, greedy/bitmask meshing.
- **Planned, on hold (discussed, not built):**
  - **Terrain tuning interface:** turn the `TERRAIN_*` constants into a params struct that `tools/terrainviz` can override from the command line, later maybe a live in-game panel.

## Controls (debug build)

Mouse look; WASD move (horizontal); Space / Left Ctrl up / down; Shift = 5× sprint; F1 wireframe; F2 freeze frustum culling; Esc quit. `--frames N` quits after N frames. Mouse look ignores the first 2 frames after cursor capture (raylib reports a bogus jump). The overlay shows FPS, position, seed, chunk/draw/cull counts, streaming queues and per-chunk gen/mesh times.

## Engine design notes

- **Coordinates:** Y is up. World block coords are `[3]i32`; chunk coords are block coords floor-divided by chunk size (careful with negatives — use floor division, not `/`).
- **Chunks:** cubic, 16×16×16 (`CHUNK_SIZE :: 16`). Chunk coords are `[3]i32` (the world is chunked vertically too). Block data within a chunk is **always** a single flat, fixed-size array (`[CHUNK_SIZE*CHUNK_SIZE*CHUNK_SIZE]Block_ID`) for cache locality — no nested arrays, per-block pointers, maps, or sparse structures inside a chunk. `Block_ID :: distinct u16` (8 KB per chunk). Index `x + z*CHUNK_SIZE + y*CHUNK_SIZE*CHUNK_SIZE`. Since 16 is a power of two, block→chunk coord is `b >> 4` and local coord is `b & 15` (correct for negatives on `i32`).
- **Why 16³ (not 32³):** it's the largest power-of-two chunk whose worst case (3D checkerboard: 3·16³ = 12,288 faces × 4 = 49,152 vertices) fits raylib's `u16` mesh indices, so every chunk is one indexed `Mesh`. Also 8× cheaper remesh on edits and finer culling. Cost: ~5× more draw calls — keep them down by never drawing empty/buried chunks and by frustum culling. Target: runs well on weak hardware.
- **Regions:** chunks are stored in 8×8×8-chunk regions (`REGION_SIZE :: 8`, 128³ blocks, 4 MB reserved each) held in `World.regions: map[[3]i32]^Region` keyed by region coord (`chunk >> 3`, local `chunk & 7`, slot index `x + z*8 + y*64`). Neighbor chunks in the same region are found by index; only cross-region neighbors hit the map. `Chunk` is only its block array (exactly 8 KB = 2 pages); per-chunk metadata (`loaded`, `dirty`) lives in parallel arrays in `Region`.

### Region memory rules (src/world/region*.odin)

RAM follows writes, not the 4 MB reservation: region memory is anonymous `mmap`, zero-filled by the OS, and pages only get RAM when written.
- Allocate with `virtual.reserve_and_commit`, then `madvise(NOHUGEPAGE)` before touching it (this machine has THP=`always`; without it one write costs 2 MB — `tests/region_memory_test.odin` catches this). Never use `virtual.reserve` alone (PROT_NONE → reads segfault).
- Unload a chunk with `madvise(DONTNEED)` (guaranteed zero on next read). **Never `virtual.decommit`** — it uses `MADV_FREE`, which can resurrect stale blocks in a reused slot.
- `AIR == 0` is `#assert`ed: untouched memory reads as air. Writing air is always *correct*; skipping it only saves RAM. `world_set_block` with the current value writes nothing.
- Whether a chunk exists is decided only by `world_get_chunk` (nil = not loaded), never by its block data — unloaded slots still read as air.
- `^Chunk` / `Neighbors` are valid only for the current pass. Never keep them across frames: unloading a region's last chunk unmaps it.
- `world_create_chunk` / `world_unload_chunk` mark all 26 loaded surrounding chunks dirty (their meshes read this chunk's border for culling and AO); `world_set_block` marks its chunk plus every chunk whose 1-block border contains the block (1 on a face, 3 on an edge, 7 on a corner). Fill a newly created chunk (e.g. terrain gen via `chunk_set`) before the next mesh pass. Revisit when generation moves to threads.

- **Terrain** (`world/terrain.odin`): `height = BASE + plains + mask * mountains`, all 2D OpenSimplex2 (`core:math/noise`), each layer with its own seed offset:
  - **plains:** 5-octave fBm, scale 220, ±7 blocks → gently rolling (every plains step is 0–1 blocks; tested).
  - **mask:** 2-octave fBm at scale 900 through `smoothstep(0.25, 0.50)` → 0 on ~70% of the world, ramping to 1 in occasional mountain regions (the ramp = foothills). `terrain_mountain_mask` is public for tests/tools.
  - **mountains:** a broad "massif" fBm (scale 200) *stretched* from its actually-used range [-0.15, 0.55] to [0, 1] and raised to 1.7 (flat valley floors, pointed peaks), roughened by ridged fBm (`(1-|n|)²`, scale 90, strength 0.45), × 95 blocks. Lessons from tuning: ridged noise alone makes a maze of thin walls; raising raw fBm to a power without stretching crushes everything flat (fBm rarely nears ±1).
  - Heights clamp to `TERRAIN_MIN/MAX_HEIGHT` (1..110). All knobs are the `TERRAIN_*` constants at the top of the file (a proper tuning interface is planned for later).
  - **Surface material:** a column is **bare stone** if at/above `TERRAIN_STONE_LINE` (Y 34) or it steps ≥ `TERRAIN_CLIFF_STEP` (3) to a horizontal neighbor; otherwise grass + 3 dirt over stone. `column_heights_compute` samples an 18×18 height grid (1-column border) to judge steepness at chunk edges and must agree with the single-column `terrain_column` (tested on a plains and a mountain chunk).
  - `terrain_height`, `terrain_column`, `terrain_mountain_mask` and `generate_chunk(c, coord, seed)` are pure — keep them that way (threading later). Generation never writes air. `World.seed` comes from `--seed N` (default 1337, parsed in `src/args.odin`).
  - **Tuning workflow:** `./run.sh terrain-preview [--seed N]` (`tools/terrainviz`) renders a hill-shaded top-down map (2,560 blocks across) and a 1:1 side profile through the tallest peak to PNGs, and prints area fractions, height percentiles and step histograms. Far quicker than flying around. It uses raylib's CPU image functions, which work without a window. Current output for seed 1337: plains 69.7%, foothills 16.8%, mountains 13.5%, bare stone 5.4%; heights p50 8, p99 63, max 104.
  - **Height cache:** `Column_Heights` holds one chunk column's (cx, cz) classified 16×16 surface plus its `max_height`, computed once by the pure `column_heights_compute` (18×18 samples incl. border). `generate_chunk_from_heights(c, coord, &heights)` is what streaming uses: chunks whose bottom is above the column's `max_height` return instantly (no noise), deep chunks fill with stone, the rest read the shared columns. `generate_chunk(c, coord, seed)` is the uncached convenience (tests), identical output (tested for whole column stacks, plains and mountain). The `Streamer` owns the cache (`heights: map[[2]i32]^Column_Heights`), evicts columns outside `radius + unload_margin`, and clears it if the seed changes.

- **Streaming** (`world/streaming.odin`): `Streamer` keeps chunks loaded in a horizontal circle of `radius` chunks × `vertical` chunks above/below the camera's chunk (defaults 12 / ±8 — ±128 blocks so the tallest peaks (Y 110) are meshed when standing on the plains). Load and unload queues are rebuilt only when the center changes chunk; loads go nearest-first within `load_budget`/frame; unloads happen beyond `radius + unload_margin` (hysteresis, default 2) within `unload_budget`. After `streamer_update`, pass `Streamer.unloaded` to `render.renderer_forget_chunks`.
- **Neighbor rule:** a chunk is meshed only when all 6 neighbors are loaded (`world.neighbors_complete`). Otherwise its dirty flag is cleared and any mesh dropped; `world_create_chunk` re-dirties it when the missing neighbor arrives. So the outermost loaded ring (incl. the top/bottom of the vertical range) is loaded but never meshed, and no faces are ever emitted toward unloaded space. (`mesh.build_chunk_mesh` still treats `nil` neighbors as air, but the renderer never passes one.)
- **Measured cost** (this dev machine, single-threaded, release, default 7,497-chunk streaming area, plains+mountains terrain, 2026-11-22): gen ≈ **28 ms** total with the height cache (441 columns sampled; 135 ms uncached), debug 214 ms. Mesh ≈ 21 ms total (surface ~0.028 ms ≈ 98 ns/face). Upload ≈ 0.04 ms per mesh. Debug meshing is ~16× slower than release.
- **Fast paths** (keep them correct if terrain or block rules change): the streamer skips height computation for chunks above `TERRAIN_MAX_HEIGHT`; generation skips chunks above their column's `max_height` and fills chunks below `TERRAIN_ALL_STONE_BELOW` with stone — this relies on `terrain_height` clamping to `TERRAIN_MIN/MAX_HEIGHT`. `build_chunk_mesh` returns no faces immediately when the chunk and all six neighbors' touching layers are fully opaque.
- **Remaining single-threaded levers:** bitmask ("binary") meshing for surface chunks (the padded 18³ copy and the per-column height cache are done). First Spall trace (2026-11-22, 600 frames from startup, release, seed 1337): frame avg 4.2 ms of which `EndDrawing` (vsync, 240 Hz) 3.7 ms → ~0.5 ms CPU/frame. Steady-state CPU: `collect dirty` ~82 µs **every frame** (`world_collect_dirty` scans all region slots even when nothing is dirty — the cheapest win if needed), `renderer_draw` ~75 µs, `streamer_update` ~10 µs when idle, overlay ~38 µs. Per chunk: mesh 5.4 µs avg (14,786, most empty), upload 20 µs (1,479), gen 1.9 µs, column heights 69 µs.

## Profiling (Spall)

- `src/prof/prof.odin` wraps `core:prof/spall`: `prof.init(path)` / `prof.shutdown()` (main thread; init names it "main"), `prof.thread_init(name)` / `thread_shutdown()` for any other thread (phase 5 workers), `prof.scope("name")` (deferred: ends at block exit), `prof.begin`/`prof.end` where a block doesn't fit (`-strict-style` rejects a bare `{` block right after an `if`). Scopes on a thread without a buffer are ignored.
- `ENABLED :: #config(PROFILE, false)`: off, every proc is empty, so scopes stay in hot code. Manual scopes only — not Odin's auto-instrumentation (would swamp tiny procs).
- Per-thread 1 MB buffer, written to the file when full (visible as "Spall Trace Buffer Flush") and at shutdown. Killing the process (Ctrl+C / SIGTERM) loses the unwritten tail — quit with Esc / window close / `--frames N`. Init spends 200 ms calibrating the TSC.
- Current scopes: `frame`, `EndDrawing` (swap + vsync wait + GPU sync), `streamer_update` › `rebuild queues`, `unload chunk`, `column heights`, `gen chunk`; `renderer_update` › `collect dirty`, `mesh chunk`, `upload`; `renderer_draw`; `debug overlay`. Keep names constant (the viewer aggregates by name).
- View traces at gravitymoth.com/spall/spall-web.html (drag & drop) or the native build (gravitymoth.itch.io/spall). It measures CPU only; GPU time would need GL timer queries.

- **Meshing:** Only emit faces adjacent to transparent/air blocks, including across chunk borders. Re-mesh a chunk (and affected neighbors) when a block changes. Upload with raylib `Mesh` + `UploadMesh`; free with `UnloadMesh` when chunks unload.
- **Meshes are indexed** with raylib's `u16` indices: 4 vertices + 6 indices per face. A chunk's worst case fits (see above), so one chunk = one `Mesh` per pass, never split. Don't grow `CHUNK_SIZE` past 16 without revisiting this. Two meshes per chunk: opaque and transparent. Chunks with no faces get no mesh and no draw call.
- Meshing (CPU, pure: chunk + neighbor borders → vertex arrays) is separate from GPU upload (main thread only).
- **raylib owns `rl.Mesh` CPU arrays**: `UnloadMesh` frees them with raylib's `free()`, so `render.upload` copies `Mesh_Data` into `rl.MemAlloc` buffers. Never put Odin-allocated memory in an `rl.Mesh`. Don't nil `indices` after upload either (`DrawMesh` uses it to choose indexed drawing).
- `render.Renderer` keeps `map[[3]i32]rl.Mesh` (only chunks with faces), re-meshes up to `remesh_budget` dirty chunks per frame via one reused scratch `Mesh_Data`. Call `renderer_forget_chunk` when the world unloads a chunk.
- **Frustum culling:** `render.camera_frustum` builds planes from the camera's geometry (not matrices) using the framebuffer aspect and near/far from `rlgl.GetCullDistanceNear/Far` — don't hard-code near/far; the binding's constants don't match the compiled lib. Each chunk's 16³ AABB is tested before `DrawMesh`. F2 freezes the culling frustum for debugging.
- **Textures:** `assets/textures/atlas.png` is a 256×256 atlas: a 16×16 grid of tightly packed 16×16-px tiles, tile index = `row*16 + col` (0 = top-left, 255 = bottom-right = magenta "undefined"). Current tiles: 0 dirt, 1 grass side, 2 grass top, 3 stone. `world.BLOCK_TILES` maps each block's faces to tiles (`world.Tile`); unknown IDs get `TILE_UNDEFINED`.
  - **No atlas UVs on the CPU.** Each vertex carries its position *within* the tile (`Mesh_Data.texcoords`, exactly 0 or 1 → raylib `texcoords`) and the tile's (column, row) (`Mesh_Data.tiles` via `mesh.tile_coords` → raylib `texcoords2` → `vertexTexCoord2`). The fragment shader computes the exact texel `tile*16 + clamp(floor(uv*16), 0, 15)` and reads it with `texelFetch`, so every face shows exactly its full 16×16 texture and can never sample a neighboring tile. No UV inset (the old half-texel inset cropped half a texel off every edge and broke seamless tiling).
  - History: MSAA extrapolating UVs outside a face caused thin lines at block edges up close and sky-blue speckles far away / at grazing angles (confirmed with a red clear color). `centroid` + texel clamping + alpha = 1 fix all of it; keep them.
  - Point sampling via `texelFetch` (no filtering, no mipmaps). Mipmaps would need texture arrays (a per-tile mip chain); revisit if distant shimmer bothers us.
  - The renderer owns the atlas texture; it resets the material's albedo map to raylib's default texture before `UnloadMaterial` (which would otherwise unload the atlas too), then unloads the atlas once.
  - Vertex color = per-direction shade × AO brightness, multiplied with the texture in the shader.
- **Chunk shader** (`assets/shaders/chunk.vs/.fs`, GLSL 330): uses raylib's default attribute/uniform names (`vertexPosition`, `vertexTexCoord`, `vertexColor`, `mvp`, `matModel`, `texture0`) so `LoadShader`/`DrawMesh` bind them automatically. Output = atlas texel (`texelFetch`, see Textures) × vertex shade, then fog. `centroid` on the in-tile UV, `flat` on the tile, and `alpha = 1` are deliberate.
  - `renderer_init` returns `Init_Error` (`.Atlas` / `.Shader`). raylib silently falls back to its default shader when a shader file is missing or fails to compile, so the init checks `shader.id != rlgl.GetShaderIdDefault()`.
  - The material's original (default) shader is saved and restored before `UnloadMaterial`, which would otherwise unload our shader too; the Renderer unloads its shader and atlas exactly once.
- **Fog:** horizontal (xz) distance from the camera, matching the streaming circle; fades into `render.SKY_COLOR` (also the clear color). `fogEnd = world.stream_meshed_distance(cfg)` = `(radius - 1 - √2) * 16` (153 blocks at radius 12): the distance within which every block's chunk is guaranteed meshed wherever the camera is in its chunk (brute-force tested). `fogStart = 0.55 * fogEnd`. Never set fogEnd beyond that or the world edge / chunk pop-in shows.
- **Meshing input:** `mesh.build_chunk_mesh_neighborhood(&world.Neighborhood, out)` takes the chunk and all 26 surrounding chunks (`world_get_neighborhood`, index via `neighborhood_index(offset)`). It copies opacity into an 18³ padded grid (`mesh.Padded`, chunk + 1-block border) so culling and AO read fixed offsets with no border branches. `build_chunk_mesh(chunk, &faces, out)` is a test convenience (edge/corner neighbors = air). The renderer still only requires the 6 face neighbors; a missing edge/corner chunk only brightens AO at that corner until it loads (which re-dirties this chunk).
- **Ambient occlusion** (0fps.net method): per face vertex, the two side blocks and the diagonal corner block on the face's open side give `ao = 0 if both sides solid else 3 - (s1 + s2 + corner)`; vertex brightness = `FACE_SHADE[face] * AO_BRIGHTNESS[ao]` ({0.45, 0.65, 0.82, 1.0}) in the vertex color. Each quad is split along the diagonal with the darker AO sum (flip when `ao0 + ao2 > ao1 + ao3`), else AO shows as diagonal streaks; both splits stay CCW (tested). Costs ~+25% per surface chunk (0.026 ms, ~103 ns/face).
- **Rendering:** light propagation (sky/block light) would also go into the vertex color.
- **Performance:** Avoid per-frame allocations in the hot path. Use explicit allocators; free chunk data and meshes on unload. Generation/meshing may move to worker threads later — keep those functions free of global mutable state.

- **No ECS.** World state is plain structs (`World`, `Renderer`, `Player`) owned by `main` and passed to procs. If mobs/items arrive, use a plain `[dynamic]Entity`.

## Deferred (do NOT implement until the core is solid)

- Uniform chunks: an all-one-block chunk (e.g. solid stone underground) stores a single ID instead of using its block pages. All-air chunks already cost no RAM if never written (region lazy pages), so this is mainly for solid ones. Wait until chunk meshing is nailed down.
- Compact custom vertex format via `rlgl`; batching multiple chunk meshes per draw call if draw calls become the bottleneck.
- Greedy meshing, worker threads for gen/meshing, light propagation, water.
- Occlusion culling: "cave culling" (per-chunk face-to-face air connectivity from a flood fill at mesh time, then a BFS from the camera chunk through connected faces). Only pays off once there are caves (3D noise); with heightmap terrain, buried chunks already have no faces. GPU occlusion queries / Hi-Z need raw GL via rlgl — avoid unless clearly needed.
- Vertical streaming range follows the camera (±8 chunks), so flying high enough drops low terrain. Revisit (e.g. load whole terrain-band columns) when it matters.

## Code conventions

- Odin style: `snake_case` procs/vars, `Ada_Case` types, `SCREAMING_SNAKE` constants.
- Prefer plain structs + procs over abstraction; no OOP-style vtables unless needed.
- Use `defer` for cleanup next to the allocation.
- Use `core:math/linalg` / raylib vector types; avoid hand-rolled vector math.
- Keep `main.odin` thin: init, loop, shutdown.
