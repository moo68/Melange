// Tests for melange:prof with profiling compiled in. Built separately with
// -define:PROFILE=true by `./run.sh test` (the main tests/ package covers the
// compiled-out build).
package prof_tests

import "core:os"
import "core:prof/spall"
import "core:testing"
import "core:time"
import "melange:prof"

#assert(prof.ENABLED, "build this package with -define:PROFILE=true")

TRACE :: "build/test-prof.spall"
FLUSH_EVENT :: "Spall Trace Buffer Flush" // written by spall itself after each flush

Event :: struct {
	kind: spall.Manual_Event_Type,
	name: string, // Begin and Name_Thread; slices the file data
	ts:   u64,
}

Trace :: struct {
	data:    []u8,
	events:  [dynamic]Event,
	buffers: int,
	tids:    [dynamic]u32,
}

trace_destroy :: proc(tr: ^Trace) {
	delete(tr.data)
	delete(tr.events)
	delete(tr.tids)
}

// Parses a whole trace: stream header, then buffers (header + events).
// Fails the test on anything malformed.
parse_trace :: proc(t: ^testing.T, path: string) -> (tr: Trace, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if !testing.expectf(t, err == nil, "can't read %s: %v", path, err) {
		return
	}
	tr.data = data
	if !testing.expect(t, len(data) >= size_of(spall.Manual_Stream_Header), "file shorter than the header") {
		return
	}
	hdr := (^spall.Manual_Stream_Header)(raw_data(data))
	testing.expect_value(t, hdr.magic, spall.MANUAL_MAGIC)
	testing.expect_value(t, hdr.version, 3)
	testing.expect(t, hdr.timestamp_scale > 0, "timestamp scale must be positive")

	pos := size_of(spall.Manual_Stream_Header)
	for pos < len(data) {
		if !testing.expect(t, pos + size_of(spall.Manual_Buffer_Header) <= len(data), "truncated buffer header") {
			return
		}
		bh := (^spall.Manual_Buffer_Header)(raw_data(data[pos:]))
		pos += size_of(spall.Manual_Buffer_Header)
		buf_end := pos + int(bh.size)
		if !testing.expect(t, buf_end <= len(data), "buffer runs past end of file") {
			return
		}
		tr.buffers += 1
		append(&tr.tids, u32(bh.tid))
		for pos < buf_end {
			kind := spall.Manual_Event_Type(data[pos])
			#partial switch kind {
			case .Begin:
				ev := (^spall.Begin_Event)(raw_data(data[pos:]))
				pos += size_of(spall.Begin_Event)
				name := string(data[pos:][:ev.name_len])
				pos += int(ev.name_len) + int(ev.args_len)
				append(&tr.events, Event{.Begin, name, u64(ev.ts)})
			case .End:
				ev := (^spall.End_Event)(raw_data(data[pos:]))
				pos += size_of(spall.End_Event)
				append(&tr.events, Event{.End, "", u64(ev.ts)})
			case .Name_Thread:
				ev := (^spall.Name_Event)(raw_data(data[pos:]))
				pos += size_of(spall.Name_Event)
				append(&tr.events, Event{.Name_Thread, string(data[pos:][:ev.name_len]), 0})
				pos += int(ev.name_len)
			case:
				testing.expectf(t, false, "unexpected event type %v at byte %d", kind, pos)
				return
			}
		}
		if !testing.expect(t, pos == buf_end, "events overran their buffer") {
			return
		}
	}
	return tr, true
}

// Begin names in order, without spall's own flush events.
begin_names :: proc(tr: ^Trace, allocator := context.temp_allocator) -> [dynamic]string {
	names := make([dynamic]string, allocator)
	for e in tr.events {
		if e.kind == .Begin && e.name != FLUSH_EVENT {
			append(&names, e.name)
		}
	}
	return names
}

// Begins and ends nest properly (never more ends than begins, all closed)
// and timestamps never go backwards.
expect_well_formed :: proc(t: ^testing.T, tr: ^Trace) {
	depth := 0
	last_ts: u64
	for e in tr.events {
		switch e.kind {
		case .Begin:
			depth += 1
		case .End:
			depth -= 1
			testing.expect(t, depth >= 0, "end without a matching begin")
		case .Invalid, .Instant, .Pad_Skip, .Name_Process, .Name_Thread:
			continue
		}
		testing.expect(t, e.ts >= last_ts, "timestamps went backwards")
		last_ts = e.ts
	}
	testing.expect_value(t, depth, 0)
}

nested :: proc() {
	prof.scope("outer")
	for _ in 0 ..< 3 {
		prof.scope("inner")
	}
	prof.begin("manual")
	prof.end()
}

// One test for everything that touches the trace file and the global
// context, so parallel tests can't interfere.
@(test)
records_scopes_to_a_valid_trace :: proc(t: ^testing.T) {
	defer os.remove(TRACE)

	// Ignored: no buffer before init.
	prof.scope("before init")

	testing.expect(t, prof.init(TRACE, 10 * time.Millisecond))
	nested()
	// Enough events to fill the 1 MB buffer a few times: every event must
	// survive the mid-recording flushes.
	MANY :: 100_000 // ~2.1 MB of "x" scopes (11 + 1 + 9 bytes each)
	for _ in 0 ..< MANY {
		prof.scope("x")
	}
	prof.shutdown()

	// Ignored: buffer gone after shutdown.
	prof.scope("after shutdown")

	tr, ok := parse_trace(t, TRACE)
	defer trace_destroy(&tr)
	if !ok {
		return
	}
	expect_well_formed(t, &tr)

	testing.expect(t, tr.buffers >= 3, "MANY scopes should span several buffer flushes")
	for tid in tr.tids {
		testing.expect_value(t, tid, tr.tids[0]) // all from this thread
	}
	testing.expect_value(t, tr.events[0].kind, spall.Manual_Event_Type.Name_Thread)
	testing.expect_value(t, tr.events[0].name, "main")

	names := begin_names(&tr)
	if !testing.expect_value(t, len(names), 5 + MANY) {
		return
	}
	expected := [5]string{"outer", "inner", "inner", "inner", "manual"}
	for name, i in expected {
		testing.expect_value(t, names[i], name)
	}
	for name in names[5:] {
		if name != "x" {
			testing.expectf(t, false, "unexpected scope %q", name)
			break
		}
	}

	// Exact nesting: each "inner" ends before the next begins, and "outer"
	// ends last, after "manual".
	B, E :: spall.Manual_Event_Type.Begin, spall.Manual_Event_Type.End
	shape := [?]spall.Manual_Event_Type{B, B, E, B, E, B, E, B, E, E, B}
	if !testing.expect(t, len(tr.events) > len(shape)) {
		return
	}
	for kind, i in shape {
		testing.expectf(t, tr.events[1 + i].kind == kind, "event %d: got %v, want %v", 1 + i, tr.events[1 + i].kind, kind)
	}
}
