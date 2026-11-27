# DG0, the dangers' base (sim/dangers.gd, sim/dangers/effects.gd, net/host_rules.gd dangers, net/protocol.gd "dg").
#   1. Off unless asked: the parameter is last, empty by default, the data file ships empty, a run without it has no
#      DangerFloor and no "dangers" block.
#   2. On with a kind that does nothing near anyone, the run is the run without it (players, resident, events).
#   3. Each ask does what the system it plugs into does (see each test).
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Floor = preload("res://sim/floor.gd")
const Places = preload("res://sim/places.gd")
const Bot = preload("res://sim/bot.gd")
const HostRules = preload("res://net/host_rules.gd")
const Protocol = preload("res://net/protocol.gd")
const Dangers = preload("res://sim/dangers.gd")
const DangerFx = preload("res://sim/dangers/effects.gd")
const Api = preload("res://sim/dangers/api.gd")
const Station = preload("res://sim/station_floor.gd")

const DT := 0.05

func test_off_unless_asked(t: T) -> void:
	var names: Array[String] = []
	for m: Dictionary in (HostRules as Script).get_script_method_list():
		if str(m["name"]) == "_init":
			for a: Dictionary in m["args"]:
				names.append(str(a["name"]))
	t.eq(names[-1], "dangers_", "dangers_ is the last parameter of HostRules._init")
	t.eq(names[-2], "ward_stairs_", "right after ST1's ward_stairs_")
	t.check(HostRules.new(true, 1).dangers.is_empty(), "off by default")
	t.check(Dangers.data_enabled().is_empty(), "data/dangers.json ships with nothing enabled")
	t.check(HostRules.dangers_by_arg().is_empty(), "no dangers= on this command line: the rooms enable nothing")
	var s := HostRules.new(true, 1, [], false, false, true).prepare(Run.create_run("dg0", ["a"] as Array[String]))
	t.check(s.dangers == null, "a run prepared without it has no dangers")
	t.check(Dangers.block(s) == null, "and no snapshot block")
	t.check(HostRules.new(true, 1, [], false, false, true, false, false, false, false, false, false, false, false, false, false, false, false, false,
		false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
		false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false,
		false, false, false).dangers.is_empty(), "a caller filling every parameter with false means none")
	var room := FileAccess.get_file_as_string("res://server/room.gd")
	t.check(room.contains("HostRules.dangers_by_arg() if not (ward_review or reactor_review or orientation_review) else [])"), "server/room.gd passes it last")
	var local := FileAccess.get_file_as_string("res://net/local_room.gd")
	t.check(local.contains("HostRules.dangers_by_arg() if Session.deck == Places.FULL and not _orientation_playtest else [])"), "net/local_room.gd passes it last, with the full deck")
	t.eq(Dangers.resolve(["all"]), Dangers.all_kinds(), "all is every kind with a file, not test_only")
	t.eq(Dangers.resolve(["0"]), [] as Array[StringName], "0 is none")
	t.eq(Dangers.resolve(["nonsense", "test_tile"]), [&"test_tile"] as Array[StringName], "unknown names are dropped")

## One line per tick: phase, every event but the dangers' own, every player and the resident.
static func _line(s: Run.RunState, events: Array[Dictionary]) -> String:
	var parts: Array[String] = ["%.3f %s %d" % [s.t, s.phase, s.depth]]
	for e in events:
		var ty := str(e.get("type", ""))
		if not ty.begins_with("danger"):
			parts.append("%s@%.3f:%s" % [ty, float(e.get("t", -1.0)), str(e.get("playerId", ""))])
	for p in s.players:
		parts.append("%s %s %.4f,%.4f,%d" % [p.id, p.status, p.body.x, p.body.z, p.body.level])
	if s.orderly != null:
		parts.append("o %.4f,%.4f %s" % [s.orderly.body.x, s.orderly.body.z, str(s.orderly.mode)])
	return " | ".join(parts)

static func _bot_run(seed: String, kinds: Array, secs: float) -> PackedStringArray:
	var ids: Array[String] = ["a", "b"]
	var rules := HostRules.new(true, 1, Places.FULL, false, false, true)
	rules.dangers = Dangers.resolve(kinds)
	var s := rules.prepare(Run.create_run(seed, ids, Places.FULL))
	var bots: Array = []
	for n in ids.size():
		bots.append(Bot.create_bot(s.plan, ids[n], "%s:bots" % seed, 0.3 + 0.3 * n))
	var out := PackedStringArray()
	for _k in roundi(secs / DT):
		var ins: Array[Run.PlayerInput] = []
		for n in ids.size():
			var p := s.players[n]
			var b: Bot.Bot = bots[n]
			if p.status == &"ok":
				Bot.step_bot(s.plan, b, DT, s.orderly.body)
				var i := Run.PlayerInput.make(p.id, b.body, 1.65, b.yaw, b.pitch, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG)
				i.gait = &"creep"
				ins.append(i)
		var r := rules.step(s, ins, DT)
		s = r.state
		out.append(_line(s, r.events))
	return out

func test_a_quiet_kind_changes_nothing(t: T) -> void:
	# Creeping bots never set the tile off: with it on, the run is the run without it, tick for tick.
	var secs := 20.0 if t.size_key() == "quick" else 60.0
	for seed: String in ["dg0-quiet-1", "dg0-quiet-2"]:
		var off := _bot_run(seed, [], secs)
		var on := _bot_run(seed, ["test_tile"], secs)
		var first := -1
		for k in off.size():
			if off[k] != on[k]:
				first = k
				break
		t.check(first < 0, "%s: identical with a quiet danger on (first difference at tick %d)" % [seed, first])

# ---------------------------------------------------------------------------------------------
# The asks, each against the system it plugs into. A test drives them through the base's own executor (Dangers._ask)
# as a kind does, on a run with test_tile on (so it has a DangerFloor), then steps the run by HostRules.

## [rules, state] of floor `depth` of the game's deck with test_tile on and the down rule, players `ids` standing at
## the start, stepped `ticks`.
static func _game(seed: String, depth: int, ids: Array[String], ticks := 2) -> Array:
	var rules := HostRules.new(true, depth, Places.FULL, false, false, true)
	rules.dangers = [&"test_tile"]
	var s := rules.prepare(Run.create_run(seed, ids, Places.FULL))
	# Out of the car, side by side a little way from the landing (the asks never take anyone in the car).
	var out_at := _far_cell(s, 3)
	var bodies := {}
	for n in ids.size():
		bodies[ids[n]] = Move.Body.make(out_at.x + 0.4 * n, out_at.z, out_at.level, out_at.y)
	for _k in maxi(ticks, 2):
		s = rules.step(s, _still(s, bodies), DT).state
	return [rules, s]

static func _still(s: Run.RunState, bodies := {}, use := {}) -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = []
	for p in s.players:
		if p.status != &"ok" and p.status != &"down":
			continue
		var b: Move.Body = bodies.get(p.id, p.body)
		var i := Run.PlayerInput.make(p.id, b, 1.65, float(bodies.get(p.id + ":yaw", 0.0)), 0.0, 90.0, 70.0)
		i.use = bool(use.get(p.id, false))
		i.gait = &"walk"
		out.append(i)
	return out

## Runs one ask as kind `kind` would, on a copy of `s`; returns [accepted, new state, events].
static func _ask(s0: Run.RunState, kind: StringName, op: StringName, args: Array) -> Array:
	var s := s0.copy()
	var c := Dangers.Ctx.new()
	c.s = s
	c.d = (s.dangers as DangerFx.DangerFloor).copy()
	# The base's own step starts these fresh each tick; here too, so `s0` keeps its own.
	c.d.heard = c.d.heard.duplicate()
	c.d.prompts = c.d.prompts.duplicate()
	c.players = s.players.duplicate()
	c.events = []
	c.t = s.t
	c.kind = kind
	var rec := {"id": 99, "kind": kind}
	var ok := Dangers._ask(c, op, rec, args)
	s.dangers = c.d
	s.players = c.players
	return [ok, s, c.events]

static func _player(s: Run.RunState, id: String) -> Run.RunPlayer:
	for p in s.players:
		if p.id == id:
			return p
	return null

## A walkable spot on level 0 at least `far` cells from the landing (the first in cell order).
static func _far_cell(s: Run.RunState, far: int) -> Move.Body:
	var steps := Floor.distances_from(s.plan, s.plan.landing)
	for i in steps.size():
		var pos := Floor.pos_from_index(s.plan, i)
		if pos.level == 0 and steps[i] >= far:
			return Move.body_at_cell(s.plan, pos)
	return null

func test_noise_is_heard_as_each_resident_hears(t: T) -> void:
	# The same tick with and without one danger noise next to the resident: the Groundskeeper and the Minder react,
	# the Orderly does not. (The Reactor's four: sim/station_floor.gd takes it as a point noise, test below; the
	# Rigger: net/host.gd, not run here.)
	for depth: int in [1, 4, 5]:
		var gs := _game("dg0-noise", depth, ["a", "b"] as Array[String], 30)
		var rules: HostRules = gs[0]
		var s: Run.RunState = gs[1]
		# Let the floor settle (the doors open, the resident about) before the noise.
		for _k in 200:
			s = rules.step(s, _still(s), DT).state
		var res: Move.Body = s.orderly.body
		if s.garden != null:
			res = s.garden.keeper.body
		if s.seek != null:
			res = s.seek.minder.body
		var loud := _ask(s, &"test_tile", &"noise", [Move.Body.make(res.x + 1.0, res.z, res.level, res.y), 30.0, "a"])
		t.check(bool(loud[0]), "floor %d: the noise is accepted" % depth)
		var a: Run.RunState = s
		var b: Run.RunState = loud[1]
		t.note("floor %d: phase %s, t %.2f, heard %d, resident at %.1f,%.1f lv %d, seek %s, garden %s" % [depth, b.phase, b.t, (b.dangers as DangerFx.DangerFloor).heard.size(), res.x, res.z, res.level, str(b.seek != null), str(b.garden != null)])
		var differ := false
		for _k in 40:
			a = rules.step(a, _still(a), DT).state
			b = rules.step(b, _still(b), DT).state
			if _line(a, []) != _line(b, []) or (a.seek != null and absf(a.seek.anger - b.seek.anger) > 1e-9) \
					or (a.garden != null and (a.garden.keeper.mode != b.garden.keeper.mode or a.garden.keeper.body.x != b.garden.keeper.body.x)):
				differ = true
				break
		if depth == 1:
			t.check(not differ, "the Clinic: the Orderly does not hunt by sound, the noise changes nothing")
		else:
			t.check(differ, "floor %d (%s): the resident hears it" % [depth, s.plan.place])

func test_station_takes_a_danger_noise(t: T) -> void:
	# sim/station_floor.gd _noises_drawn: an extra noise is one of the tick's point noises, as a flare's burst is.
	var crew: Array[Station.Crew] = []
	var none: Array[Dictionary] = []
	t.eq(Station._noises_drawn(Station.StationFloor.new(), crew, 1.0, null, none, [[1.0, 2.0, 10.0]]).size(), 0, "with nobody awake a noise draws nobody (the call takes the extra list)")
	t.check(FileAccess.get_file_as_string("res://sim/run.gd").contains("StationRules.step(st, crew, t, dt, s.tuning, events, danger_noises)"), "the run hands the four the danger noises")

func test_dark_counts_as_nobody_looking_on_the_clinic(t: T) -> void:
	var s: Run.RunState = _game("dg0-dark", 1, ["a"] as Array[String])[1]
	var o := s.orderly.body
	t.check(not DangerFx.hides_resident(s.dangers, o, _player(s, "a").body, s.t, 2.0), "no dark: nothing hidden")
	var r := _ask(s, &"test_tile", &"dark", [o.level, o.x - 2.0, o.z - 2.0, o.x + 2.0, o.z + 2.0, s.t + 5.0])
	t.check(bool(r[0]), "a dark region is accepted")
	var d: Run.RunState = r[1]
	t.check(DangerFx.hides_resident(d.dangers, o, _player(d, "a").body, d.t, 2.0), "the resident inside it is hidden from the player, as in a blink")
	t.check(not DangerFx.hides_resident(d.dangers, o, _player(d, "a").body, d.t + 6.0, 2.0), "and seen again after it")
	var src := FileAccess.get_file_as_string("res://sim/run.gd")
	t.check(src.contains("if s.dangers != null and DangerFx.dark_at(s.dangers, s.orderly.body.level, s.orderly.body.x, s.orderly.body.z, t):\n\t\tblind = true"), "the Stillness step folds it into the blink's own blindness")
	var early := _ask(s, &"test_tile", &"dark", [o.level, o.x - 2.0, o.z - 2.0, o.x + 2.0, o.z + 2.0, s.t + 8.0, s.t + 2.0])
	t.check(not DangerFx.dark_at((early[1] as Run.RunState).dangers, o.level, o.x, o.z, s.t + 1.0), "announced ahead, it is not dark before its time")
	t.check(DangerFx.dark_at((early[1] as Run.RunState).dangers, o.level, o.x, o.z, s.t + 2.5), "and dark from it")
	var long := _ask(s, &"test_tile", &"dark", [o.level, o.x - 2.0, o.z - 2.0, o.x + 2.0, o.z + 2.0, s.t + 100.0])
	t.check(not DangerFx.dark_at((long[1] as Run.RunState).dangers, o.level, o.x, o.z, s.t + Dangers.DARK_MAX + 0.1), "never longer than danger.dark_max")

## A door of the plan on level 0 and the bodies either side of it: [door, a body, b body].
static func _a_door(s: Run.RunState) -> Array:
	for door in s.plan.doors:
		if door.level == 0:
			var a := Move.body_at_cell(s.plan, Floor.Pos.make(0, door.ax, door.ay))
			var b := Move.body_at_cell(s.plan, Floor.Pos.make(0, door.bx, door.by))
			return [door, a, b]
	return []

func test_a_closed_edge_blocks_walk_and_sight_and_never_seals(t: T) -> void:
	var s: Run.RunState = _game("dg0-door", 1, ["a", "b"] as Array[String])[1]
	var found := _a_door(s)
	t.check(not found.is_empty(), "the Clinic has a door")
	var door: Floor.Door = found[0]
	var a: Move.Body = found[1]
	var b: Move.Body = found[2]
	var open_walk := Run.move_in_run(s, a, b.x - a.x, b.z - a.z, 0.3)
	t.check(Move.cell_of(s.plan, open_walk).x == door.bx and Move.cell_of(s.plan, open_walk).y == door.by, "open, a walk goes through the doorway")
	var r := _ask(s, &"test_tile", &"close_edge", [0, door.ax, door.ay, door.bx, door.by, s.t + 10.0])
	t.check(bool(r[0]), "nobody near it: the door shuts")
	var shut: Run.RunState = r[1]
	var shut_walk := Run.move_in_run(shut, a, b.x - a.x, b.z - a.z, 0.3)
	t.check(Move.cell_of(shut.plan, shut_walk).x == door.ax and Move.cell_of(shut.plan, shut_walk).y == door.ay, "shut, the same walk stays on its side")
	t.check(DangerFx.line_blocked(shut.dangers, 0, a.x, a.z, b.x, b.z, float(shut.plan.cell_size)), "shut, it cuts the line of sight through it")
	t.check(DangerFx.hides_resident(shut.dangers, b, a, shut.t, float(shut.plan.cell_size)), "a resident behind it is unseen")
	var cs := float(s.plan.cell_size)
	var mid := Move.Body.make((door.ax + door.bx + 1) * 0.5 * cs, (door.ay + door.by + 1) * 0.5 * cs, 0, 0.0)
	var moved := s.copy()
	var players: Array[Run.RunPlayer] = []
	for p in s.players:
		var np := p.copy()
		if np.id == "b":
			np.body = mid
		players.append(np)
	moved.players = players
	t.check(not bool(_ask(moved, &"test_tile", &"close_edge", [0, door.ax, door.ay, door.bx, door.by, s.t + 10.0])[0]), "someone in the doorway: it never shuts on them")
	t.check(not bool(_ask(s, &"test_tile", &"close_edge", [0, door.ax, door.ay, door.bx, door.by, s.t + Dangers.DOOR_MAX + 1.0])[0]), "never for longer than danger.door_max")
	# The base opens it at its time, whatever the kind does.
	var rules := HostRules.new(true, 1, Places.FULL, false, false, true)
	rules.dangers = [&"test_tile"]
	var later := shut
	var opened := false
	for _k in roundi(11.0 / DT):
		var res := rules.step(later, _still(later), DT)
		later = res.state
		for e in res.events:
			if e["type"] == "dangerDoor" and bool(e["open"]):
				opened = true
	t.check(opened and (later.dangers as DangerFx.DangerFloor).doors.is_empty(), "it opens again by itself at its time")

func test_hold_keeps_the_body(t: T) -> void:
	var gs := _game("dg0-hold", 1, ["a", "b"] as Array[String])
	var rules: HostRules = gs[0]
	var s: Run.RunState = gs[1]
	var start := _player(s, "a").body
	var r := _ask(s, &"test_tile", &"stumble", ["a", 1.0, 8.0])
	t.check(bool(r[0]), "a stumble is accepted")
	var evs: Array = r[2]
	t.check(evs.any(func(e: Dictionary) -> bool: return e["type"] == "dangerNoise" and e["by"] == "a"), "a stumble is a noise blamed on them")
	s = r[1]
	for _k in 10:
		s = rules.step(s, _still(s, {"a": Move.Body.make(start.x + 0.5, start.z, start.level, start.y)}), DT).state
	t.eq([_player(s, "a").body.x, _player(s, "a").body.z], [start.x, start.z], "held: the input's body is not taken")
	for _k in 20:
		s = rules.step(s, _still(s, {"a": Move.Body.make(start.x + 0.5, start.z, start.level, start.y)}), DT).state
	t.check(absf(_player(s, "a").body.x - (start.x + 0.5)) < 1e-6, "after it, the input's body is taken again")
	t.check(not bool(_ask(s, &"test_tile", &"hold", ["a", 0.0])[0]), "a hold of no time is refused")
	var long := _ask(s, &"test_tile", &"hold", ["a", 60.0])
	t.check(float(((long[1] as Run.RunState).dangers as DangerFx.DangerFloor).fx["a"]["until"]) <= s.t + Dangers.HOLD_MAX + 1e-9, "never longer than danger.hold_max")

func test_hang_cut_down_and_out_behave_as_the_heal(t: T) -> void:
	var gs := _game("dg0-hang", 1, ["a", "b"] as Array[String])
	var rules: HostRules = gs[0]
	var s0: Run.RunState = gs[1]
	var spot := _player(s0, "a").body
	var at := Move.Body.make(spot.x, spot.z, spot.level, spot.y + 1.0)
	t.check(not bool(_ask(s0, &"test_tile", &"pin", ["a", &"hang", at, spot])[0]), "a passive kind may not hang anyone")
	var r := _ask(s0, &"grabber", &"pin", ["a", &"hang", at, spot])
	t.check(bool(r[0]), "an active kind hangs a player while a crewmate is up")
	var s: Run.RunState = r[1]
	t.eq(_player(s, "a").status, &"down", "hung is the run's own down")
	t.check(not bool(_ask(s, &"grabber", &"pin", ["b", &"hang", at, spot])[0]), "never the last one up")
	# Not helped: out by the run's own timer, its red spot where they come down.
	var out := s
	for k in roundi((Run.DOWN_TIME + 0.5) / DT):
		out = rules.step(out, _still(out, {"a": Move.Body.make(spot.x + 3.0, spot.z, 0, 0.0)}), DT).state
		if k == 5:
			t.check(_player(out, "a").status == &"down" and absf(_player(out, "a").body.y - at.y) < 1e-6 and _player(out, "a").body.x == at.x, "while hung the body stays at the pin, whatever the input says")
	t.eq(_player(out, "a").status, &"out", "not cut down in time: out")
	t.eq([_player(out, "a").body.x, _player(out, "a").body.y], [spot.x, spot.y], "and down on the stand spot")
	t.check(out.spots.size() == 1 and absf(float(out.spots[0]["y"]) - spot.y) < 0.01, "the red spot is on the floor")
	# Cut down: b holds F beside them for the heal's time.
	var cut := s
	var healed := false
	for _k in roundi((Run.HEAL_TIME + 0.5) / DT):
		var res := rules.step(cut, _still(cut, {"b": Move.Body.make(spot.x + 0.5, spot.z, spot.level, spot.y)}, {"b": true}), DT)
		cut = res.state
		for e in res.events:
			healed = healed or (e["type"] == "healed" and e["playerId"] == "a")
	t.check(healed and _player(cut, "a").status == &"ok", "a crewmate's hold is the cut down (the run's heal)")
	t.eq([_player(cut, "a").body.x, _player(cut, "a").body.y], [spot.x, spot.y], "they stand on the stand spot")
	t.check(not (cut.dangers as DangerFx.DangerFloor).pins.has("a"), "and are no longer pinned")

func test_ledge_has_its_own_timer_and_fall(t: T) -> void:
	var gs := _game("dg0-ledge", 1, ["a", "b"] as Array[String])
	var rules: HostRules = gs[0]
	var s0: Run.RunState = gs[1]
	var spot := _player(s0, "a").body
	var fall := Move.Body.make(spot.x + 1.0, spot.z, 0, spot.y)
	var r := _ask(s0, &"trapdoor", &"pin", ["a", &"ledge", spot, spot, 2.0, fall])
	t.check(bool(r[0]), "a ledge is accepted")
	var s: Run.RunState = r[1]
	for _k in roundi(2.3 / DT):
		s = rules.step(s, _still(s), DT).state
	t.eq(_player(s, "a").status, &"out", "not pulled up within its own 2 s: out (not the down timer)")
	t.eq(_player(s, "a").body.x, fall.x, "at the fall spot")

func test_send_out_and_the_last_one_up(t: T) -> void:
	var solo: Run.RunState = _game("dg0-out", 1, ["a"] as Array[String])[1]
	t.check(not bool(_ask(solo, &"trapdoor", &"send_out", ["a"])[0]), "a solo player is never taken")
	var gs := _game("dg0-out", 1, ["a", "b"] as Array[String])
	var rules: HostRules = gs[0]
	var r := _ask(gs[1], &"trapdoor", &"send_out", ["a"])
	t.check(bool(r[0]), "with a crewmate up, out is accepted")
	var s: Run.RunState = rules.step(r[1], _still(r[1]), DT).state
	t.eq(_player(s, "a").status, &"out", "out by the run's own rule on the next tick")
	t.check(not bool(_ask(s, &"trapdoor", &"send_out", ["b"])[0]), "the last one up is never taken")

func test_block_only_when_enabled(t: T) -> void:
	var on: Run.RunState = _game("dg0-block", 1, ["a"] as Array[String])[1]
	t.check(Dangers.block(on) is Dictionary, "with a kind on and placed, the world has a dangers block")
	var host := FileAccess.get_file_as_string("res://net/host.gd")
	t.check(host.contains("var danger_block: Variant = Dangers.block(s)\n\tif danger_block != null:\n\t\tout[\"dangers\"] = danger_block"), "net/host.gd sends it only when there is one")

func test_setting_per_floor(t: T) -> void:
	var rules := HostRules.new(true, 1, Places.FULL, false, false, true)
	rules.dangers = [&"test_tile"]
	var s := Run.with_tuning(rules.prepare(Run.create_run("dg0-pf", ["a"] as Array[String], Places.FULL)), {&"danger.per_floor": 0.0})
	s = rules.step(s, _still(s), DT).state
	t.eq((s.dangers as DangerFx.DangerFloor).records.size(), 0, "danger.per_floor 0: no danger on floor 1")

func test_setting_per_floor_deep(t: T) -> void:
	var rules := HostRules.new(true, 2, Places.FULL, false, false, true)
	rules.dangers = [&"test_tile"]
	var s := Run.with_tuning(rules.prepare(Run.create_run("dg0-pfd", ["a"] as Array[String], Places.FULL)), {&"danger.deep_from": 2.0, &"danger.per_floor_deep": 0.0})
	s = rules.step(s, _still(s), DT).state
	t.eq((s.dangers as DangerFx.DangerFloor).records.size(), 0, "deep from floor 2 with danger.per_floor_deep 0: none on floor 2")

func test_setting_deep_from(t: T) -> void:
	var rules := HostRules.new(true, 2, Places.FULL, false, false, true)
	rules.dangers = [&"test_tile"]
	var s := Run.with_tuning(rules.prepare(Run.create_run("dg0-df", ["a"] as Array[String], Places.FULL)), {&"danger.deep_from": 3.0, &"danger.per_floor_deep": 0.0})
	s = rules.step(s, _still(s), DT).state
	t.eq((s.dangers as DangerFx.DangerFloor).records.size(), 1, "danger.deep_from 3: floor 2 still has the shallow count")

func test_setting_door_max(t: T) -> void:
	var s: Run.RunState = _game("dg0-door", 1, ["a"] as Array[String])[1]
	var door: Floor.Door = _a_door(s)[0]
	s = Run.with_tuning(s, {&"danger.door_max": 5.0})
	t.check(not bool(_ask(s, &"test_tile", &"close_edge", [0, door.ax, door.ay, door.bx, door.by, s.t + 6.0])[0]), "danger.door_max 5 s: a 6 s shut is refused")
	t.check(bool(_ask(s, &"test_tile", &"close_edge", [0, door.ax, door.ay, door.bx, door.by, s.t + 4.0])[0]), "a 4 s one is not")

func test_setting_hold_max(t: T) -> void:
	var s := Run.with_tuning(_game("dg0-hm", 1, ["a", "b"] as Array[String])[1], {&"danger.hold_max": 1.0})
	var r := _ask(s, &"test_tile", &"hold", ["a", 3.0])
	t.check(absf(float(((r[1] as Run.RunState).dangers as DangerFx.DangerFloor).fx["a"]["until"]) - (s.t + 1.0)) < 1e-9, "danger.hold_max 1 s: a 3 s hold lasts 1 s")

func test_setting_dark_max(t: T) -> void:
	var s := Run.with_tuning(_game("dg0-dm", 1, ["a"] as Array[String])[1], {&"danger.dark_max": 2.0})
	var r := _ask(s, &"test_tile", &"dark", [0, 0.0, 0.0, 10.0, 10.0, s.t + 8.0])
	t.check(absf(float(((r[1] as Run.RunState).dangers as DangerFx.DangerFloor).dark[0][5]) - (s.t + 2.0)) < 1e-9, "danger.dark_max 2 s: an 8 s dark lasts 2 s")

func test_snapshot_block_round_trips(t: T) -> void:
	var b := {"r": [{"id": 0, "kind": "test_tile", "x": 1.25, "y": 0.0, "z": 3.5, "level": 0, "yaw": 0.5, "state": "armed", "since": 12.5, "n": [1.0, 2.5]}],
		"dark": [[0, 1.0, 2.0, 3.0, 4.0, 20.0, 15.0]], "doors": [[0, 1, 2, 2, 2, 30.0]], "solids": [[1, 0.5, 0.5, 1.0, 1.0]],
		"fx": [["a", "blind", 14.0]], "pins": [["b", "hang", 1.0, 2.0, 3.0]], "prompts": [[0, "HOLD F", 1.5]]}
	var c := Protocol._V.new()
	var back := Protocol.dec_dangers(c, JSON.parse_string(JSON.stringify(Protocol.enc_dangers(b))))
	t.check(not c.bad, "the block decodes")
	t.eq(JSON.stringify(back), JSON.stringify(b), "and comes back as it was sent")
