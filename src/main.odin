package main

import "core:fmt"
import "core:mem"
import "melange:prof"
import "melange:render"
import rl "third_party:raylib"

// Written by `./run.sh profile` builds (-define:PROFILE=true); open it in Spall.
TRACE_PATH :: "build/trace.spall"

Screen :: enum {
	Title,
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

	// --world/--seed/--frames go straight into the game; otherwise the
	// title screen's Play opens that same world (the world list comes later).
	game: Game
	screen := Screen.Title
	if opts.direct {
		if !game_open(&game, opts, &r) {
			return
		}
		screen = .Playing
	}
	title_message: cstring // why Play failed, shown on the title screen
	play_label := describe_play(opts)
	defer delete(play_label)

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
		pause_action := Pause_Action.None
		switch screen {
		case .Title:
			title_action = draw_title(play_label, title_message)
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
			if game_open(&game, opts, &r) {
				screen = .Playing
				title_message = nil
			} else {
				title_message = "Couldn't open the world (see the terminal for why)"
			}
		case .Quit:
			break main_loop
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

// What the title screen's Play button opens.
describe_play :: proc(opts: Options) -> cstring {
	if opts.world != "" {
		return fmt.caprintf("world '%s' (saves/%s)", opts.world, opts.world)
	}
	return fmt.caprintf("unsaved world, seed %d (pass --world NAME to save)", opts.seed)
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
