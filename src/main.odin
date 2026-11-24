package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "melange:prof"
import "melange:render"
import "melange:save"
import "melange:settings"
import rl "third_party:raylib"
import "third_party:raylib/rlgl"

// Written by `./run.sh profile` builds (-define:PROFILE=true); open it in Spall.
TRACE_PATH :: "build/trace.spall"

Screen :: enum {
	Title,
	World_Select,
	Create_World,
	Playing,
	Paused,
	Settings, // from the title or the pause menu (settings_from)
}

main :: proc() {
	// Debug builds report leaked allocations at exit (raylib's and the
	// regions' mmap memory aren't tracked).
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer report_leaks(&track)
	}

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

	// settings.json, except in --frames runs (profiles stay comparable).
	cfg := settings.DEFAULT
	if opts.frames == 0 {
		warning: string
		if cfg, warning = settings.settings_load(settings.PATH); warning != "" {
			fmt.eprintln(warning)
		}
	}

	flags := rl.ConfigFlags{.WINDOW_RESIZABLE, .MSAA_4X_HINT}
	if cfg.vsync {
		flags += {.VSYNC_HINT}
	}
	rl.SetConfigFlags(flags)
	rl.InitWindow(1280, 720, "Melange")
	defer rl.CloseWindow()
	rl.SetExitKey(.KEY_NULL) // Esc pauses; only closing the window quits
	ui_init()

	r: render.Renderer
	switch render.renderer_init(&r) {
	case .None:
	case .Atlas:
		fmt.eprintln("failed to load", render.ATLAS_PATH, "(run from the project root, e.g. via ./run.sh)")
		return
	case .Shader:
		fmt.eprintln("failed to load chunk shader", render.CHUNK_SHADER_VS, "/", render.CHUNK_SHADER_FS, "(see raylib log above)")
		return
	case .GL:
		fmt.eprintln("OpenGL function glDrawElements not found")
		return
	}
	defer render.renderer_destroy(&r)

	// --world/--seed/--frames go straight into that world; otherwise start
	// on the title screen.
	game: Game
	has_game := false // a world is open (Playing, Paused, or Settings from Paused)
	screen := Screen.Title
	settings_from := Screen.Title // where Settings returns to
	vsync_applied := cfg.vsync
	if opts.direct {
		if game_open(&game, request_from_opts(opts), cfg) != "" {
			return
		}
		game.no_mouse_look = opts.screenshot != ""
		game.freeze_time = opts.frames > 0
		if opts.time_set {
			game_set_clock(&game, opts.time_hour)
		}
		has_game = true
		screen = .Playing
	}
	ws: World_Select // while on the world select screen
	defer world_select_close(&ws)
	cw: Create_World // while on the create world screen

	main_loop: for frame := 0; !rl.WindowShouldClose(); frame += 1 {
		if opts.frames > 0 && frame >= opts.frames {
			break
		}
		prof.scope("frame")
		defer free_all(context.temp_allocator)

		// Esc pauses, and so does losing focus (alt-tab), except in --frames
		// runs, which must keep playing for repeatable profiles.
		if screen == .Playing && (rl.IsKeyPressed(.ESCAPE) || (!rl.IsWindowFocused() && opts.frames == 0)) {
			game_release_mouse(&game)
			screen = .Paused
		} else if screen == .Paused && rl.IsKeyPressed(.ESCAPE) {
			game_capture_mouse(&game)
			screen = .Playing
		}
		if screen == .Playing && !game_update(&game, &r, cfg) {
			break main_loop // streaming failed (printed); game_close below still saves
		}

		rl.BeginDrawing()
		title_action := Title_Action.None
		select_action := World_Select_Action.None
		create_action := Create_World_Action.None
		pause_action := Pause_Action.None
		settings_action := Settings_Action.None
		switch screen {
		case .Title:
			title_action = draw_title()
		case .World_Select:
			select_action = draw_world_select(&ws, unix_now())
		case .Create_World:
			create_action = draw_create_world(&cw)
		case .Playing, .Paused:
			game_draw(&game, &r, screen == .Playing)
			if screen == .Paused {
				pause_action = draw_pause()
			}
		case .Settings:
			if has_game {
				game_draw(&game, &r, false)
			}
			settings_action = draw_settings(&cfg, has_game)
		}
		if opts.screenshot != "" && frame == opts.frames - 1 {
			save_screenshot(opts.screenshot)
		}
		// Swaps buffers: includes the vsync wait and any GPU sync.
		prof.begin("EndDrawing")
		rl.EndDrawing()
		prof.end()

		switch title_action {
		case .None:
		case .Play:
			world_select_open(&ws)
			screen = .World_Select
		case .Settings:
			settings_from = .Title
			screen = .Settings
		case .Quit:
			break main_loop
		}
		switch select_action {
		case .None:
		case .Play:
			name, _ := world_select_playable(&ws)
			if failure := game_open(&game, {name = name}, cfg); failure == "" {
				world_select_close(&ws)
				has_game = true
				screen = .Playing
			} else {
				world_select_set_message(&ws, failure)
			}
		case .Delete:
			name := ws.entries[ws.selected].name
			if err := save.delete_world(save.SAVES_DIR, name); err != .None {
				world_select_set_message(&ws, fmt.tprintf("couldn't delete '%s': %v", name, err))
			} else {
				fmt.printfln("deleted world '%s'", name)
				world_select_open(&ws) // rescan
			}
		case .Create:
			world_select_close(&ws)
			create_world_open(&cw)
			screen = .Create_World
		case .Back:
			world_select_close(&ws)
			screen = .Title
		}
		switch create_action {
		case .None:
		case .Create:
			if failure := game_open(&game, create_world_request(&cw), cfg); failure == "" {
				has_game = true
				screen = .Playing
			} else {
				create_world_set_message(&cw, failure)
			}
		case .Cancel:
			world_select_open(&ws)
			screen = .World_Select
		}
		switch pause_action {
		case .None:
		case .Resume:
			game_capture_mouse(&game)
			screen = .Playing
		case .Settings:
			settings_from = .Paused
			screen = .Settings
		case .Quit_To_Title:
			game_close(&game, &r)
			has_game = false
			screen = .Title
		}
		switch settings_action {
		case .None:
		case .Done:
			cfg = settings.settings_clamp(cfg)
			if has_game {
				game_set_render_distance(&game, cfg.render_distance)
			}
			if !settings.settings_save(settings.PATH, cfg) {
				fmt.eprintln("couldn't save", settings.PATH)
			}
			screen = settings_from
		}
		// V-Sync applies as soon as it's toggled.
		if cfg.vsync != vsync_applied {
			if cfg.vsync {
				rl.SetWindowState({.VSYNC_HINT})
			} else {
				rl.ClearWindowState({.VSYNC_HINT})
			}
			vsync_applied = cfg.vsync
		}
	}
	// Closing the window, Quit, --frames, or a streaming error.
	if has_game {
		game_close(&game, &r)
	}
}

// Saves what's been drawn this frame (before the swap) as a PNG.
@(private = "file")
save_screenshot :: proc(path: string) {
	rlgl.DrawRenderBatchActive() // raylib batches 2D/immediate drawing
	img := rl.LoadImageFromScreen()
	defer rl.UnloadImage(img)
	if rl.ExportImage(img, strings.clone_to_cstring(path, context.temp_allocator)) {
		fmt.println("screenshot saved to", path)
	} else {
		fmt.eprintln("couldn't save screenshot to", path)
	}
}

@(private = "file")
report_leaks :: proc(track: ^mem.Tracking_Allocator) {
	if len(track.allocation_map) > 0 {
		fmt.eprintfln("=== %d allocations not freed ===", len(track.allocation_map))
		for _, entry in track.allocation_map {
			fmt.eprintfln("- %v bytes @ %v", entry.size, entry.location)
		}
	}
	if len(track.bad_free_array) > 0 {
		fmt.eprintfln("=== %d bad frees ===", len(track.bad_free_array))
		for entry in track.bad_free_array {
			fmt.eprintfln("- %p @ %v", entry.memory, entry.location)
		}
	}
	mem.tracking_allocator_destroy(track)
}
