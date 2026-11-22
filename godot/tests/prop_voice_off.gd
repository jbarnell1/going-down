# VC1, the microphone's run flag (net/host_rules.gd voice, the last parameter of HostRules._init, after economy_fix_;
# sim/run.gd with_voice). The rule for every rule change: with the flag off, nothing changes. Proved here:
#   1. Off unless asked: HostRules, a run made as before, and copy() keeps it; the game's rooms (server/room.gd,
#      net/local_room.gd) ask for it unless started with voice=0.
#   2. With it off, a run whose players shout (level 15) the whole time is identical, tick for tick, to one whose
#      players are silent: every event, every player and every resident, on each of the game's first five floors
#      (the Clinic, the Annex, the Playroom, the Arboretum, in the deck's order) with wandering bot players.
#   3. With it on, the same shouting changes the Arboretum's run (so 2 can see a difference).
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Places = preload("res://sim/places.gd")
const Bot = preload("res://sim/bot.gd")
const Move = preload("res://sim/move.gd")
const HostRules = preload("res://net/host_rules.gd")

const DT := 0.05
const EYE := 1.65

func test_off_by_default_and_on_in_the_rooms(t: T) -> void:
	t.check(not HostRules.new(true, 1).voice, "HostRules: off unless asked")
	var ids: Array[String] = ["a", "b"]
	t.check(not Run.create_run("vc1", ids).voice, "a run made as before: off")
	t.check(not HostRules.new(true, 1, Places.FULL).prepare(Run.create_run("vc1", ids, Places.FULL)).voice, "prepared without it: off")
	var r := HostRules.new(true, 1, Places.FULL)
	r.voice = true
	t.check(r.prepare(Run.create_run("vc1", ids, Places.FULL)).voice, "asked for: the prepared run has it")
	t.check(Run.with_voice(Run.create_run("vc1", ids)).copy().voice, "copy() keeps it")
	t.check(HostRules.voice_by_arg(), "no voice=0 on this command line: the rooms ask for it")
	var src := FileAccess.get_file_as_string("res://server/room.gd")
	t.check(src.contains("and HostRules.voice_by_arg(),"), "server/room.gd passes it (RL1's ward_lift_clear_ follows it)")
	src = FileAccess.get_file_as_string("res://net/local_room.gd")
	t.check(src.contains("and HostRules.voice_by_arg(),"), "net/local_room.gd passes it (RL1's ward_lift_clear_ follows it)")
	var host := FileAccess.get_file_as_string("res://net/host.gd")
	t.check(host.contains("if s.voice and not _ward_review.webbed.has(i.id):"), "net/host.gd gives the Rigger a voice only with the flag")

## One line per tick: the time, the phase, every event's type, time and player, every player and the resident.
static func _line(s: Run.RunState, events: Array[Dictionary]) -> String:
	var parts: Array[String] = ["%.3f %s %d" % [s.t, s.phase, s.depth]]
	for e in events:
		parts.append("%s@%.3f:%s" % [str(e.get("type", e.get("kind", ""))), float(e.get("t", -1.0)), str(e.get("playerId", ""))])
	for p in s.players:
		var b := p.body
		parts.append("%s %s %s %.4f,%.4f,%d" % [p.id, p.status, str(p.aboard), b.x if b != null else 0.0, b.z if b != null else 0.0, b.level if b != null else -1])
	if s.orderly != null and s.orderly.body != null:
		parts.append("o %.4f,%.4f %s" % [s.orderly.body.x, s.orderly.body.z, str(s.orderly.mode)])
	if s.garden != null:
		parts.append("k %.4f,%.4f %s" % [s.garden.keeper.body.x, s.garden.keeper.body.z, s.garden.keeper.mode])
	if s.seek != null:
		parts.append("m %.4f,%.4f %s %.4f" % [s.seek.minder.body.x, s.seek.minder.body.z, s.seek.minder.mode, s.seek.anger])
	return " | ".join(parts)

static var _prepared := {}

## `secs` of floor `depth` of the game's deck with two wandering bots, everyone speaking at `level`, the run's voice
## `on` or off. Returns one line per tick.
static func _bot_run(seed: String, depth: int, on: bool, level: int, secs: float) -> PackedStringArray:
	var ids: Array[String] = ["a", "b"]
	var rules := HostRules.new(true, depth, Places.FULL, false, false, true)
	rules.voice = on
	# A prepared run is never edited, so the same one starts every run of this seed, floor and flag.
	var key := "%s/%d/%s" % [seed, depth, str(on)]
	if not _prepared.has(key):
		_prepared[key] = rules.prepare(Run.create_run(seed, ids, Places.FULL))
	var s: Run.RunState = _prepared[key]
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
				Bot.step_bot(s.plan, b, DT, s.orderly.body if s.orderly != null else null)
				var inp := Run.PlayerInput.make(p.id, b.body, EYE, b.yaw, b.pitch, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG)
				inp.voice_level = level
				ins.append(inp)
			elif p.status == &"down":
				var dn := Run.PlayerInput.make(p.id, p.body, EYE, b.yaw, b.pitch, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG)
				dn.blind = true
				dn.voice_level = level
				ins.append(dn)
		var r := rules.step(s, ins, DT)
		s = r.state
		out.append(_line(s, r.events))
	return out

static func _first_diff(a: PackedStringArray, b: PackedStringArray) -> int:
	for i in mini(a.size(), b.size()):
		if a[i] != b[i]:
			return i
	return -1 if a.size() == b.size() else mini(a.size(), b.size())

func test_flag_off_shouting_changes_nothing(t: T) -> void:
	var secs := 15.0 if t.quick else 90.0
	var seeds: Array[String] = ["vc1-off-0"]
	if not t.quick:
		seeds.append_array(["vc1-off-1", "vc1-off-2"] as Array[String])
	for seed in seeds:
		for depth in range(1, 6):
			var quiet := _bot_run(seed, depth, false, 0, secs)
			var loud := _bot_run(seed, depth, false, 15, secs)
			var at := _first_diff(quiet, loud)
			t.check(at < 0, "%s floor %d: the flag off, shouting is the same run as silence (first differs at tick %d: %s / %s)" % [seed, depth, at, quiet[at] if at >= 0 and at < quiet.size() else "", loud[at] if at >= 0 and at < loud.size() else ""])

func test_flag_on_shouting_is_heard(t: T) -> void:
	# The Arboretum (floor 5): the shouting crew is heard, so the run is not the silent one.
	var quiet := _bot_run("vc1-off-0", 5, true, 0, 60.0)
	var loud := _bot_run("vc1-off-0", 5, true, 15, 60.0)
	var silent_off := _bot_run("vc1-off-0", 5, false, 0, 60.0)
	t.eq(_first_diff(quiet, silent_off), -1, "on, a silent crew is the same run as the flag off")
	t.check(_first_diff(quiet, loud) >= 0, "on, a shouting crew changes the Arboretum's run")

