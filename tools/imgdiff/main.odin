package main

// imgdiff A.png B.png [OUT.png]: compares two screenshots of the same size
// (e.g. from `--frames N --screenshot PATH` before and after a rendering
// change). Prints how many pixels differ, how many by more than 1 level
// (repeat runs of the same build differ by ±1 in a few dozen pixels: draw
// order), the largest channel difference, and the first few pixels that
// differ by more than 1. OUT gets a map: differing pixels red, the rest
// image A dimmed. Exit code 0 = identical, 1 = different, 2 = bad input.

import "core:fmt"
import "core:os"
import "core:strings"
import rl "third_party:raylib"

main :: proc() {
	os.exit(run())
}

run :: proc() -> int {
	if len(os.args) < 3 {
		fmt.eprintln("usage: imgdiff A.png B.png [OUT.png]")
		return 2
	}
	rl.SetTraceLogLevel(.WARNING)
	a := rl.LoadImage(strings.clone_to_cstring(os.args[1]))
	b := rl.LoadImage(strings.clone_to_cstring(os.args[2]))
	defer rl.UnloadImage(a)
	defer rl.UnloadImage(b)
	if a.data == nil || b.data == nil {
		fmt.eprintln("couldn't load both images")
		return 2
	}
	if a.width != b.width || a.height != b.height {
		fmt.printfln("size differs: %dx%d vs %dx%d", a.width, a.height, b.width, b.height)
		return 1
	}
	out := rl.ImageCopy(a)
	defer rl.UnloadImage(out)
	diff, big, max_d := 0, 0, 0
	for y in 0 ..< a.height {
		for x in 0 ..< a.width {
			ca, cb := rl.GetImageColor(a, x, y), rl.GetImageColor(b, x, y)
			d := max(abs(int(ca.r) - int(cb.r)), abs(int(ca.g) - int(cb.g)), abs(int(ca.b) - int(cb.b)))
			if d == 0 {
				rl.ImageDrawPixel(&out, x, y, {ca.r / 3, ca.g / 3, ca.b / 3, 255})
				continue
			}
			diff += 1
			max_d = max(max_d, d)
			rl.ImageDrawPixel(&out, x, y, rl.RED)
			if d > 1 {
				if big < 10 {
					fmt.printfln("  (%d, %d): %v -> %v", x, y, ca, cb)
				}
				big += 1
			}
		}
	}
	total := int(a.width * a.height)
	fmt.printfln("%dx%d: %d pixels differ (%.4f%%), %d by more than 1, max channel diff %d", a.width, a.height, diff, 100 * f64(diff) / f64(total), big, max_d)
	if len(os.args) > 3 {
		rl.ExportImage(out, strings.clone_to_cstring(os.args[3]))
	}
	return 0 if diff == 0 else 1
}
