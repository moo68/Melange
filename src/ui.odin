package main

// Menu screens (raygui, immediate mode: each proc draws its screen and
// returns what was clicked this frame). Call between BeginDrawing and
// EndDrawing.

import "core:fmt"
import "core:math"
import "melange:save"
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

// The title screen.
draw_title :: proc() -> (action: Title_Action) {
	rl.ClearBackground(SKY_UI)
	w, h := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	centered_text("Melange", w, h * 0.22, rl.WHITE, UI_TITLE_SIZE)
	y := h * 0.48
	if button(w, &y, "Play") {
		action = .Play
	}
	if button(w, &y, "Quit") {
		action = .Quit
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

// ---- World select --------------------------------------------------------------

World_Select_Action :: enum {
	None,
	Play, // the selected world
	Delete, // the selected world (already confirmed)
	Back,
}

// The world select screen's state; lives while the screen is open.
World_Select :: struct {
	entries:          []save.World_Entry,
	selected:         int, // index into entries, -1 = none
	scroll:           f32, // pixels scrolled down
	confirm_delete:   bool, // the "Delete?" dialog is open
	last_click_index: int, // for double-click detection
	last_click_time:  f64,
	message:          [256]u8, // a failed open/delete, shown in red ("" = none)
	message_len:      int,
}

UI_ROW_HEIGHT :: 64
UI_DOUBLE_CLICK :: 0.4 // seconds

// (Re)scans the saves folder. Preselects the most recently played world.
world_select_open :: proc(ws: ^World_Select) {
	world_select_close(ws)
	ws.entries = save.list_worlds(save.SAVES_DIR)
	ws.selected = 0 if len(ws.entries) > 0 && ws.entries[0].err == .None else -1
	ws.last_click_index = -1
}

world_select_close :: proc(ws: ^World_Select) {
	save.world_entries_destroy(ws.entries)
	ws^ = {}
}

world_select_set_message :: proc(ws: ^World_Select, msg: string) {
	ws.message_len = copy(ws.message[:len(ws.message) - 1], msg)
	ws.message[ws.message_len] = 0
}

// The selected world, if it can be played.
world_select_playable :: proc(ws: ^World_Select) -> (name: string, ok: bool) {
	if ws.selected < 0 || ws.selected >= len(ws.entries) || ws.entries[ws.selected].err != .None {
		return "", false
	}
	return ws.entries[ws.selected].name, true
}

// The world list: click selects, double-click / Enter plays, wheel scrolls,
// Up/Down move the selection, Delete (key or button) asks first, Esc goes back.
draw_world_select :: proc(ws: ^World_Select, now: i64) -> (action: World_Select_Action) {
	rl.ClearBackground(SKY_UI)
	w, h := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	panel_w := min(720, w - 40)
	x0 := (w - panel_w) / 2
	centered_text("Select World", w, 30, rl.WHITE, 40)
	list := rl.Rectangle{x0, 90, panel_w, max(UI_ROW_HEIGHT * 2, h - 90 - 150)}
	n := len(ws.entries)
	_, can_play := world_select_playable(ws)
	input := !ws.confirm_delete
	confirm_was_open := ws.confirm_delete

	// Keyboard.
	if input {
		switch {
		case rl.IsKeyPressed(.ESCAPE):
			action = .Back
		case rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER):
			if can_play {
				action = .Play
			}
		case rl.IsKeyPressed(.DELETE):
			ws.confirm_delete = ws.selected >= 0
		case rl.IsKeyPressed(.DOWN) && n > 0:
			ws.selected = min(ws.selected + 1, n - 1)
			scroll_into_view(ws, list.height)
		case rl.IsKeyPressed(.UP) && n > 0:
			ws.selected = max(ws.selected - 1, 0)
			scroll_into_view(ws, list.height)
		}
	}

	// Scrolling and clicks in the list.
	content_h := f32(n * UI_ROW_HEIGHT)
	max_scroll := max(0, content_h - list.height)
	mouse := rl.GetMousePosition()
	in_list := rl.CheckCollisionPointRec(mouse, list)
	if input && in_list {
		ws.scroll -= rl.GetMouseWheelMove() * UI_ROW_HEIGHT
	}
	ws.scroll = clamp(ws.scroll, 0, max_scroll)
	hovered := -1
	if in_list {
		i := int(math.floor((mouse.y - list.y + ws.scroll) / UI_ROW_HEIGHT))
		hovered = i if i >= 0 && i < n else -1
	}
	if input && hovered >= 0 && rl.IsMouseButtonPressed(.LEFT) {
		t := rl.GetTime()
		if hovered == ws.last_click_index && t - ws.last_click_time < UI_DOUBLE_CLICK {
			ws.selected = hovered
			if _, ok := world_select_playable(ws); ok {
				action = .Play
			}
			ws.last_click_index = -1
		} else {
			ws.selected = hovered
			ws.last_click_index = hovered
			ws.last_click_time = t
		}
		_, can_play = world_select_playable(ws)
	}

	// The list.
	rl.DrawRectangleRec(list, style_color(.DEFAULT, i32(rl.GuiDefaultProperty.BACKGROUND_COLOR)))
	rl.DrawRectangleLinesEx(list, 1, style_color(.DEFAULT, i32(rl.GuiControlProperty.BORDER_COLOR_NORMAL)))
	if n == 0 {
		centered_text("No worlds yet. Run with --world NAME to make one.", w, list.y + list.height / 2 - 10, style_color(.DEFAULT, i32(rl.GuiControlProperty.TEXT_COLOR_NORMAL)))
	}
	rl.BeginScissorMode(i32(list.x), i32(list.y), i32(list.width), i32(list.height))
	buf: [64]u8
	for e, i in ws.entries {
		row := rl.Rectangle{list.x + 4, list.y + f32(i * UI_ROW_HEIGHT) - ws.scroll + 4, list.width - 8 - 10, UI_ROW_HEIGHT - 8}
		if row.y + row.height < list.y || row.y > list.y + list.height {
			continue
		}
		state := rl.GuiControlProperty.BORDER_COLOR_NORMAL // the normal/focused/pressed group's first property
		if i == ws.selected {
			state = .BORDER_COLOR_PRESSED
		} else if i == hovered && input {
			state = .BORDER_COLOR_FOCUSED
		}
		rl.DrawRectangleRec(row, style_color(.BUTTON, i32(state) + 1))
		rl.DrawRectangleLinesEx(row, 2, style_color(.BUTTON, i32(state)))
		text_color := style_color(.BUTTON, i32(state) + 2)
		rl.DrawText(fmt.ctprint(e.name), i32(row.x + 12), i32(row.y + 7), UI_TEXT_SIZE, text_color)
		detail: cstring
		detail_color := text_color
		if e.err == .None {
			detail = fmt.ctprintf("Last played %s, seed %d", save.format_last_played(buf[:], now, e.info.last_played), e.info.seed)
			detail_color.a = 170
		} else {
			detail = fmt.ctprintf("Can't load: %v", e.err)
			detail_color = UI_ERROR_COLOR
		}
		rl.DrawText(detail, i32(row.x + 12), i32(row.y + 31), UI_TEXT_SIZE, detail_color)
	}
	rl.EndScissorMode()
	if max_scroll > 0 {
		// Scroll position indicator (wheel only).
		bar_h := max(24, list.height * list.height / content_h)
		bar_y := list.y + (list.height - bar_h) * ws.scroll / max_scroll
		rl.DrawRectangleRec({list.x + list.width - 10, bar_y, 6, bar_h}, style_color(.DEFAULT, i32(rl.GuiControlProperty.BORDER_COLOR_FOCUSED)))
	}

	// Buttons.
	if ws.confirm_delete {
		rl.GuiLock()
	}
	gap: f32 = UI_BUTTON_GAP
	bw := (panel_w - 2 * gap) / 3
	by := list.y + list.height + 20
	if !can_play {
		rl.GuiDisable()
	}
	if rl.GuiButton({x0, by, bw, UI_BUTTON_SIZE.y}, "Play Selected") {
		action = .Play
	}
	rl.GuiEnable()
	if ws.selected < 0 {
		rl.GuiDisable()
	}
	if rl.GuiButton({x0 + bw + gap, by, bw, UI_BUTTON_SIZE.y}, "Delete") {
		ws.confirm_delete = true
	}
	rl.GuiEnable()
	if rl.GuiButton({x0 + 2 * (bw + gap), by, bw, UI_BUTTON_SIZE.y}, "Back") {
		action = .Back
	}
	if ws.message_len > 0 {
		centered_text(cstring(raw_data(ws.message[:])), w, by + UI_BUTTON_SIZE.y + 14, UI_ERROR_COLOR)
	}
	rl.GuiUnlock()

	opening := ws.confirm_delete && !confirm_was_open
	// The delete confirmation, over everything. Our own dialog, not
	// GuiMessageBox: the vendored libraygui.a is newer than its 4.0 bindings
	// and its GuiMessageBox returns 0 ("closed") on every frame without a
	// click. Inactive on the frame it opens.
	if ws.confirm_delete && ws.selected >= 0 {
		if opening {
			rl.GuiLock()
		}
		rl.DrawRectangle(0, 0, i32(w), i32(h), {0, 0, 0, 120})
		box := rl.Rectangle{(w - 460) / 2, (h - 180) / 2, 460, 180}
		rl.DrawRectangleRec(box, style_color(.DEFAULT, i32(rl.GuiDefaultProperty.BACKGROUND_COLOR)))
		rl.DrawRectangleLinesEx(box, 2, style_color(.DEFAULT, i32(rl.GuiControlProperty.BORDER_COLOR_NORMAL)))
		text := style_color(.DEFAULT, i32(rl.GuiControlProperty.TEXT_COLOR_NORMAL))
		centered_text(fmt.ctprintf("Delete '%s'?", ws.entries[ws.selected].name), w, box.y + 28, text)
		centered_text("This can't be undone.", w, box.y + 60, text)
		dw := (box.width - 3 * gap) / 2
		buttons_y := box.y + box.height - UI_BUTTON_SIZE.y - gap
		if rl.GuiButton({box.x + gap, buttons_y, dw, UI_BUTTON_SIZE.y}, "Delete") {
			action = .Delete
			ws.confirm_delete = false
		}
		if rl.GuiButton({box.x + 2 * gap + dw, buttons_y, dw, UI_BUTTON_SIZE.y}, "Cancel") || rl.IsKeyPressed(.ESCAPE) {
			ws.confirm_delete = false
		}
		rl.GuiUnlock()
	}
	return
}

// Scrolls so the selected row is fully visible.
@(private = "file")
scroll_into_view :: proc(ws: ^World_Select, list_h: f32) {
	top := f32(ws.selected * UI_ROW_HEIGHT)
	ws.scroll = clamp(ws.scroll, top + UI_ROW_HEIGHT - list_h, top)
}

@(private = "file")
style_color :: proc(control: rl.GuiControl, property: i32) -> rl.Color {
	return rl.GetColor(u32(rl.GuiGetStyle(control, property)))
}

UI_ERROR_COLOR :: rl.Color{190, 30, 30, 255}

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
