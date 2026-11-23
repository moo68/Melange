package main

// One open world: everything that lives from opening a world to closing it.
// The Renderer is app-wide (shader + atlas load once); game_close drops its
// chunk meshes.

import "core:fmt"
import "core:math"
import "melange:geom"
import "melange:player"
import "melange:render"
import "melange:settings"
import "melange:world"
import rl "third_party:raylib"
import "third_party:raylib/rlgl"

Game :: struct {
	w:                   world.World,
	s:                   world.Streamer, // per world: its height cache depends on the seed
	pl:                  player.Player,
	sess:                Session,
	edit:                player.Edit_State,
	debug:               bool, // F3: fly through blocks + the debug overlay
	wireframe:           bool, // F1
	// F2 freezes the culling frustum at the current camera so you can fly out
	// and see which chunks are being culled.
	cull_frozen:         bool,
	frustum:             geom.Frustum,
	ignore_mouse_frames: int, // see player.CAPTURE_IGNORE_FRAMES
	// Block editing waits until both mouse buttons are up after the mouse
	// is captured, so the click that resumed the game can't break a block.
	edit_blocked:        bool,
	// This frame's view, for game_draw.
	camera:              rl.Camera3D,
	target:              geom.Ray_Hit,
	has_target:          bool,
}

// Opens the world `req` (see session_open). On failure returns why (also
// printed; temp-allocated).
game_open :: proc(g: ^Game, req: World_Request, r: ^render.Renderer, cfg: settings.Settings) -> (failure: string) {
	g^ = {}
	sess, failed := session_open(req, &g.w, &g.pl, &g.debug)
	if failed != "" {
		return failed
	}
	g.sess = sess
	// Loads/unloads chunks around the camera each frame.
	stream := world.DEFAULT_STREAM_CONFIG
	stream.radius = i32(cfg.render_distance)
	world.streamer_init(&g.s, stream)
	set_fog(g, r)
	g.edit = player.DEFAULT_EDIT_STATE
	g.camera = player.camera_of(&g.pl, cfg.fov, cfg.fov_effects)
	g.frustum = render.camera_frustum(g.camera)
	game_capture_mouse(g)
	return ""
}

// Changes the render distance of the open world (the streamer restarts its
// passes; chunks beyond the new range unload over the next frames).
game_set_render_distance :: proc(g: ^Game, r: ^render.Renderer, chunks: int) {
	if i32(chunks) == g.s.config.radius {
		return
	}
	stream := g.s.config
	stream.radius = i32(chunks)
	world.streamer_set_config(&g.s, stream)
	set_fog(g, r)
}

// Fully fogged just before chunks can be missing, so the world's edge and
// chunks popping in are never visible.
@(private = "file")
set_fog :: proc(g: ^Game, r: ^render.Renderer) {
	fog_end := world.stream_meshed_distance(g.s.config)
	render.renderer_set_fog(r, fog_end * 0.55, fog_end)
}

// Saves and frees the world, and drops its meshes from the renderer.
game_close :: proc(g: ^Game, r: ^render.Renderer) {
	session_save(&g.sess, &g.w, &g.pl)
	session_close(&g.sess)
	world.streamer_destroy(&g.s)
	world.world_destroy(&g.w)
	render.renderer_clear_chunks(r)
	rl.EnableCursor()
	g^ = {}
}

// Hides the cursor for mouse look (opening or resuming).
game_capture_mouse :: proc(g: ^Game) {
	rl.DisableCursor()
	g.ignore_mouse_frames = player.CAPTURE_IGNORE_FRAMES
	g.edit_blocked = true
}

// Shows the cursor (pausing).
game_release_mouse :: proc(_: ^Game) {
	rl.EnableCursor()
}

// One frame of play: input, physics, editing, streaming, meshing, autosave.
// Returns false if streaming failed (after printing why).
game_update :: proc(g: ^Game, r: ^render.Renderer, cfg: settings.Settings) -> bool {
	player.update_look(&g.pl, g.ignore_mouse_frames == 0, cfg.mouse_sensitivity)
	g.ignore_mouse_frames = max(g.ignore_mouse_frames - 1, 0)
	if rl.IsKeyPressed(.F3) {
		g.debug = !g.debug
		player.set_mode(&g.pl, &g.w, .Fly if g.debug else .Walk)
	}
	player.update_movement(&g.pl, &g.w)
	g.camera = player.camera_of(&g.pl, cfg.fov, cfg.fov_effects)
	if rl.IsKeyPressed(.F1) {
		g.wireframe = !g.wireframe
	}
	if rl.IsKeyPressed(.F2) {
		g.cull_frozen = !g.cull_frozen
	}
	if !g.cull_frozen {
		g.frustum = render.camera_frustum(g.camera)
	}

	// Edit before meshing, so changes show this frame; re-pick so the
	// outline moves to whatever is now targeted.
	g.target, g.has_target = player.pick_block(&g.w, g.camera)
	if g.edit_blocked && !rl.IsMouseButtonDown(.LEFT) && !rl.IsMouseButtonDown(.RIGHT) {
		g.edit_blocked = false
	}
	if !g.edit_blocked && player.update_block_edit(&g.edit, &g.w, g.target, g.has_target, player.player_box(&g.pl)) {
		g.target, g.has_target = player.pick_block(&g.w, g.camera)
	}

	p := g.camera.position
	center := world.block_to_chunk({i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))})
	if err := world.streamer_update(&g.s, &g.w, center); err != nil {
		fmt.eprintln("chunk streaming failed:", err)
		return false
	}
	render.renderer_forget_chunks(r, g.s.unloaded[:])
	render.renderer_update(r, &g.w, center)

	session_tick(&g.sess, &g.w, &g.pl, f64(rl.GetFrameTime()))
	return true
}

// Draws the world as of the last game_update (between BeginDrawing and
// EndDrawing). `hud` = crosshair and debug overlay (off while paused).
game_draw :: proc(g: ^Game, r: ^render.Renderer, hud: bool) {
	rl.BeginMode3D(g.camera)
	if g.wireframe {
		rlgl.EnableWireMode()
	}
	render.renderer_draw(r, &g.frustum, g.camera.position)
	if g.wireframe {
		rlgl.DisableWireMode()
	}
	if g.has_target {
		render.draw_block_outline(g.target.block)
	}
	rl.EndMode3D()

	if !hud {
		return
	}
	render.draw_crosshair()
	if g.debug {
		render.draw_debug_overlay(r, &g.w, &g.s, g.camera, g.target if g.has_target else nil, g.edit.selected, g.wireframe, g.cull_frozen)
	}
}
