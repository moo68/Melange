package render

import rl "third_party:raylib"

// Slightly larger than a block so the lines sit just outside its faces
// instead of z-fighting with the block's own edges.
OUTLINE_SCALE :: 1.002
OUTLINE_COLOR :: rl.Color{0, 0, 0, 220}

// Wireframe box around the targeted block. Call between BeginMode3D /
// EndMode3D, after the chunks: depth-tested, so edges behind other blocks
// stay hidden.
draw_block_outline :: proc(block: [3]i32) {
	center := [3]f32{f32(block.x), f32(block.y), f32(block.z)} + 0.5
	rl.DrawCubeWires(center, OUTLINE_SCALE, OUTLINE_SCALE, OUTLINE_SCALE, OUTLINE_COLOR)
}
