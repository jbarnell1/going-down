# DV1: out, you see through a crewmate's eyes (client/crew_watch.gd, used by client/main.gd _update_watch).
#   1. Out ("out", "caught", "leftBehind"): the camera is at a living crewmate's eyes and looks where they look.
#   2. LEFT CLICK or E: the next crewmate, in the run's player order, round again.
#   3. The one watched goes out: the view moves on by itself to the next after them.
#   4. Nobody left: no watching (the out screen as before).
#   5. Down and still to be healed: not watching; the down view's timer and crawl as before.
#   6. Where it is not used: the Playroom's party table, the catch's scene, the end. On the native Ward the caught
#      list counts as out. The entry points other code calls: watch_crewmate, stop_watching, defer_watching.
#   7. Through the real room (server/room.gd over WebSockets, two RoomClients and their PlayLinks): on a Clinic floor
#      and on the Reactor, the out player's camera follows the other within 0.75 m and their look within 0.25 rad,
#      for several seconds while they walk and turn.
extends RefCounted

const T = preload("res://tests/t.gd")
const CrewWatch = preload("res://client/crew_watch.gd")
const DownView = preload("res://client/down_view.gd")
const EyeHeight = preload("res://client/eye_height.gd")
const Main = preload("res://client/main.gd")
const PlayLink = preload("res://client/play_link.gd")
const Room = preload("res://server/room.gd")
const RoomClient = preload("res://net/room_client.gd")
const WsServer = preload("res://net/ws_server.gd")
const Places = preload("res://sim/places.gd")
const Run = preload("res://sim/run.gd")

const SECRET := "crew-watch-test-passphrase"
const PORT := 4840
## How close the out player's camera stays to the watched crewmate's own camera, and their look to theirs.
const FOLLOW_M := 0.75
const FOLLOW_RAD := 0.25

static func _row(id: String, index: int, status: String, x: float, yaw := 0.0, pitch := 0.0, gait := "walk", active := true) -> Dictionary:
	return {"id": id, "index": index, "status": status, "x": x, "y": 0.0, "z": 2.0 * x, "level": 0, "yaw": yaw, "pitch": pitch,
		"gait": gait, "active": active}

static func _snap(my_status: String, others: Array) -> Dictionary:
	return {"me": {"status": my_status, "x": 0.0, "y": 0.0, "z": 0.0, "level": 0, "eye": EyeHeight.DOWN}, "others": others,
		"phase": "away", "depth": 1}

const NAMES := {"me": "Me", "a": "Ann", "b": "Bob", "c": "Cy"}

# --- 1. out, at their eyes --------------------------------------------------------------------------------

func test_out_camera_is_at_a_crewmates_eyes(t: T) -> void:
	for st: String in CrewWatch.OUT_STATES:
		var w := CrewWatch.new()
		w.update(_snap(st, [_row("a", 1, "ok", 3.0, 0.7, -0.2)]), "me", NAMES, true, DownView.OUT_LINES)
		t.check(w.watching and w.watch_id == "a", "%s: watching Ann" % st)
		t.check(w.eye.is_equal_approx(Vector3(3.0, EyeHeight.STAND, 6.0)), "%s: the camera at her eyes (%s)" % [st, w.eye])
		t.check(is_equal_approx(w.yaw, 0.7) and is_equal_approx(w.pitch, -0.2), "%s: looking where she looks" % st)
		t.eq(w.caption, "WATCHING THROUGH ANN'S EYES   LEFT CLICK OR E: NEXT", "%s: the caption names her" % st)
		t.eq(w.note, "OUT   YOU REJOIN WHEN THE CAR NEXT MOVES", "%s: the out screen's words in one line" % st)
	# Their eyes as their status and gait put them: creeping lower, down near the floor.
	var w2 := CrewWatch.new()
	w2.update(_snap("out", [_row("a", 1, "ok", 1.0, 0.0, 0.0, "creep")]), "me", NAMES, true)
	t.check(is_equal_approx(w2.eye.y, EyeHeight.CREEP), "a creeping crewmate's eyes are lower")
	w2.update(_snap("out", [_row("a", 1, "down", 1.0)]), "me", NAMES, true)
	t.check(w2.watching and is_equal_approx(w2.eye.y, EyeHeight.DOWN), "a downed crewmate can be watched, from the floor")
	# Out, then the car moves and you are back in it: your own view again.
	w2.update(_snap("ok", [_row("a", 1, "ok", 1.0)]), "me", NAMES, true)
	t.check(not w2.watching and w2.caption == "", "back on your feet: not watching")

# --- 2. cycling --------------------------------------------------------------------------------------------

func test_next_cycles_in_player_order(t: T) -> void:
	var w := CrewWatch.new()
	# Listed out of order on purpose: the run's player order (index) decides.
	var crew := [_row("c", 3, "ok", 3.0), _row("a", 1, "ok", 1.0), _row("b", 2, "ok", 2.0)]
	var s := _snap("out", crew)
	w.update(s, "me", NAMES, true)
	t.eq(w.watch_id, "a", "the first in the player order first")
	var seen: Array[String] = []
	for i in 4:
		w.next()
		w.update(s, "me", NAMES, true)
		seen.append(w.watch_id)
	t.eq(seen, ["b", "c", "a", "b"] as Array[String], "next: b, c, round to a, b")
	t.check(w.eye.is_equal_approx(Vector3(2.0, EyeHeight.STAND, 4.0)), "the camera went to Bob")
	# Not watching, next does nothing.
	var idle := CrewWatch.new()
	idle.next()
	idle.update(s, "me", NAMES, true)
	t.eq(idle.watch_id, "a", "a next pressed before watching is not kept")
	# The keys: E, or a left click with the mouse held by the game.
	var e := InputEventKey.new()
	e.physical_keycode = KEY_E
	e.pressed = true
	t.check(Main.watch_next_input(e, false), "E is next")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	t.check(Main.watch_next_input(click, true), "a left click is next")
	t.check(not Main.watch_next_input(click, false), "the first click with the mouse free only takes the mouse")
	var f := InputEventKey.new()
	f.physical_keycode = KEY_F
	f.pressed = true
	t.check(not Main.watch_next_input(f, true), "F is not next")

# --- 3. hand-over ------------------------------------------------------------------------------------------

func test_watched_goes_out_hands_over_to_the_next(t: T) -> void:
	var w := CrewWatch.new()
	w.update(_snap("out", [_row("a", 1, "ok", 1.0), _row("b", 2, "ok", 2.0), _row("c", 3, "ok", 3.0)]), "me", NAMES, true)
	w.next()
	w.update(_snap("out", [_row("a", 1, "ok", 1.0), _row("b", 2, "ok", 2.0), _row("c", 3, "ok", 3.0)]), "me", NAMES, true)
	t.eq(w.watch_id, "b", "watching Bob")
	# Bob goes out: the next after him (Cy), not the first.
	w.update(_snap("out", [_row("a", 1, "ok", 1.0), _row("b", 2, "out", 2.0), _row("c", 3, "ok", 3.0)]), "me", NAMES, true)
	t.eq(w.watch_id, "c", "Bob out: on to Cy")
	t.check(w.eye.is_equal_approx(Vector3(3.0, EyeHeight.STAND, 6.0)), "the camera at Cy's eyes")
	# Cy leaves the run (disconnected) or is left behind: round to Ann.
	w.update(_snap("out", [_row("a", 1, "ok", 1.0), _row("b", 2, "out", 2.0), _row("c", 3, "ok", 3.0, 0.0, 0.0, "walk", false)]), "me", NAMES, true)
	t.eq(w.watch_id, "a", "Cy gone: round to Ann")
	w.update(_snap("out", [_row("a", 1, "ok", 1.0), _row("c", 3, "leftBehind", 3.0)]), "me", NAMES, true)
	t.eq(w.watch_id, "a", "a left-behind crewmate is not watched")

# --- 4. nobody left -----------------------------------------------------------------------------------------

func test_nobody_left_is_todays_out_screen(t: T) -> void:
	var w := CrewWatch.new()
	w.update(_snap("out", [_row("a", 1, "ok", 1.0)]), "me", NAMES, true)
	t.check(w.watching, "watching Ann")
	w.update(_snap("out", [_row("a", 1, "out", 1.0)]), "me", NAMES, true)
	t.check(not w.watching and w.watch_id == "" and w.caption == "" and w.note == "", "Ann out too: nothing to watch, the out screen as before")
	w.update(_snap("out", []), "me", NAMES, true)
	t.check(not w.watching, "alone: nothing to watch")
	# And the down view still says what it says today.
	var dv := DownView.new()
	dv.update({"me": {"status": "out"}, "others": [], "downs": {"down": [], "spots": []}, "hostNow": 1.0}, "me", NAMES, false)
	t.check(dv.out and dv.out_lines == DownView.OUT_LINES, "the out screen's words are today's")

# --- 5. down and still to be healed ---------------------------------------------------------------------------

func test_rescuable_down_keeps_todays_view(t: T) -> void:
	var s := _snap("down", [_row("a", 1, "ok", 1.0)])
	s["downs"] = {"down": [{"id": "me", "at": 0.0, "until": 10.0, "healer": "", "healFrom": null}], "spots": []}
	s["hostNow"] = 3.0
	var w := CrewWatch.new()
	w.update(s, "me", NAMES, true)
	t.check(not w.watching and w.caption == "", "down and still to be healed: not watching")
	var dv := DownView.new()
	dv.update(s, "me", NAMES, false)
	t.eq(dv.head, "DOWN  7", "the timer as today")
	t.eq(dv.line2, "CRAWL: W A S D", "the crawl as today")
	t.eq(dv.line, "A CREWMATE CAN HOLD F BESIDE YOU", "the help line as today")

# --- 6. where it is not used -----------------------------------------------------------------------------------

func test_not_at_the_party_table_or_in_the_catch(t: T) -> void:
	var s := _snap("out", [_row("a", 1, "ok", 1.0)])
	t.check(Main.watch_allowed(s, false, false, true), "out on a floor: used")
	var seated := s.duplicate()
	seated["mySeek"] = {"status": "taken", "phase": "inside"}
	t.check(not Main.watch_allowed(seated, true, false, true), "the Playroom's party table: seated there")
	t.check(not Main.watch_allowed(s, false, true, true), "the catch's noise: not yet")
	t.check(not Main.watch_allowed(s, false, false, false), "the end screen: not used")
	var ended := s.duplicate()
	ended["phase"] = "ended"
	t.check(not Main.watch_allowed(ended, false, false, true), "the run ended: not used")
	var w := CrewWatch.new()
	w.update(s, "me", NAMES, false)
	t.check(not w.watching, "not allowed: not watching")

## The Ward's caught list (not the run's status) counts as out, and caught crewmates are not watched.
func test_ward_caught_counts_as_out(t: T) -> void:
	var crew := [_row("a", 1, "ok", 1.0), _row("b", 2, "ok", 2.0)]
	var w := CrewWatch.new()
	w.update(_snap("ok", crew), "me", NAMES, true, [], true, ["me", "a"])
	t.check(w.watching and w.watch_id == "b", "caught on the Ward: watching Bob, not Ann (caught too)")
	t.eq(w.note, "", "no out-screen words on the Ward")
	w.update(_snap("ok", crew), "me", NAMES, true, [], true, ["me", "a", "b"])
	t.check(not w.watching, "everyone caught: nothing to watch")
	w.update(_snap("ok", crew), "me", NAMES, true, [], false, [])
	t.check(not w.watching, "let go: your own view")

## The entry points other code calls (WC1's web cocoon): watch now, not yet, stop.
func test_entry_points(t: T) -> void:
	var ok := _snap("ok", [_row("a", 1, "ok", 1.0)])
	var out := _snap("out", [_row("a", 1, "ok", 1.0)])
	var w := CrewWatch.new()
	w.watch_crewmate()
	w.update(ok, "me", NAMES, true)
	t.check(w.watching and w.watch_id == "a", "watch_crewmate: watching though the run has you on your feet")
	w.stop_watching()
	t.check(not w.watching, "stop_watching: your own view at once")
	w.update(ok, "me", NAMES, true)
	t.check(not w.watching, "stop_watching: and after")
	w.defer_watching()
	w.update(out, "me", NAMES, true)
	t.check(not w.watching, "defer_watching: not even out")
	w.watch_crewmate()
	w.update(out, "me", NAMES, true)
	t.check(w.watching, "watch_crewmate after a deferral: watching")
	w.defer_watching()
	w.stop_watching()
	w.update(out, "me", NAMES, true)
	t.check(w.watching, "stop_watching ends a deferral: out watches again")
	w.watch_crewmate()
	w.clear()
	w.update(ok, "me", NAMES, true)
	t.check(not w.watching, "a new run clears the ask")
	for name: String in ["watch_crewmate", "stop_watching", "defer_watching"]:
		t.check(_main_has(name), "client/main.gd has %s()" % name)

static func _main_has(name: String) -> bool:
	for m: Dictionary in (Main as Script).get_script_method_list():
		if str(m["name"]) == name:
			return true
	return false

# --- 7. through the real room ----------------------------------------------------------------------------------

func test_follows_through_the_room_on_a_clinic_floor(t: T) -> void:
	_room_follow(t, 1, PORT, Places.CLINIC)

func test_follows_through_the_room_on_the_reactor(t: T) -> void:
	_room_follow(t, 7, PORT + 1, Places.REACTOR)

func _room_follow(t: T, depth: int, port: int, place: StringName) -> void:
	var say := func(_l: String) -> void: pass
	var ws := WsServer.new(SECRET, false, say)
	ws.listen(port, "127.0.0.1")
	var room := Room.new(ws, say)
	room.fixed_seed = "dv1-watch"
	room.quota = false
	room.first_depth = depth
	var clients: Array[RoomClient] = []
	for name: String in ["Ana", "Bo"]:
		var rc := RoomClient.new()
		rc.connect_to("ws://127.0.0.1:%d" % port, SECRET, name)
		clients.append(rc)
	var now := 0.0
	var readied := false
	var links: Array[PlayLink] = []
	var dt := 1.0 / 60.0
	var started := -1.0
	var out_set := false
	var frames := 0
	var watched := 0
	var max_d := 0.0
	var max_a := 0.0
	var walked := 0.0
	var turned := 0.0
	var last_feet := Vector3.INF
	var a_id := ""
	var b_id := ""
	var watch := CrewWatch.new()
	while now < 40.0:
		now += dt
		ws.poll(now)
		room.update(now)
		var all_lobby := true
		for rc in clients:
			rc.poll(now)
			all_lobby = all_lobby and rc.status == "lobby"
		if all_lobby and not readied:
			readied = true
			for rc in clients:
				rc.set_ready(true)
		if links.is_empty():
			var ready := true
			for rc in clients:
				var l: Variant = rc.client.latest if rc.client != null else null
				ready = ready and l != null and int(l.depth) == depth
			if ready:
				for rc in clients:
					links.append(PlayLink.new(rc, false))
				a_id = clients[0].my_id
				b_id = clients[1].my_id
				started = now
			OS.delay_msec(1)
			continue
		var tt := now - started
		var a_yaw := 0.9 * sin(tt * 1.3)
		var a_pitch := 0.3 * sin(tt * 0.7)
		var sa := links[0].step(now, {"dt": dt, "f": 1.0, "r": 0.4 * sin(tt * 0.5), "sprint": false, "creep": false, "yaw": a_yaw, "pitch": a_pitch, "hfov": 90.0, "vfov": 70.0})
		var sb := links[1].step(now, {"dt": dt, "f": 0.0, "r": 0.0, "sprint": false, "creep": false, "yaw": 0.0, "pitch": 0.0, "hfov": 90.0, "vfov": 70.0})
		if not out_set and tt > 1.0 and room.host != null:
			# Bo is out, as the rules would have it after a down nobody healed (the test's hand on the host).
			var ps := room.host.state.players.duplicate()
			for i in ps.size():
				if ps[i].id == b_id:
					var np: Run.RunPlayer = ps[i].copy()
					np.status = &"out"
					np.side = null
					ps[i] = np
			room.host.state.players = ps
			out_set = true
		if sa.is_empty() or sb.is_empty() or tt < 2.0:
			OS.delay_msec(1)
			continue
		if tt > 8.0:
			break
		frames += 1
		watch.update(sb, b_id, links[1].names(), true)
		if not watch.watching or watch.watch_id != a_id:
			continue
		watched += 1
		var a_eye := PlayLink.camera_point(sa["me"])
		max_d = maxf(max_d, a_eye.distance_to(watch.eye))
		max_a = maxf(max_a, maxf(absf(angle_difference(a_yaw, watch.yaw)), absf(a_pitch - watch.pitch)))
		var feet := Vector3(float(sa["me"]["x"]), 0.0, float(sa["me"]["z"]))
		if last_feet != Vector3.INF:
			walked += feet.distance_to(last_feet)
		last_feet = feet
		turned = maxf(turned, absf(a_yaw))
		OS.delay_msec(1)
	t.check(room.host != null and room.host.state.plan.place == place, "depth %d is %s (%s)" % [depth, place, room.host.state.plan.place if room.host != null else "no host"])
	t.check(frames > 200, "depth %d: %d frames of Bo out" % [depth, frames])
	t.check(watched >= frames - 30 and watched > 200, "depth %d: Bo watched Ana on %d of %d frames" % [depth, watched, frames])
	t.check(max_d <= FOLLOW_M, "depth %d: Bo's camera within %.2f m of Ana's own (worst %.3f m, Ana walked %.1f m)" % [depth, FOLLOW_M, max_d, walked])
	t.check(max_a <= FOLLOW_RAD, "depth %d: Bo looks where Ana looks within %.2f rad (worst %.3f)" % [depth, FOLLOW_RAD, max_a])
	t.check(walked > 1.0 and turned > 0.5, "depth %d: Ana really walked (%.1f m) and turned (%.2f rad)" % [depth, walked, turned])
	t.note("depth %d (%s): %d frames, worst %.3f m, %.3f rad, Ana walked %.1f m" % [depth, place, frames, max_d, max_a, walked])
	for rc in clients:
		if rc.status != "closed":
			rc.leave()
	for k in 10:
		ws.poll(now + k * 0.02)
		room.update(now + k * 0.02)
	ws.stop()
