# WN3: on the Hanging Ward played as a normal level (net/host_rules.gd ward_place), a player who is NOT the host's
# local player walks out of the lift, through a doorway, along a walkway to a winch switch, by the main game's own
# player path (client/play_link.gd with the Ward's walker, client/ward/floor.gd) and the main scene's per-frame Ward
# step (client/main.gd _ward_frame: WardFloor.update, then WardFloor.reconcile). The real Host checks every input
# (nobody trusted), over in-memory links (net/transport.gd MemoryNetwork), with the wire's rounding.
#   1. After every frame the host's body for the walker is within 0.5 m of the screen's; at rest, within 5 cm.
#   2. F at the switch works the bridge on the host.
#   3. A step the host refuses brings the screen back to the host within a moment (never left walking a world the
#      host does not see), and a second client sees the walker where the host has them.
#   4. The same with delay, jitter and lost messages on both links.
#   5. Boarding: a walker the host has outside the lift at departure sees themselves outside and left behind.
extends RefCounted

const T = preload("res://tests/t.gd")
const Host = preload("res://net/host.gd")
const HostRules = preload("res://net/host_rules.gd")
const Client = preload("res://net/client.gd")
const RoomClient = preload("res://net/room_client.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Transport = preload("res://net/transport.gd")
const Session = preload("res://net/session.gd")
const Places = preload("res://sim/places.gd")
const Move = preload("res://sim/move.gd")
const Ward = preload("res://sim/ward/state.gd")
const PlayLink = preload("res://client/play_link.gd")
const WardFloor = preload("res://client/ward/floor.gd")
const Main = preload("res://client/main.gd")
const Protocol = preload("res://net/protocol.gd")
const View = preload("res://client/ward/view.gd")
const Stamina = preload("res://sim/stamina.gd")
const EyeHeight = preload("res://client/eye_height.gd")

const DT := 1.0 / 60.0

## A room client on an in-memory link: what client/play_link.gd talks to, without a socket.
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

## One player's screen: the link, the Ward floor node (no media: the same walk model the view would give it).
class Screen:
	var id := ""
	var link: PlayLink
	var floor: WardFloor = null
	var use := false
	var f := 0.0
	var yaw := 0.0
	## WN4: the old swapped-in Ward room's screen (client/ward/review.gd with client/ward/view.gd), when the room
	## plays the Ward that way (ward_place off): its client and its view (null until the Ward's first snapshot).
	var client: Client = null
	var view: View = null

class Rig:
	var net: Transport.MemoryNetwork
	var host: Host
	var rules: HostRules
	var screens: Array[Screen] = []
	var now := 0.0
	var clamps: Array[String] = []
	var _clamped := 0

	var old := false

	## `old_room`: the rules with ward_place off, and each screen the old Ward room's (review.gd and view.gd).
	func _init(run_seed: String, config: Transport.LinkConfig, old_room := false) -> void:
		old = old_room
		# The rules exactly as a full-deck room makes them for floor 6 with the Ward as a normal level (or not).
		var lr := LocalRoom.new()
		lr.open_local(run_seed, "Tester", true)
		lr.late_archive_root = ""
		lr.ward_place = not old_room
		lr.start_playtest(HostRules.WARD_DEPTH)
		rules = lr.rules
		lr.leave()
		net = Transport.MemoryNetwork.new(run_seed, config)
		var roster: Array[String] = ["ann", "bob"]
		host = Host.new(net.connect_peer("host"), run_seed, roster, now, Callable(rules, "prepare"), Callable(rules, "step"), [])
		for p in host.state.players:
			host.place_player(p.id, p.body)
		host.enable_late_floors("")
		for id in roster:
			var c := Client.new(net.connect_peer(id), "host", id, now, Session.INTERP_DELAY, Session.INPUT_INTERVAL)
			c.floor_deck = rules.deck
			c.garden_dense = host.state.garden_search
			c.draw_in_dark = true
			var s := Screen.new()
			s.id = id
			if old_room:
				s.client = c
			else:
				s.link = PlayLink.new(Seat.new(c, id), false)
			screens.append(s)

	func ward() -> Ward:
		return host._ward_review

	## One rendered frame for everyone: the host, then each screen's link step and the main scene's Ward step.
	func frame() -> void:
		now += DT
		net.now = now
		host.update(now)
		for s in screens:
			if old:
				_old_frame(s)
				continue
			s.link.step(now, {"dt": DT, "f": s.f, "r": 0.0, "yaw": s.yaw, "pitch": 0.0, "use": s.use, "hfov": 90.0, "vfov": 70.0})
			_ward_frame(s)
		if host.stats.clamped_inputs != _clamped:
			_clamped = host.stats.clamped_inputs
			for hp: Host.HostPlayer in host._players.values():
				if hp.input != null and hp.body != null:
					var mb: Move.Body = hp.input["body"]
					var a := Vector3(hp.body.x, hp.body.y, hp.body.z)
					var b := Vector3(mb.x, mb.y, mb.z)
					if a == b:
						continue
					clamps.append("t=%.2f %s held (%.3f, %.3f, %.3f), refused (%.3f, %.3f, %.3f), the straight line clear %s" % [host.state.t, hp.id,
						a.x, a.y, a.z, b.x, b.y, b.z, ward().walk_clear(a, b)])

	## client/main.gd _ward_frame's part that matters to the walk, through the same WardFloor calls.
	func _ward_frame(s: Screen) -> void:
		var c := s.link.client()
		var latest: Variant = c.latest if c != null else null
		if not Main.ward_native_on(latest):
			if s.floor != null:
				s.link.walker = Callable()
				s.floor.free()
				s.floor = null
			return
		var block: Dictionary = latest["ward"]
		if s.floor == null:
			s.floor = WardFloor.new()
			s.floor.setup(int(block["seed"]), false, c.events.size())
			s.link.walker = s.floor.walk
		var feet := Vector3(s.link.body.x, s.link.body.y, s.link.body.z) if s.link.body != null else Vector3.ZERO
		s.floor.update(block, c.clock.host_time(now), s.link.my_id(), feet, latest["players"], c.events, {})
		for row: Dictionary in latest["players"]:
			if str(row["id"]) == s.link.my_id() and s.link.body != null:
				s.link.body = s.floor.reconcile(s.link.body, row["body"], c._seq, c._host_tank_seq, s.link.frame != null and s.link.frame.placed != null)
				break

	## client/ward/review.gd's frame for the old room: _physics_process's walk (view._move), then _process's input,
	## placement, the view's sync from the host's block (view.show_host's walk-model part) and view.reconcile.
	func _old_frame(s: Screen) -> void:
		var c := s.client
		if s.view != null and c.playing and s.view.local_phase != "departed" and s.f != 0.0:
			var vector := Vector3(-sin(s.yaw), 0.0, -cos(s.yaw)) * s.f
			s.view._move(vector * Stamina.speed_for(&"walk"), DT)
		c.receive(now)
		var local := Client.LocalFrame.new()
		local.body = Move.Body.make(0.0, 0.0, 0, 0.0)
		local.eye = EyeHeight.STAND
		if s.view != null:
			var at := s.view.player.position
			local.body = Move.Body.make(at.x, at.z, 0, at.y)
			local.yaw = s.yaw
			local.gait = "walk"
			local.stamina = Stamina.fresh_stamina()
			local.use = s.use
		var fr := c.frame(now, local)
		if c.latest == null or c.latest.get("ward") == null:
			return
		var block: Dictionary = c.latest.ward
		if s.view == null:
			var spawn := Ward.new(int(block.seed)).lift_door() + Vector3(0, 0.06, -1.5)
			for index: int in c.latest.players.size():
				if c.latest.players[index].id == str(c.id):
					spawn = Ward.new(int(block.seed)).lift_door() + Vector3(-0.28 + float(index % 2) * 0.56, 0.02, -0.55 - 0.59 * float(index / 2))
			if fr.placed != null:
				spawn = Vector3(fr.placed.x, fr.placed.y, fr.placed.z)
			s.view = View.new(int(block.seed), spawn)
			s.view.player.position = spawn
		elif fr.placed != null:
			s.view.player.position = Vector3(fr.placed.x, fr.placed.y, fr.placed.z)
		var m := s.view.walk_model
		m.bridge_lowered = bool(block.bridgeLowered)
		m.phase = StringName(block.phase)
		for i in (block.doors as Array).size():
			m.requested_doors[i] = bool(block.doors[i])
		s.view.local_phase = str(block.phase)
		if c.playing and block.phase != "departed":
			for row: Dictionary in c.latest.players:
				if row.id == str(c.id):
					s.view.reconcile(row.body, c._seq, c._host_tank_seq, fr.placed != null)
					break

	static func model(s: Screen) -> Ward:
		return s.view.walk_model if s.view != null else s.floor.model

	static func latest(s: Screen) -> Dictionary:
		return s.client.latest if s.client != null else s.link.client().latest

	func host_body(id: String) -> Vector3:
		var b: Move.Body = host._players[id].body
		return Vector3(b.x, b.y, b.z)

	static func feet(s: Screen) -> Vector3:
		if s.client != null:
			return s.view.player.position if s.view != null else Vector3.ZERO
		return Vector3(s.link.body.x, s.link.body.y, s.link.body.z)

	func close() -> void:
		for s in screens:
			if s.view != null:
				for n: Node in [s.view.player, s.view.camera, s.view.watch_camera]:
					if is_instance_valid(n) and n.get_parent() == null:
						n.free()
				s.view.free()
				s.view = null
			if s.floor != null:
				s.floor.free()
				s.floor = null

## A walkable route through the Ward's walk model (as tools/play_late.mjs's wardroute): waypoints from `from` to
## within `radius` of any of `goals` (xz), or [] when none.
static func route(model: Ward, from: Vector3, goals: Array[Vector3], radius := 0.4) -> Array[Vector3]:
	var stp := 0.3
	var key := func(v: Vector3) -> Vector3i: return Vector3i(roundi(v.x / stp), roundi(v.z / stp), roundi(v.y / 0.5))
	var came := {key.call(from): null}
	var at := {key.call(from): from}
	var queue: Array[Vector3] = [from]
	var head := 0
	var found: Variant = null
	while head < queue.size() and head < 60000:
		var q: Vector3 = queue[head]
		head += 1
		for g in goals:
			if Vector2(q.x, q.z).distance_to(Vector2(g.x, g.z)) < radius and absf(q.y - g.y) < 0.4:
				found = q
		if found != null:
			break
		for k in 8:
			var dir := Vector2.from_angle(k * PI / 4.0) * stp
			var nq: Vector3 = model.walk(q, dir)
			if Vector2(nq.x - q.x, nq.z - q.z).length() < stp * 0.8:
				continue
			var nk: Vector3i = key.call(nq)
			if came.has(nk):
				continue
			came[nk] = key.call(q)
			at[nk] = nq
			queue.append(nq)
	var out: Array[Vector3] = []
	if found == null:
		return out
	var ck: Variant = key.call(found)
	while ck != null:
		out.push_front(at[ck])
		ck = came[ck]
	return out

## Walk screen `s` along `path` with the main game's W key (yaw toward the next waypoint). Calls `each` after every
## frame. Returns the frames taken, or -1 when stuck.
static func walk(rig: Rig, s: Screen, path: Array[Vector3], each: Callable) -> int:
	var k := 0
	var frames := 0
	var stuck := 0
	var best := INF
	while k < path.size():
		var at := Rig.feet(s)
		var to := path[k]
		var d := Vector2(to.x - at.x, to.z - at.z)
		if d.length() < 0.1:
			k += 1
			best = INF
			continue
		s.yaw = atan2(-d.x, -d.y)
		s.f = 1.0
		rig.frame()
		frames += 1
		each.call()
		if d.length() < best - 0.01:
			best = d.length()
			stuck = 0
		else:
			stuck += 1
			if stuck > 180:
				s.f = 0.0
				print("STUCK %s at %s toward %s (waypoint %d of %d), host %s, refused %s" % [s.id, at, to, k, path.size(), rig.host_body(s.id), rig.clamps.slice(-4)])
				return -1
	s.f = 0.0
	return frames

static func _settle(rig: Rig, seconds: float) -> void:
	for i in ceili(seconds / DT):
		rig.frame()

static func _with_deck(body: Callable) -> void:
	var original := Session.deck
	Session.deck = Places.FULL
	body.call()
	Session.deck = original

## The doorway, walkway and winch walk of one seed; `config` the links. Returns a short line of what happened.
static func _walk_to_winch(t: T, run_seed: String, config: Transport.LinkConfig, during: float, old_room := false) -> void:
	var rig := Rig.new(run_seed, config, old_room)
	_settle(rig, 1.0)
	var ann := rig.screens[0]
	var bob := rig.screens[1]
	var w := rig.ward()
	if not t.check(w != null and (ann.view != null if old_room else ann.floor != null and ann.link.body != null), "%s: the Ward is on for a networked client" % run_seed):
		rig.close()
		return
	# Bob steps out too, so the lift leaves them on the floor (the winch works only then).
	var out := route(Rig.model(bob), Rig.feet(bob), [w.lift_door() + Vector3(-0.4, 0, 2.0)] as Array[Vector3])
	walk(rig, bob, out, func() -> void: pass)
	var start := Rig.feet(ann)
	var goals: Array[Vector3] = []
	for sw: Dictionary in w.switches:
		goals.append(sw.position)
	var path := route(Rig.model(ann), start, goals)
	if not t.check(path.size() > 10, "%s: a walk from the lift to a winch switch exists (%d waypoints)" % [run_seed, path.size()]):
		rig.close()
		return
	# A lambda captures locals by value: the worst gap lives in a dictionary.
	var worst := {"gap": 0.0, "at": ""}
	var each := func() -> void:
		var gap := rig.host_body("ann").distance_to(Rig.feet(ann))
		if gap > float(worst.gap):
			worst.gap = gap
			worst.at = "t=%.2f screen %s host %s" % [rig.host.state.t, Rig.feet(ann), rig.host_body("ann")]
	var frames := walk(rig, ann, path, each)
	var walked := start.distance_to(Rig.feet(ann))
	t.check(frames > 0, "%s: the walk reached the switch (%d frames, %.1f m from the lift)" % [run_seed, frames, walked])
	t.check(walked > 12.0, "%s: at least 12 m straight-line out of the lift (%.1f m)" % [run_seed, walked])
	t.check(float(worst.gap) <= during, "%s: host within %.2f m of the screen on every frame (worst %.2f m at %s; refused: %s)" % [run_seed, during, worst.gap, worst.at, rig.clamps.slice(0, 3)])
	_settle(rig, 0.6)
	var rest := rig.host_body("ann").distance_to(Rig.feet(ann))
	t.check(rest <= 0.05, "%s: at rest the host has the walker where the screen does (%.3f m)" % [run_seed, rest])
	# The second client sees the walker where the host has them.
	var seen: Variant = null
	for row: Dictionary in Rig.latest(bob).players:
		if str(row.id) == "ann":
			seen = row.body
	t.check(seen != null and Vector3(seen.x, seen.y, seen.z).distance_to(rig.host_body("ann")) <= 0.05, "%s: the other client sees the walker where the host has them" % run_seed)
	# F at the switch.
	var lowered := w.bridge_lowered
	t.eq(String(w.phase), "away", "%s: the lift has left the crew on the floor" % run_seed)
	ann.use = true
	_settle(rig, 0.3)
	ann.use = false
	_settle(rig, 0.5)
	t.check(w.bridge_lowered != lowered, "%s: F at the switch works the bridge on the host" % run_seed)
	t.check(bool(Rig.latest(ann).ward.bridgeLowered) == w.bridge_lowered, "%s: and the walker's screen shows it" % run_seed)
	rig.close()

func test_a_networked_walker_reaches_the_winch_with_the_host(t: T) -> void:
	_with_deck(func() -> void:
		for run_seed: String in ["late-5", "wn3-a", "wn3-b"]:
			_walk_to_winch(t, run_seed, Transport.LinkConfig.make(0.0), 0.5))

func test_the_same_walk_with_delay_jitter_and_loss(t: T) -> void:
	_with_deck(func() -> void:
		# 60-120 ms one way, 10% lost, some reordered: the host is that far behind while walking, never further.
		_walk_to_winch(t, "late-5", Transport.LinkConfig.make(0.06, 0.06, 0.1, 0.1, 0.08), 1.2))

func test_the_old_ward_room_walks_to_the_winch_with_the_host(t: T) -> void:
	# WN4: the host's fallback for the night (ward_place off: the old swapped-in Ward scene, client/ward/review.gd and
	# client/ward/view.gd) walks the same route on the same seeds with the host.
	_with_deck(func() -> void:
		for run_seed: String in ["late-5", "wn3-a", "wn3-b"]:
			_walk_to_winch(t, run_seed, Transport.LinkConfig.make(0.0), 0.5, true)
		_walk_to_winch(t, "late-5", Transport.LinkConfig.make(0.06, 0.06, 0.1, 0.1, 0.08), 1.2, true))

func test_the_old_ward_room_comes_back_after_a_refused_step(t: T) -> void:
	_with_deck(func() -> void:
		var rig := Rig.new("late-5", Transport.LinkConfig.make(0.0), true)
		_settle(rig, 1.0)
		var ann := rig.screens[0]
		var path := route(Rig.model(ann), Rig.feet(ann), [rig.ward().lift_door() + Vector3(0, 0, 3.0)] as Array[Vector3])
		walk(rig, ann, path, func() -> void: pass)
		_settle(rig, 0.5)
		var held := rig.host_body("ann")
		var hp: Host.HostPlayer = rig.host._players["ann"]
		ann.yaw = 0.0
		ann.f = 1.0
		for i in 30:
			hp.allowance = -1000.0
			rig.frame()
		ann.f = 0.0
		for i in 24:
			hp.allowance = -1000.0
			rig.frame()
		t.check(rig.host_body("ann").distance_to(held) < 0.01, "the host refused the walk and kept the body (%.3f m)" % rig.host_body("ann").distance_to(held))
		t.check(Rig.feet(ann).distance_to(held) <= 0.05, "the old room's screen stands where the host has them (%.2f m off)" % Rig.feet(ann).distance_to(held))
		hp.allowance = Session.JUMP_SLACK
		rig.close())

func test_a_refused_step_brings_the_screen_back_to_the_host(t: T) -> void:
	_with_deck(func() -> void:
		var rig := Rig.new("late-5", Transport.LinkConfig.make(0.0))
		_settle(rig, 1.0)
		var ann := rig.screens[0]
		var bob := rig.screens[1]
		var w := rig.ward()
		var start := Rig.feet(ann)
		var goals: Array[Vector3] = [w.lift_door() + Vector3(0, 0, 3.0)]
		var path := route(Rig.model(ann), start, goals)
		walk(rig, ann, path, func() -> void: pass)
		_settle(rig, 0.5)
		var held := rig.host_body("ann")
		# The host refuses what this screen walks next: a step its own model allows, but the host does not (as after a
		# door or deck that changed under the player, or an input the host could not accept).
		var hp: Host.HostPlayer = rig.host._players["ann"]
		var clamped := rig.host.stats.clamped_inputs
		ann.yaw = 0.0
		ann.f = 1.0
		var worst := 0.0
		for i in 30:
			hp.allowance = -1000.0
			rig.frame()
			worst = maxf(worst, Rig.feet(ann).distance_to(rig.host_body("ann")))
		ann.f = 0.0
		hp.allowance = Session.JUMP_SLACK
		t.check(rig.host.stats.clamped_inputs > clamped + 5 and rig.host_body("ann").distance_to(held) < 0.01, "the host refused the walk and kept the body")
		t.check(worst < 0.3, "the screen never got further than a few frames' walk from the host (%.2f m)" % worst)
		var refuse_from := rig.now
		var back_at := -1.0
		for i in 60:
			rig.frame()
			if Rig.feet(ann).distance_to(rig.host_body("ann")) <= 0.05:
				back_at = rig.now - refuse_from
				break
		t.check(back_at >= 0.0 and back_at < 0.5 and Rig.feet(ann).distance_to(held) <= 0.05, "the screen stands where the host has them (%.2f s)" % back_at)
		var seen: Variant = null
		for row: Dictionary in Rig.latest(bob).players:
			if str(row.id) == "ann":
				seen = row.body
		t.check(seen != null and Vector3(seen.x, seen.y, seen.z).distance_to(Rig.feet(ann)) <= 0.05, "and the other client sees them there too")
		# Walking on afterwards is accepted again.
		ann.f = 1.0
		for i in 30:
			rig.frame()
		ann.f = 0.0
		_settle(rig, 0.5)
		t.check(rig.host_body("ann").distance_to(Rig.feet(ann)) <= 0.05 and rig.host_body("ann").distance_to(held) > 0.3, "the next walk is the host's again")
		rig.close())

func test_left_outside_at_departure_sees_themselves_outside(t: T) -> void:
	_with_deck(func() -> void:
		var rig := Rig.new("late-5", Transport.LinkConfig.make(0.0))
		_settle(rig, 1.0)
		var ann := rig.screens[0]
		var bob := rig.screens[1]
		var w := rig.ward()
		var door := w.lift_door()
		# Both out of the lift: it leaves.
		for s: Screen in [ann, bob]:
			var out := route(Rig.model(s), Rig.feet(s), [door + Vector3(0.4 if s == ann else -0.4, 0, 2.5)] as Array[Vector3])
			walk(rig, s, out, func() -> void: pass)
		_settle(rig, 0.5)
		t.eq(String(w.phase), "away", "the lift left the walkers on the floor")
		# The lift comes back early; Bob walks in, Ann stays out.
		w.collection_at = rig.host.state.t + 0.2
		_settle(rig, 0.5)
		t.eq(String(w.phase), "boarding", "the lift is back")
		var cabin := route(Rig.model(bob), Rig.feet(bob), [door + Vector3(0, 0, -1.5)] as Array[Vector3], 0.25)
		walk(rig, bob, cabin, func() -> void: pass)
		_settle(rig, 0.4)
		t.check(w.in_lift(rig.host_body("bob")) and not w.in_lift(rig.host_body("ann")), "the host has Bob aboard and Ann outside")
		w.depart_at = rig.host.state.t + 0.2
		_settle(rig, 0.8)
		t.eq(w.boarded, ["bob"] as Array[String], "Bob rode")
		t.eq(w.left_behind, ["ann"] as Array[String], "Ann was left")
		var block: Dictionary = Rig.latest(ann).ward
		t.check((block.leftBehind as Array).has("ann"), "Ann's screen has her left behind")
		t.check(not w.in_lift(Rig.feet(ann)), "and her screen has her outside the lift, where the host has her")
		rig.close())

func test_every_step_sent_rounds_to_feet_the_host_can_walk_from(t: T) -> void:
	# A walker sliding along a jamb stands at the edge of its clearance; the wire's centimetre can round their feet
	# inside it. Steps from clear spots all over the lift's end of the floor, in eight directions: every body the
	# screen walks to rounds to feet the host can walk on from, and the model's own step would not always have.
	var floor := WardFloor.new()
	floor.setup(183025965, false, 0)
	var m := floor.model
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var steps := 0
	var raw_inside := 0
	var sent_inside := 0
	var moved := 0
	for i in 4000:
		var flat := Vector2(rng.randf_range(-2.0, 7.0), rng.randf_range(-6.0, 3.0))
		var y := m.footing.walking_height(flat, 0.0, false)
		if not is_finite(y):
			continue
		var at := Vector3(flat.x, y, flat.y)
		if not m.walk_clear(at, at):
			continue
		for k in 8:
			var d := Vector2.from_angle(k * PI / 4.0) * 0.05
			var raw := m.walk(at, d)
			var raw_q := Vector3(snappedf(raw.x, 0.01), snappedf(raw.y, 0.01), snappedf(raw.z, 0.01))
			if not m.walk_clear(raw_q, raw_q):
				raw_inside += 1
			var b := floor.walk(Move.Body.make(at.x, at.z, 0, at.y), d.x, d.y)
			var sent := Protocol.q_body(b)
			var feet := Vector3(sent.x, sent.y, sent.z)
			steps += 1
			# A step not taken leaves the body where it was (on the floor, always one the walk itself reached).
			if (b.x != at.x or b.z != at.z or b.y != at.y) and not m.walk_clear(feet, feet):
				sent_inside += 1
			if Vector3(b.x, b.y, b.z).distance_to(at) > 0.03:
				moved += 1
	t.check(steps > 2000 and raw_inside > 0, "the fixture: some of the model's own steps round into a clearance (%d of %d)" % [raw_inside, steps])
	t.eq(sent_inside, 0, "no body the screen walks to rounds into one")
	t.check(moved > steps * 0.6, "and the walk still goes (%d of %d steps moved)" % [moved, steps])
	floor.free()

func test_with_ward_place_off_the_old_room_keeps_its_own_walk(t: T) -> void:
	# The old swapped-in Ward (FL1) is its own scene with its own walk (client/ward/view.gd); the main scene's
	# reconcile is never asked for it: no native block, no walker.
	_with_deck(func() -> void:
		var lr := LocalRoom.new()
		lr.open_local("late-5", "Tester", true)
		lr.late_archive_root = ""
		lr.ward_place = false
		lr.start_playtest(HostRules.WARD_DEPTH)
		for i in 6:
			lr.poll(0.05 * i)
		t.check(lr.client.latest.get("ward") is Dictionary, "the Ward is on the floor")
		t.check(not Main.ward_native_on(lr.client.latest), "but not as a normal level: the main scene leaves it to its own scene")
		t.eq(Main.floor_handover(lr.client.latest), "ward", "and swaps to it, as before")
		lr.leave())
