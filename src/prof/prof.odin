// Manual-scope CPU profiling that writes Spall traces (gravitymoth.com/spall).
//
// Compiled out unless built with -define:PROFILE=true (`./run.sh profile`):
// every proc here is then empty, so scopes can stay in hot code for free.
//
// Usage:
//	prof.init("build/trace.spall")      // main thread, once
//	defer prof.shutdown()
//	{
//		prof.scope("mesh chunk")        // ends when the enclosing block exits
//		...
//	}
//
// Each thread records into its own thread-local buffer, written to the file
// when full and on thread_shutdown. Other threads must call thread_init /
// thread_shutdown themselves; scopes on a thread without a buffer (or
// before init / after shutdown) are ignored.
//
// Scope names are copied into the buffer (any string works; at most 255
// bytes are kept). Keep them constant: the viewer groups scopes by name.
package prof

import "core:prof/spall"
import "core:sync"
import "core:time"

_ :: sync // only used when ENABLED

ENABLED :: #config(PROFILE, false)

// Per-thread event buffer. A scope is ~30 bytes, so 1 MB holds ~30k scopes;
// a full buffer is written out mid-frame (shows up as a "Spall Trace Buffer
// Flush" event).
BUFFER_SIZE :: spall.BUFFER_DEFAULT_SIZE

// How long init spends measuring the CPU timestamp counter's frequency.
// Longer = more accurate timings; 200 ms is well under 0.1% error.
DEFAULT_CALIBRATION :: 200 * time.Millisecond

@(private)
trace: spall.Context
@(private, thread_local)
buffer: spall.Buffer
@(private, thread_local)
backing: []u8

// Creates the trace file (truncating it) and starts recording on the calling
// thread, named "main". Returns false if the file can't be created.
// Always succeeds (doing nothing) when profiling is compiled out.
init :: proc(path: string, calibration := DEFAULT_CALIBRATION) -> bool {
	when ENABLED {
		ok: bool
		trace, ok = spall.context_create_with_sleep(path, calibration)
		if !ok {
			return false
		}
		thread_init("main")
	}
	return true
}

// Writes out the calling thread's remaining events and closes the file.
// Call on the thread that called init, after other threads' thread_shutdown.
shutdown :: proc() {
	when ENABLED {
		thread_shutdown()
		spall.context_destroy(&trace)
	}
}

// Starts recording on the calling thread (not needed on the thread that called init).
thread_init :: proc(name: string) {
	when ENABLED {
		backing = make([]u8, BUFFER_SIZE)
		buffer = spall.buffer_create(backing, u32(sync.current_thread_id()))
		spall._buffer_name_thread(&trace, &buffer, name)
	}
}

// Writes out the calling thread's events and frees its buffer.
thread_shutdown :: proc() {
	when ENABLED {
		if len(buffer.data) == 0 {
			return
		}
		spall.buffer_destroy(&trace, &buffer)
		delete(backing)
		backing = nil
	}
}

// Times the rest of the enclosing block.
@(deferred_none = end)
scope :: proc "contextless" (name: string) {
	begin(name)
}

// Starts a timed span; pair with end on the same thread. Prefer scope.
begin :: proc "contextless" (name: string) {
	when ENABLED {
		if len(buffer.data) == 0 {
			return
		}
		spall._buffer_begin(&trace, &buffer, name)
	}
}

// Ends the innermost open span on this thread.
end :: proc "contextless" () {
	when ENABLED {
		if len(buffer.data) == 0 {
			return
		}
		spall._buffer_end(&trace, &buffer)
	}
}
