# DG0R3: the dangers' base with a real host and real players' screens (net/host.gd, net/client.gd and client/play_link.gd
# over in-memory links, nobody trusted, with the wire's rounding): what a danger does to a player's body is the same on
# their own screen as on the host, with no delay and with delay.
#   1. Held or stumbling: their own screen stands still where the host holds them from the first snapshot that says so
#      until the host's own until, then walks on from there; the host never sees the body jump and never refuses a step.
#   2. Pinned (hung, on a ledge): the down screen does not crawl away from the pin; cut down, they stand where the host
#      stands them; out, they lie at the fall spot.
#   3. Pushed: the screen takes the pushed spot and walks on from it; the host follows with no refusal.
#   4. A danger's shut door: the screen's walk stops at it as the host's would, and the host agrees on the side.
# The asks are made by the base's own executor (sim/dangers.gd _ask) as the template kind test_tile would make them
# (an active ask under an active kind's name, as test_dangers_base does).
extends RefCounted

const T = preload("res://tests/t.gd")
const Host = preload("res://net/host.gd")
const HostRules = preload("res://net/host_rules.gd")
const Run = preload("res://sim/run.gd")
const Client = preload("res://net/client.gd")
const RoomClient = preload("res://net/room_client.gd")
const Transport = preload("res://net/transport.gd")
const Session = preload("res://net/session.gd")
const Places = preload("res://sim/places.gd")
const Move = preload("res://sim/move.gd")
const Floor = preload("res://sim/floor.gd")
const PlayLink = preload("res://client/play_link.gd")
const Dangers = preload("res://sim/dangers.gd")
const DangerFx = preload("res://sim/dangers/effects.gd")
const DangersView = preload("res://client/dangers/dangers_view.gd")

const DT := 1.0 / 60.0
## How close the screen must stand to the host's held body (the wire rounds a body to the centimetre).
const SAME := 0.03
## The most the host's body may move between two frames: a sprint's input (5 m/s for 50 ms) and its slack.
const STEP_MAX := 0.5

## A room client on an in-memory link (as tests/prop_ward_walk_net.gd).
class Seat extends RoomClient:
	func _init(c: Client, id: String) -> void:
		client = c
		my_id = id
		status = "running"
		run_on = true
	func poll(now: float) -> void:
		_now = now
		client.receive(now)
	func frame(now: float, local: Client.LocalFrame) -> Client.Frame:
		return client.frame(now, local)

## The rooms' rules with test_tile on and the down rule; once the run reaches host time `at`, one ask is made after
## the tick as a kind's step makes it, its events with the tick's.
class Rules extends HostRules:
	var at := INF
	var kind := &"test_tile"
	var op := &""
	## func(s: Run.RunState) -> Array: the ask's arguments, made at that tick.
	var args: Callable
	var fired := -1.0
	var accepted := false
	var asked_events: Array[Dictionary] = []
	## From the ask on, every tick: a prompt of the record (text, reach) when `hint` is set, as a kind asks it each step.
	var hint := ""
	var hint_reach := -1.0
	## From the ask on, each tick: [Api.Who.use of "ann", ann pinned] as a kind's step reads it.
	var ann_use: Array = []

	func step(before: Run.RunState, raw: Array[Run.PlayerInput], dt: float) -> Run.RunStep:
		var r := super.step(before, raw, dt)
		if fired < 0.0 and r.state.t >= at - 1e-9 and r.state.dangers != null:
			fired = r.state.t
			var s := r.state
			var c := Dangers.Ctx.new()
			c.s = s
			c.d = (s.dangers as DangerFx.DangerFloor).copy()
			c.d.heard = c.d.heard.duplicate()
			c.d.prompts = c.d.prompts.duplicate()
			c.players = s.players.duplicate()
			c.events = []
			c.t = s.t
			c.kind = kind
			accepted = Dangers._ask(c, op, {"id": 0, "kind": kind}, args.call(s))
			s.dangers = c.d
			s.players = c.players
			asked_events = c.events
			r.events.append_array(c.events)
		elif fired >= 0.0 and r.state.dangers != null:
			var s := r.state
			var c := Dangers.Ctx.new()
			c.s = s
			c.d = (s.dangers as DangerFx.DangerFloor).copy()
			c.d.prompts = c.d.prompts.duplicate()
			c.players = s.players.duplicate()
			c.events = []
			c.t = s.t
			c.kind = kind
			if hint != "":
				Dangers._ask(c, &"prompt", {"id": 0, "kind": kind}, [hint, hint_reach])
				s.dangers = c.d
			var w: Variant = Dangers._tick(c, raw, dt).who("ann")
			if w != null:
				ann_use.append([w.use, w.pinned])
		return r

class Screen:
	var id := ""
	var link: PlayLink
	var f := 0.0
	var yaw := 0.0
	var use := false

class Rig:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: Rules
	var screens: Array[Screen] = []
	var now := 0.0
	## The largest move of each player's host body between two frames, and the host's refusals.
	var host_step := {}
	var _last := {}

	func _init(run_seed: String, config: Transport.LinkConfig) -> void:
		rules = Rules.new(false, 1, Places.FULL, false, false, true)
		rules.dangers = [&"test_tile"]
		net = Transport.MemoryNetwork.new(run_seed, config)
		var roster: Array[String] = ["ann", "bob"]
		host = Host.new(net.connect_peer("host"), run_seed, roster, now, Callable(rules, "prepare"), Callable(rules, "step"), [])
		for p in host.state.players:
			host.place_player(p.id, p.body)
		for id in roster:
			var c := Client.new(net.connect_peer(id), "host", id, now, Session.INTERP_DELAY, Session.INPUT_INTERVAL)
			c.floor_deck = rules.deck
			var s := Screen.new()
			s.id = id
			s.link = PlayLink.new(Seat.new(c, id), false)
			screens.append(s)

	func frame() -> void:
		now += DT
		net.now = now
		host.update(now)
		for s in screens:
			s.link.step(now, {"dt": DT, "f": s.f, "r": 0.0, "yaw": s.yaw, "pitch": 0.0, "use": s.use, "hfov": 90.0, "vfov": 70.0})
		for id: String in host._players:
			var b: Move.Body = host._players[id].body
			if b == null:
				continue
			var v := Vector3(b.x, b.y, b.z)
			if _last.has(id):
				host_step[id] = maxf(float(host_step.get(id, 0.0)), (v - (_last[id] as Vector3)).length())
			_last[id] = v

	func settle(seconds: float) -> void:
		for _i in ceili(seconds / DT):
			frame()

	func host_body(id: String) -> Vector3:
		var b: Move.Body = host._players[id].body
		return Vector3(b.x, b.y, b.z)

	func screen_body(id: String) -> Vector3:
		var b: Move.Body = screen(id).link.body
		return Vector3(b.x, b.y, b.z) if b != null else Vector3.INF

	func screen(id: String) -> Screen:
		for s in screens:
			if s.id == id:
				return s
		return null

	func client(id: String) -> Client:
		return screen(id).link.client()

	## The screen's own host clock now.
	func host_now(id: String) -> float:
		return client(id).clock.host_time(now)

	func status(id: String) -> StringName:
		for p in host.state.players:
			if p.id == id:
				return p.status
		return &""

	## Puts both players out of the car on the floor at `at` (bob 0.6 m beside) and lets every screen take it.
	func stand(at: Move.Body, bob_dx := 0.6) -> void:
		host.place_player("ann", at)
		host.place_player("bob", Move.Body.make(at.x + bob_dx, at.z, at.level, at.y))
		settle(1.0)
		host_step.clear()
		_last.clear()

static func _with_deck(body: Callable) -> void:
	var original := Session.deck
	Session.deck = Places.FULL
	body.call()
	Session.deck = original

## A walkable cell centre on level 0 at least `far` steps from the landing, with the yaw whose straight walk goes
## furthest (at least 3 m) before a wall: [body, yaw], or [] when none.
static func _open_run(rig: Rig, far: int) -> Array:
	var plan := rig.host.state.plan
	var steps := Floor.distances_from(plan, plan.landing)
	for i in steps.size():
		var pos := Floor.pos_from_index(plan, i)
		if pos.level != 0 or steps[i] < far:
			continue
		var at := Move.body_at_cell(plan, pos)
		for yaw: float in [0.0, PI * 0.5, PI, PI * 1.5]:
			var b := at
			for _k in 40:
				b = Session.move_local(plan, "unloading", b, -sin(yaw) * 0.1, -cos(yaw) * 0.1)
			if Vector2(b.x - at.x, b.z - at.z).length() > 3.5:
				return [at, yaw]
	return []

## One hold or stumble of `secs` on ann while she walks, over links of one-way `delay`: what each side saw.
static func _held_walk(t: T, op: StringName, delay: float, secs: float) -> void:
	var rig := Rig.new("dg0r3-%s-%d" % [op, roundi(delay * 1000.0)], Transport.LinkConfig.make(delay))
	rig.settle(1.5)
	var run := _open_run(rig, 3)
	if not t.check(not run.is_empty(), "a straight run of floor to walk"):
		return
	rig.stand(run[0])
	var ann := rig.screen("ann")
	ann.yaw = float(run[1])
	ann.f = 1.0
	rig.rules.at = rig.host.state.t + 0.4
	rig.rules.op = op
	rig.rules.args = func(_s: Run.RunState) -> Array: return ["ann", secs, 6.0] if op == &"stumble" else ["ann", secs]
	var held := Vector3.INF
	var until := INF
	var worst_held := 0.0
	var held_frames := 0
	var froze_at := -1.0
	var snap := 0.0
	var before := Vector3.INF
	var after_moved := 0.0
	var at_release := Vector3.INF
	for _i in ceili((0.4 + secs + 1.5 + 4.0 * delay) / DT):
		before = rig.screen_body("ann")
		rig.frame()
		if rig.rules.fired >= 0.0 and is_inf(until):
			for e in rig.rules.asked_events:
				if e["type"] == "dangerHold" or e["type"] == "dangerStumble":
					var b: Move.Body = e["at"]
					held = Vector3(b.x, b.y, b.z)
					until = float(e["until"])
		if is_inf(until):
			continue
		var c := rig.client("ann")
		var hn := rig.host_now("ann")
		var block: Variant = (c.latest as Dictionary).get("dangers") if c.latest is Dictionary else null
		# From the first snapshot that tells this screen of the hold until the host's until by this screen's clock.
		if DangerFx.block_holds(block, "ann", hn):
			if froze_at < 0.0:
				froze_at = rig.host.state.t
				snap = (before - held).length()
			held_frames += 1
			worst_held = maxf(worst_held, (rig.screen_body("ann") - held).length())
		elif froze_at >= 0.0:
			if is_inf(at_release.x):
				at_release = rig.screen_body("ann")
			after_moved = (rig.screen_body("ann") - at_release).length()
	var tag := "%s %.1f s, %d ms each way" % [op, secs, roundi(delay * 1000.0)]
	t.check(rig.rules.accepted, "%s: the ask is accepted" % tag)
	t.check(held_frames > 0, "%s: the screen is told of it (%d frames held)" % [tag, held_frames])
	t.check(worst_held <= SAME, "%s: while held, the player's own screen stands where the host holds them (at most %.3f m off)" % [tag, worst_held])
	t.check(froze_at - rig.rules.fired <= 2.0 * delay + 0.12, "%s: it starts on their screen %.3f s after the host (the snapshot's way down)" % [tag, froze_at - rig.rules.fired])
	t.check(float(rig.host_step.get("ann", 0.0)) <= STEP_MAX, "%s: the host's body never jumps (largest move between frames %.2f m)" % [tag, float(rig.host_step.get("ann", 0.0))])
	t.check(after_moved > 1.0, "%s: after it, they walk on (%.2f m)" % [tag, after_moved])
	t.eq(rig.host.stats.clamped_inputs, 0, "%s: the host never refuses a step" % tag)
	t.note("%s: the screen was pulled back %.2f m to the held spot when it learned of it" % [tag, snap])

func test_a_hold_stands_still_on_their_own_screen(t: T) -> void:
	_with_deck(func() -> void:
		_held_walk(t, &"hold", 0.0, 1.0)
		_held_walk(t, &"hold", 0.1, 1.0)
		_held_walk(t, &"hold", 0.2, 0.5))

func test_a_stumble_stands_still_on_their_own_screen(t: T) -> void:
	_with_deck(func() -> void:
		_held_walk(t, &"stumble", 0.0, 1.0)
		_held_walk(t, &"stumble", 0.2, 1.0))

## Hung (or on a ledge) while trying to crawl away; then cut down by bob, or out at the fall spot.
static func _pinned(t: T, style: StringName, delay: float, cut: bool) -> void:
	var rig := Rig.new("dg0r3-pin-%s-%d" % [style, roundi(delay * 1000.0)], Transport.LinkConfig.make(delay))
	rig.settle(1.5)
	var run := _open_run(rig, 3)
	if not t.check(not run.is_empty(), "a straight run of floor"):
		return
	var spot: Move.Body = run[0]
	rig.stand(spot, 0.8)
	var ann := rig.screen("ann")
	ann.yaw = float(run[1])
	ann.f = 1.0
	var pin_at := Move.Body.make(spot.x, spot.z, spot.level, spot.y + (1.0 if style == &"hang" else -1.3))
	var fall := Move.Body.make(spot.x - sin(float(run[1])) * 1.5, spot.z - cos(float(run[1])) * 1.5, spot.level, spot.y)
	rig.rules.at = rig.host.state.t + 0.1
	rig.rules.kind = &"grabber" if style == &"hang" else &"trapdoor"
	rig.rules.op = &"pin"
	rig.rules.args = func(_s: Run.RunState) -> Array:
		return ["ann", style, pin_at, spot] if style == &"hang" else ["ann", style, pin_at, spot, 2.0, fall]
	var worst := 0.0
	var pinned_frames := 0
	var pin_v := Vector3(pin_at.x, pin_at.y, pin_at.z)
	var tag := "%s, %d ms each way" % [style, roundi(delay * 1000.0)]
	for _i in ceili((1.6 + 2.0 * delay) / DT):
		rig.frame()
		var c := rig.client("ann")
		var block: Variant = (c.latest as Dictionary).get("dangers") if c.latest is Dictionary else null
		if rig.rules.fired >= 0.0 and DangerFx.block_holds(block, "ann", rig.host_now("ann")) and c._place_applied > 0 and rig.screen_body("ann").distance_to(pin_v) < 0.5:
			pinned_frames += 1
		if pinned_frames > 0 and DangerFx.block_holds(block, "ann", rig.host_now("ann")):
			worst = maxf(worst, rig.screen_body("ann").distance_to(pin_v))
	t.check(rig.rules.accepted and rig.status("ann") == &"down", "%s: pinned, down by the run's rule" % tag)
	t.check(pinned_frames > 0, "%s: the screen is put at the pin" % tag)
	t.check(worst <= SAME, "%s: pinned, their own screen stays at the pin whatever they press (at most %.3f m off)" % [tag, worst])
	if cut:
		var bob := rig.screen("bob")
		bob.use = true
		# Still pressing forward: the first frame her screen is on her feet again, it is on the stand spot.
		var stand := Vector3(spot.x, spot.y, spot.z)
		var first := Vector3.INF
		for _i in ceili((Run.HEAL_TIME + 0.8 + 2.0 * delay) / DT):
			rig.frame()
			var c2 := rig.client("ann")
			var me: Variant = null
			for row: Dictionary in (c2.latest as Dictionary)["players"]:
				if str(row["id"]) == "ann":
					me = row
			if is_inf(first.x) and me != null and str(me["status"]) == "ok":
				first = rig.screen_body("ann")
		bob.use = false
		t.eq(rig.status("ann"), &"ok", "%s: bob's hold is the cut down" % tag)
		t.check(not is_inf(first.x) and first.distance_to(stand) <= SAME,
			"%s: cut down, their screen stands them on the stand spot (%.3f m off)" % [tag, first.distance_to(stand)])
		rig.host_step.clear()
		rig._last.clear()
		var from := rig.screen_body("ann")
		rig.settle(1.0)
		t.check(rig.screen_body("ann").distance_to(from) > 1.0 and float(rig.host_step.get("ann", 0.0)) <= STEP_MAX,
			"%s: and walk on from there with the host following (largest host move %.2f m)" % [tag, float(rig.host_step.get("ann", 0.0))])
	else:
		rig.settle(2.5 + 2.0 * delay)
		var fv := Vector3(fall.x, fall.y, fall.z)
		t.eq(rig.status("ann"), &"out", "%s: not pulled up in time: out" % tag)
		t.check(rig.screen_body("ann").distance_to(fv) <= SAME and rig.host_body("ann").distance_to(fv) <= SAME,
			"%s: out, they lie at the fall spot on their screen and on the host (%.3f, %.3f m)" % [tag, rig.screen_body("ann").distance_to(fv), rig.host_body("ann").distance_to(fv)])
	t.eq(rig.host.stats.clamped_inputs, 0, "%s: the host never refuses a step" % tag)

func test_pinned_stays_on_the_pin_on_their_own_screen(t: T) -> void:
	_with_deck(func() -> void:
		_pinned(t, &"hang", 0.0, true)
		_pinned(t, &"hang", 0.2, true)
		_pinned(t, &"ledge", 0.0, false)
		_pinned(t, &"ledge", 0.2, false))

func test_a_push_is_taken_by_their_own_screen(t: T) -> void:
	_with_deck(func() -> void:
		for delay: float in [0.0, 0.2]:
			var tag := "push, %d ms each way" % roundi(delay * 1000.0)
			var rig := Rig.new("dg0r3-push-%d" % roundi(delay * 1000.0), Transport.LinkConfig.make(delay))
			rig.settle(1.5)
			var run := _open_run(rig, 3)
			if not t.check(not run.is_empty(), "a straight run of floor"):
				return
			rig.stand(run[0], -0.8)
			var ann := rig.screen("ann")
			var yaw := float(run[1])
			ann.yaw = yaw
			ann.f = 1.0
			rig.rules.at = rig.host.state.t + 0.5
			rig.rules.op = &"push"
			# Thrown back the way she came, 1.5 m.
			rig.rules.args = func(_s: Run.RunState) -> Array: return ["ann", sin(yaw) * 1.5, cos(yaw) * 1.5]
			var pushed := Vector3.INF
			var took := false
			var worst_after := 0.0
			var seen_at := -1.0
			for _i in ceili((1.5 + 4.0 * delay) / DT):
				var was := rig.screen_body("ann")
				rig.frame()
				if rig.rules.fired >= 0.0 and is_inf(pushed.x):
					for e in rig.rules.asked_events:
						if e["type"] == "dangerPush":
							var b: Move.Body = e["at"]
							pushed = Vector3(b.x, b.y, b.z)
				if is_inf(pushed.x):
					continue
				if not took and rig.screen_body("ann").distance_to(pushed) <= SAME and was.distance_to(pushed) > 0.5:
					took = true
					seen_at = rig.now
				# A moment after the screen took it, the host keeps up with the screen (no tug of war).
				if took and rig.now - seen_at > 2.0 * delay + 0.2:
					worst_after = maxf(worst_after, rig.host_body("ann").distance_to(rig.screen_body("ann")))
			t.check(rig.rules.accepted and took, "%s: the screen jumps to the pushed spot in one frame" % tag)
			t.check(worst_after <= 3.0 * (2.0 * delay + 0.15), "%s: after it the host follows the screen (at most %.2f m behind)" % [tag, worst_after])
			t.eq(rig.host.stats.clamped_inputs, 0, "%s: the host never refuses a step" % tag))

func test_a_shut_door_stops_the_screen_where_the_host_would(t: T) -> void:
	_with_deck(func() -> void:
		for delay: float in [0.0, 0.2]:
			var tag := "door, %d ms each way" % roundi(delay * 1000.0)
			var rig := Rig.new("dg0r3-door-%d" % roundi(delay * 1000.0), Transport.LinkConfig.make(delay))
			rig.settle(1.5)
			var plan := rig.host.state.plan
			var door: Floor.Door = null
			for d in plan.doors:
				if d.level == 0 and Floor.distances_from(plan, plan.landing)[Floor.pos_index(plan, Floor.Pos.make(0, d.ax, d.ay))] >= 3:
					door = d
					break
			if not t.check(door != null, "a door away from the lift"):
				return
			var a := Move.body_at_cell(plan, Floor.Pos.make(0, door.ax, door.ay))
			var b := Move.body_at_cell(plan, Floor.Pos.make(0, door.bx, door.by))
			rig.stand(a, 0.0)
			rig.host.place_player("bob", Move.Body.make(a.x - (b.x - a.x) * 0.3, a.z - (b.z - a.z) * 0.3, 0, a.y))
			rig.settle(0.5)
			var ann := rig.screen("ann")
			ann.yaw = atan2(-(b.x - a.x), -(b.z - a.z))
			rig.rules.at = rig.host.state.t + 0.05
			rig.rules.op = &"close_edge"
			rig.rules.args = func(s: Run.RunState) -> Array: return [0, door.ax, door.ay, door.bx, door.by, s.t + 5.0]
			if delay == 0.0:
				# Shut first, then she walks into it.
				rig.settle(0.5)
				ann.f = 1.0
			else:
				# She sets off the moment it shuts: her screen walks a round trip before it hears.
				ann.f = 1.0
			rig.settle(2.0 + 2.0 * delay)
			ann.f = 0.0
			rig.settle(0.3 + 2.0 * delay)
			var sc := Move.cell_of(plan, rig.screen("ann").link.body)
			var hc := Move.cell_of(plan, rig.host._players["ann"].body)
			t.check(rig.rules.accepted, "%s: the door shuts" % tag)
			t.check(sc.x == hc.x and sc.y == hc.y, "%s: the screen and the host agree which side she is on" % tag)
			if delay == 0.0:
				t.check(sc.x == door.ax and sc.y == door.ay, "%s: she stays on her side" % tag)
			else:
				t.note("%s: she ended on %s" % [tag, "her side" if sc.x == door.ax and sc.y == door.ay else "the far side (walked through within a round trip of it shutting)"])
			t.check(rig.host_body("ann").distance_to(rig.screen_body("ann")) <= SAME, "%s: at rest the host has her where her screen does" % tag)
			t.eq(rig.host.stats.clamped_inputs, 0, "%s: the host never refuses a step" % tag))

## Hung by an active kind's ask while bob stands by; the kind's hint asked every tick; ann holds F.
static func _hung(t: T, delay: float) -> Rig:
	var rig := Rig.new("dg0r3-hung-%d" % roundi(delay * 1000.0), Transport.LinkConfig.make(delay))
	rig.settle(1.5)
	var run := _open_run(rig, 3)
	if not t.check(not run.is_empty(), "a straight run of floor"):
		return null
	var spot: Move.Body = run[0]
	rig.stand(spot, 3.0)
	rig.rules.at = rig.host.state.t + 0.1
	rig.rules.kind = &"grabber"
	rig.rules.op = &"pin"
	rig.rules.hint = "KICK"
	rig.rules.args = func(_s: Run.RunState) -> Array:
		return ["ann", &"hang", Move.Body.make(spot.x, spot.z, spot.level, spot.y + 1.0), spot]
	rig.screen("ann").use = true
	rig.settle(1.0 + 2.0 * delay)
	return rig

func test_a_pinned_players_snapshot_crosses_the_network(t: T) -> void:
	_with_deck(func() -> void:
		for delay: float in [0.0, 0.2]:
			var tag := "%d ms each way" % roundi(delay * 1000.0)
			var rig := _hung(t, delay)
			if rig == null:
				return
			t.check(rig.rules.accepted and rig.status("ann") == &"down", "%s: hung, down by the run's rule" % tag)
			for id: String in ["ann", "bob"]:
				var c := rig.client(id)
				var behind := rig.host.tick - int((c.latest as Dictionary)["tick"])
				t.check(behind <= 2 + ceili(delay / 0.05), "%s: %s's screen still takes the snapshots (%d ticks behind the host)" % [tag, id, behind])
				var downs: Variant = (c.latest as Dictionary).get("downs")
				var by := ""
				if downs is Dictionary:
					for row: Dictionary in (downs as Dictionary).get("down", []):
						if str(row["id"]) == "ann":
							by = str(row["by"])
				t.eq(by, "danger", "%s: %s's screen has ann down by a danger" % [tag, id]))

func test_the_hint_reaches_only_the_pinned_player(t: T) -> void:
	_with_deck(func() -> void:
		var rig := _hung(t, 0.1)
		if rig == null:
			return
		for id: String in ["ann", "bob"]:
			var block: Variant = (rig.client(id).latest as Dictionary).get("dangers")
			if not t.check(block is Dictionary, "%s's screen has the block" % id):
				continue
			var v := DangersView.new()
			v.me = id
			(Engine.get_main_loop() as SceneTree).root.add_child(v)
			var feet := rig.screen_body(id)
			v.update(block, rig.host_now(id), Vector3(feet.x, 0.0, feet.z), DT)
			var mine: Variant = v.pin_of(id)
			var line := DangersView.hint_for(v.block, mine) if mine is Array else ""
			t.eq(line, "KICK" if id == "ann" else "", "%s: the hint line on their down screen" % id)
			t.eq(v.prompt, "", "%s: and it is never a prompt shown near the record" % id)
			v.free())

func test_a_pinned_players_f_reaches_the_kind(t: T) -> void:
	_with_deck(func() -> void:
		var rig := _hung(t, 0.1)
		if rig == null:
			return
		var pinned_use := 0
		var pinned := 0
		for u: Array in rig.rules.ann_use:
			if bool(u[1]):
				pinned += 1
				if bool(u[0]):
					pinned_use += 1
		t.check(pinned > 5 and pinned_use > 0 and pinned_use >= pinned - 8, "hung and holding F: the kind reads her F (%d of %d pinned ticks)" % [pinned_use, pinned])
		t.check(FileAccess.get_file_as_string("res://net/host.gd").contains("pins.has(p.id):
				di.use = dm.get(\"use\", false) == true"), "only a pinned player's F is passed while down"))
