package tests

import "core:testing"
import "melange:mesh"
import "melange:world"

@(test)
tile_coords_are_row_major :: proc(t: ^testing.T) {
	// Tile 0 is top-left, 1 is right of it, 16 is below it, 255 bottom-right.
	testing.expect_value(t, mesh.tile_coords(0), [2]f32{0, 0})
	testing.expect_value(t, mesh.tile_coords(1), [2]f32{1, 0})
	testing.expect_value(t, mesh.tile_coords(16), [2]f32{0, 1})
	testing.expect_value(t, mesh.tile_coords(255), [2]f32{15, 15})
}

// Mesh a single block and check, per face: all 4 vertices name the expected
// tile; the in-tile positions are exactly the tile's 4 corners (no inset, so
// the whole 16x16 texture is shown); and side tiles are upright (top
// vertices, y = 1, use the top of the tile, v = 0).
expect_block_tiles :: proc(t: ^testing.T, id: world.Block_ID, expected: [world.Face]world.Tile) {
	c := new(world.Chunk)
	defer free(c)
	world.chunk_set(c, 4, 4, 4, id)
	cm: mesh.Chunk_Mesh
	defer mesh.chunk_mesh_destroy(&cm)
	m := &cm[.Opaque]
	mesh.build_chunk_mesh(c, &no_neighbors, &cm)
	testing.expect_value(t, mesh.face_count(m), 6)

	for f in 0 ..< mesh.face_count(m) {
		n := vnormal(m, f * 4)
		face: world.Face
		for candidate in world.Face {
			fn := world.FACE_NORMALS[candidate]
			candidate_normal := [3]f32{f32(fn.x), f32(fn.y), f32(fn.z)}
			if candidate_normal == n {
				face = candidate
			}
		}
		seen: [4]bool // which of the 4 tile corners appear
		for v in f * 4 ..< f * 4 + 4 {
			testing.expectf(t, vtile(m, v) == mesh.tile_coords(expected[face]), "block %v face %v: wrong tile %v", id, face, vtile(m, v))
			uv := vuv(m, v)
			testing.expectf(t, (uv.x == 0 || uv.x == 1) && (uv.y == 0 || uv.y == 1), "block %v face %v: uv %v not a tile corner", id, face, uv)
			seen[int(uv.x) + 2 * int(uv.y)] = true
			if face != .Pos_Y && face != .Neg_Y {
				is_top := vpos(m, v).y > 4.5
				testing.expectf(t, (uv.y == 0) == is_top, "block %v face %v: tile is upside down", id, face)
			}
		}
		testing.expectf(t, seen == {true, true, true, true}, "block %v face %v: doesn't cover the whole tile", id, face)
	}
}

@(test)
grass_uses_top_side_bottom_tiles :: proc(t: ^testing.T) {
	expect_block_tiles(
		t,
		world.GRASS,
		{
			.Pos_Y = world.TILE_GRASS_TOP,
			.Neg_Y = world.TILE_DIRT,
			.Pos_X = world.TILE_GRASS_SIDE,
			.Neg_X = world.TILE_GRASS_SIDE,
			.Pos_Z = world.TILE_GRASS_SIDE,
			.Neg_Z = world.TILE_GRASS_SIDE,
		},
	)
}

@(test)
stone_and_dirt_use_one_tile :: proc(t: ^testing.T) {
	expect_block_tiles(t, world.STONE, {.Pos_X ..= .Neg_Z = world.TILE_STONE})
	expect_block_tiles(t, world.DIRT, {.Pos_X ..= .Neg_Z = world.TILE_DIRT})
}

@(test)
unknown_block_uses_undefined_tile :: proc(t: ^testing.T) {
	expect_block_tiles(t, world.Block_ID(9999), {.Pos_X ..= .Neg_Z = world.TILE_UNDEFINED})
}

// Every real block must have a texture on every face.
@(test)
registry_has_no_missing_textures :: proc(t: ^testing.T) {
	for tiles, id in world.BLOCK_TILES {
		if world.Block_ID(id) == world.AIR {
			continue
		}
		for tile, face in tiles {
			testing.expectf(t, tile != world.TILE_UNDEFINED, "block %d face %v has no texture", id, face)
		}
	}
}
