package main

// Menu screens (raygui, immediate mode: each proc draws its screen and
// returns what was clicked this frame). Call between BeginDrawing and
// EndDrawing.

import rl "third_party:raylib"

UI_TEXT_SIZE :: 20
UI_BUTTON_SIZE :: [2]f32{300, 44}
UI_BUTTON_GAP :: 12
UI_TITLE_SIZE :: 80

Title_Action :: enum {
	None,
	Play,
	Quit,
}

Pause_Action :: enum {
	None,
	Resume,
	Quit_To_Title,
}

ui_init :: proc() {
	rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SIZE), UI_TEXT_SIZE)
	rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SPACING), 2)
}

// The title screen. `play_label` says what Play opens; `message` (if any)
// is shown in red below the buttons (e.g. why opening failed).
draw_title :: proc(play_label: cstring, message: cstring) -> (action: Title_Action) {
	rl.ClearBackground(SKY_UI)
	w, h := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	title: cstring = "Melange"
	title_w := f32(rl.MeasureText(title, UI_TITLE_SIZE))
	rl.DrawText(title, i32((w - title_w) / 2), i32(h * 0.22), UI_TITLE_SIZE, rl.WHITE)

	y := h * 0.48
	if button(w, &y, "Play") {
		action = .Play
	}
	if button(w, &y, "Quit") {
		action = .Quit
	}
	centered_text(play_label, w, y + 8, rl.Color{255, 255, 255, 200})
	if message != nil {
		centered_text(message, w, y + 36, rl.Color{200, 30, 30, 255})
	}
	return
}

// The pause menu, over the (already drawn) world.
draw_pause :: proc() -> (action: Pause_Action) {
	w, h := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	rl.DrawRectangle(0, 0, i32(w), i32(h), {0, 0, 0, 140})
	centered_text("Paused", w, h * 0.30, rl.WHITE, 40)
	y := h * 0.45
	if button(w, &y, "Resume") {
		action = .Resume
	}
	if button(w, &y, "Save & Quit to Title") {
		action = .Quit_To_Title
	}
	return
}

// The title screen's background (render.SKY_COLOR, slightly darker so
// white text reads well).
@(private = "file")
SKY_UI :: rl.Color{100, 150, 205, 255}

// A centered button at height y; moves y below it.
@(private = "file")
button :: proc(screen_w: f32, y: ^f32, text: cstring) -> bool {
	size := UI_BUTTON_SIZE
	clicked := rl.GuiButton({(screen_w - size.x) / 2, y^, size.x, size.y}, text)
	y^ += size.y + UI_BUTTON_GAP
	return clicked
}

@(private = "file")
centered_text :: proc(text: cstring, screen_w, y: f32, color: rl.Color, size: i32 = UI_TEXT_SIZE) {
	tw := f32(rl.MeasureText(text, size))
	rl.DrawText(text, i32((screen_w - tw) / 2), i32(y), size, color)
}
