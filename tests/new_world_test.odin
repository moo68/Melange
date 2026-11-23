package tests

import "core:os"
import "core:testing"
import "melange:save"

@(test)
seeds_from_text :: proc(t: ^testing.T) {
	cases := []struct {
		text: string,
		seed: i64,
		kind: save.Seed_Kind,
	} {
		{"", 0, .Random},
		{"   ", 0, .Random},
		{"\t", 0, .Random},
		{"42", 42, .Number},
		{"-7", -7, .Number},
		{" 42 ", 42, .Number},
		{"+5", 5, .Number},
		{"0", 0, .Number},
		{"007", 7, .Number},
		{"9223372036854775807", max(i64), .Number},
		{"-9223372036854775808", min(i64), .Number},
		{"9223372036854775806", max(i64) - 1, .Number},
		{"-9223372036854775807", min(i64) + 1, .Number},
		{"-0", 0, .Number},
	}
	for c in cases {
		seed, kind := save.seed_from_text(c.text)
		testing.expectf(t, kind == c.kind && seed == c.seed, "'%s': %d %v, want %d %v", c.text, seed, kind, c.seed, c.kind)
	}

	// Text (incl. things a looser parser would read as numbers).
	texts := []string{"abc", "0x10", "1e5", "1_000", "9223372036854775808", "-9223372036854775809", "18446744073709551616", "18446744073709551615", "92233720368547758070", "4 2", "--1", "+-1", "-", "+", "Hello World"}
	seen: map[i64]string
	defer delete(seen)
	for text in texts {
		seed, kind := save.seed_from_text(text)
		testing.expectf(t, kind == .Text, "'%s': %v, want Text", text, kind)
		again, _ := save.seed_from_text(text)
		testing.expectf(t, seed == again, "'%s' is deterministic", text)
		if other, dup := seen[seed]; dup {
			testing.expectf(t, false, "'%s' and '%s' both give %d", text, other, seed)
		}
		seen[seed] = text
	}
	// Surrounding spaces don't change a text seed; case does.
	a, _ := save.seed_from_text("abc")
	b, _ := save.seed_from_text("  abc ")
	c, _ := save.seed_from_text("ABC")
	testing.expect(t, a == b, "trimmed")
	testing.expect(t, a != c, "case-sensitive")
	// FNV-1a 64 of "abc", reinterpreted as i64 (pins the hash, so seeds stay stable).
	testing.expect_value(t, u64(a), 0xe71fa2190541574b)
}

@(test)
new_world_names :: proc(t: ^testing.T) {
	root := test_saves_root("new_names")
	defer os.remove_all(root)
	save_test_world(t, root, "taken", 1, 1)
	testing.expect(t, os.make_directory(join(root, "folder")) == nil, "setup")

	cases := []struct {
		name: string,
		want: save.Name_Problem,
	} {
		{"fresh", .None},
		{"My World 2", .None},
		{"a-b_c", .None},
		{"ABCDEFGHIJKLMNOPQRSTUVWXYZ012345", .None}, // 32 characters
		{"", .Empty},
		{"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456", .Too_Long},
		{"a.b", .Bad_Chars},
		{"..", .Bad_Chars},
		{"a/b", .Bad_Chars},
		{"é", .Bad_Chars},
		{" lead", .Edge_Spaces},
		{"trail ", .Edge_Spaces},
		{" ", .Edge_Spaces},
		{"taken", .Exists},
		{"folder", .Exists}, // not a world, but the folder is in the way
		{"Taken", .None}, // names are case-sensitive (Linux)
	}
	for c in cases {
		got := save.check_new_name(root, c.name)
		testing.expectf(t, got == c.want, "'%s': %v, want %v", c.name, got, c.want)
		testing.expectf(t, (save.name_problem_text(got) == "") == (got == .None), "'%s': message iff problem", c.name)
	}
}

@(test)
default_new_world_name :: proc(t: ^testing.T) {
	root := test_saves_root("default_name")
	defer os.remove_all(root)
	buf: [64]u8
	testing.expect_value(t, save.default_new_name(root, buf[:]), "New World")
	save_test_world(t, root, "New World", 1, 1)
	testing.expect_value(t, save.default_new_name(root, buf[:]), "New World 2")
	save_test_world(t, root, "New World 2", 1, 1)
	testing.expect_value(t, save.default_new_name(root, buf[:]), "New World 3")
	// A gap is reused.
	testing.expect(t, save.delete_world(root, "New World") == .None, "setup")
	testing.expect_value(t, save.default_new_name(root, buf[:]), "New World")
}
