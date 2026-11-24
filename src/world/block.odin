package world

Block_ID :: distinct u16

// Placeholder IDs until the block registry grows.
AIR   :: Block_ID(0)
STONE :: Block_ID(1)
DIRT  :: Block_ID(2)
GRASS :: Block_ID(3)
GLASS :: Block_ID(4)
LEAVES :: Block_ID(5)

// Load-bearing: region memory comes from the OS zero-filled, so untouched
// blocks read as 0. AIR must be 0 for that to mean "empty".
#assert(AIR == 0)

@(rodata)
BLOCK_NAMES := [?]string {
	AIR   = "air",
	STONE = "stone",
	DIRT  = "dirt",
	GRASS = "grass",
	GLASS = "glass",
	LEAVES = "leaves",
}

block_name :: proc "contextless" (id: Block_ID) -> string {
	return BLOCK_NAMES[id] if int(id) < len(BLOCK_NAMES) else "unknown"
}

// ---- Properties -----------------------------------------------------------------

// Which mesh (and shader) a block's faces go into.
Block_Render :: enum u8 {
	None, // never meshed (air)
	Opaque, // fully opaque texture
	Cutout, // texels are either opaque or fully clear (glass, leaves): alpha-tested, no sorting
}

Block_Flag :: enum u8 {
	Opaque, // a full opaque cube: faces of any block against it are culled
	Casts_AO, // darkens the AO of faces next to it
	Solid, // stops movement and is hit by block picking
	// Faces between two of this block are culled (glass: a wall reads as one
	// pane). Without it they're drawn (leaves: trees look full).
	Cull_Same,
}
Block_Flags :: bit_set[Block_Flag; u8]

Block_Props :: struct {
	render: Block_Render,
	flags:  Block_Flags, // one byte, so the mesher can copy it per cell
}

OPAQUE_CUBE :: Block_Props{.Opaque, {.Opaque, .Casts_AO, .Solid, .Cull_Same}}

@(rodata)
BLOCK_PROPS := [?]Block_Props {
	AIR    = {},
	STONE  = OPAQUE_CUBE,
	DIRT   = OPAQUE_CUBE,
	GRASS  = OPAQUE_CUBE,
	GLASS  = {.Cutout, {.Solid, .Cull_Same}},
	LEAVES = {.Cutout, {.Casts_AO, .Solid}},
}

// Unknown IDs (e.g. from a newer save) are shown as opaque cubes with the
// missing texture.
block_props :: #force_inline proc "contextless" (id: Block_ID) -> Block_Props {
	return BLOCK_PROPS[id] if int(id) < len(BLOCK_PROPS) else OPAQUE_CUBE
}

block_flags :: #force_inline proc "contextless" (id: Block_ID) -> Block_Flags {
	return block_props(id).flags
}

// A full opaque cube: hides the faces of blocks next to it.
block_is_opaque :: #force_inline proc "contextless" (id: Block_ID) -> bool {
	return .Opaque in block_flags(id)
}

// Stops movement and is hit by block picking.
block_is_solid :: #force_inline proc "contextless" (id: Block_ID) -> bool {
	return .Solid in block_flags(id)
}

// Whether a face of `id` toward `neighbor` is visible (emitted when meshing).
// Air has no faces.
face_visible :: #force_inline proc "contextless" (id, neighbor: Block_ID) -> bool {
	p := block_props(id)
	if p.render == .None {
		return false
	}
	if .Opaque in block_flags(neighbor) {
		return false
	}
	return !(neighbor == id && .Cull_Same in p.flags)
}

// ---- Textures -----------------------------------------------------------------
// assets/textures/atlas.png: 16x16 grid of 16x16-pixel tiles, tightly packed.
// Tile index = row * 16 + col, row 0 at the top of the image.

Tile :: distinct u8

TILE_DIRT       :: Tile(0)
TILE_GRASS_SIDE :: Tile(1)
TILE_GRASS_TOP  :: Tile(2)
TILE_STONE      :: Tile(3)
TILE_GLASS      :: Tile(4)
TILE_LEAVES     :: Tile(5)
TILE_UNDEFINED  :: Tile(255) // magenta/black checker: missing texture

// Atlas tile for each face of each block. AIR is never meshed.
@(rodata)
BLOCK_TILES := [?][Face]Tile {
	AIR   = {.Pos_X ..= .Neg_Z = TILE_UNDEFINED},
	STONE = {.Pos_X ..= .Neg_Z = TILE_STONE},
	DIRT  = {.Pos_X ..= .Neg_Z = TILE_DIRT},
	GLASS  = {.Pos_X ..= .Neg_Z = TILE_GLASS},
	LEAVES = {.Pos_X ..= .Neg_Z = TILE_LEAVES},
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
