package player

import "melange:geom"
import "melange:world"
import rl "third_party:raylib"

// Seconds between repeated breaks/places while a mouse button is held.
EDIT_REPEAT :: 0.2

// Blocks selectable with keys 1-6 (until there's a hotbar).
@(rodata)
PLACEABLE := [6]world.Block_ID{world.STONE, world.DIRT, world.GRASS, world.GLASS, world.LEAVES, world.WATER}
@(rodata)
PLACEABLE_KEYS := [6]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR, .FIVE, .SIX}

Edit_State :: struct {
	selected:       world.Block_ID, // what right click places
	break_cooldown: f32, // geom.repeat_update state, per button
	place_cooldown: f32,
}

DEFAULT_EDIT_STATE :: Edit_State {
	selected = world.STONE,
}

// Keys 1-6 select a block; left click breaks the targeted block, right
// click places the selected one against the targeted face; both repeat
// every EDIT_REPEAT while held. `hit`/`has_hit` = this frame's pick_block;
// nothing is placed overlapping `keep_clear` (the player's box).
// Returns true if the world changed (re-pick for the outline).
update_block_edit :: proc(e: ^Edit_State, w: ^world.World, hit: geom.Ray_Hit, has_hit: bool, keep_clear: geom.AABB) -> bool {
	for key, i in PLACEABLE_KEYS {
		if rl.IsKeyPressed(key) {
			e.selected = PLACEABLE[i]
		}
	}

	dt := rl.GetFrameTime()
	breaks := geom.repeat_update(&e.break_cooldown, rl.IsMouseButtonPressed(.LEFT), rl.IsMouseButtonDown(.LEFT), dt, EDIT_REPEAT)
	places := geom.repeat_update(&e.place_cooldown, rl.IsMouseButtonPressed(.RIGHT), rl.IsMouseButtonDown(.RIGHT), dt, EDIT_REPEAT)
	if !has_hit {
		return false
	}
	if breaks {
		return world.world_break_block(w, hit) // one edit per frame: break wins
	}
	if places {
		return world.world_place_block(w, hit, e.selected, keep_clear)
	}
	return false
}
