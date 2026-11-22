package tests

import "core:os"
import "core:testing"
import "melange:prof"

// The normal test build has profiling compiled out (tests/prof/ covers it
// compiled in): init succeeds without creating a file and scopes do nothing.
@(test)
prof_compiled_out_writes_nothing :: proc(t: ^testing.T) {
	PATH :: "build/test-prof-disabled.spall"
	testing.expect(t, !prof.ENABLED, "tests/ must build without -define:PROFILE=true")
	os.remove(PATH)
	testing.expect(t, prof.init(PATH))
	{
		prof.scope("ignored")
	}
	prof.shutdown()
	testing.expect(t, !os.exists(PATH), "a compiled-out profiler must not create a trace file")
}
