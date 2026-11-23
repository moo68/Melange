package main

// Menu screens (raygui, immediate mode: each proc draws its screen and
// returns what was clicked this frame). Call between BeginDrawing and
// EndDrawing.

import "core:fmt"
import "core:math"
import "melange:save"
import "melange:settings"
import "melange:textedit"
import rl "third_party:raylib"

UI_TEXT_SIZE :: 20
UI_BUTTON_SIZE :: [2]f32{300, 44}
UI_BUTTON_GAP :: 12
UI_TITLE_SIZE :: 80

Title_Action :: enum {
	None,
	Play,
	Settings,
	Quit,
}

Pause_Action :: enum {
	None,
	Resume,
	Settings,
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
	if button(w, &y, "Settings") {
		action = .Settings
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
	if button(w, &y, "Settings") {
		action = .Settings
	}
	if button(w, &y, "Save & Quit to Title") {
		action = .Quit_To_Title
	}
	return
}

// ---- Settings -------------------------------------------------------------------

Settings_Action :: enum {
	None,
	Done,
}

// The settings screen; edits `s` in place (main applies FOV, sensitivity,
// FOV effects and v-sync live, render distance on Done). `over_world` = opened from
// the pause menu: drawn over the (already drawn) world instead of the sky.
// Esc = Done.
draw_settings :: proc(s: ^settings.Settings, over_world: bool) -> (action: Settings_Action) {
	w, h := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	if over_world {
		rl.DrawRectangle(0, 0, i32(w), i32(h), {0, 0, 0, 160})
	} else {
		rl.ClearBackground(SKY_UI)
	}
	centered_text("Settings", w, 30, rl.WHITE, 40)
	panel_w := min(600, w - 40)
	x0 := (w - panel_w) / 2
	y: f32 = 110

	rd := f32(s.render_distance)
	slider_row(x0, &y, panel_w, fmt.ctprintf("Render distance: %d chunks", s.render_distance), &rd, settings.MIN_RENDER_DISTANCE, settings.MAX_RENDER_DISTANCE)
	s.render_distance = int(math.round(rd))

	fov := s.fov
	fov_label := fmt.ctprintf("Field of view: %d degrees", int(math.round(s.fov)))
	if math.round(s.fov) >= settings.MAX_FOV {
		fov_label = "Field of view: Quake Pro!"
	}
	slider_row(x0, &y, panel_w, fov_label, &fov, settings.MIN_FOV, settings.MAX_FOV)
	s.fov = math.round(fov)

	pct := s.mouse_sensitivity * 100
	slider_row(x0, &y, panel_w, fmt.ctprintf("Mouse sensitivity: %d%%", int(math.round(s.mouse_sensitivity * 100))), &pct, settings.MIN_MOUSE_SENSITIVITY * 100, settings.MAX_MOUSE_SENSITIVITY * 100)
	s.mouse_sensitivity = math.round(pct / 5) * 5 / 100 // steps of 5%

	fx := s.fov_effects * 100
	fx_label := fmt.ctprintf("FOV effects: %d%%", int(math.round(s.fov_effects * 100)))
	if s.fov_effects <= 0 {
		fx_label = "FOV effects: Off"
	}
	slider_row(x0, &y, panel_w, fx_label, &fx, settings.MIN_FOV_EFFECTS * 100, settings.MAX_FOV_EFFECTS * 100)
	s.fov_effects = math.round(fx / 5) * 5 / 100 // steps of 5%

	if rl.GuiButton({x0, y, panel_w, UI_BUTTON_SIZE.y}, fmt.ctprintf("V-Sync: %s", "On" if s.vsync else "Off")) {
		s.vsync = !s.vsync
	}
	y += UI_BUTTON_SIZE.y + 40

	gap: f32 = UI_BUTTON_GAP
	bw := (panel_w - gap) / 2
	if rl.GuiButton({x0, y, bw, UI_BUTTON_SIZE.y}, "Reset to defaults") {
		s^ = settings.DEFAULT
	}
	if rl.GuiButton({x0 + bw + gap, y, bw, UI_BUTTON_SIZE.y}, "Done") || rl.IsKeyPressed(.ESCAPE) {
		action = .Done
	}
	return
}

// A label line, then a full-width slider under it; moves y below both.
@(private = "file")
slider_row :: proc(x0: f32, y: ^f32, width: f32, label: cstring, value: ^f32, lo, hi: f32) {
	rl.DrawText(label, i32(x0), i32(y^), UI_TEXT_SIZE, rl.WHITE)
	y^ += 28
	rl.GuiSlider({x0, y^, width, 30}, nil, nil, value, lo, hi)
	y^ += 30 + 24
}

// ---- World select --------------------------------------------------------------

World_Select_Action :: enum {
	None,
	Play, // the selected world
	Delete, // the selected world (already confirmed)
	Create, // open the create world screen
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
	list := rl.Rectangle{x0, 90, panel_w, max(UI_ROW_HEIGHT * 2, h - 90 - 200)}
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
		centered_text("No worlds yet. Click Create New World.", w, list.y + list.height / 2 - 10, style_color(.DEFAULT, i32(rl.GuiControlProperty.TEXT_COLOR_NORMAL)))
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
	bw := (panel_w - gap) / 2
	by := list.y + list.height + 20
	by2 := by + UI_BUTTON_SIZE.y + gap
	if !can_play {
		rl.GuiDisable()
	}
	if rl.GuiButton({x0, by, bw, UI_BUTTON_SIZE.y}, "Play Selected") {
		action = .Play
	}
	rl.GuiEnable()
	if rl.GuiButton({x0 + bw + gap, by, bw, UI_BUTTON_SIZE.y}, "Create New World") {
		action = .Create
	}
	if ws.selected < 0 {
		rl.GuiDisable()
	}
	if rl.GuiButton({x0, by2, bw, UI_BUTTON_SIZE.y}, "Delete") {
		ws.confirm_delete = true
	}
	rl.GuiEnable()
	if rl.GuiButton({x0 + bw + gap, by2, bw, UI_BUTTON_SIZE.y}, "Back") {
		action = .Back
	}
	if ws.message_len > 0 {
		centered_text(cstring(raw_data(ws.message[:])), w, by2 + UI_BUTTON_SIZE.y + 14, UI_ERROR_COLOR)
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

// ---- Create world ------------------------------------------------------------

Create_World_Action :: enum {
	None,
	Create, // create_world_request says what
	Cancel,
}

// The create world screen's state; lives while the screen is open.
Create_World :: struct {
	name:         textedit.Field,
	seed:         textedit.Field,
	name_scroll:  f32, // text_field horizontal scroll, per field
	seed_scroll:  f32,
	focus:        int, // 0 = name field, 1 = seed field
	keys:         Field_Keys, // key repeat + caret blink of the focused field
	// check_new_name result for `checked` (re-checked only when the name changes)
	problem:      save.Name_Problem,
	checked:      textedit.Field,
	checked_once: bool,
	message:      [256]u8, // why creating failed, shown in red ("" = none)
	message_len:  int,
}

create_world_open :: proc(cw: ^Create_World) {
	cw^ = {}
	cw.name.max_len = save.MAX_NAME_LEN
	buf: [save.MAX_NAME_LEN + 16]u8
	textedit.field_set(&cw.name, save.default_new_name(save.SAVES_DIR, buf[:]))
	cw.seed.max_len = textedit.MAX_BYTES
}

create_world_set_message :: proc(cw: ^Create_World, msg: string) {
	cw.message_len = copy(cw.message[:len(cw.message) - 1], msg)
	cw.message[cw.message_len] = 0
}

// The world the form describes (seed_set = false for a random seed).
create_world_request :: proc(cw: ^Create_World) -> World_Request {
	seed, kind := save.seed_from_text(textedit.field_text(&cw.seed))
	return {name = textedit.field_text(&cw.name), seed = seed, seed_set = kind != .Random, create = true}
}

// The form: click a field (or Tab) to switch fields, Enter creates, Esc
// cancels. Create is disabled while the name has a problem.
draw_create_world :: proc(cw: ^Create_World) -> (action: Create_World_Action) {
	rl.ClearBackground(SKY_UI)
	w := f32(rl.GetScreenWidth())
	panel_w := min(600, w - 40)
	x0 := (w - panel_w) / 2
	centered_text("Create New World", w, 30, rl.WHITE, 40)
	hint_color := rl.Color{255, 255, 255, 210}

	// Name check, only when the name changed.
	name := textedit.field_text(&cw.name)
	if !cw.checked_once || name != textedit.field_text(&cw.checked) {
		cw.problem = save.check_new_name(save.SAVES_DIR, name)
		cw.checked = cw.name
		cw.checked_once = true
	}
	seed, kind := save.seed_from_text(textedit.field_text(&cw.seed))

	name_box := rl.Rectangle{x0, 148, panel_w, UI_BUTTON_SIZE.y}
	seed_box := rl.Rectangle{x0, 278, panel_w, UI_BUTTON_SIZE.y}
	old_focus := cw.focus
	if rl.IsKeyPressed(.TAB) {
		cw.focus = 1 - cw.focus
	}
	if rl.IsMouseButtonPressed(.LEFT) {
		mouse := rl.GetMousePosition()
		if rl.CheckCollisionPointRec(mouse, name_box) {
			cw.focus = 0
		} else if rl.CheckCollisionPointRec(mouse, seed_box) {
			cw.focus = 1
		}
	}
	if cw.focus != old_focus {
		cw.keys = {} // no repeat or blink carried over to the other field
	}

	rl.DrawText("World Name", i32(x0), i32(name_box.y - 26), UI_TEXT_SIZE, rl.WHITE)
	text_field(&cw.name, name_box, cw.focus == 0, &cw.keys, &cw.name_scroll)
	if cw.problem == .None {
		rl.DrawText(fmt.ctprintf("Will be saved in %s/%s", save.SAVES_DIR, name), i32(x0), i32(name_box.y + name_box.height + 8), UI_TEXT_SIZE, hint_color)
	} else {
		rl.DrawText(fmt.ctprint(save.name_problem_text(cw.problem)), i32(x0), i32(name_box.y + name_box.height + 8), UI_TEXT_SIZE, UI_ERROR_COLOR)
	}

	rl.DrawText("Seed (optional)", i32(x0), i32(seed_box.y - 26), UI_TEXT_SIZE, rl.WHITE)
	text_field(&cw.seed, seed_box, cw.focus == 1, &cw.keys, &cw.seed_scroll)
	seed_hint: cstring
	switch kind {
	case .Random:
		seed_hint = "Blank: a random seed"
	case .Number:
		seed_hint = fmt.ctprintf("Seed %d", seed)
	case .Text:
		seed_hint = fmt.ctprintf("Text seed -> %d", seed)
	}
	rl.DrawText(seed_hint, i32(x0), i32(seed_box.y + seed_box.height + 8), UI_TEXT_SIZE, hint_color)

	gap: f32 = UI_BUTTON_GAP
	bw := (panel_w - gap) / 2
	by := seed_box.y + seed_box.height + 70
	can_create := cw.problem == .None
	if !can_create {
		rl.GuiDisable()
	}
	if rl.GuiButton({x0, by, bw, UI_BUTTON_SIZE.y}, "Create") || (can_create && (rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER))) {
		action = .Create
	}
	rl.GuiEnable()
	if rl.GuiButton({x0 + bw + gap, by, bw, UI_BUTTON_SIZE.y}, "Cancel") || rl.IsKeyPressed(.ESCAPE) {
		action = .Cancel
	}
	if cw.message_len > 0 {
		centered_text(cstring(raw_data(cw.message[:])), w, by + UI_BUTTON_SIZE.y + 14, UI_ERROR_COLOR)
	}
	return
}

// ---- Text field ----------------------------------------------------------------
// Our own single-line text box (editing logic in melange:textedit). Not
// GuiTextBox: the vendored raygui repeats keys per frame (one character per
// frame after 40 frames = 240 chars/s at 240 fps, not configurable in the
// prebuilt lib), its hover colors are unreadable on our background, and
// its caret overlaps letters.

// Key repeat and caret blink for the focused field (reset on focus change).
Field_Keys :: struct {
	repeat: [4]textedit.Key_Repeat, // FIELD_REPEAT_KEYS
	blink:  f32, // seconds since the last edit / move (caret shows first)
}

@(private = "file")
FIELD_REPEAT_KEYS :: [4]rl.KeyboardKey{.LEFT, .RIGHT, .BACKSPACE, .DELETE}
@(private = "file")
FIELD_PAD :: 10
@(private = "file")
FIELD_SPACING :: 4 // between glyphs: room for a 2-px caret with 1 px clear on each side
@(private = "file")
FIELD_TEXT :: rl.Color{30, 30, 30, 255}

// Edits `f` from this frame's keyboard input when focused (typing, Left /
// Right / Home / End, Backspace / Delete with key repeat, Ctrl+V paste, a
// click places the caret), then draws it. `scroll` keeps the caret in view
// when the text is wider than the box.
text_field :: proc(f: ^textedit.Field, bounds: rl.Rectangle, focused: bool, keys: ^Field_Keys, scroll: ^f32) {
	text_x := bounds.x + FIELD_PAD
	inner_w := bounds.width - 2 * FIELD_PAD
	mouse := rl.GetMousePosition()
	hovered := rl.CheckCollisionPointRec(mouse, bounds)

	if focused {
		dt := rl.GetFrameTime()
		keys.blink += dt
		for r := rl.GetCharPressed(); r != 0; r = rl.GetCharPressed() {
			if textedit.field_insert(f, r) {
				keys.blink = 0
			}
		}
		ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
		if ctrl && rl.IsKeyPressed(.V) {
			if clip := rl.GetClipboardText(); clip != nil {
				textedit.field_insert_text(f, string(clip))
				keys.blink = 0
			}
		}
		for key, i in FIELD_REPEAT_KEYS {
			n := textedit.key_repeat(&keys.repeat[i], rl.IsKeyPressed(key), rl.IsKeyDown(key), dt)
			for _ in 0 ..< n {
				#partial switch key {
				case .LEFT:
					textedit.field_left(f)
				case .RIGHT:
					textedit.field_right(f)
				case .BACKSPACE:
					textedit.field_backspace(f)
				case .DELETE:
					textedit.field_delete(f)
				}
			}
			if n > 0 {
				keys.blink = 0
			}
		}
		if rl.IsKeyPressed(.HOME) {
			textedit.field_home(f)
			keys.blink = 0
		}
		if rl.IsKeyPressed(.END) {
			textedit.field_end(f)
			keys.blink = 0
		}
		if hovered && rl.IsMouseButtonPressed(.LEFT) {
			// The caret goes to the character boundary nearest the click.
			bounds_buf: [textedit.MAX_BYTES + 1]int
			n := textedit.field_boundaries(f, bounds_buf[:])
			best, best_d := 0, max(f32)
			for b in bounds_buf[:n] {
				d := abs(text_x - scroll^ + field_prefix_width(f, b) - mouse.x)
				if d < best_d {
					best, best_d = b, d
				}
			}
			f.cursor = best
			keys.blink = 0
		}
	}

	// Keep the caret inside the box.
	caret := field_prefix_width(f, f.cursor)
	total := field_prefix_width(f, f.len)
	if total <= inner_w {
		scroll^ = 0
	} else {
		scroll^ = clamp(scroll^, caret - inner_w + FIELD_SPACING, caret)
	}

	border := rl.Color{110, 110, 110, 255}
	if focused {
		border = {40, 90, 160, 255}
	} else if hovered {
		border = {60, 60, 60, 255}
	}
	rl.DrawRectangleRec(bounds, {245, 245, 245, 255})
	rl.DrawRectangleLinesEx(bounds, 2 if focused else 1, border)
	rl.BeginScissorMode(i32(text_x - 3), i32(bounds.y), i32(inner_w + 6), i32(bounds.height))
	text_y := bounds.y + (bounds.height - UI_TEXT_SIZE) / 2
	rl.DrawTextEx(rl.GetFontDefault(), textedit.field_cstring(f), {text_x - scroll^, text_y}, UI_TEXT_SIZE, FIELD_SPACING, FIELD_TEXT)
	if focused && math.mod(keys.blink, 1.0) < 0.6 {
		// In the gap between glyphs: the previous glyph ends at `caret`, the
		// next starts FIELD_SPACING later.
		x := text_x - scroll^ + caret + (FIELD_SPACING / 2 - 1 if f.cursor > 0 else -3)
		rl.DrawRectangleRec({x, text_y - 2, 2, UI_TEXT_SIZE + 4}, FIELD_TEXT)
	}
	rl.EndScissorMode()
}

// Width of the text before byte offset `upto`, as text_field draws it.
@(private = "file")
field_prefix_width :: proc(f: ^textedit.Field, upto: int) -> f32 {
	if upto <= 0 {
		return 0
	}
	tmp: [textedit.MAX_BYTES + 1]u8
	copy(tmp[:], f.buf[:upto])
	return rl.MeasureTextEx(rl.GetFontDefault(), cstring(raw_data(tmp[:])), UI_TEXT_SIZE, FIELD_SPACING).x
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
