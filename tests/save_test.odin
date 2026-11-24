package tests

import "core:math/rand"
import "core:os"
import "core:strings"
import "core:testing"
import "melange:save"
import "melange:world"

// A fresh, empty saves root for one test (tests run in parallel).
test_saves_root :: proc(test_name: string) -> string {
	root := strings.concatenate({"build/test-saves/", test_name}, context.temp_allocator)
	os.remove_all(root)
	os.make_directory_all(root)
	return root
}

// Random edits through world_set_block, spread over many chunks (created
// as needed), including re-edits of the same block.
random_edits :: proc(w: ^world.World, r: ^rand.Generator, n: int) {
	for _ in 0 ..< n {
		coord := [3]i32{rand.int32_range(-12, 12, r^), rand.int32_range(-3, 3, r^), rand.int32_range(-12, 12, r^)}
		if world.world_get_chunk(w, coord) == nil {
			world.world_create_chunk(w, coord)
		}
		// Half the edits hit a 4x4x4 corner, so many overwrite earlier ones.
		span := i32(4 if rand.int_max(2, r^) == 0 else world.CHUNK_SIZE)
		local := [3]i32{i32(rand.int_max(int(span), r^)), i32(rand.int_max(int(span), r^)), i32(rand.int_max(int(span), r^))}
		world.world_set_block(w, coord * world.CHUNK_SIZE + local, world.Block_ID(1 + rand.int_max(1 << 16 - 1, r^)))
	}
}

expect_same_log :: proc(t: ^testing.T, a, b: ^world.World) {
	testing.expect_value(t, b.edit_count, a.edit_count)
	testing.expect_value(t, len(b.edits), len(a.edits))
	for coord, list in a.edits {
		got := world.world_chunk_edits(b, coord)
		if !testing.expectf(t, len(got) == len(list), "chunk %v: %d edits, want %d", coord, len(got), len(list)) {
			return
		}
		for e, i in list {
			if got[i] != e {
				testing.expectf(t, false, "chunk %v edit %d: %v, want %v", coord, i, got[i], e)
				return
			}
		}
	}
}

encode :: proc(w: ^world.World) -> [dynamic]byte {
	out: [dynamic]byte
	world.edit_log_encode(w, &out)
	return out
}

@(test)
edit_log_round_trip :: proc(t: ^testing.T) {
	gen := rand.create(7)
	r := rand.default_random_generator(&gen)
	a: world.World
	world.world_init(&a, 1)
	defer world.world_destroy(&a)
	random_edits(&a, &r, 20_000)
	testing.expect(t, len(a.edits) > 1000, "many chunks")
	testing.expect(t, a.edit_count < 20_000, "some re-edits")

	data := encode(&a)
	defer delete(data)
	testing.expect_value(t, len(data), world.EDIT_LOG_HEADER_SIZE + len(a.edits) * world.EDIT_LOG_CHUNK_HEADER_SIZE + a.edit_count * world.EDIT_LOG_ENTRY_SIZE)

	b: world.World
	world.world_init(&b, 1)
	defer world.world_destroy(&b)
	testing.expect_value(t, world.edit_log_decode(&b, data[:]), world.Decode_Error.None)
	expect_same_log(t, &a, &b)

	// Re-encoding gives the same bytes (chunks are written sorted).
	again := encode(&b)
	defer delete(again)
	testing.expect(t, string(again[:]) == string(data[:]), "re-encoding is identical")

	// An empty log round-trips too.
	e: world.World
	world.world_init(&e, 1)
	defer world.world_destroy(&e)
	empty := encode(&e)
	defer delete(empty)
	testing.expect_value(t, len(empty), world.EDIT_LOG_HEADER_SIZE)
	testing.expect_value(t, world.edit_log_decode(&e, empty[:]), world.Decode_Error.None)
}

// Decodes `data` into a fresh world; on failure the log must be left empty.
decode_fresh :: proc(t: ^testing.T, data: []byte) -> world.Decode_Error {
	w: world.World
	world.world_init(&w, 1)
	defer world.world_destroy(&w)
	err := world.edit_log_decode(&w, data)
	if err != .None {
		testing.expectf(t, len(w.edits) == 0 && w.edit_count == 0, "%v left %d chunks / %d edits behind", err, len(w.edits), w.edit_count)
	}
	return err
}

@(test)
edit_log_decode_rejects_bad_files :: proc(t: ^testing.T) {
	gen := rand.create(8)
	r := rand.default_random_generator(&gen)
	w: world.World
	world.world_init(&w, 1)
	defer world.world_destroy(&w)
	random_edits(&w, &r, 300)
	// The first chunk written (lowest coord) gets 3 edits.
	first := [3]i32{-20, 0, 0}
	world.world_create_chunk(&w, first)
	for i in i32(0) ..< 3 {
		world.world_set_block(&w, first * world.CHUNK_SIZE + {i, 0, 0}, world.STONE)
	}
	good := encode(&w)
	defer delete(good)

	// Every truncation fails cleanly.
	for n in 0 ..< len(good) {
		if err := decode_fresh(t, good[:n]); err != .Truncated {
			testing.expectf(t, false, "prefix of %d bytes: %v, want Truncated", n, err)
			return
		}
	}

	bad := make([]byte, len(good) + 4)
	defer delete(bad)
	reset :: proc(bad: []byte, good: []byte) -> []byte {
		copy(bad, good)
		return bad[:len(good)]
	}
	put32 :: proc(b: []byte, v: u32) {
		b[0], b[1], b[2], b[3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)
	}
	put16 :: proc(b: []byte, v: u16) {
		b[0], b[1] = u8(v), u8(v >> 8)
	}
	H :: world.EDIT_LOG_HEADER_SIZE
	C :: world.EDIT_LOG_CHUNK_HEADER_SIZE
	first_count := int(good[H + 12]) | int(good[H + 13]) << 8

	b := reset(bad, good[:])
	b[0] = 'X'
	testing.expect_value(t, decode_fresh(t, b), world.Decode_Error.Bad_Magic)

	b = reset(bad, good[:])
	put32(b[8:], world.EDIT_LOG_VERSION + 1)
	testing.expect_value(t, decode_fresh(t, b), world.Decode_Error.Newer_Version)
	put32(b[8:], 0)
	testing.expect_value(t, decode_fresh(t, b), world.Decode_Error.Bad_Version)

	// One chunk too many claimed / too few: truncated / trailing data.
	b = reset(bad, good[:])
	put32(b[12:], u32(len(w.edits) + 1))
	testing.expect_value(t, decode_fresh(t, b), world.Decode_Error.Truncated)
	put32(b[12:], u32(len(w.edits) - 1))
	testing.expect_value(t, decode_fresh(t, b), world.Decode_Error.Trailing_Data)
	b = bad[:len(good) + 1]
	copy(b, good[:])
	testing.expect_value(t, decode_fresh(t, b), world.Decode_Error.Trailing_Data)

	// Edit counts: 0, more than a chunk holds.
	b = reset(bad, good[:])
	put32(b[H + 12:], 0)
	testing.expect_value(t, decode_fresh(t, b), world.Decode_Error.Bad_Count)
	put32(b[H + 12:], world.CHUNK_VOLUME + 1)
	testing.expect_value(t, decode_fresh(t, b), world.Decode_Error.Bad_Count)
	// A file that is otherwise well-formed: one chunk with no edits.
	empty_chunk: [H + C]byte
	copy(empty_chunk[:], good[:8])
	put32(empty_chunk[8:], world.EDIT_LOG_VERSION)
	put32(empty_chunk[12:], 1)
	testing.expect_value(t, decode_fresh(t, empty_chunk[:]), world.Decode_Error.Bad_Count)

	// A block index out of range, in the last entry of the first chunk (so
	// the earlier ones were already added and must be rolled back).
	last := H + C + (first_count - 1) * world.EDIT_LOG_ENTRY_SIZE
	b = reset(bad, good[:])
	put16(b[last:], world.CHUNK_VOLUME)
	testing.expect_value(t, decode_fresh(t, b), world.Decode_Error.Bad_Index)
	put16(b[last:], world.CHUNK_VOLUME - 1) // the highest valid index
	testing.expect_value(t, decode_fresh(t, b), world.Decode_Error.None)

	// The same block twice in one chunk.
	testing.expect_value(t, first_count, 3)
	b = reset(bad, good[:])
	copy(b[last:last + 2], b[last - world.EDIT_LOG_ENTRY_SIZE:])
	testing.expect_value(t, decode_fresh(t, b), world.Decode_Error.Duplicate_Index)

	// The same chunk twice: copy the first chunk's coord onto the second's.
	b = reset(bad, good[:])
	second := H + C + first_count * world.EDIT_LOG_ENTRY_SIZE
	copy(b[second:second + 12], b[H:H + 12])
	testing.expect_value(t, decode_fresh(t, b), world.Decode_Error.Duplicate_Chunk)

	// Decoding into a world that already has edits is refused (and keeps them).
	testing.expect_value(t, world.edit_log_decode(&w, good[:]), world.Decode_Error.Log_Not_Empty)
	testing.expect(t, w.edit_count > 0, "existing edits kept")
}

@(test)
world_names :: proc(t: ^testing.T) {
	for name in ([]string{"a", "My World", "test-1_2", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"}) {
		testing.expectf(t, save.valid_name(name), "'%s' should be valid", name)
	}
	bad := []string{"", " a", "a ", "../x", "a/b", "a.b", ".", "..", "é", "a\x00", "tab\t", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456"}
	for name in bad {
		testing.expectf(t, !save.valid_name(name), "'%s' should be invalid", name)
	}
}

@(test)
world_info_round_trip :: proc(t: ^testing.T) {
	root := test_saves_root("info")
	defer os.remove_all(root)
	w: world.World
	world.world_init(&w, 1)
	defer world.world_destroy(&w)

	seeds := []i64{min(i64), max(i64), -1, 0, 1337}
	feet := [][3]f64{{0.5, 64.001, 0.5}, {1_000_000.123, -63.999, -1_000_000.987654321}, {-0.3, 110.0000001, 2.25}}
	for seed, i in seeds {
		info := save.new_world_info("w", seed, 1_795_000_000 + i64(i))
		defer save.info_destroy(&info)
		info.player = {feet[i % len(feet)], 359.99, -89, i % 2 == 0}
		info.time = 0 if i == 0 else 98_765.4321 * f64(i)
		testing.expect_value(t, save.save_world(root, &info, &w, 1_800_000_000), save.Error.None)
		testing.expect_value(t, info.last_played, 1_800_000_000)

		got, err := save.load_info(root, "w")
		defer save.info_destroy(&got)
		testing.expect_value(t, err, save.Error.None)
		testing.expect_value(t, got.version, save.FORMAT_VERSION)
		testing.expect_value(t, got.name, "w")
		testing.expect_value(t, got.seed, seed)
		testing.expect_value(t, got.created, info.created)
		testing.expect_value(t, got.last_played, info.last_played)
		// JSON floats are written with 16 decimals: exact for these magnitudes.
		testing.expect_value(t, got.player, info.player)
		testing.expect_value(t, got.time, info.time)
	}
}

// Saves from before day/night have no "time": they load at 0 (day 1, 7:00).
@(test)
world_info_without_time_loads_at_morning :: proc(t: ^testing.T) {
	root := test_saves_root("info-no-time")
	defer os.remove_all(root)
	_ = os.make_directory_all(strings.concatenate({root, "/old"}, context.temp_allocator))
	write_file(t, strings.concatenate({root, "/old/", save.INFO_FILE}, context.temp_allocator), `{
	"version": 1, "name": "old", "seed": 5, "created": 1, "last_played": 2,
	"player": {"feet": [0.5, 10, 0.5], "yaw": 0, "pitch": 0, "flying": false}
}`)
	got, err := save.load_info(root, "old")
	defer save.info_destroy(&got)
	testing.expect_value(t, err, save.Error.None)
	testing.expect_value(t, got.seed, 5)
	testing.expect_value(t, got.time, 0)
}

@(test)
save_and_load_world_end_to_end :: proc(t: ^testing.T) {
	root := test_saves_root("end_to_end")
	defer os.remove_all(root)

	e: Edit_World
	edit_world_init(&e)
	h := e.surface
	for i in i32(0) ..< 40 {
		world.world_set_block(&e.w, {i - 20, h - i % 3, 3}, world.AIR)
		world.world_set_block(&e.w, {5, h + 1 + i % 4, i - 20}, world.STONE)
	}
	sky := (e.center.y + 1) * world.CHUNK_SIZE + 8 // the chunk above: no terrain (sky fast path)
	testing.expect(t, world.world_set_block(&e.w, {0, sky, 0}, world.DIRT), "placed in the sky")
	info := save.new_world_info("e2e", e.w.seed, 1)
	info.player = {{0.5, f64(h) + 1.001, 0.5}, 45, -10, false}
	testing.expect_value(t, save.save_world(root, &info, &e.w, 2), save.Error.None)
	want_count := e.w.edit_count
	save.info_destroy(&info)
	edit_world_destroy(&e) // everything in memory is gone

	got, err := save.load_info(root, "e2e")
	defer save.info_destroy(&got)
	testing.expect_value(t, err, save.Error.None)
	testing.expect_value(t, got.player.feet, [3]f64{0.5, f64(h) + 1.001, 0.5})

	f: Edit_World
	world.world_init(&f.w, got.seed)
	load_err, decode := save.load_edits(root, "e2e", &f.w)
	testing.expect_value(t, load_err, save.Error.None)
	testing.expect_value(t, decode, world.Decode_Error.None)
	testing.expect_value(t, f.w.edit_count, want_count)
	world.streamer_init(&f.s, SMALL)
	f.surface = world.terrain_height(f.w.seed, 0, 0)
	f.center = world.block_to_chunk({0, f.surface, 0})
	world.streamer_update(&f.s, &f.w, f.center)
	defer edit_world_destroy(&f)

	expect_generated_plus_edits(t, &f.w)
	for check in ([]struct {
			b:  [3]i32,
			id: world.Block_ID,
		}{{{-20, h, 3}, world.AIR}, {{5, h + 1, 0}, world.STONE}, {{0, sky, 0}, world.DIRT}}) {
		id, ok := world.world_get_block(&f.w, check.b)
		testing.expectf(t, ok && id == check.id, "block %v: %v (loaded %v), want %v", check.b, id, ok, check.id)
	}
}

@(test)
save_errors :: proc(t: ^testing.T) {
	root := test_saves_root("errors")
	defer os.remove_all(root)
	w: world.World
	world.world_init(&w, 1)
	defer world.world_destroy(&w)

	_, err := save.load_info(root, "nope")
	testing.expect_value(t, err, save.Error.Not_Found)
	testing.expect(t, !save.world_exists(root, "nope"), "doesn't exist")
	_, err = save.load_info(root, "../x")
	testing.expect_value(t, err, save.Error.Bad_Name)

	info := save.new_world_info("x", 5, 1)
	defer save.info_destroy(&info)
	testing.expect_value(t, save.save_world(root, &info, &w, 1), save.Error.None)
	testing.expect(t, save.world_exists(root, "x"), "exists after saving")
	dir := save.world_dir(root, "x", context.temp_allocator)
	info_path := strings.concatenate({dir, "/", save.INFO_FILE}, context.temp_allocator)
	edits_path := strings.concatenate({dir, "/", save.EDITS_FILE}, context.temp_allocator)

	// No .tmp files are left behind; stray ones are ignored.
	testing.expect(t, !os.exists(strings.concatenate({info_path, save.TMP_SUFFIX}, context.temp_allocator)), "no world.json.tmp")
	testing.expect(t, !os.exists(strings.concatenate({edits_path, save.TMP_SUFFIX}, context.temp_allocator)), "no edits.bin.tmp")
	write_file(t, strings.concatenate({info_path, save.TMP_SUFFIX}, context.temp_allocator), "garbage")
	write_file(t, strings.concatenate({edits_path, save.TMP_SUFFIX}, context.temp_allocator), "garbage")
	got, load_err := save.load_info(root, "x")
	save.info_destroy(&got)
	testing.expect_value(t, load_err, save.Error.None)
	edits_err, _ := save.load_edits(root, "x", &w)
	testing.expect_value(t, edits_err, save.Error.None)

	// A newer format, a missing version, broken JSON.
	for text, i in ([]string{`{"version": 2, "name": "x", "seed": 5}`, `{"name": "x", "seed": 5}`, `{"version": 1, "seed": `}) {
		write_file(t, info_path, text)
		got, err = save.load_info(root, "x")
		save.info_destroy(&got)
		want := save.Error.Newer_Version if i == 0 else save.Error.Bad_Info
		testing.expectf(t, err == want, "%s: %v, want %v", text, err, want)
	}

	// edits.bin missing or corrupt.
	os.remove(edits_path)
	edits_err, _ = save.load_edits(root, "x", &w)
	testing.expect_value(t, edits_err, save.Error.Missing_Edits)
	write_file(t, edits_path, "MLEDITS\x00garbage")
	decode: world.Decode_Error
	edits_err, decode = save.load_edits(root, "x", &w)
	testing.expect_value(t, edits_err, save.Error.Bad_Edits)
	testing.expect_value(t, decode, world.Decode_Error.Truncated)
}

write_file :: proc(t: ^testing.T, path: string, text: string) {
	testing.expectf(t, os.write_entire_file(path, text) == nil, "writing %s", path)
}
