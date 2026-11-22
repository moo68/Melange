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
}

DEFAULT_STREAM_CONFIG :: Stream_Config {
	radius        = 28,
	vertical      = 8, // ±128 blocks: covers the tallest peaks (TERRAIN_MAX_HEIGHT) from the plains
	unload_margin = 2,
	load_budget   = 32,
	unload_budget = 64,
}

Stream_Stats :: struct {
	loaded:          int, // last update
	unloaded:        int, // last update
	pending_loads:   int,
	pending_unloads: int,
	gen_time:        time.Duration, // total generation time, last update
	height_columns:  int, // chunk columns whose heights are cached
}

Streamer :: struct {
	config:       Stream_Config,
	center:       [3]i32,
	has_center:   bool,
	// Both queues are rebuilt only when the center changes chunk, then
	// consumed a budget's worth per update via the *_next cursors.
	load_queue:   [dynamic]Queued_Chunk, // sorted nearest first
	load_next:    int,
	unload_queue: [dynamic][3]i32,
	unload_next:  int,
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
	s.load_queue = make([dynamic]Queued_Chunk, allocator)
	s.unload_queue = make([dynamic][3]i32, allocator)
	s.unloaded = make([dynamic][3]i32, allocator)
	s.heights = make(map[[2]i32]^Column_Heights, allocator)
	s.evict = make([dynamic][2]i32, allocator)
	s.allocator = allocator
}

streamer_destroy :: proc(s: ^Streamer) {
	delete(s.load_queue)
	delete(s.unload_queue)
	delete(s.unloaded)
	clear_heights(s)
	delete(s.heights)
	delete(s.evict)
	s^ = {}
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
	for s.unload_next < len(s.unload_queue) && len(s.unloaded) < s.config.unload_budget {
		c := s.unload_queue[s.unload_next]
		s.unload_next += 1
		if world_get_chunk(w, c) == nil {
			continue
		}
		prof.scope("unload chunk")
		world_unload_chunk(w, c)
		append(&s.unloaded, c)
	}

	start := time.tick_now()
	loaded := 0
	for s.load_next < len(s.load_queue) && loaded < s.config.load_budget {
		q := s.load_queue[s.load_next]
		s.load_next += 1
		if world_get_chunk(w, q.coord) != nil {
			continue
		}
		c := world_create_chunk(w, q.coord) or_return
		if q.coord.y * CHUNK_SIZE > TERRAIN_MAX_HEIGHT {
			loaded += 1 // above any possible terrain: no heights needed
			continue
		}
		ch := column_heights(s, w.seed, q.coord.x, q.coord.z) or_return
		prof.scope("gen chunk")
		generate_chunk_from_heights(c, q.coord, ch)
		loaded += 1
	}

	s.stats.gen_time = time.tick_since(start)
	s.stats.loaded = loaded
	s.stats.unloaded = len(s.unloaded)
	s.stats.pending_loads = len(s.load_queue) - s.load_next
	s.stats.pending_unloads = len(s.unload_queue) - s.unload_next
	s.stats.height_columns = len(s.heights)
	return nil
}

@(private)
rebuild_queues :: proc(s: ^Streamer, w: ^World) {
	prof.scope("rebuild queues")
	cfg := s.config

	clear(&s.load_queue)
	s.load_next = 0
	for dy in -cfg.vertical ..= cfg.vertical {
		for dz in -cfg.radius ..= cfg.radius {
			for dx in -cfg.radius ..= cfg.radius {
				if dx * dx + dz * dz > cfg.radius * cfg.radius {
					continue
				}
				c := s.center + {dx, dy, dz}
				if world_get_chunk(w, c) != nil {
					continue
				}
				append(&s.load_queue, Queued_Chunk{c, dx * dx + dy * dy + dz * dz})
			}
		}
	}
	slice.sort_by(s.load_queue[:], proc(a, b: Queued_Chunk) -> bool {
		return a.dist2 < b.dist2
	})

	// Everything loaded but outside the (wider) keep range.
	clear(&s.unload_queue)
	s.unload_next = 0
	world_collect_loaded(w, &s.unload_queue)
	kept := 0
	for c in s.unload_queue {
		if !in_stream_range(cfg, s.center, c, cfg.unload_margin) {
			s.unload_queue[kept] = c
			kept += 1
		}
	}
	resize(&s.unload_queue, kept)

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
