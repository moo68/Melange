package tests

import "core:testing"
import "melange:textedit"

@(test)
text_field_editing :: proc(t: ^testing.T) {
	f: textedit.Field
	f.max_len = 8
	textedit.field_set(&f, "abc")
	testing.expect_value(t, textedit.field_text(&f), "abc")
	testing.expect_value(t, f.cursor, 3)
	testing.expect_value(t, string(textedit.field_cstring(&f)), "abc") // NUL-terminated

	textedit.field_left(&f)
	textedit.field_insert(&f, 'X')
	testing.expect_value(t, textedit.field_text(&f), "abXc")
	testing.expect_value(t, f.cursor, 3)
	textedit.field_backspace(&f) // removes X
	testing.expect_value(t, textedit.field_text(&f), "abc")
	textedit.field_delete(&f) // removes c
	testing.expect_value(t, textedit.field_text(&f), "ab")
	testing.expect_value(t, string(textedit.field_cstring(&f)), "ab")
	textedit.field_delete(&f) // at the end: nothing
	testing.expect_value(t, textedit.field_text(&f), "ab")
	textedit.field_home(&f)
	textedit.field_backspace(&f) // at the start: nothing
	textedit.field_left(&f) // stays at 0
	testing.expect_value(t, f.cursor, 0)
	testing.expect_value(t, textedit.field_text(&f), "ab")
	textedit.field_insert(&f, '1')
	testing.expect_value(t, textedit.field_text(&f), "1ab")
	textedit.field_end(&f)
	textedit.field_right(&f) // stays at the end
	testing.expect_value(t, f.cursor, 3)

	// Control characters are refused; the byte limit holds.
	testing.expect(t, !textedit.field_insert(&f, '\t'), "tab refused")
	testing.expect(t, !textedit.field_insert(&f, '\n'), "newline refused")
	testing.expect(t, !textedit.field_insert(&f, 127), "DEL refused")
	textedit.field_insert_text(&f, "de\nfghij") // newline skipped, cut at 8 bytes
	testing.expect_value(t, textedit.field_text(&f), "1abdefgh")
	testing.expect(t, !textedit.field_insert(&f, 'z'), "full")
	textedit.field_set(&f, "0123456789")
	testing.expect_value(t, textedit.field_text(&f), "01234567")

	// Shrinking leaves stale bytes past the end; growing again must still
	// NUL-terminate (raylib draws the cstring).
	// (Deleting a multi-byte character leaves its other bytes behind.)
	textedit.field_set(&f, "ab€")
	textedit.field_backspace(&f)
	textedit.field_insert(&f, 'x')
	testing.expect_value(t, string(textedit.field_cstring(&f)), "abx")
}

@(test)
text_field_utf8 :: proc(t: ^testing.T) {
	f: textedit.Field
	textedit.field_set(&f, "aé€b") // 1 + 2 + 3 + 1 bytes
	testing.expect_value(t, f.len, 7)
	textedit.field_left(&f) // before b
	textedit.field_left(&f) // before €
	testing.expect_value(t, f.cursor, 3)
	textedit.field_delete(&f) // removes all 3 bytes of €
	testing.expect_value(t, textedit.field_text(&f), "aéb")
	textedit.field_backspace(&f) // removes both bytes of é
	testing.expect_value(t, textedit.field_text(&f), "ab")
	testing.expect_value(t, f.cursor, 1)

	textedit.field_set(&f, "aé€b")
	out: [16]int
	n := textedit.field_boundaries(&f, out[:])
	testing.expect_value(t, n, 5)
	testing.expect(t, out[:n][0] == 0 && out[1] == 1 && out[2] == 3 && out[3] == 6 && out[4] == 7, "boundaries 0 1 3 6 7")

	// A multi-byte character that doesn't fit isn't split.
	g: textedit.Field
	g.max_len = 3
	textedit.field_set(&g, "ab€")
	testing.expect_value(t, textedit.field_text(&g), "ab")
	// The full buffer works too.
	h: textedit.Field
	for _ in 0 ..< textedit.MAX_BYTES + 5 {
		textedit.field_insert(&h, 'x')
	}
	testing.expect_value(t, h.len, textedit.MAX_BYTES)
	testing.expect_value(t, len(string(textedit.field_cstring(&h))), textedit.MAX_BYTES)
}

// Total actions over `seconds` of holding a key at a fixed frame time.
hold_key :: proc(seconds, dt: f32) -> int {
	k: textedit.Key_Repeat
	total := textedit.key_repeat(&k, true, true, dt)
	for elapsed := dt; elapsed < seconds - dt / 2; elapsed += dt {
		total += textedit.key_repeat(&k, false, true, dt)
	}
	return total
}

@(test)
text_key_repeat_is_frame_rate_independent :: proc(t: ^testing.T) {
	// 1 s held: the press, nothing for REPEAT_DELAY, then 30/s.
	after_delay: f64 = (1.0 - textedit.REPEAT_DELAY) / textedit.REPEAT_INTERVAL
	want := 1 + int(after_delay) + 1
	for fps in ([]f32{30, 60, 144, 240, 1000}) {
		got := hold_key(1.0, 1 / fps)
		testing.expectf(t, abs(got - want) <= 1, "%v fps: %d actions in 1 s, want ~%d", fps, got, want)
	}
	// Nothing repeats before the delay.
	testing.expect_value(t, hold_key(textedit.REPEAT_DELAY - 0.02, 1.0 / 240), 1)

	// Releasing resets; a new press acts at once.
	k: textedit.Key_Repeat
	testing.expect_value(t, textedit.key_repeat(&k, true, true, 0.01), 1)
	testing.expect_value(t, textedit.key_repeat(&k, false, true, 1.0), textedit.MAX_REPEATS_PER_FRAME) // a long frame is capped
	testing.expect_value(t, textedit.key_repeat(&k, false, true, 0.001), 0) // and doesn't burst afterwards
	testing.expect_value(t, textedit.key_repeat(&k, false, false, 0.01), 0)
	testing.expect_value(t, k.held_for, 0)
	testing.expect_value(t, textedit.key_repeat(&k, false, true, 0.2), 0) // held again without a press: still waits for the delay
	testing.expect_value(t, textedit.key_repeat(&k, true, true, 0.01), 1)
}
