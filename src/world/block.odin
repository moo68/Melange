package world

Block_ID :: distinct u16

// Placeholder IDs until the block registry grows.
AIR   :: Block_ID(0)
STONE :: Block_ID(1)
DIRT  :: Block_ID(2)
GRASS :: Block_ID(3)

// Load-bearing: region memory comes from the OS zero-filled, so untouched
// blocks read as 0. AIR must be 0 for that to mean "empty".
#assert(AIR == 0)

@(rodata)
BLOCK_NAMES := [?]string {
	AIR   = "air",
	STONE = "stone",
	DIRT  = "dirt",
	GRASS = "grass",
}

block_name :: proc "contextless" (id: Block_ID) -> string {
	return BLOCK_NAMES[id] if int(id) < len(BLOCK_NAMES) else "unknown"
}

// Whether this block hides the faces of blocks next to it.
// For now every non-air block is a full opaque cube.
block_is_opaque :: #force_inline proc "contextless" (id: Block_ID) -> bool {
	return id != AIR
}

// ---- Textures -----------------------------------------------------------------
// assets/textures/atlas.png: 16x16 grid of 16x16-pixel tiles, tightly packed.
// Tile index = row * 16 + col, row 0 at the top of the image.

Tile :: distinct u8

TILE_DIRT       :: Tile(0)
TILE_GRASS_SIDE :: Tile(1)
TILE_GRASS_TOP  :: Tile(2)
TILE_STONE      :: Tile(3)
TILE_UNDEFINED  :: Tile(255) // magenta/black checker: missing texture

// Atlas tile for each face of each block. AIR is never meshed.
@(rodata)
BLOCK_TILES := [?][Face]Tile {
	AIR   = {.Pos_X ..= .Neg_Z = TILE_UNDEFINED},
	STONE = {.Pos_X ..= .Neg_Z = TILE_STONE},
	DIRT  = {.Pos_X ..= .Neg_Z = TILE_DIRT},
	GRASS = {
		.Pos_Y = TILE_GRASS_TOP,
		.Neg_Y = TILE_DIRT,
		.Pos_X = TILE_GRASS_SIDE,
		.Neg_X = TILE_GRASS_SIDE,
		.Pos_Z = TILE_GRASS_SIDE,
		.Neg_Z = TILE_GRASS_SIDE,
	},
}

block_tile :: #force_inline proc "contextless" (id: Block_ID, face: Face) -> Tile {
	if int(id) >= len(BLOCK_TILES) {
		return TILE_UNDEFINED
	}
	return BLOCK_TILES[id][face]
}
