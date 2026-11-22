package player

import "melange:geom"
import "melange:prof"
import "melange:world"
import rl "third_party:raylib"

// How far the player can reach to target a block, in blocks (from the eye).
REACH :: 5.0

// The solid block the camera is looking at within REACH, and the face it's
// looking at. Unloaded chunks count as empty.
pick_block :: proc(w: ^world.World, camera: rl.Camera3D) -> (hit: geom.Ray_Hit, ok: bool) {
	prof.scope("pick block")
	return geom.raycast_voxels(camera.position, camera.target - camera.position, REACH, w, world.world_is_solid)
}
