package world

Block_ID :: distinct u16

// Placeholder IDs until the block registry grows.
AIR   :: Block_ID(0)
STONE :: Block_ID(1)
DIRT  :: Block_ID(2)
GRASS :: Block_ID(3)
GLASS :: Block_ID(4)
LEAVES :: Block_ID(5)
WATER :: Block_ID(6)
SAND :: Block_ID(7)

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
	WATER = "water",
	SAND = "sand",
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
	Translucent, // alpha-blended (water): drawn last, back to front, no depth writes
}

Block_Flag :: enum u8 {
	Opaque, // a full opaque cube: faces of any block against it are culled
	Casts_AO, // darkens the AO of faces next to it
	Solid, // stops movement and is hit by block picking
	// Faces between two of this block are culled (glass: a wall reads as one
	// pane). Without it they're drawn (leaves: trees look full).
	Cull_Same,
	// Placing a block into this one replaces it (water).
	Replaceable,
	// Its top is lowered to FLUID_SURFACE unless the same block is above it
	// (Minecraft's still water). See face_extent.
	Fluid,
}
Block_Flags :: bit_set[Block_Flag; u8]

Block_Props :: struct {
	render: Block_Render,
	flags:  Block_Flags, // one byte, so the mesher can copy it per cell
	// How much light fades entering this block (light.odin): 0 clear,
	// 1 = water / leaves, MAX_LIGHT = opaque (holds no light).
	light_filter: u8,
}

OPAQUE_CUBE :: Block_Props{.Opaque, {.Opaque, .Casts_AO, .Solid, .Cull_Same}, MAX_LIGHT}

@(rodata)
BLOCK_PROPS := [?]Block_Props {
	AIR    = {},
	STONE  = OPAQUE_CUBE,
	DIRT   = OPAQUE_CUBE,
	GRASS  = OPAQUE_CUBE,
	GLASS  = {.Cutout, {.Solid, .Cull_Same}, 0},
	LEAVES = {.Cutout, {.Casts_AO, .Solid}, 1},
	WATER  = {.Translucent, {.Cull_Same, .Replaceable, .Fluid}, 1},
	SAND   = OPAQUE_CUBE,
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

// Whether a face of `id` toward `neighbor` is visible (emitted when meshing),
// ignoring fluid heights (see face_extent). Air has no faces.
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

// Height of a fluid's lowered top surface: 14/16 (Minecraft's still water is ~0.89).
FLUID_SURFACE :: f32(0.875)

// Height of the top of `id` with `above` on top of it: FLUID_SURFACE for a
// fluid without the same fluid above, else 1.
block_top :: #force_inline proc "contextless" (id, above: Block_ID) -> f32 {
	if .Fluid in block_flags(id) && above != id {
		return FLUID_SURFACE
	}
	return 1
}

// The visible part of face `face` of block `id`, whose neighbor across that
// face is `neighbor`: its vertical extent [lo, hi] within the block (side
// faces; top and bottom faces sit at hi and lo). `above` is the block above
// `id`, `neighbor_above` the block above `neighbor` (fluid heights).
//   - Not fluids: face_visible, full height.
//   - A lowered fluid top is always visible: there's a gap under whatever is
//     above it, even an opaque block.
//   - A fluid side toward the same fluid shows only where it's taller than
//     the neighbor (a full block next to a lowered one: the strip
//     FLUID_SURFACE..1), so stacked water never shows a gap.
//   - Fluid sides and bottoms against a see-through Solid block (glass,
//     leaves) are drawn in that block's face plane, so an aquarium shows its
//     water. The two coplanar faces would z-fight (fluids are drawn
//     double-sided); the renderer draws the translucent pass with a polygon
//     offset so the other block's face always wins (render.renderer_draw).
//     Hiding the fluid face made aquarium water invisible; pushing it into
//     the fluid left visible gaps around submerged glass.
face_extent :: proc "contextless" (id, neighbor, above, neighbor_above: Block_ID, face: Face) -> (lo, hi: f32, visible: bool) {
	if .Fluid not_in block_flags(id) {
		return 0, 1, face_visible(id, neighbor)
	}
	top := block_top(id, above)
	switch face {
	case .Pos_Y:
		return top, top, top < 1 || face_visible(id, neighbor)
	case .Neg_Y:
		return 0, 0, face_visible(id, neighbor)
	case .Pos_X, .Neg_X, .Pos_Z, .Neg_Z:
	}
	if .Opaque in block_flags(neighbor) {
		return 0, top, false
	}
	if neighbor == id && .Cull_Same in block_flags(id) {
		n_top := block_top(neighbor, neighbor_above)
		return n_top, top, n_top < top
	}
	return 0, top, true
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
TILE_WATER      :: Tile(6)
TILE_SAND       :: Tile(7)
TILE_UNDEFINED  :: Tile(255) // magenta/black checker: missing texture

// Atlas tile for each face of each block. AIR is never meshed.
@(rodata)
BLOCK_TILES := [?][Face]Tile {
	AIR   = {.Pos_X ..= .Neg_Z = TILE_UNDEFINED},
	STONE = {.Pos_X ..= .Neg_Z = TILE_STONE},
	DIRT  = {.Pos_X ..= .Neg_Z = TILE_DIRT},
	GLASS  = {.Pos_X ..= .Neg_Z = TILE_GLASS},
	LEAVES = {.Pos_X ..= .Neg_Z = TILE_LEAVES},
	WATER  = {.Pos_X ..= .Neg_Z = TILE_WATER},
	SAND   = {.Pos_X ..= .Neg_Z = TILE_SAND},
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
