package main

import "core:fmt"
import "core:math"
import "melange:geom"
import "melange:player"
import "melange:prof"
import "melange:render"
import "melange:world"
import rl "third_party:raylib"
import "third_party:raylib/rlgl"

// Written by `./run.sh profile` builds (-define:PROFILE=true); open it in Spall.
TRACE_PATH :: "build/trace.spall"

main :: proc() {
	opts, ok := parse_args()
	if !ok {
		return
	}

	if !prof.init(TRACE_PATH) {
		fmt.eprintln("failed to create", TRACE_PATH)
		return
	}
	defer prof.shutdown()
	when prof.ENABLED {
		fmt.println("profiling: recording to", TRACE_PATH)
		defer fmt.println("profiling: trace written to", TRACE_PATH)
	}

	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT, .MSAA_4X_HINT})
	rl.InitWindow(1280, 720, "Melange")
	defer rl.CloseWindow()

	w: world.World
	world.world_init(&w, opts.seed)
	defer world.world_destroy(&w)

	r: render.Renderer
	switch render.renderer_init(&r) {
	case .None:
	case .Atlas:
		fmt.eprintln("failed to load", render.ATLAS_PATH, "(run from the project root, e.g. via ./run.sh)")
		return
	case .Shader:
		fmt.eprintln("failed to load chunk shader", render.CHUNK_SHADER_VS, "/", render.CHUNK_SHADER_FS, "(see raylib log above)")
		return
	}
	defer render.renderer_destroy(&r)

	// Loads/unloads chunks around the camera each frame.
	s: world.Streamer
	world.streamer_init(&s)
	defer world.streamer_destroy(&s)

	// Fully fogged just before chunks can be missing, so the world's edge
	// and chunks popping in are never visible.
	fog_end := world.stream_meshed_distance(s.config)
	render.renderer_set_fog(&r, fog_end * 0.55, fog_end)

	// TEMPORARY: free-fly camera until real player movement exists.
	// Mouse look, WASD move, Space/Ctrl up/down, Shift sprint.
	camera := rl.Camera3D {
		position   = {0, 50, 0},
		target     = {20, 40, 20},
		up         = {0, 1, 0},
		fovy       = 70,
		projection = .PERSPECTIVE,
	}
	rl.DisableCursor()
	ignore_mouse_frames := 2 // see update_fly_camera
	wireframe := false
	// F2 freezes the culling frustum at the current camera so you can fly out
	// and see which chunks are being culled.
	cull_frozen := false
	frustum: geom.Frustum
	edit := player.DEFAULT_EDIT_STATE

	for frame := 0; !rl.WindowShouldClose(); frame += 1 {
		if opts.frames > 0 && frame >= opts.frames {
			break
		}
		prof.scope("frame")
		player.update_fly_camera(&camera, ignore_mouse_frames == 0)
		ignore_mouse_frames = max(ignore_mouse_frames - 1, 0)
		if rl.IsKeyPressed(.F1) {
			wireframe = !wireframe
		}
		if rl.IsKeyPressed(.F2) {
			cull_frozen = !cull_frozen
		}
		if !cull_frozen {
			frustum = render.camera_frustum(camera)
		}

		// Edit before meshing, so changes show this frame; re-pick so the
		// outline moves to whatever is now targeted.
		target, has_target := player.pick_block(&w, camera)
		if player.update_block_edit(&edit, &w, camera, target, has_target) {
			target, has_target = player.pick_block(&w, camera)
		}

		p := camera.position
		center := world.block_to_chunk({i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))})
		if err := world.streamer_update(&s, &w, center); err != nil {
			fmt.eprintln("chunk streaming failed:", err)
			return
		}
		render.renderer_forget_chunks(&r, s.unloaded[:])
		render.renderer_update(&r, &w, center)

		rl.BeginDrawing()
		rl.ClearBackground(render.SKY_COLOR)

		rl.BeginMode3D(camera)
		if wireframe {
			rlgl.EnableWireMode()
		}
		render.renderer_draw(&r, &frustum, camera.position)
		if wireframe {
			rlgl.DisableWireMode()
		}
		if has_target {
			render.draw_block_outline(target.block)
		}
		rl.EndMode3D()

		render.draw_crosshair()
		render.draw_debug_overlay(&r, &w, &s, camera, target if has_target else nil, edit.selected, wireframe, cull_frozen)
		{
			// Swaps buffers: includes the vsync wait and any GPU sync.
			prof.scope("EndDrawing")
			rl.EndDrawing()
		}
	}
}
