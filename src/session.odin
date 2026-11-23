package main

// Opening, creating and saving the world given by --world (package save
// does the files; this converts between it and the Player).

import "core:fmt"
import "core:math/rand"
import "core:time"
import "melange:player"
import "melange:save"
import "melange:world"

AUTOSAVE_INTERVAL :: 5 * 60.0 // seconds of play

Session :: struct {
	saving:         bool, // false without --world: nothing is saved
	info:           save.World_Info,
	autosave_timer: f64,
}

// Initializes `w` and `pl` from --world (opening or creating the save) or,
// without it, as an unsaved world with --seed. Prints why on failure (and
// leaves `w` uninitialized). `debug` is set if the player was flying.
session_open :: proc(opts: Options, w: ^world.World, pl: ^player.Player, debug: ^bool) -> (sess: Session, ok: bool) {
	if opts.world == "" {
		world.world_init(w, opts.seed)
		pl^ = player.player_spawn(w.seed, 0, 0, 45, -10)
		return {}, true
	}
	sess.saving = true
	name := opts.world

	if !save.world_exists(save.SAVES_DIR, name) {
		seed := opts.seed if opts.seed_set else i64(rand.uint64())
		sess.info = save.new_world_info(name, seed, unix_now())
		world.world_init(w, seed)
		// Walking on the surface at the origin, looking toward +X+Z and a bit down.
		pl^ = player.player_spawn(w.seed, 0, 0, 45, -10)
		if !session_save(&sess, w, pl) {
			session_close(&sess)
			world.world_destroy(w)
			return {}, false
		}
		fmt.printfln("created world '%s' (seed %d) in %s/%s", name, seed, save.SAVES_DIR, name)
		return sess, true
	}

	err: save.Error
	if sess.info, err = save.load_info(save.SAVES_DIR, name); err != .None {
		fmt.eprintfln("can't load world '%s': %v (in %s/%s/%s)", name, err, save.SAVES_DIR, name, save.INFO_FILE)
		return {}, false
	}
	if opts.seed_set && opts.seed != sess.info.seed {
		fmt.eprintfln("world '%s' already exists with seed %d; drop --seed or pick another name", name, sess.info.seed)
		session_close(&sess)
		return {}, false
	}
	world.world_init(w, sess.info.seed)
	if edits_err, decode := save.load_edits(save.SAVES_DIR, name, w); edits_err != .None {
		fmt.eprintfln("can't load world '%s': %v %v (in %s/%s/%s)", name, edits_err, decode, save.SAVES_DIR, name, save.EDITS_FILE)
		session_close(&sess)
		world.world_destroy(w)
		return {}, false
	}
	ps := sess.info.player
	pl^ = player.player_at(ps.feet, ps.yaw, ps.pitch)
	if ps.flying {
		debug^ = true
		player.set_mode(pl, w, .Fly)
	}
	fmt.printfln("loaded world '%s' (seed %d, %d edits)", name, w.seed, w.edit_count)
	return sess, true
}

// Saves the world and player (no-op without --world). Prints why on failure.
session_save :: proc(sess: ^Session, w: ^world.World, pl: ^player.Player) -> bool {
	if !sess.saving {
		return true
	}
	sess.info.player = {
		feet   = pl.body.position,
		yaw    = pl.yaw,
		pitch  = pl.pitch,
		flying = pl.mode == .Fly,
	}
	sess.autosave_timer = 0
	if err := save.save_world(save.SAVES_DIR, &sess.info, w, unix_now()); err != .None {
		fmt.eprintfln("saving world '%s' failed: %v", sess.info.name, err)
		return false
	}
	return true
}

// Call once per frame; saves every AUTOSAVE_INTERVAL seconds.
session_tick :: proc(sess: ^Session, w: ^world.World, pl: ^player.Player, dt: f64) {
	if !sess.saving {
		return
	}
	sess.autosave_timer += dt
	if sess.autosave_timer >= AUTOSAVE_INTERVAL {
		session_save(sess, w, pl)
	}
}

session_close :: proc(sess: ^Session) {
	save.info_destroy(&sess.info)
}

@(private = "file")
unix_now :: proc() -> i64 {
	return time.time_to_unix(time.now())
}
