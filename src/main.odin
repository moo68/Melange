package main

import "core:fmt"
import "core:mem"
import "melange:prof"
import "melange:render"
import "melange:save"
import rl "third_party:raylib"

// Written by `./run.sh profile` builds (-define:PROFILE=true); open it in Spall.
TRACE_PATH :: "build/trace.spall"

Screen :: enum {
	Title,
	World_Select,
	Playing,
	Paused,
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

	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT, .MSAA_4X_HINT})
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
	}
	defer render.renderer_destroy(&r)

	// --world/--seed/--frames go straight into that world; otherwise start
	// on the title screen.
	game: Game
	screen := Screen.Title
	if opts.direct {
		if game_open(&game, request_from_opts(opts), &r) != "" {
			return
		}
		screen = .Playing
	}
	ws: World_Select // while on the world select screen
	defer world_select_close(&ws)

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
		if screen == .Playing && !game_update(&game, &r) {
			break main_loop // streaming failed (printed); game_close below still saves
		}

		rl.BeginDrawing()
		title_action := Title_Action.None
		select_action := World_Select_Action.None
		pause_action := Pause_Action.None
		switch screen {
		case .Title:
			title_action = draw_title()
		case .World_Select:
			select_action = draw_world_select(&ws, unix_now())
		case .Playing, .Paused:
			rl.ClearBackground(render.SKY_COLOR)
			game_draw(&game, &r, screen == .Playing)
			if screen == .Paused {
				pause_action = draw_pause()
			}
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
		case .Quit:
			break main_loop
		}
		switch select_action {
		case .None:
		case .Play:
			name, _ := world_select_playable(&ws)
			if failure := game_open(&game, {name = name}, &r); failure == "" {
				world_select_close(&ws)
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
		case .Back:
			world_select_close(&ws)
			screen = .Title
		}
		switch pause_action {
		case .None:
		case .Resume:
			game_capture_mouse(&game)
			screen = .Playing
		case .Quit_To_Title:
			game_close(&game, &r)
			screen = .Title
		}
	}
	// Closing the window, Quit, --frames, or a streaming error.
	if screen != .Title {
		game_close(&game, &r)
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
