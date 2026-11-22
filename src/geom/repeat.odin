package geom

// Hold-to-repeat for a button: fires on the press, then every `interval`
// seconds while it stays held. `cooldown` is the caller's per-button state
// (start at 0). After a long frame it fires once, never in a burst.
repeat_update :: proc "contextless" (cooldown: ^f32, pressed, held: bool, dt, interval: f32) -> bool {
	if pressed {
		cooldown^ = interval
		return true
	}
	if !held {
		cooldown^ = 0
		return false
	}
	cooldown^ -= dt
	if cooldown^ <= 0 {
		cooldown^ = interval
		return true
	}
	return false
}
