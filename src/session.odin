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

// Which world to open: a save (opened, or created if missing) or, with no
// name, an unsaved world.
World_Request :: struct {
	name:     string, // saves/<name>; "" = unsaved world with `seed`
	seed:     i64, // for an unsaved or new world (if seed_set); an existing one must match
	seed_set: bool, // false: a new world gets a random seed
	create:   bool, // must be new: fail if saves/<name> already exists (never opens it)
}

// The world asked for on the command line.
request_from_opts :: proc(opts: Options) -> World_Request {
	return {name = opts.world, seed = opts.seed, seed_set = opts.seed_set}
}

// Initializes `w` and `pl` for `req`. On failure returns why (also printed;
// temp-allocated) and leaves `w` uninitialized. `debug` is set if the player
// was flying.
session_open :: proc(req: World_Request, w: ^world.World, pl: ^player.Player, debug: ^bool) -> (sess: Session, failure: string) {
	if req.name == "" {
		world.world_init(w, req.seed)
		pl^ = spawn_player(w.seed)
		return {}, ""
	}
	sess.saving = true
	name := req.name
	fail :: proc(format: string, args: ..any) -> string {
		msg := fmt.tprintf(format, ..args)
		fmt.eprintln(msg)
		return msg
	}

	if req.create && save.check_new_name(save.SAVES_DIR, name) != .None {
		return {}, fail("can't create world '%s': %s", name, save.name_problem_text(save.check_new_name(save.SAVES_DIR, name)))
	}
	if !save.world_exists(save.SAVES_DIR, name) {
		seed := req.seed if req.seed_set else i64(rand.uint64())
		sess.info = save.new_world_info(name, seed, unix_now())
		world.world_init(w, seed)
		pl^ = spawn_player(w.seed)
		if !session_save(&sess, w, pl) {
			session_close(&sess)
			world.world_destroy(w)
			return {}, fmt.tprintf("couldn't create world '%s' (see the terminal)", name)
		}
		fmt.printfln("created world '%s' (seed %d) in %s/%s", name, seed, save.SAVES_DIR, name)
		return sess, ""
	}

	err: save.Error
	if sess.info, err = save.load_info(save.SAVES_DIR, name); err != .None {
		return {}, fail("can't load world '%s': %v (in %s/%s/%s)", name, err, save.SAVES_DIR, name, save.INFO_FILE)
	}
	if req.seed_set && req.seed != sess.info.seed {
		msg := fail("world '%s' already exists with seed %d; drop --seed or pick another name", name, sess.info.seed)
		session_close(&sess)
		return {}, msg
	}
	world.world_init(w, sess.info.seed)
	if edits_err, decode := save.load_edits(save.SAVES_DIR, name, w); edits_err != .None {
		session_close(&sess)
		world.world_destroy(w)
		return {}, fail("can't load world '%s': %v %v (in %s/%s/%s)", name, edits_err, decode, save.SAVES_DIR, name, save.EDITS_FILE)
	}
	ps := sess.info.player
	pl^ = player.player_at(ps.feet, ps.yaw, ps.pitch)
	if ps.flying {
		debug^ = true
		player.set_mode(pl, w, .Fly)
	}
	fmt.printfln("loaded world '%s' (seed %d, %d edits)", name, w.seed, w.edit_count)
	return sess, ""
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

// Now, in unix seconds.
unix_now :: proc() -> i64 {
	return time.time_to_unix(time.now())
}

// A new player walking on the land nearest the origin (oceans would put
// them on the seabed), looking toward +X+Z and a bit down.
spawn_player :: proc(seed: i64) -> player.Player {
	land, _ := world.find_land(seed, 0, 0)
	return player.player_spawn(seed, land.x, land.y, 45, -10)
}
