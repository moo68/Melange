package player

import "core:math"
import "melange:geom"
import "melange:prof"
import "melange:world"
import rl "third_party:raylib"

// WASD walk (normalized: diagonals aren't faster), Shift sprint, Left Ctrl
// crouch (slower, lower eye, won't walk off edges; beats sprint), Space jump
// (held: jumps again on landing). In water: swim (see geom.WATER_CONTROL),
// Space up, Left Ctrl down faster. Physics runs in fixed 60 Hz steps;
// the camera interpolates between the last two.
update_walk :: proc(p: ^Player, w: ^world.World) {
	prof.scope("player physics")
	// Wait for the ground: the player's chunk and the one below must exist
	// before simulating (unloaded chunks are solid, so without this a
	// player could stand on not-yet-generated air).
	feet := p.body.position
	here := world.block_to_chunk({i32(math.floor(feet.x)), i32(math.floor(feet.y)), i32(math.floor(feet.z))})
	p.waiting = world.world_get_chunk(w, here) == nil || world.world_get_chunk(w, here - {0, 1, 0}) == nil
	if p.waiting {
		p.accumulator = 0
		p.prev_feet = p.body.position
		p.prev_eye_height = p.eye_height
		p.alpha = 0
		return
	}

	forward, right := geom.look_basis(p.yaw)
	axis :: proc(pos, neg: rl.KeyboardKey) -> f64 {
		return f64(int(rl.IsKeyDown(pos))) - f64(int(rl.IsKeyDown(neg)))
	}
	f, r := axis(.W, .S), axis(.D, .A)
	input := geom.Body_Input {
		wish   = {f64(forward.x) * f + f64(right.x) * r, f64(forward.z) * f + f64(right.z) * r},
		jump   = rl.IsKeyDown(.SPACE),
		sprint = rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT),
		crouch = rl.IsKeyDown(.LEFT_CONTROL),
	}

	steps, alpha := geom.fixed_steps(&p.accumulator, f64(rl.GetFrameTime()))
	for _ in 0 ..< steps {
		p.prev_feet = p.body.position
		p.prev_eye_height = p.eye_height
		p.eye_height = geom.eye_height_step(p.eye_height, input.crouch, geom.PHYSICS_DT)
		geom.body_step(&p.body, input, geom.PHYSICS_DT, w, world.world_blocks_movement, world.world_fluid_top)
	}
	p.alpha = alpha
}
