package textedit

// Single-line text editing for menu text fields: a fixed buffer, a cursor
// on UTF-8 boundaries, and frame-rate independent key repeat. Pure (no
// raylib) so it's testable; src/ui.odin maps input to these procs and draws.

import "core:unicode/utf8"

MAX_BYTES :: 64

Field :: struct {
	buf:     [MAX_BYTES + 1]u8, // text + NUL (handy for raylib's cstrings)
	len:     int, // bytes used
	cursor:  int, // byte offset, always on a UTF-8 boundary, 0..len
	max_len: int, // byte limit, 1..MAX_BYTES (0 = MAX_BYTES)
}

field_text :: proc(f: ^Field) -> string {
	return string(f.buf[:f.len])
}

field_cstring :: proc(f: ^Field) -> cstring {
	return cstring(raw_data(f.buf[:]))
}

// Replaces the text (cut at the byte limit on a boundary); cursor at the end.
field_set :: proc(f: ^Field, text: string) {
	f.len = 0
	f.cursor = 0
	f.buf[0] = 0
	for r in text {
		if !field_insert(f, r) {
			break
		}
	}
}

@(private)
limit :: proc(f: ^Field) -> int {
	return f.max_len if f.max_len > 0 && f.max_len <= MAX_BYTES else MAX_BYTES
}

// Inserts `r` at the cursor. Control characters and characters that don't
// fit are refused (returns false).
field_insert :: proc(f: ^Field, r: rune) -> bool {
	if r < 32 || r == 127 || !utf8.valid_rune(r) {
		return false
	}
	bytes, n := utf8.encode_rune(r)
	if f.len + n > limit(f) {
		return false
	}
	copy(f.buf[f.cursor + n:f.len + n], f.buf[f.cursor:f.len])
	copy(f.buf[f.cursor:], bytes[:n])
	f.len += n
	f.cursor += n
	f.buf[f.len] = 0
	return true
}

// Inserts as much of `text` as fits (e.g. a paste), skipping control
// characters (newlines etc.).
field_insert_text :: proc(f: ^Field, text: string) {
	for r in text {
		if r >= 32 && r != 127 && !field_insert(f, r) {
			break
		}
	}
}

// Deletes the character before the cursor.
field_backspace :: proc(f: ^Field) {
	if f.cursor == 0 {
		return
	}
	start := prev_boundary(f, f.cursor)
	remove(f, start, f.cursor)
	f.cursor = start
}

// Deletes the character after the cursor.
field_delete :: proc(f: ^Field) {
	if f.cursor == f.len {
		return
	}
	remove(f, f.cursor, next_boundary(f, f.cursor))
}

field_left :: proc(f: ^Field) {
	f.cursor = prev_boundary(f, f.cursor)
}

field_right :: proc(f: ^Field) {
	f.cursor = next_boundary(f, f.cursor)
}

field_home :: proc(f: ^Field) {
	f.cursor = 0
}

field_end :: proc(f: ^Field) {
	f.cursor = f.len
}

// Byte offsets of every cursor position (0, each character boundary, len),
// into `out`; returns how many.
field_boundaries :: proc(f: ^Field, out: []int) -> int {
	n := 0
	i := 0
	for n < len(out) {
		out[n] = i
		n += 1
		if i >= f.len {
			break
		}
		i = next_boundary(f, i)
	}
	return n
}

@(private)
remove :: proc(f: ^Field, from, to: int) {
	copy(f.buf[from:], f.buf[to:f.len])
	f.len -= to - from
	f.buf[f.len] = 0
}

@(private)
next_boundary :: proc(f: ^Field, i: int) -> int {
	if i >= f.len {
		return f.len
	}
	_, size := utf8.decode_rune(f.buf[i:f.len])
	return i + max(size, 1)
}

@(private)
prev_boundary :: proc(f: ^Field, i: int) -> int {
	if i <= 0 {
		return 0
	}
	_, size := utf8.decode_last_rune(f.buf[:i])
	return i - max(size, 1)
}

// ---- Key repeat ---------------------------------------------------------------

REPEAT_DELAY :: 0.45 // seconds held before repeating
REPEAT_INTERVAL :: 1.0 / 30 // then this often
MAX_REPEATS_PER_FRAME :: 8 // a long frame doesn't jump far

// One held key's repeat state.
Key_Repeat :: struct {
	held_for: f32, // seconds since the press
	fired:    int, // repeats fired since the press (not counting the press)
}

// How many times a key acts this frame: 1 on the press, then after
// REPEAT_DELAY once per REPEAT_INTERVAL while held (by elapsed time, so
// the speed doesn't depend on the frame rate). Releasing resets.
key_repeat :: proc(k: ^Key_Repeat, pressed, held: bool, dt: f32) -> int {
	if pressed {
		k^ = {}
		return 1
	}
	if !held {
		k^ = {}
		return 0
	}
	k.held_for += dt
	if k.held_for < REPEAT_DELAY {
		return 0
	}
	due := int((k.held_for - REPEAT_DELAY) / REPEAT_INTERVAL) + 1
	steps := min(due - k.fired, MAX_REPEATS_PER_FRAME)
	k.fired = due // skip what a long frame couldn't do, rather than burst later
	return max(steps, 0)
}
