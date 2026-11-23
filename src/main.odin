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

	// The world and player: from saves/<--world> (or a new save there), or
	// an unsaved world without --world.
	w: world.World
	pl: player.Player
	// F3: debug mode = fly through blocks + the debug overlay.
	debug := false
	sess, opened := session_open(opts, &w, &pl, &debug)
	if !opened {
		return
	}
	defer world.world_destroy(&w)
	defer session_close(&sess)

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

	rl.DisableCursor()
	ignore_mouse_frames := player.CAPTURE_IGNORE_FRAMES
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
		player.update_look(&pl, ignore_mouse_frames == 0)
		ignore_mouse_frames = max(ignore_mouse_frames - 1, 0)
		if rl.IsKeyPressed(.F3) {
			debug = !debug
			player.set_mode(&pl, &w, .Fly if debug else .Walk)
		}
		player.update_movement(&pl, &w)
		camera := player.camera_of(&pl)
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
		if player.update_block_edit(&edit, &w, target, has_target, player.player_box(&pl)) {
			target, has_target = player.pick_block(&w, camera)
		}

		p := camera.position
		center := world.block_to_chunk({i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))})
		if err := world.streamer_update(&s, &w, center); err != nil {
			fmt.eprintln("chunk streaming failed:", err)
			break
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
		if debug {
			render.draw_debug_overlay(&r, &w, &s, camera, target if has_target else nil, edit.selected, wireframe, cull_frozen)
		}
		// Swaps buffers: includes the vsync wait and any GPU sync.
		prof.begin("EndDrawing")
		rl.EndDrawing()
		prof.end()

		session_tick(&sess, &w, &pl, f64(rl.GetFrameTime()))
	}
	// Esc, closing the window, --frames, or a streaming error.
	session_save(&sess, &w, &pl)
}
