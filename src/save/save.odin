package save

// World saves on disk, one folder per world: <root>/<name>/
//   world.json  metadata: format version, name, seed, times, player state
//   edits.bin   the edit log (world.edit_log_encode)
// Every file is written to <file>.tmp, synced, then renamed over the old
// one, so a crash mid-save leaves the previous save intact. Leftover .tmp
// files are ignored. No raylib: main converts its Player to Player_State.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "melange:world"

SAVES_DIR :: "saves" // relative to the project root (gitignored)
FORMAT_VERSION :: 1
MAX_NAME_LEN :: 32

INFO_FILE :: "world.json"
EDITS_FILE :: "edits.bin"
TMP_SUFFIX :: ".tmp"

Player_State :: struct {
	feet:   [3]f64,
	yaw:    f32,
	pitch:  f32,
	flying: bool,
}

World_Info :: struct {
	version:     int,
	name:        string, // allocated by load_info; free with info_destroy
	seed:        i64,
	created:     i64, // unix seconds
	last_played: i64, // unix seconds, updated by save_world
	player:      Player_State,
}

Error :: enum u8 {
	None,
	Bad_Name, // see valid_name
	Not_Found, // no world.json
	Read_Failed,
	Write_Failed,
	Bad_Info, // world.json isn't valid
	Newer_Version, // saved by a later version of the game
	Missing_Edits, // world.json without edits.bin
	Bad_Edits, // edits.bin isn't valid (see the world.Decode_Error)
}

// World names are folder names: 1..MAX_NAME_LEN of ASCII letters, digits,
// space, '-' and '_', not starting or ending with a space.
valid_name :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > MAX_NAME_LEN || name[0] == ' ' || name[len(name) - 1] == ' ' {
		return false
	}
	for c in transmute([]byte)name {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', ' ', '-', '_':
		case:
			return false
		}
	}
	return true
}

// <root>/<name>, allocated with `allocator`.
world_dir :: proc(root, name: string, allocator := context.allocator) -> string {
	return strings.concatenate({root, "/", name}, allocator)
}

// Whether <root>/<name> holds a world (has a world.json).
world_exists :: proc(root, name: string) -> bool {
	if !valid_name(name) {
		return false
	}
	return os.exists(file_path(root, name, INFO_FILE))
}

// Metadata for a new world (nothing is written until save_world).
new_world_info :: proc(name: string, seed: i64, now: i64) -> World_Info {
	return {version = FORMAT_VERSION, name = strings.clone(name), seed = seed, created = now, last_played = now}
}

info_destroy :: proc(info: ^World_Info) {
	delete(info.name)
	info^ = {}
}

// Reads <root>/<name>/world.json.
load_info :: proc(root, name: string) -> (info: World_Info, err: Error) {
	if !valid_name(name) {
		return {}, .Bad_Name
	}
	path := file_path(root, name, INFO_FILE)
	if !os.exists(path) {
		return {}, .Not_Found
	}
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return {}, .Read_Failed
	}
	if json.unmarshal(data, &info) != nil {
		info_destroy(&info)
		return {}, .Bad_Info
	}
	switch {
	case info.version > FORMAT_VERSION:
		err = .Newer_Version
	case info.version < 1:
		err = .Bad_Info
	}
	if err != .None {
		info_destroy(&info)
		return {}, err
	}
	// The folder name is the world's name.
	delete(info.name)
	info.name = strings.clone(name)
	return info, .None
}

// Reads <root>/<name>/edits.bin into `w` (whose edit log must be empty).
// On error the log stays empty; `decode` says what was wrong with the file.
load_edits :: proc(root, name: string, w: ^world.World) -> (err: Error, decode: world.Decode_Error) {
	path := file_path(root, name, EDITS_FILE)
	if !os.exists(path) {
		return .Missing_Edits, .None
	}
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return .Read_Failed, .None
	}
	if decode = world.edit_log_decode(w, data); decode != .None {
		return .Bad_Edits, decode
	}
	return .None, .None
}

// Writes the world: edits.bin first, then world.json (so a world.json on
// disk always has its edits.bin). Sets info.last_played = now.
save_world :: proc(root: string, info: ^World_Info, w: ^world.World, now: i64) -> Error {
	if !valid_name(info.name) {
		return .Bad_Name
	}
	dir := world_dir(root, info.name, context.temp_allocator)
	if os.make_directory_all(dir) != nil && !os.is_dir(dir) {
		return .Write_Failed
	}

	edits: [dynamic]byte
	defer delete(edits)
	world.edit_log_encode(w, &edits)
	write_atomic(file_path(root, info.name, EDITS_FILE), edits[:]) or_return

	info.version = FORMAT_VERSION
	info.last_played = now
	text, marshal_err := json.marshal(info^, {pretty = true}, context.temp_allocator)
	if marshal_err != nil {
		return .Write_Failed
	}
	return write_atomic(file_path(root, info.name, INFO_FILE), text)
}

@(private)
file_path :: proc(root, name, file: string) -> string {
	return strings.concatenate({root, "/", name, "/", file}, context.temp_allocator)
}

// Writes path + ".tmp", syncs it to disk, then renames it over `path`.
@(private)
write_atomic :: proc(path: string, data: []byte) -> Error {
	tmp := strings.concatenate({path, TMP_SUFFIX}, context.temp_allocator)
	f, open_err := os.open(tmp, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if open_err != nil {
		return .Write_Failed
	}
	n, write_err := os.write(f, data)
	sync_err := os.sync(f)
	close_err := os.close(f)
	if n != len(data) || write_err != nil || sync_err != nil || close_err != nil {
		os.remove(tmp)
		return .Write_Failed
	}
	if os.rename(tmp, path) != nil {
		os.remove(tmp)
		return .Write_Failed
	}
	return .None
}

// ---- World list --------------------------------------------------------------

// One world in the saves folder, for the world select screen.
World_Entry :: struct {
	name: string, // the folder name (owned)
	info: World_Info, // valid when err == .None (owned)
	err:  Error, // why world.json can't be loaded (the world can't be played)
}

// The worlds in `root`: every folder with a valid name and a world.json
// (other folders and files are ignored; symlinks aren't followed). Playable
// worlds come first, most recently played first, ties by name; then broken
// ones by name. A missing `root` is an empty list. Free with
// world_entries_destroy.
list_worlds :: proc(root: string, allocator := context.allocator) -> []World_Entry {
	context.allocator = allocator
	infos, err := os.read_all_directory_by_path(root, context.temp_allocator)
	if err != nil {
		return nil
	}
	entries := make([dynamic]World_Entry, 0, len(infos))
	for fi in infos {
		if fi.type != .Directory || !valid_name(fi.name) || !os.exists(file_path(root, fi.name, INFO_FILE)) {
			continue
		}
		info, load_err := load_info(root, fi.name)
		append(&entries, World_Entry{name = strings.clone(fi.name), info = info, err = load_err})
	}
	slice.sort_by(entries[:], world_entry_less)
	return entries[:]
}

// Sort order of list_worlds.
world_entry_less :: proc(a, b: World_Entry) -> bool {
	a_ok, b_ok := a.err == .None, b.err == .None
	if a_ok != b_ok {
		return a_ok
	}
	if a_ok && a.info.last_played != b.info.last_played {
		return a.info.last_played > b.info.last_played
	}
	return a.name < b.name
}

world_entries_destroy :: proc(entries: []World_Entry, allocator := context.allocator) {
	context.allocator = allocator
	for &e in entries {
		delete(e.name)
		info_destroy(&e.info)
	}
	delete(entries)
}

// Permanently deletes the world folder <root>/<name> and everything in it.
// Refuses invalid names (so never anything outside <root>) and anything
// that isn't a real folder (e.g. a symlink).
delete_world :: proc(root, name: string) -> Error {
	if !valid_name(name) {
		return .Bad_Name
	}
	dir := world_dir(root, name, context.temp_allocator)
	fi, err := os.lstat(dir, context.temp_allocator)
	if err != nil || fi.type != .Directory {
		return .Not_Found
	}
	if os.remove_all(dir) != nil {
		return .Write_Failed
	}
	return .None
}

// "just now", "5 minutes ago", "yesterday", "3 days ago", or the date
// ("on 2026-10-01", UTC) after 30 days. Times are unix seconds; a `then`
// in the future (clock changes) is "just now". Written into `buf`.
format_last_played :: proc(buf: []u8, now, then: i64) -> string {
	MINUTE :: 60
	HOUR :: 60 * MINUTE
	DAY :: 24 * HOUR
	d := now - then
	switch {
	case d < MINUTE:
		return fmt.bprint(buf, "just now")
	case d < HOUR:
		return plural_ago(buf, d / MINUTE, "minute")
	case d < DAY:
		return plural_ago(buf, d / HOUR, "hour")
	case d < 2 * DAY:
		return fmt.bprint(buf, "yesterday")
	case d < 30 * DAY:
		return plural_ago(buf, d / DAY, "day")
	}
	y, m, day := time.date(time.unix(then, 0))
	return fmt.bprintf(buf, "on %04d-%02d-%02d", y, int(m), day)
}

@(private = "file")
plural_ago :: proc(buf: []u8, n: i64, unit: string) -> string {
	return fmt.bprintf(buf, "%d %s%s ago", n, unit, "" if n == 1 else "s")
}
