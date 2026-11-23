package world

import "core:math"
import "core:mem"
import "core:slice"
import "core:time"
import "melange:prof"

// Keeps the chunks around a moving center loaded: a horizontal circle of
// `radius` chunks, `vertical` chunks above and below. Loads nearest-first and
// unloads beyond radius + unload_margin, both within per-update budgets.
// The margin (hysteresis) stops chunks at the edge from flickering in and out
// when the center moves back and forth across a chunk border.

Stream_Config :: struct {
	radius:        i32, // horizontal load radius, chunks
	vertical:      i32, // chunks loaded above and below the center
	unload_margin: i32, // extra chunks beyond the load range before unloading
	load_budget:   int, // max chunks generated per update
	unload_budget: int, // max chunks unloaded per update
	// Max load-order positions checked per update (each a world_get_chunk
	// lookup, ~12 ns release): spreads the search for missing chunks after
	// a move over several frames. 0 = no limit.
	scan_budget:   int,
	// Max regions whose slots are checked for unloading per update (up to
	// 512 slots each; regions that are empty or entirely inside the keep
	// range are skipped in O(1) and don't count). 0 = no limit.
	region_scan_budget: int,
}

DEFAULT_STREAM_CONFIG :: Stream_Config {
	radius        = 28,
	vertical      = 8, // ±128 blocks: covers the tallest peaks (TERRAIN_MAX_HEIGHT) from the plains
	unload_margin = 2,
	load_budget   = 32,
	unload_budget = 64,
	scan_budget   = 8192, // the 41,701-chunk shape in ~5 updates, ~0.1 ms each
	region_scan_budget = 32,
}

Stream_Stats :: struct {
	loaded:          int, // last update
	unloaded:        int, // last update
	load_scan_left:  int, // load-order positions not yet checked (an upper bound on pending loads)
	unload_regions_left: int, // regions not yet checked in the current unload pass
	gen_time:        time.Duration, // total generation time, last update
	height_columns:  int, // chunk columns whose heights are cached
}

Streamer :: struct {
	// Change only through streamer_set_config: load_order is derived from it.
	config:       Stream_Config,
	center:       [3]i32,
	has_center:   bool,
	// Every offset in the load shape, sorted nearest first (built once: the
	// shape relative to the center never changes). Loading walks it from
	// load_next, skipping chunks that exist; a center change resets
	// load_next to 0. No per-move scan or sort.
	load_order:   [dynamic][3]i32,
	load_next:    int,
	// Unload pass: when the center changes chunk, the keys of all regions
	// are snapshotted; each update then checks regions from unload_next
	// (resuming inside a region at unload_slot after the unload budget ran
	// out) and unloads their chunks beyond the keep range. Regions created
	// after the snapshot only hold chunks loaded in range, so they can wait
	// for the next pass.
	unload_regions: [dynamic][3]i32,
	unload_next:    int,
	unload_slot:    int,
	// Chunks unloaded by the last update. The caller must drop anything it
	// keeps per chunk (e.g. GPU meshes) for these.
	unloaded:     [dynamic][3]i32,
	// Surface heights per chunk column (cx, cz), computed once and shared by
	// every chunk generated in that column. Evicted with the same keep range
	// as chunks. Only valid for `heights_seed`.
	heights:      map[[2]i32]^Column_Heights,
	heights_seed: i64,
	evict:        [dynamic][2]i32, // scratch for eviction
	allocator:    mem.Allocator,
	stats:        Stream_Stats,
}

Queued_Chunk :: struct {
	coord: [3]i32,
	dist2: i32, // squared distance to the center, in chunks
}

streamer_init :: proc(s: ^Streamer, config := DEFAULT_STREAM_CONFIG, allocator := context.allocator) {
	s.config = config
	s.load_order = make([dynamic][3]i32, allocator)
	build_load_order(&s.load_order, config)
	s.unload_regions = make([dynamic][3]i32, allocator)
	s.unloaded = make([dynamic][3]i32, allocator)
	s.heights = make(map[[2]i32]^Column_Heights, allocator)
	s.evict = make([dynamic][2]i32, allocator)
	s.allocator = allocator
}

streamer_destroy :: proc(s: ^Streamer) {
	delete(s.load_order)
	delete(s.unload_regions)
	delete(s.unloaded)
	clear_heights(s)
	delete(s.heights)
	delete(s.evict)
	s^ = {}
}

// Changes the streaming config (e.g. render distance) at runtime. The next
// update restarts both passes around the current center: the new shape
// loads nearest-first and chunks beyond the new keep range unload, within
// the budgets. The caller updates anything else derived from the radius
// (fog: stream_meshed_distance).
streamer_set_config :: proc(s: ^Streamer, config: Stream_Config) {
	if config.radius != s.config.radius || config.vertical != s.config.vertical {
		build_load_order(&s.load_order, config)
	}
	s.config = config
	s.has_center = false // forces a restart on the next update
}

@(private)
clear_heights :: proc(s: ^Streamer) {
	for _, ch in s.heights {
		free(ch, s.allocator)
	}
	clear(&s.heights)
}

// The cached surface of chunk column (cx, cz), computing it on first use.
@(private)
column_heights :: proc(s: ^Streamer, seed: i64, cx, cz: i32) -> (ch: ^Column_Heights, err: mem.Allocator_Error) {
	if seed != s.heights_seed {
		clear_heights(s) // a different world: nothing cached is valid
		s.heights_seed = seed
	}
	if cached, ok := s.heights[{cx, cz}]; ok {
		return cached, nil
	}
	prof.scope("column heights")
	ch = new(Column_Heights, s.allocator) or_return
	column_heights_compute(ch, seed, cx, cz)
	s.heights[{cx, cz}] = ch
	return ch, nil
}

// Every offset in the load shape of `cfg`, nearest first; ties in a fixed
// order (y, then z, then x), so loading is deterministic.
build_load_order :: proc(out: ^[dynamic][3]i32, cfg: Stream_Config) {
	clear(out)
	for dy in -cfg.vertical ..= cfg.vertical {
		for dz in -cfg.radius ..= cfg.radius {
			for dx in -cfg.radius ..= cfg.radius {
				if dx * dx + dz * dz <= cfg.radius * cfg.radius {
					append(out, [3]i32{dx, dy, dz})
				}
			}
		}
	}
	slice.sort_by(out[:], proc(a, b: [3]i32) -> bool {
		da, db := a.x * a.x + a.y * a.y + a.z * a.z, b.x * b.x + b.y * b.y + b.z * b.z
		if da != db {
			return da < db
		}
		if a.y != b.y {
			return a.y < b.y
		}
		if a.z != b.z {
			return a.z < b.z
		}
		return a.x < b.x
	})
}

// Inside the load shape (circle × vertical span) around `center`, widened by `margin`.
in_stream_range :: proc "contextless" (cfg: Stream_Config, center, c: [3]i32, margin: i32 = 0) -> bool {
	d := c - center
	r := cfg.radius + margin
	return d.x * d.x + d.z * d.z <= r * r && abs(d.y) <= cfg.vertical + margin
}

// Horizontal distance (blocks) from the camera within which every block's
// chunk is guaranteed to be meshed, wherever the camera is inside its chunk.
// Fog must be fully opaque by here, or the edge of the world shows.
//
// Why: a chunk is meshed when all its neighbors are loaded, i.e. when it's
// within radius - 1 of the center chunk. A point at horizontal distance D
// from the camera is in a chunk whose coord differs from the camera's chunk
// by less than D/16 + 1 on each axis, so by at most D/16 + sqrt(2) overall
// (Euclidean, in chunks). Requiring D/16 + sqrt(2) <= radius - 1 gives:
stream_meshed_distance :: proc "contextless" (cfg: Stream_Config) -> f32 {
	return (f32(cfg.radius) - 1 - math.SQRT_TWO) * CHUNK_SIZE
}

// Call once per frame with the chunk the camera/player is in.
streamer_update :: proc(s: ^Streamer, w: ^World, center: [3]i32) -> (err: mem.Allocator_Error) {
	prof.scope("streamer_update")
	clear(&s.unloaded)
	if !s.has_center || center != s.center {
		s.center = center
		s.has_center = true
		rebuild_queues(s, w)
	}

	// Unload first, so memory is freed before more is allocated.
	unload_pass(s, w)

	start := time.tick_now()
	loaded, scanned := 0, 0
	for s.load_next < len(s.load_order) && loaded < s.config.load_budget && (s.config.scan_budget == 0 || scanned < s.config.scan_budget) {
		coord := s.center + s.load_order[s.load_next]
		s.load_next += 1
		scanned += 1
		if world_get_chunk(w, coord) != nil {
			continue
		}
		c := world_create_chunk(w, coord) or_return
		loaded += 1
		// Above any possible terrain: no generation, but it may hold edits.
		if coord.y * CHUNK_SIZE <= TERRAIN_MAX_HEIGHT {
			ch := column_heights(s, w.seed, coord.x, coord.z) or_return
			prof.scope("gen chunk")
			generate_chunk_from_heights(c, coord, ch)
		}
		world_apply_edits(w, coord, c)
	}

	s.stats.gen_time = time.tick_since(start)
	s.stats.loaded = loaded
	s.stats.unloaded = len(s.unloaded)
	s.stats.load_scan_left = len(s.load_order) - s.load_next
	s.stats.unload_regions_left = len(s.unload_regions) - s.unload_next
	s.stats.height_columns = len(s.heights)
	return nil
}

@(private)
rebuild_queues :: proc(s: ^Streamer, w: ^World) {
	prof.scope("rebuild queues")
	cfg := s.config

	s.load_next = 0 // restart the nearest-first walk around the new center

	// Restart the unload pass over a snapshot of the regions.
	clear(&s.unload_regions)
	for key in w.regions {
		append(&s.unload_regions, key)
	}
	s.unload_next = 0
	s.unload_slot = 0

	// Drop cached heights for columns outside the keep range (horizontal).
	clear(&s.evict)
	keep := cfg.radius + cfg.unload_margin
	for key in s.heights {
		dx, dz := key.x - s.center.x, key.y - s.center.z
		if dx * dx + dz * dz > keep * keep {
			append(&s.evict, key)
		}
	}
	for key in s.evict {
		free(s.heights[key], s.allocator)
		delete_key(&s.heights, key)
	}
}

// Whether every chunk of region `key` is within the keep range (load range
// widened by unload_margin) around `center`: its farthest corner chunk is.
region_inside_keep :: proc "contextless" (cfg: Stream_Config, center, key: [3]i32) -> bool {
	lo := key * REGION_SIZE - center
	hi := lo + (REGION_SIZE - 1)
	far := [3]i32{max(abs(lo.x), abs(hi.x)), max(abs(lo.y), abs(hi.y)), max(abs(lo.z), abs(hi.z))}
	r := cfg.radius + cfg.unload_margin
	return far.x * far.x + far.z * far.z <= r * r && far.y <= cfg.vertical + cfg.unload_margin
}

// Continues the unload pass within unload_budget and region_scan_budget.
@(private)
unload_pass :: proc(s: ^Streamer, w: ^World) {
	cfg := s.config
	scanned := 0
	for s.unload_next < len(s.unload_regions) && len(s.unloaded) < cfg.unload_budget {
		key := s.unload_regions[s.unload_next]
		r := w.regions[key]
		if r == nil || region_inside_keep(cfg, s.center, key) {
			s.unload_next += 1 // gone, or nothing in it to unload: O(1)
			s.unload_slot = 0
			continue
		}
		if cfg.region_scan_budget != 0 && scanned >= cfg.region_scan_budget {
			break
		}
		scanned += 1
		done := true
		for i := s.unload_slot; i < REGION_VOLUME; i += 1 {
			if !r.loaded[i] {
				continue
			}
			c := key * REGION_SIZE + region_local_from_index(i)
			if in_stream_range(cfg, s.center, c, cfg.unload_margin) {
				continue
			}
			if len(s.unloaded) >= cfg.unload_budget {
				s.unload_slot = i // resume here next update
				done = false
				break
			}
			last := r.loaded_count == 1
			prof.scope("unload chunk")
			world_unload_chunk(w, c) // frees the region with its last chunk
			append(&s.unloaded, c)
			if last {
				break
			}
		}
		if done {
			s.unload_next += 1
			s.unload_slot = 0
		}
	}
}
