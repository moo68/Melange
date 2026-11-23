package tests

import "core:os"
import "core:strings"
import "core:testing"
import "melange:save"
import "melange:world"

// Saves an empty world `name` into `root` with the given times.
save_test_world :: proc(t: ^testing.T, root, name: string, seed, last_played: i64) {
	w: world.World
	world.world_init(&w, seed)
	defer world.world_destroy(&w)
	info := save.new_world_info(name, seed, 1)
	defer save.info_destroy(&info)
	testing.expect_value(t, save.save_world(root, &info, &w, last_played), save.Error.None)
}

join :: proc(parts: ..string) -> string {
	return strings.join(parts, "/", context.temp_allocator)
}

@(test)
list_worlds_sorted_and_filtered :: proc(t: ^testing.T) {
	root := test_saves_root("list")
	defer os.remove_all(root)

	testing.expect_value(t, len(save.list_worlds(join(root, "missing"))), 0)

	save_test_world(t, root, "old", 1, 100)
	save_test_world(t, root, "new", 2, 300)
	save_test_world(t, root, "b tie", 3, 200)
	save_test_world(t, root, "a tie", 4, 200)
	// A newer-format world and one with broken JSON: listed, with errors.
	save_test_world(t, root, "z newer", 5, 999)
	write_file(t, join(root, "z newer", save.INFO_FILE), `{"version": 99, "name": "z newer", "seed": 5}`)
	save_test_world(t, root, "broken", 6, 999)
	write_file(t, join(root, "broken", save.INFO_FILE), `{"version": `)
	// Not worlds: a folder without world.json, an invalid folder name, a file.
	testing.expect(t, os.make_directory(join(root, "empty")) == nil, "setup: os.make_directory(join(root, 'empty'))")
	save_test_world(t, root, "dot", 7, 500)
	testing.expect(t, os.rename(join(root, "dot"), join(root, "a.b")) == nil, "setup: os.rename(join(root, 'dot'), join(root, 'a.b'))")
	write_file(t, join(root, "notes.txt"), "hi")
	// A symlink to a world isn't followed.
	testing.expect(t, os.symlink("new", join(root, "link")) == nil, "setup: os.symlink('new', join(root, 'link'))")

	entries := save.list_worlds(root)
	defer save.world_entries_destroy(entries)
	want := []struct {
		name: string,
		err:  save.Error,
		seed: i64,
	}{{"new", .None, 2}, {"a tie", .None, 4}, {"b tie", .None, 3}, {"old", .None, 1}, {"broken", .Bad_Info, 0}, {"z newer", .Newer_Version, 0}}
	if !testing.expectf(t, len(entries) == len(want), "%d entries, want %d: %v", len(entries), len(want), entries) {
		return
	}
	for e, i in entries {
		testing.expectf(t, e.name == want[i].name && e.err == want[i].err, "entry %d: %s %v, want %s %v", i, e.name, e.err, want[i].name, want[i].err)
		if e.err == .None {
			testing.expect_value(t, e.info.seed, want[i].seed)
			testing.expect_value(t, e.info.name, e.name)
		}
	}
}

@(test)
delete_world_removes_only_that_world :: proc(t: ^testing.T) {
	root := test_saves_root("delete")
	defer os.remove_all(root)
	save_test_world(t, root, "keep", 1, 1)
	save_test_world(t, root, "doomed", 2, 1)
	write_file(t, join(root, "doomed", "extra.txt"), "x") // anything inside goes too
	outside := strings.concatenate({root, "-outside"}, context.temp_allocator)
	testing.expect(t, os.make_directory(outside) == nil, "setup: os.make_directory(outside)")
	defer os.remove_all(outside)

	for name in ([]string{"", "..", ".", "../x", "a/b", "/", " doomed"}) {
		testing.expectf(t, save.delete_world(root, name) == .Bad_Name, "'%s' refused", name)
	}
	testing.expect_value(t, save.delete_world(root, "nope"), save.Error.Not_Found)
	write_file(t, join(root, "afile"), "x")
	testing.expect_value(t, save.delete_world(root, "afile"), save.Error.Not_Found)
	testing.expect(t, os.symlink("keep", join(root, "link")) == nil, "setup: os.symlink('keep', join(root, 'link'))")
	testing.expect_value(t, save.delete_world(root, "link"), save.Error.Not_Found)

	testing.expect_value(t, save.delete_world(root, "doomed"), save.Error.None)
	testing.expect(t, !os.exists(join(root, "doomed")), "folder gone")
	testing.expect(t, save.world_exists(root, "keep"), "sibling kept")
	testing.expect(t, os.exists(join(root, "link")), "symlink itself kept")
	testing.expect(t, os.exists(outside), "outside kept")
	testing.expect_value(t, save.delete_world(root, "doomed"), save.Error.Not_Found)
}

@(test)
last_played_text :: proc(t: ^testing.T) {
	MIN :: 60
	HOUR :: 3600
	DAY :: 86400
	now: i64 = 1_795_451_370 // 2026-11-23 16:29:30 UTC
	cases := []struct {
		ago:  i64,
		want: string,
	} {
		{-500, "just now"}, // clock skew: a time in the future
		{0, "just now"},
		{MIN - 1, "just now"},
		{MIN, "1 minute ago"},
		{2 * MIN - 1, "1 minute ago"},
		{2 * MIN, "2 minutes ago"},
		{HOUR - 1, "59 minutes ago"},
		{HOUR, "1 hour ago"},
		{2 * HOUR, "2 hours ago"},
		{DAY - 1, "23 hours ago"},
		{DAY, "yesterday"},
		{2 * DAY - 1, "yesterday"},
		{2 * DAY, "2 days ago"},
		{30 * DAY - 1, "29 days ago"},
		{30 * DAY, "on 2026-10-24"},
		{now - 0, "on 1970-01-01"},
	}
	buf: [64]u8
	for c in cases {
		got := save.format_last_played(buf[:], now, now - c.ago)
		testing.expectf(t, got == c.want, "%d s ago: '%s', want '%s'", c.ago, got, c.want)
	}
}
