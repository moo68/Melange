package tests

import "core:testing"
import "melange:mesh"
import "melange:world"

// ---- Rules --------------------------------------------------------------------

@(test)
light_filter_matches_opacity :: proc(t: ^testing.T) {
	for id in 0 ..< 300 {
		b := world.Block_ID(id)
		filter := world.block_light_filter(b)
		testing.expectf(t, world.block_is_opaque(b) == (filter == world.MAX_LIGHT), "%v: opaque must mean filter 15 (and only then)", b)
	}
	testing.expect_value(t, world.block_light_filter(world.AIR), 0)
	testing.expect_value(t, world.block_light_filter(world.GLASS), 0)
	testing.expect_value(t, world.block_light_filter(world.WATER), 1)
	testing.expect_value(t, world.block_light_filter(world.LEAVES), 1)
}

@(test)
sky_light_goes_straight_down :: proc(t: ^testing.T) {
	testing.expect_value(t, world.sky_below(15, world.AIR), 15) // no loss at full strength
	testing.expect_value(t, world.sky_below(15, world.GLASS), 15)
	testing.expect_value(t, world.sky_below(15, world.WATER), 14) // water dims 1 per block
	testing.expect_value(t, world.sky_below(14, world.WATER), 13)
	testing.expect_value(t, world.sky_below(14, world.AIR), 13) // below full: fades like any light
	testing.expect_value(t, world.sky_below(15, world.LEAVES), 14)
	testing.expect_value(t, world.sky_below(1, world.WATER), 0)
	testing.expect_value(t, world.sky_below(0, world.AIR), 0)
	testing.expect_value(t, world.sky_below(15, world.STONE), 0)
}

// column_sky_light (the closed form used for the light entering a chunk's
// top) must equal walking the generated column down from the open sky.
@(test)
column_sky_light_matches_walking_down :: proc(t: ^testing.T) {
	for h in i32(world.TERRAIN_MIN_HEIGHT) ..= world.TERRAIN_MAX_HEIGHT {
		for kind in 0 ..< 3 {
			col := world.Column{height = h, bare_stone = kind == 1, sand = kind == 2}
			l := u8(world.MAX_LIGHT)
			for y := i32(world.TERRAIN_MAX_HEIGHT + 2); y >= world.TERRAIN_MIN_HEIGHT - 5; y -= 1 {
				l = world.sky_below(l, world.column_block(col, y))
				if world.column_sky_light(col, y) != l {
					testing.fail_now(t, "closed form disagrees with the walk")
				}
			}
		}
	}
	// A seabed 15+ blocks deep is dark; the top water block is 14.
	col := world.Column{height = -20, sand = true}
	testing.expect_value(t, world.column_sky_light(col, world.TERRAIN_SEA_LEVEL), 14)
	testing.expect_value(t, world.column_sky_light(col, world.TERRAIN_SEA_LEVEL + 1), 15)
	testing.expect_value(t, world.column_sky_light(col, -19), 0)
}

// ---- Generated light vs a brute-force flood fill -------------------------------

// Reference sky light over a box of generated terrain: iterate the
// propagation rules (straight-down sky rule, max(1, filter) per step in
// all 6 directions) until nothing changes. Full sky above the box, dark
// outside it, so only cells >= 15 blocks from the sides are exact.
@(private = "file")
Ref_Box :: struct {
	lo, size: [3]i32,
	blocks:   []world.Block_ID,
	light:    []u8,
}

@(private = "file")
ref_index :: proc(b: ^Ref_Box, p: [3]i32) -> int {
	q := p - b.lo
	return int(q.x + q.z * b.size.x + q.y * b.size.x * b.size.z)
}

@(private = "file")
ref_flood_fill :: proc(b: ^Ref_Box, seed: i64) {
	n := int(b.size.x * b.size.y * b.size.z)
	b.blocks = make([]world.Block_ID, n)
	b.light = make([]u8, n)
	for z in i32(0) ..< b.size.z {
		for x in i32(0) ..< b.size.x {
			col := world.terrain_column(seed, b.lo.x + x, b.lo.z + z)
			for y in i32(0) ..< b.size.y {
				p := b.lo + {x, y, z}
				b.blocks[ref_index(b, p)] = world.column_block(col, p.y)
			}
		}
	}
	get :: proc(b: ^Ref_Box, p: [3]i32) -> u8 {
		q := p - b.lo
		if q.x < 0 || q.z < 0 || q.y < 0 || q.x >= b.size.x || q.z >= b.size.z {
			return 0
		}
		if q.y >= b.size.y {
			return world.MAX_LIGHT // open sky above
		}
		return b.light[ref_index(b, p)]
	}
	for changed := true; changed; {
		changed = false
		for y := b.size.y - 1; y >= 0; y -= 1 {
			for z in i32(0) ..< b.size.z {
				for x in i32(0) ..< b.size.x {
					p := b.lo + {x, y, z}
					i := ref_index(b, p)
					id := b.blocks[i]
					filter := world.block_light_filter(id)
					l := u8(0)
					if filter < world.MAX_LIGHT {
						l = world.sky_below(get(b, p + {0, 1, 0}), id)
						for face in world.Face {
							nl := get(b, p + world.FACE_NORMALS[face])
							cost := max(filter, 1)
							if nl > cost {
								l = max(l, nl - cost)
							}
						}
					}
					if l != b.light[i] {
						b.light[i] = l
						changed = true
					}
				}
			}
		}
	}
}

// Generated light for every chunk of chunk column (cx, cz) must match the
// flood fill exactly: heightmap terrain's light is a pure function of each
// column, so no flood fill is needed at generation.
@(private = "file")
expect_generated_light_matches :: proc(t: ^testing.T, seed: i64, cx, cz: i32) {
	ch := new(world.Column_Heights)
	defer free(ch)
	world.column_heights_compute(ch, seed, cx, cz)
	// The box: this column plus 16 blocks around, from below the all-stone
	// line to above the tallest surface nearby.
	top := max(ch.max_height, world.TERRAIN_SEA_LEVEL)
	for z in cz * 16 - 16 ..< cz * 16 + 32 {
		for x in cx * 16 - 16 ..< cx * 16 + 32 {
			top = max(top, world.terrain_height(seed, x, z))
		}
	}
	min_cy := i32(world.TERRAIN_ALL_STONE_BELOW >> 4) - 1
	max_cy := (top + 1) >> 4
	box := Ref_Box{lo = {cx * 16 - 16, min_cy * 16 - 16, cz * 16 - 16}}
	box.size = {48, (max_cy + 1) * 16 + 2 - box.lo.y, 48}
	ref_flood_fill(&box, seed)
	defer delete(box.blocks)
	defer delete(box.light)

	scratch := new(world.Chunk_Light)
	defer free(scratch)
	mixed := 0
	for cy in min_cy ..= max_cy + 2 {
		coord := [3]i32{cx, cy, cz}
		c := new(world.Chunk)
		defer free(c)
		world.generate_chunk_from_heights(c, coord, ch)
		state := world.generate_light(scratch, c, coord, ch)
		ref := world.Light_Ref{scratch, state}
		mixed += int(state == .Mixed)
		for y in i32(0) ..< 16 {
			for z in i32(0) ..< 16 {
				for x in i32(0) ..< 16 {
					p := world.chunk_origin(coord) + {x, y, z}
					want := u8(world.MAX_LIGHT) // above the box: open sky
					if p.y < box.lo.y + box.size.y {
						want = box.light[ref_index(&box, p)]
					}
					got := world.light_ref_get(ref, world.chunk_index(x, y, z))
					if got != want {
						testing.fail_now(t, "generated light differs from the flood fill")
					}
				}
			}
		}
	}
	testing.expect(t, mixed > 0)
}

@(test)
generated_light_matches_flood_fill_on_a_coast :: proc(t: ^testing.T) {
	// Seed 1337: water, sand and steps (the coast spot of the sand tests).
	expect_generated_light_matches(t, 1337, -1721 >> 4, -9410 >> 4)
}

@(test)
generated_light_matches_flood_fill_in_deep_ocean :: proc(t: ^testing.T) {
	ocean := find_column(7, proc(h: i32) -> bool {return h < world.TERRAIN_SEA_LEVEL - 15})
	expect_generated_light_matches(t, 7, ocean.x >> 4, ocean.y >> 4)
}

@(test)
generated_light_matches_flood_fill_in_mountains :: proc(t: ^testing.T) {
	SEED :: 7
	for r := i32(0); r < 400; r += 1 {
		if world.terrain_height(SEED, r * 16, 0) > world.TERRAIN_STONE_LINE + 10 {
			expect_generated_light_matches(t, SEED, r, 0)
			return
		}
	}
	testing.fail_now(t, "no mountain found to test")
}

// A chunk that misses generation's fast path but is all open air (only
// with a loose max_height) is stored as uniform Sky, not as an array.
@(test)
open_air_chunk_light_is_uniform :: proc(t: ^testing.T) {
	ch := new(world.Column_Heights)
	defer free(ch)
	for &row in ch.columns {
		for &col in row {
			col.height = 5
		}
	}
	ch.max_height = 40
	c := new(world.Chunk)
	defer free(c)
	out := new(world.Chunk_Light)
	defer free(out)
	world.generate_chunk_from_heights(c, {0, 1, 0}, ch)
	testing.expect(t, world.generate_light(out, c, {0, 1, 0}, ch) == .Sky)
	world.generate_chunk_from_heights(c, {0, -5, 0}, ch)
	testing.expect(t, world.generate_light(out, c, {0, -5, 0}, ch) == .Dark)
}

// ---- Storage and streaming ---------------------------------------------------------

@(test)
light_states_store_and_unload :: proc(t: ^testing.T) {
	w: world.World
	world.world_init(&w)
	defer world.world_destroy(&w)
	_, _ = world.world_create_chunk(&w, {0, 0, 0})
	_, _ = world.world_create_chunk(&w, {1, 0, 0})
	// New chunks are Dark.
	l, ok := world.world_get_light(&w, {3, 4, 5})
	testing.expect(t, ok && l == 0)
	_, ok = world.world_get_light(&w, {3, 4, 50})
	testing.expect(t, !ok, "unloaded chunk")

	world.world_set_chunk_light(&w, {1, 0, 0}, .Sky, nil)
	l, _ = world.world_get_light(&w, {20, 4, 5})
	testing.expect_value(t, l, world.SKY_LIGHT_FULL)
	testing.expect_value(t, w.light_mixed_count, 0)

	src := new(world.Chunk_Light)
	defer free(src)
	src.data[world.chunk_index(3, 4, 5)] = 9
	world.world_set_chunk_light(&w, {0, 0, 0}, .Mixed, src)
	l, _ = world.world_get_light(&w, {3, 4, 5})
	testing.expect_value(t, l, 9)
	testing.expect_value(t, w.light_mixed_count, 1)
	ref, _ := world.world_get_light_ref(&w, {0, 0, 0})
	testing.expect(t, ref.state == .Mixed && ref.data != nil)

	// Neighborhood: loaded chunks as stored, missing ones full sky.
	hood := world.world_get_light_neighborhood(&w, {0, 0, 0})
	testing.expect(t, hood[world.neighborhood_index({0, 0, 0})].state == .Mixed)
	testing.expect(t, hood[world.neighborhood_index({1, 0, 0})].state == .Sky)
	testing.expect(t, hood[world.neighborhood_index({-1, 0, 0})].state == .Sky)

	// Unloading forgets it: the slot comes back Dark and zeroed.
	world.world_unload_chunk(&w, {0, 0, 0})
	testing.expect_value(t, w.light_mixed_count, 0)
	_, _ = world.world_create_chunk(&w, {0, 0, 0})
	l, _ = world.world_get_light(&w, {3, 4, 5})
	testing.expect_value(t, l, 0)
	world.world_set_chunk_light(&w, {0, 0, 0}, .Mixed, src)
	world.world_set_chunk_light(&w, {0, 0, 0}, .Dark, nil) // Mixed -> uniform zeroes the array
	testing.expect_value(t, w.light_mixed_count, 0)
	ref, _ = world.world_get_light_ref(&w, {0, 0, 0})
	testing.expect(t, ref.state == .Dark && ref.data == nil)
	r := w.regions[{0, 0, 0}]
	testing.expect_value(t, r.light[0].data[world.chunk_index(3, 4, 5)], 0)
}

// Streaming stores each chunk's generated light: equal to the column rule
// everywhere, with only surface chunks storing an array.
@(test)
streaming_lights_chunks :: proc(t: ^testing.T) {
	SEED :: 1337
	w: world.World
	world.world_init(&w, SEED)
	defer world.world_destroy(&w)
	s: world.Streamer
	// vertical 8 around y 0 reaches above TERRAIN_MAX_HEIGHT (not generated).
	world.streamer_init(&s, {radius = 2, vertical = 8, unload_margin = 1, load_budget = 10000, unload_budget = 1000})
	defer world.streamer_destroy(&s)
	spot := [2]i32{-1721, -9410} // a coast
	center := world.block_to_chunk({spot.x, 0, spot.y})
	world.streamer_update(&s, &w, center)

	coords: [dynamic][3]i32
	defer delete(coords)
	world.world_collect_loaded(&w, &coords)
	ch := new(world.Column_Heights)
	defer free(ch)
	states: [world.Light_State]int
	for coord in coords {
		world.column_heights_compute(ch, SEED, coord.x, coord.z)
		ref, ok := world.world_get_light_ref(&w, coord)
		testing.expect(t, ok)
		states[ref.state] += 1
		for y in i32(0) ..< 16 {
			for z in i32(0) ..< 16 {
				for x in i32(0) ..< 16 {
					wy := coord.y * 16 + y
					want := world.column_sky_light(ch.columns[z][x], wy)
					if world.light_ref_get(ref, world.chunk_index(x, y, z)) != want {
						testing.fail_now(t, "stored light differs from the column rule")
					}
				}
			}
		}
	}
	testing.expectf(t, states[.Sky] > 0 && states[.Dark] > 0 && states[.Mixed] > 0, "%v", states)
	top, _ := world.world_get_light_ref(&w, center + {0, 8, 0})
	testing.expect(t, top.state == .Sky, "a chunk above all terrain is open sky")
	testing.expect_value(t, w.light_mixed_count, states[.Mixed])
}

// ---- Smooth lighting in the mesh -------------------------------------------------------

// A center chunk with a Mixed light array (all 15 unless set) and a stone floor at y = 4.
@(private = "file")
Lit_Scene :: struct {
	chunk: ^world.Chunk,
	light: ^world.Chunk_Light,
	hood:  world.Neighborhood,
	lhood: world.Light_Neighborhood,
	cm:    mesh.Chunk_Mesh,
}

@(private = "file")
scene_init :: proc(s: ^Lit_Scene) {
	s.chunk = new(world.Chunk)
	s.light = new(world.Chunk_Light)
	for &l in s.light.data {
		l = world.SKY_LIGHT_FULL
	}
	for z in i32(0) ..< 16 {
		for x in i32(0) ..< 16 {
			world.chunk_set(s.chunk, x, 4, z, world.STONE)
		}
	}
	for &l in s.lhood {
		l = {nil, .Sky}
	}
	s.hood[world.neighborhood_index({0, 0, 0})] = s.chunk
	s.lhood[world.neighborhood_index({0, 0, 0})] = {s.light, .Mixed}
}

@(private = "file")
scene_destroy :: proc(s: ^Lit_Scene) {
	free(s.chunk)
	free(s.light)
	mesh.chunk_mesh_destroy(&s.cm)
}

@(private = "file")
set_light :: proc(s: ^Lit_Scene, p: [3]i32, level: u8) {
	s.light.data[world.chunk_index(p.x, p.y, p.z)] = level
}

// Sky light (vertex units) at a face corner.
@(private = "file")
corner_light :: proc(t: ^testing.T, m: ^mesh.Mesh_Data, pos: [3]i32, face: world.Face, corner: [3]f32) -> int {
	first, ok := find_face(m, pos, face)
	if !ok {
		testing.fail_now(t, "face not found")
	}
	for v in first ..< first + 4 {
		if vpos(m, v) == corner {
			return int(mesh.unpack_vertex(m.vertices[v]).sky)
		}
	}
	testing.fail_now(t, "corner not found")
}

@(test)
smooth_light_averages_the_four_cells :: proc(t: ^testing.T) {
	s: Lit_Scene
	scene_init(&s)
	defer scene_destroy(&s)
	// Above the floor block (5, 4, 5): its front cell and the cells around
	// its (6, 5, 6) corner.
	set_light(&s, {5, 5, 5}, 12)
	set_light(&s, {6, 5, 5}, 8)
	set_light(&s, {5, 5, 6}, 4)
	set_light(&s, {6, 5, 6}, 0)
	set_light(&s, {5, 4, 5}, 3) // the block's own cell: opaque, never read
	mesh.build_chunk_mesh_neighborhood(&s.hood, &s.cm, &s.lhood)
	m := &s.cm[.Opaque]
	// (12 + 8 + 4 + 0) / 4 = 6 levels.
	testing.expect_value(t, corner_light(t, m, {5, 4, 5}, .Pos_Y, {6, 5, 6}), 6 * mesh.LIGHT_SCALE)
	// (12 + 15 + 15 + 15) / 4 = 14.25 levels: exact in quarter levels.
	testing.expect_value(t, corner_light(t, m, {5, 4, 5}, .Pos_Y, {5, 5, 5}), 57)
	// A fully lit spot is 15.
	testing.expect_value(t, corner_light(t, m, {10, 4, 10}, .Pos_Y, {10, 5, 10}), mesh.MAX_VERTEX_LIGHT)

	// Without a light neighborhood everything is fully lit.
	mesh.build_chunk_mesh_neighborhood(&s.hood, &s.cm)
	testing.expect_value(t, corner_light(t, m, {5, 4, 5}, .Pos_Y, {6, 5, 6}), mesh.MAX_VERTEX_LIGHT)
}

// Opaque cells hold no light and are left out of the average (their stored
// value is ignored); with both side cells opaque the corner cell is hidden
// behind them and left out too.
@(test)
smooth_light_skips_opaque_cells :: proc(t: ^testing.T) {
	s: Lit_Scene
	scene_init(&s)
	defer scene_destroy(&s)
	set_light(&s, {5, 5, 5}, 12)
	set_light(&s, {5, 5, 6}, 4)
	set_light(&s, {6, 5, 6}, 1)
	world.chunk_set(s.chunk, 6, 5, 5, world.STONE) // its stored light stays 15
	mesh.build_chunk_mesh_neighborhood(&s.hood, &s.cm, &s.lhood)
	m := &s.cm[.Opaque]
	// (12 + 4 + 1) / 3 = 5.67 levels = 22.67 quarter levels -> rounded to 23.
	testing.expect_value(t, corner_light(t, m, {5, 4, 5}, .Pos_Y, {6, 5, 6}), 23)

	world.chunk_set(s.chunk, 5, 5, 6, world.STONE)
	mesh.build_chunk_mesh_neighborhood(&s.hood, &s.cm, &s.lhood)
	// Both sides opaque: only the front cell counts (not the corner's 1).
	testing.expect_value(t, corner_light(t, m, {5, 4, 5}, .Pos_Y, {6, 5, 6}), 12 * mesh.LIGHT_SCALE)
}

// A water surface under a block (its front cell is opaque) is lit by the
// water's own cell.
@(test)
smooth_light_of_water_under_a_block :: proc(t: ^testing.T) {
	s: Lit_Scene
	scene_init(&s)
	defer scene_destroy(&s)
	world.chunk_set(s.chunk, 2, 5, 2, world.WATER)
	world.chunk_set(s.chunk, 2, 6, 2, world.STONE)
	set_light(&s, {2, 5, 2}, 9)
	for z in i32(1) ..= 3 {
		for x in i32(1) ..= 3 {
			if x != 2 || z != 2 {
				set_light(&s, {x, 6, z}, 3)
			}
		}
	}
	mesh.build_chunk_mesh_neighborhood(&s.hood, &s.cm, &s.lhood)
	m := &s.cm[.Translucent]
	// The water's only top face (lowered, so find_face doesn't match it).
	first := -1
	for f in 0 ..< mesh.face_count(m) {
		if mesh.unpack_vertex(m.vertices[f * 4]).face == .Pos_Y {
			first = f * 4
		}
	}
	testing.expect(t, first >= 0)
	for v in first ..< first + 4 {
		// (9 + 3 + 3 + 3) / 4 = 4.5 levels.
		testing.expect_value(t, mesh.unpack_vertex(m.vertices[v]).sky, 18)
	}
}

// Light across a chunk border comes from the neighbor's stored light.
@(test)
smooth_light_reads_neighbor_chunks :: proc(t: ^testing.T) {
	s: Lit_Scene
	scene_init(&s)
	defer scene_destroy(&s)
	world.chunk_set(s.chunk, 5, 15, 5, world.STONE)
	above := new(world.Chunk)
	defer free(above)
	above_light := new(world.Chunk_Light)
	defer free(above_light)
	for &l in above_light.data {
		l = 7
	}
	up := world.neighborhood_index({0, 1, 0})
	s.hood[up] = above
	s.lhood[up] = {above_light, .Mixed}
	mesh.build_chunk_mesh_neighborhood(&s.hood, &s.cm, &s.lhood)
	testing.expect_value(t, corner_light(t, &s.cm[.Opaque], {5, 15, 5}, .Pos_Y, {5, 16, 5}), 7 * mesh.LIGHT_SCALE)

	s.lhood[up] = {nil, .Dark}
	mesh.build_chunk_mesh_neighborhood(&s.hood, &s.cm, &s.lhood)
	testing.expect_value(t, corner_light(t, &s.cm[.Opaque], {5, 15, 5}, .Pos_Y, {5, 16, 5}), 0)
}

// With even AO, light decides the quad split: it runs through the dark
// corner, so both triangles darken toward it.
@(test)
quad_split_follows_light :: proc(t: ^testing.T) {
	s: Lit_Scene
	scene_init(&s)
	defer scene_destroy(&s)
	// Darken the (9, 5, 9) corner of the floor block (8, 4, 8)'s top.
	set_light(&s, {9, 5, 8}, 0)
	set_light(&s, {8, 5, 9}, 0)
	set_light(&s, {9, 5, 9}, 0)
	mesh.build_chunk_mesh_neighborhood(&s.hood, &s.cm, &s.lhood)
	m := &s.cm[.Opaque]
	expect_ccw(t, m)
	first, ok := find_face(m, {8, 4, 8}, .Pos_Y)
	testing.expect(t, ok)
	dark := -1
	for v in first ..< first + 4 {
		testing.expect_value(t, vao(m, v), 3)
		if vpos(m, v) == {9, 5, 9} {
			dark = v
		}
	}
	testing.expect_value(t, int(mesh.unpack_vertex(m.vertices[dark]).sky), 15) // 15 / 4 levels
	in_triangle :: proc(tri, v: int) -> bool {
		for k in 0 ..< 3 {
			if index_at(tri * 3 + k) == v {
				return true
			}
		}
		return false
	}
	face := first / 4
	testing.expect(t, in_triangle(face * 2, dark) && in_triangle(face * 2 + 1, dark), "quad not split through the dark corner")
}
