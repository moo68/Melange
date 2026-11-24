package tests

import "core:math/linalg"
import "core:testing"
import "melange:geom"
import "melange:mesh"
import "melange:world"

@(test)
water_properties :: proc(t: ^testing.T) {
	p := world.block_props(world.WATER)
	testing.expect_value(t, p.render, world.Block_Render.Translucent)
	testing.expect_value(t, p.flags, world.Block_Flags{.Cull_Same, .Replaceable, .Fluid})
	testing.expect_value(t, mesh.block_pass(world.WATER), mesh.Pass.Translucent)
	testing.expect_value(t, world.block_tile(world.WATER, .Pos_Y), world.TILE_WATER)
	testing.expect_value(t, mesh.tile_coords(world.TILE_WATER), [2]f32{6, 0})
	testing.expect_value(t, world.block_top(world.WATER, world.AIR), world.FLUID_SURFACE)
	testing.expect_value(t, world.block_top(world.WATER, world.STONE), world.FLUID_SURFACE)
	testing.expect_value(t, world.block_top(world.WATER, world.WATER), 1)
	testing.expect_value(t, world.block_top(world.STONE, world.AIR), 1)
	testing.expect_value(t, world.FLUID_SURFACE, 0.875)
}

@(test)
face_extent_rules :: proc(t: ^testing.T) {
	W, A, S, G, LV := world.WATER, world.AIR, world.STONE, world.GLASS, world.LEAVES
	L :: world.FLUID_SURFACE
	cases := []struct {
		id, neighbor, above, neighbor_above: world.Block_ID,
		face:                                world.Face,
		visible:                             bool,
		lo, hi:                              f32,
	} {
		// Sides toward air: lowered unless water is above.
		{W, A, A, A, .Pos_X, true, 0, L},
		{W, A, W, A, .Pos_X, true, 0, 1},
		{W, A, S, A, .Neg_Z, true, 0, L}, // a solid block above doesn't raise it
		// Toward water: only where taller than the neighbor.
		{W, W, A, A, .Pos_X, false, 0, 0}, // flat surface: no faces between
		{W, W, W, W, .Pos_X, false, 0, 0}, // both full
		{W, W, W, A, .Pos_X, true, L, 1}, // full next to lowered: the strip
		{W, W, A, W, .Pos_X, false, 0, 0}, // lowered next to full: nothing
		// Toward opaque: hidden. Toward glass / leaves: drawn in their face
		// plane (an aquarium shows its water; the renderer's polygon offset
		// keeps it from z-fighting).
		{W, S, A, A, .Pos_X, false, 0, 0},
		{W, G, A, A, .Pos_X, true, 0, L},
		{W, LV, A, A, .Neg_Z, true, 0, L},
		{W, G, W, A, .Pos_X, true, 0, 1},
		// Top: a lowered top always shows (gap under anything), except under water.
		{W, A, A, A, .Pos_Y, true, L, L},
		{W, S, S, A, .Pos_Y, true, L, L},
		{W, G, G, A, .Pos_Y, true, L, L},
		{W, W, W, A, .Pos_Y, false, 0, 0},
		// Bottom.
		{W, A, A, A, .Neg_Y, true, 0, 0},
		{W, S, A, A, .Neg_Y, false, 0, 0},
		{W, G, A, A, .Neg_Y, true, 0, 0},
		{W, LV, A, A, .Neg_Y, true, 0, 0},
		{W, W, A, A, .Neg_Y, false, 0, 0},
		// Other blocks are full height and see water as see-through (the
		// glass / leaves face toward water is the one that's drawn).
		{S, W, A, A, .Pos_X, true, 0, 1},
		{G, W, A, A, .Pos_X, true, 0, 1},
		{LV, W, A, A, .Neg_Y, true, 0, 1},
		{S, W, A, A, .Pos_Y, true, 0, 1},
	}
	for c in cases {
		lo, hi, visible := world.face_extent(c.id, c.neighbor, c.above, c.neighbor_above, c.face)
		testing.expectf(t, visible == c.visible, "%v %v toward %v (above %v / %v): visible %v", world.block_name(c.id), c.face, world.block_name(c.neighbor), world.block_name(c.above), world.block_name(c.neighbor_above), visible)
		if c.visible && visible {
			testing.expectf(t, lo == c.lo && hi == c.hi, "%v %v toward %v: extent %v..%v, want %v..%v", world.block_name(c.id), c.face, world.block_name(c.neighbor), lo, hi, c.lo, c.hi)
		}
	}
}

// The 4 corner positions a face of the block at `pos` with extent lo..hi
// should have, in emission order.
expected_corners :: proc(pos: [3]i32, face: world.Face, lo, hi: f32) -> (out: [4][3]f32) {
	for corner, i in mesh.FACE_CORNERS[face] {
		c := corner
		c.y = lo if corner.y == 0 else hi
		out[i] = linalg.array_cast(pos, f32) + c
	}
	return
}

has_quad :: proc(m: ^mesh.Mesh_Data, corners: [4][3]f32) -> bool {
	for f in 0 ..< mesh.face_count(m) {
		if vpos(m, f * 4) == corners[0] && vpos(m, f * 4 + 1) == corners[1] && vpos(m, f * 4 + 2) == corners[2] && vpos(m, f * 4 + 3) == corners[3] {
			return true
		}
	}
	return false
}

@(test)
single_water_block :: proc(t: ^testing.T) {
	// Stone diagonally above: would darken the top's AO if water had AO.
	cm := mesh_blocks({{{5, 5, 5}, world.WATER}, {{6, 6, 5}, world.STONE}})
	defer mesh.chunk_mesh_destroy(&cm)
	m := &cm[.Translucent]
	testing.expect_value(t, mesh.face_count(m), 6)
	testing.expect_value(t, mesh.face_count(&cm[.Cutout]), 0)
	for face in world.Face {
		lo, hi: f32 = 0, world.FLUID_SURFACE
		if face == .Pos_Y {
			lo = hi
		} else if face == .Neg_Y {
			hi = 0
		}
		testing.expectf(t, has_quad(m, expected_corners({5, 5, 5}, face, lo, hi)), "%v face at %v..%v", face, lo, hi)
	}
	for v in 0 ..< len(m.vertices) {
		face: world.Face
		for f in world.Face {
			if vnormal(m, v) == linalg.array_cast(world.FACE_NORMALS[f], f32) {
				face = f
			}
		}
		testing.expectf(t, vbright(m, v) == u8(mesh.FACE_SHADE[face]), "water has no AO: %v", vbright(m, v))
		// Side faces: the texture is cut, not squashed (v follows the height).
		if face != .Pos_Y && face != .Neg_Y {
			testing.expect_value(t, vuv(m, v).y, 1 - (vpos(m, v).y - 5))
		}
	}
	expect_ccw(t, m)
	// The stone's faces toward the water's open sides are unaffected (opaque pass).
	testing.expect_value(t, mesh.face_count(&cm[.Opaque]), 6)
}

// A water block stacked on a lake surface: the full block under it shows a
// strip above its lowered neighbors, so there's never a gap.
@(test)
stacked_water_has_no_gap :: proc(t: ^testing.T) {
	cm := mesh_blocks({{{5, 5, 5}, world.WATER}, {{5, 6, 5}, world.WATER}, {{6, 5, 5}, world.WATER}})
	defer mesh.chunk_mesh_destroy(&cm)
	m := &cm[.Translucent]
	L := world.FLUID_SURFACE
	testing.expect(t, has_quad(m, expected_corners({5, 5, 5}, .Pos_X, L, 1)), "strip on the full block toward its lowered neighbor")
	testing.expect(t, !has_quad(m, expected_corners({5, 5, 5}, .Pos_Y, 1, 1)), "no top under water")
	testing.expect(t, !has_quad(m, expected_corners({5, 5, 5}, .Pos_Y, L, L)), "no lowered top under water")
	testing.expect(t, has_quad(m, expected_corners({6, 5, 5}, .Pos_Y, L, L)), "lowered neighbor's top")
	testing.expect(t, has_quad(m, expected_corners({5, 6, 5}, .Pos_Y, L, L)), "top block lowered")
	testing.expect(t, has_quad(m, expected_corners({5, 5, 5}, .Neg_X, 0, 1)), "full side toward air")
	expect_ccw(t, m)
}

// The mesher agrees with world.face_extent on random scenes.
@(test)
mesher_matches_face_extent :: proc(t: ^testing.T) {
	ids := [5]world.Block_ID{world.AIR, world.WATER, world.STONE, world.GLASS, world.LEAVES}
	state := u32(777)
	next :: proc(s: ^u32) -> u32 {
		s^ = s^ * 1664525 + 1013904223
		return s^ >> 16
	}
	for _ in 0 ..< 40 {
		c := new(world.Chunk)
		defer free(c)
		for y in i32(2) ..< 8 {
			for z in i32(2) ..< 8 {
				for x in i32(2) ..< 8 {
					// Mostly water, so water meets water at many heights.
					world.chunk_set(c, x, y, z, ids[next(&state) % 5] if next(&state) % 3 == 0 else world.WATER)
				}
			}
		}
		cm: mesh.Chunk_Mesh
		defer mesh.chunk_mesh_destroy(&cm)
		mesh.build_chunk_mesh(c, &no_neighbors, &cm)
		m := &cm[.Translucent]
		want := 0
		for y in i32(2) ..< 8 {
			for z in i32(2) ..< 8 {
				for x in i32(2) ..< 8 {
					if world.chunk_get(c, x, y, z) != world.WATER {
						continue
					}
					get :: proc(c: ^world.Chunk, p: [3]i32) -> world.Block_ID {
						if p.x < 0 || p.y < 0 || p.z < 0 || p.x > 15 || p.y > 15 || p.z > 15 {
							return world.AIR
						}
						return world.chunk_get(c, p.x, p.y, p.z)
					}
					p := [3]i32{x, y, z}
					up := [3]i32{0, 1, 0}
					for face in world.Face {
						np := p + world.FACE_NORMALS[face]
						lo, hi, visible := world.face_extent(world.WATER, get(c, np), get(c, p + up), get(c, np + up), face)
						if visible {
							want += 1
							if !has_quad(m, expected_corners(p, face, lo, hi)) {
								testing.fail_now(t, "a visible water face is missing from the mesh")
							}
						}
					}
				}
			}
		}
		testing.expect_value(t, mesh.face_count(m), want)
	}
}

// Water isn't solid: rays and bodies pass through, and placing replaces it.
@(test)
water_in_the_world :: proc(t: ^testing.T) {
	w: world.World
	make_flat_world(&w)
	defer world.world_destroy(&w)
	for y in i32(32) ..< 35 {
		testing.expect(t, world.world_set_block(&w, {5, y, 5}, world.WATER))
	}
	testing.expect(t, !world.world_is_solid(&w, {5, 33, 5}))
	testing.expect(t, !world.world_blocks_movement(&w, {5, 33, 5}))
	// The ray from above goes through the water to the floor.
	hit, ok := cast_down(&w, 5.5, 5.5)
	testing.expect(t, ok)
	testing.expect_value(t, hit.block, [3]i32{5, 31, 5})
	far_away := geom.body_box({100, 100, 100})
	// Placing on the floor goes into the water cell above it, replacing it.
	testing.expect(t, world.world_place_block(&w, hit, world.STONE, far_away))
	id, _ := world.world_get_block(&w, {5, 32, 5})
	testing.expect_value(t, id, world.STONE)
	// Placing water into solid ground is still refused.
	testing.expect(t, !world.world_place_block(&w, {block = {5, 30, 5}, normal = {0, 1, 0}, dist = 1}, world.WATER, far_away))
	// A body falls through water (no swimming yet) and lands on the stone.
	b := geom.Body{position = {5.5, 40, 5.5}}
	for _ in 0 ..< 180 {
		geom.body_step(&b, {}, geom.PHYSICS_DT, &w, world.world_blocks_movement)
	}
	testing.expect(t, b.on_ground)
	testing.expectf(t, abs(b.position.y - 33) < 0.01, "landed on the placed stone: %v", b.position.y)
}

@(test)
translucent_chunks_sort_far_first :: proc(t: ^testing.T) {
	cam := [3]f32{8, 8, 8} // center of chunk 0
	testing.expect_value(t, world.chunk_center_dist2({0, 0, 0}, cam), 0)
	testing.expect_value(t, world.chunk_center_dist2({1, 0, 0}, cam), 256)
	testing.expect_value(t, world.chunk_center_dist2({-1, -1, 0}, cam), 512)
	items := []world.Chunk_Distance {
		{{0, 0, 0}, world.chunk_center_dist2({0, 0, 0}, cam)},
		{{3, 0, 0}, world.chunk_center_dist2({3, 0, 0}, cam)},
		{{-1, 1, 0}, world.chunk_center_dist2({-1, 1, 0}, cam)},
		{{0, 0, -2}, world.chunk_center_dist2({0, 0, -2}, cam)},
	}
	world.sort_far_first(items)
	want := [4][3]i32{{3, 0, 0}, {0, 0, -2}, {-1, 1, 0}, {0, 0, 0}}
	for item, i in items {
		testing.expect_value(t, item.coord, want[i])
	}
}

// No water face may lie in the same plane as, and overlap, an opaque face:
// water against opaque blocks is culled (only glass / leaves faces may share
// a water face's plane; the renderer's polygon offset handles those).
@(test)
water_never_overlaps_coplanar_faces :: proc(t: ^testing.T) {
	ids := [6]world.Block_ID{world.AIR, world.WATER, world.STONE, world.GLASS, world.LEAVES, world.WATER}
	state := u32(4242)
	next :: proc(s: ^u32) -> u32 {
		s^ = s^ * 1664525 + 1013904223
		return s^ >> 16
	}
	Rect :: struct {
		axis:     int,
		plane:    f32,
		lo, hi:   [2]f32,
	}
	rect_of :: proc(m: ^mesh.Mesh_Data, f: int) -> (r: Rect) {
		n := vnormal(m, f * 4)
		r.axis = 0 if n.x != 0 else (1 if n.y != 0 else 2)
		r.plane = vpos(m, f * 4)[r.axis]
		r.lo, r.hi = {max(f32), max(f32)}, {min(f32), min(f32)}
		for v in 0 ..< 4 {
			p := vpos(m, f * 4 + v)
			a, b := p[(r.axis + 1) % 3], p[(r.axis + 2) % 3]
			r.lo = {min(r.lo.x, a), min(r.lo.y, b)}
			r.hi = {max(r.hi.x, a), max(r.hi.y, b)}
		}
		return
	}
	for _ in 0 ..< 40 {
		c := new(world.Chunk)
		defer free(c)
		for y in i32(2) ..< 8 {
			for z in i32(2) ..< 8 {
				for x in i32(2) ..< 8 {
					world.chunk_set(c, x, y, z, ids[next(&state) % 6])
				}
			}
		}
		cm: mesh.Chunk_Mesh
		defer mesh.chunk_mesh_destroy(&cm)
		mesh.build_chunk_mesh(c, &no_neighbors, &cm)
		water := &cm[.Translucent]
		testing.expect(t, mesh.face_count(water) > 0, "scene has water faces")
		for other_pass in ([]mesh.Pass{.Opaque}) {
			other := &cm[other_pass]
			for wf in 0 ..< mesh.face_count(water) {
				a := rect_of(water, wf)
				for of in 0 ..< mesh.face_count(other) {
					b := rect_of(other, of)
					if a.axis == b.axis && a.plane == b.plane && a.lo.x < b.hi.x && b.lo.x < a.hi.x && a.lo.y < b.hi.y && b.lo.y < a.hi.y {
						testing.fail_now(t, "a water face overlaps a coplanar opaque face")
					}
				}
			}
		}
	}
}

// An aquarium: water behind a glass wall is drawn exactly in the glass's
// face plane (no gap around submerged glass), and so is the glass face
// toward the water.
@(test)
aquarium_water_shows_through_glass :: proc(t: ^testing.T) {
	cm := mesh_blocks({{{5, 5, 5}, world.WATER}, {{6, 5, 5}, world.GLASS}, {{5, 4, 5}, world.GLASS}})
	defer mesh.chunk_mesh_destroy(&cm)
	water := &cm[.Translucent]
	L := world.FLUID_SURFACE
	testing.expect(t, has_quad(water, expected_corners({5, 5, 5}, .Pos_X, 0, L)), "side toward the glass wall, in its plane")
	testing.expect(t, has_quad(water, expected_corners({5, 5, 5}, .Neg_Y, 0, 0)), "bottom on the glass floor, in its plane")
	testing.expect_value(t, mesh.face_count(water), 6)
	_, ok := find_face(&cm[.Cutout], {6, 5, 5}, .Neg_X)
	testing.expect(t, ok, "the glass face toward the water")
	expect_ccw(t, water)
}
