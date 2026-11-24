package tests

import "core:math/rand"
import "core:testing"
import "melange:world"

// Relighting (world/light_engine.odin) is checked against a brute-force
// reference: the light of a box of loaded chunks (and nothing else loaded),
// computed by iterating the propagation rules over its blocks until nothing
// changes. Above the box: the open-sky light of the unedited terrain
// (column_sky_light), which is what generate_light assumes for unloaded
// chunks above; beside and below it: nothing (light doesn't flow out of
// unloaded chunks).

RELIGHT_SEED :: 1337
// A coast (water, sand, steps): the sand tests' spot, chunk (-108, -589).
RELIGHT_BOX_LO :: [3]i32{-109, -2, -590}
RELIGHT_BOX_HI :: [3]i32{-107, 2, -588}

@(private = "file")
box_blocks_lo :: proc() -> [3]i32 {return RELIGHT_BOX_LO * 16}

@(private = "file")
box_size :: proc() -> [3]i32 {return (RELIGHT_BOX_HI - RELIGHT_BOX_LO + 1) * 16}

@(private = "file")
box_index :: proc(p: [3]i32) -> int {
	q, s := p - box_blocks_lo(), box_size()
	return int(q.x + q.z * s.x + q.y * s.x * s.z)
}

@(private = "file")
in_box :: proc(p: [3]i32) -> bool {
	q, s := p - box_blocks_lo(), box_size()
	return q.x >= 0 && q.y >= 0 && q.z >= 0 && q.x < s.x && q.y < s.y && q.z < s.z
}

@(private = "file")
box_chunks :: proc(out: ^[dynamic][3]i32) {
	for y in RELIGHT_BOX_LO.y ..= RELIGHT_BOX_HI.y {
		for z in RELIGHT_BOX_LO.z ..= RELIGHT_BOX_HI.z {
			for x in RELIGHT_BOX_LO.x ..= RELIGHT_BOX_HI.x {
				append(out, [3]i32{x, y, z})
			}
		}
	}
}

@(private = "file")
load_chunk :: proc(w: ^world.World, coord: [3]i32) {
	ch := new(world.Column_Heights)
	defer free(ch)
	scratch := new(world.Chunk_Light)
	defer free(scratch)
	world.column_heights_compute(ch, RELIGHT_SEED, coord.x, coord.z)
	err := world.world_load_generated_chunk(w, coord, ch, scratch)
	assert(err == nil)
}

@(private = "file")
load_box :: proc(w: ^world.World) {
	world.world_init(w, RELIGHT_SEED)
	coords: [dynamic][3]i32
	defer delete(coords)
	box_chunks(&coords)
	for c in coords {
		load_chunk(w, c)
	}
	world.world_update_light(w)
}

// The reference sky light of every cell of the box.
@(private = "file")
reference_light :: proc(w: ^world.World) -> []u8 {
	size := box_size()
	lo := box_blocks_lo()
	n := int(size.x * size.y * size.z)
	blocks := make([]world.Block_ID, n)
	defer delete(blocks)
	light := make([]u8, n)
	sky_above := make([]u8, int(size.x * size.z))
	defer delete(sky_above)
	for z in i32(0) ..< size.z {
		for x in i32(0) ..< size.x {
			col := world.terrain_column(RELIGHT_SEED, lo.x + x, lo.z + z)
			sky_above[x + z * size.x] = world.column_sky_light(col, lo.y + size.y)
			for y in i32(0) ..< size.y {
				p := lo + {x, y, z}
				blocks[box_index(p)], _ = world.world_get_block(w, p)
			}
		}
	}
	get :: proc(light: []u8, sky_above: []u8, p: [3]i32) -> u8 {
		q, s := p - box_blocks_lo(), box_size()
		if q.y == s.y && q.x >= 0 && q.z >= 0 && q.x < s.x && q.z < s.z {
			return sky_above[q.x + q.z * s.x]
		}
		if !in_box(p) {
			return 0
		}
		return light[box_index(p)]
	}
	for changed, pass := true, 0; changed; pass += 1 {
		changed = false
		for k in 0 ..< n {
			i := k if pass % 2 == 0 else n - 1 - k // alternate sweep directions
			ii := i32(i)
			p := lo + {ii % size.x, ii / (size.x * size.z), (ii / size.x) % size.z}
			id := blocks[i]
			l := u8(0)
			filter := world.block_light_filter(id)
			if filter < world.MAX_LIGHT {
				// The rules written out again (not world.light_spread), so a
				// bug there can't hide in the reference too.
				cost := max(filter, 1)
				for face in world.Face {
					from := get(light, sky_above, p + world.FACE_NORMALS[face])
					if face == .Pos_Y && from == world.MAX_LIGHT && filter == 0 {
						l = world.MAX_LIGHT // full sky light comes straight down
					} else if from > cost {
						l = max(l, from - cost)
					}
				}
			}
			if l != light[i] {
				light[i] = l
				changed = true
			}
		}
	}
	return light
}

@(private = "file")
expect_light_matches_reference :: proc(t: ^testing.T, w: ^world.World, what: string) -> bool {
	want := reference_light(w)
	defer delete(want)
	size := box_size()
	lo := box_blocks_lo()
	for y in i32(0) ..< size.y {
		for z in i32(0) ..< size.z {
			for x in i32(0) ..< size.x {
				p := lo + {x, y, z}
				got, ok := world.world_get_light(w, p)
				if !ok || world.light_sky(got) != want[box_index(p)] {
					id, _ := world.world_get_block(w, p)
					testing.expectf(t, false, "%s: light at %v (%v) is %d, want %d", what, p, id, world.light_sky(got), want[box_index(p)])
					return false
				}
			}
		}
	}
	return true
}

// A land column in the middle chunk (surface at least 3 above the sea).
@(private = "file")
land_spot :: proc() -> (x, z, h: i32) {
	mid := (RELIGHT_BOX_LO + RELIGHT_BOX_HI) / 2 * 16
	for dz in i32(0) ..< 16 {
		for dx in i32(0) ..< 16 {
			hh := world.terrain_height(RELIGHT_SEED, mid.x + dx, mid.z + dz)
			if hh >= 3 {
				return mid.x + dx, mid.z + dz, hh
			}
		}
	}
	panic("no land in the middle chunk")
}

// A column next to a water column at least 2 deep, across a chunk
// border (x or z) inside the box; h = the column's top (surface or sea).
@(private = "file")
shore_spot :: proc() -> (x, z, h: i32) {
	lo := box_blocks_lo()
	size := box_size()
	for i := i32(16); i < size.x - 1; i += 16 {
		for j in i32(0) ..< size.z {
			for axis in 0 ..< 2 {
				p := lo + ({i, 0, j} if axis == 0 else {j, 0, i}) // p and the column before it straddle a border
				q := p - ({1, 0, 0} if axis == 0 else {0, 0, 1})
				hp := world.terrain_height(RELIGHT_SEED, p.x, p.z)
				hq := world.terrain_height(RELIGHT_SEED, q.x, q.z)
				if hq <= -2 && hp > hq {
					return p.x, p.z, max(hp, world.TERRAIN_SEA_LEVEL)
				}
				if hp <= -2 && hq > hp {
					return q.x, q.z, max(hq, world.TERRAIN_SEA_LEVEL)
				}
			}
		}
	}
	panic("no deep water on a chunk border")
}

@(private = "file")
fill :: proc(w: ^world.World, lo, hi: [3]i32, id: world.Block_ID) {
	for y in lo.y ..= hi.y {
		for z in lo.z ..= hi.z {
			for x in lo.x ..= hi.x {
				world.world_set_block(w, {x, y, z}, id)
			}
		}
	}
}

// Runs the edit scenario used by several tests (each step relit and, if
// `t` is given, compared with the reference).
@(private = "file")
edit_scenario :: proc(w: ^world.World, t: ^testing.T = nil) {
	check :: proc(t: ^testing.T, w: ^world.World, what: string) {
		world.world_update_light(w)
		if t != nil {
			expect_light_matches_reference(t, w, what)
		}
	}
	x, z, h := land_spot()
	// A shaft down from the surface into the ground, with a tunnel at the
	// bottom crossing a chunk border, and a cave room off it.
	fill(w, {x, h - 20, z}, {x, h, z}, world.AIR)
	check(t, w, "shaft")
	fill(w, {x - 18, h - 20, z}, {x, h - 19, z}, world.AIR)
	fill(w, {x - 22, h - 24, z - 3}, {x - 16, h - 19, z + 3}, world.AIR)
	check(t, w, "tunnel and room")
	// A roof over the shaft, spanning chunk borders, then a hole in it.
	fill(w, {x - 9, h + 4, z - 9}, {x + 9, h + 4, z + 9}, world.STONE)
	check(t, w, "roof")
	fill(w, {x - 1, h + 4, z - 1}, {x, h + 4, z}, world.AIR)
	check(t, w, "hole in the roof")
	// See-through and dimming blocks: glass, leaves and water in the shaft.
	fill(w, {x, h - 3, z}, {x, h - 2, z}, world.GLASS)
	fill(w, {x, h - 6, z}, {x, h - 5, z}, world.LEAVES)
	fill(w, {x, h - 10, z}, {x, h - 8, z}, world.WATER)
	check(t, w, "glass, leaves, water")
	// Close the roof again: everything under it goes dark.
	fill(w, {x - 1, h + 4, z - 1}, {x, h + 4, z}, world.STONE)
	check(t, w, "roof closed")
	// A tower and a floating platform up into the open-air chunks above.
	fill(w, {x + 5, h + 5, z}, {x + 5, h + 30, z}, world.STONE)
	fill(w, {x + 2, h + 30, z - 3}, {x + 8, h + 30, z + 3}, world.GLASS)
	fill(w, {x + 3, h + 26, z - 2}, {x + 7, h + 26, z + 2}, world.STONE)
	check(t, w, "tower")
	// A shaft (through sand or water) next to deeper sea across a chunk
	// border: the water beside it lights up, the side that wasn't edited.
	sx, sz, sh := shore_spot()
	fill(w, {sx, -12, sz}, {sx, sh, sz}, world.AIR)
	check(t, w, "shore shaft")
	// Random edits around the surface and in the room.
	r := rand.create(42)
	context.random_generator = rand.default_random_generator(&r)
	ids := [?]world.Block_ID{world.AIR, world.AIR, world.AIR, world.STONE, world.STONE, world.GLASS, world.WATER, world.LEAVES}
	for round in 0 ..< 4 {
		for _ in 0 ..< 40 {
			p := [3]i32{x - 24 + rand.int31_max(32), h - 26 + rand.int31_max(34), z - 12 + rand.int31_max(24)}
			world.world_set_block(w, p, rand.choice(ids[:]))
		}
		check(t, w, "random edits")
		_ = round
	}
}

@(test)
generated_box_matches_reference :: proc(t: ^testing.T) {
	w: world.World
	load_box(&w)
	defer world.world_destroy(&w)
	expect_light_matches_reference(t, &w, "generated")
}

@(test)
relight_matches_reference_after_edits :: proc(t: ^testing.T) {
	w: world.World
	load_box(&w)
	defer world.world_destroy(&w)
	regions := len(w.regions)
	edit_scenario(&w, t)
	testing.expect_value(t, len(w.regions), regions) // nothing outside the box was touched
	testing.expect(t, !world.world_light_pending(&w))
	coords: [dynamic][3]i32
	defer delete(coords)
	box_chunks(&coords)
	mixed := 0
	for c in coords {
		ref, _ := world.world_get_light_ref(&w, c)
		mixed += int(ref.state == .Mixed)
	}
	testing.expect_value(t, w.light_mixed_count, mixed)
}

// Loading the same edited chunks in any order (relighting at random points
// in between) ends with the same light as editing a loaded world; so does
// unloading and reloading a chunk.
@(test)
relight_doesnt_depend_on_load_order :: proc(t: ^testing.T) {
	a: world.World
	load_box(&a)
	defer world.world_destroy(&a)
	edit_scenario(&a)
	encoded: [dynamic]byte
	defer delete(encoded)
	world.edit_log_encode(&a, &encoded)
	want := reference_light(&a)
	defer delete(want)

	coords: [dynamic][3]i32
	defer delete(coords)
	box_chunks(&coords)
	r := rand.create(7)
	context.random_generator = rand.default_random_generator(&r)
	for order in 0 ..< 4 {
		b: world.World
		world.world_init(&b, RELIGHT_SEED)
		defer world.world_destroy(&b)
		testing.expect_value(t, world.edit_log_decode(&b, encoded[:]), world.Decode_Error.None)
		switch order {
		case 0: // bottom up: chunks below load before the roof above them
		case 1: // top down
			for i in 0 ..< len(coords) / 2 {
				coords[i], coords[len(coords) - 1 - i] = coords[len(coords) - 1 - i], coords[i]
			}
		case:
			rand.shuffle(coords[:])
		}
		for c in coords {
			load_chunk(&b, c)
			if rand.int_max(3) == 0 {
				world.world_update_light(&b)
			}
		}
		world.world_update_light(&b)
		if !expect_light_matches_reference(t, &b, "loaded in some order") {
			return
		}
		// Unload and reload the middle chunk (it holds the shaft).
		mid := (RELIGHT_BOX_LO + RELIGHT_BOX_HI) / 2
		world.world_unload_chunk(&b, mid)
		world.world_update_light(&b)
		load_chunk(&b, mid)
		world.world_update_light(&b)
		if !expect_light_matches_reference(t, &b, "reloaded") {
			return
		}
	}
}

// Every chunk whose mesh reads a cell whose light changed is dirty.
@(test)
relight_dirties_affected_chunks :: proc(t: ^testing.T) {
	w: world.World
	load_box(&w)
	defer world.world_destroy(&w)
	x, z, h := land_spot()
	before := reference_light(&w) // = the stored light (tested above)
	defer delete(before)
	coords: [dynamic][3]i32
	defer delete(coords)
	box_chunks(&coords)
	for c in coords {
		world.world_clear_dirty(&w, c)
	}
	// Breaking the surface block on a chunk corner side changes light
	// in several chunks; a roof changes more.
	fill(&w, {x - 9, h + 4, z - 9}, {x + 9, h + 4, z + 9}, world.STONE)
	world.world_update_light(&w)
	changed := 0
	size := box_size()
	lo := box_blocks_lo()
	for y in i32(0) ..< size.y {
		for zz in i32(0) ..< size.z {
			for xx in i32(0) ..< size.x {
				p := lo + {xx, y, zz}
				l, _ := world.world_get_light(&w, p)
				if world.light_sky(l) == before[box_index(p)] {
					continue
				}
				changed += 1
				for dy in i32(-1) ..= 1 {
					for dz in i32(-1) ..= 1 {
						for dx in i32(-1) ..= 1 {
							c := world.block_to_chunk(p + {dx, dy, dz})
							if world.world_get_chunk(&w, c) != nil && !world.world_is_dirty(&w, c) {
								testing.fail_now(t, "a chunk reading a relit cell isn't dirty")
							}
						}
					}
				}
			}
		}
	}
	testing.expect(t, changed > 100)
}

// Light arrays appear only where light changed: breaking a buried block
// (no light reaches it) leaves its all-dark chunk uniform, and an open-air
// chunk far from an edit stays uniform.
@(test)
relight_keeps_untouched_chunks_uniform :: proc(t: ^testing.T) {
	w: world.World
	load_box(&w)
	defer world.world_destroy(&w)
	deep := [3]i32{RELIGHT_BOX_LO.x, RELIGHT_BOX_LO.y, RELIGHT_BOX_LO.z} * 16 + 8 // deep stone, chunk y -2
	ref, _ := world.world_get_light_ref(&w, world.block_to_chunk(deep))
	testing.expect(t, ref.state == .Dark)
	mixed := w.light_mixed_count
	world.world_set_block(&w, deep, world.AIR)
	world.world_update_light(&w)
	ref, _ = world.world_get_light_ref(&w, world.block_to_chunk(deep))
	testing.expect(t, ref.state == .Dark)
	testing.expect_value(t, w.light_mixed_count, mixed)

	sky_chunk := [3]i32{RELIGHT_BOX_LO.x, RELIGHT_BOX_HI.y, RELIGHT_BOX_LO.z}
	ref, _ = world.world_get_light_ref(&w, sky_chunk)
	testing.expect(t, ref.state == .Sky)
	edit_scenario(&w) // near the middle chunk, far from that corner
	ref, _ = world.world_get_light_ref(&w, sky_chunk)
	testing.expect(t, ref.state == .Sky)
}

// Light crosses chunk borders when a chunk loads, in both directions and
// into all-dark (Dark) chunks, even with no edits to trigger a relight:
// an air tunnel in a chunk of stone, opening onto an open-air chunk.
@(test)
chunk_load_spreads_light_across_borders :: proc(t: ^testing.T) {
	// Chunk {0,0,0}: stone with a tunnel along x at y 8, z 8, plus a shaft
	// up from it at x 3 through the top. Its light: Dark (nothing lit).
	make_tunnel :: proc(w: ^world.World) {
		c, _ := world.world_create_chunk(w, {0, 0, 0})
		for &b in c.blocks {
			b = world.STONE
		}
		for x in i32(0) ..< 16 {
			world.chunk_set(c, x, 8, 8, world.AIR)
		}
		for y in i32(8) ..< 16 {
			world.chunk_set(c, 3, y, 8, world.AIR)
		}
		world.world_set_chunk_light(w, {0, 0, 0}, .Dark, nil)
		world.world_light_chunk_loaded(w, {0, 0, 0})
	}
	make_open_air :: proc(w: ^world.World, coord: [3]i32) {
		_, _ = world.world_create_chunk(w, coord)
		world.world_set_chunk_light(w, coord, .Sky, nil)
		world.world_light_chunk_loaded(w, coord)
	}
	sky :: proc(w: ^world.World, p: [3]i32) -> u8 {
		l, _ := world.world_get_light(w, p)
		return world.light_sky(l)
	}
	for order in 0 ..< 2 {
		w: world.World
		world.world_init(&w)
		defer world.world_destroy(&w)
		if order == 0 {
			make_tunnel(&w)
			make_open_air(&w, {1, 0, 0}) // the tunnel's +x end opens here
			make_open_air(&w, {0, 1, 0}) // and the shaft's top
		} else {
			make_open_air(&w, {1, 0, 0})
			make_open_air(&w, {0, 1, 0})
			make_tunnel(&w)
		}
		world.world_update_light(&w)
		// The shaft gets full sky light straight down, the tunnel fades
		// sideways from it and from the open end.
		testing.expect_value(t, sky(&w, {3, 15, 8}), 15)
		testing.expect_value(t, sky(&w, {3, 8, 8}), 15)
		testing.expect_value(t, sky(&w, {0, 8, 8}), 12)
		testing.expect_value(t, sky(&w, {15, 8, 8}), 14)
		testing.expect_value(t, sky(&w, {9, 8, 8}), 9) // from the shaft: 15 - 6
		testing.expect_value(t, sky(&w, {10, 8, 8}), 9) // from the end: 14 - 5
		testing.expect_value(t, sky(&w, {5, 5, 5}), 0) // stone
	}
}
