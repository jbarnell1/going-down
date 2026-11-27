# DG0's template kind, test_tile (sim/dangers/test_tile.gd; client/dangers/test_tile_view.gd). Copy this file's shape
# for a kind: placed from the seed the same every time, its cue a second before its cost, a careful player passes,
# every number a live setting (each with its test_setting_ proof, as tests/prop_settings.gd requires).
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Places = preload("res://sim/places.gd")
const HostRules = preload("res://net/host_rules.gd")
const Dangers = preload("res://sim/dangers.gd")
const Settings = preload("res://sim/settings.gd")

const DT := 0.05

static func _rules(kinds: Array) -> HostRules:
	# The down rule on (as in the game's rooms), the dangers asked for by name (the last parameter's field).
	var r := HostRules.new(true, 1, [], false, false, true)
	r.dangers = Dangers.resolve(kinds)
	return r

## A Clinic run with test_tile on, stepped `ticks` with nobody moving; returns [rules, state].
static func _run(seed: String, ticks := 2, tuning: Dictionary = {}) -> Array:
	var r := _rules(["test_tile"])
	var s := r.prepare(Run.create_run(seed, ["a", "b"] as Array[String]))
	if not tuning.is_empty():
		s = Run.with_tuning(s, tuning)
	for _k in ticks:
		s = r.step(s, _inputs(s, {}), DT).state
	return [r, s]

static func _inputs(s: Run.RunState, bodies: Dictionary, gait: StringName = &"walk") -> Array[Run.PlayerInput]:
	var out: Array[Run.PlayerInput] = []
	for p in s.players:
		var b: Move.Body = bodies.get(p.id, p.body)
		var i := Run.PlayerInput.make(p.id, b, 1.65, 0.0, 0.0, 90.0, 70.0)
		i.gait = gait
		out.append(i)
	return out

static func _tile(s: Run.RunState) -> Dictionary:
	for r in (s.dangers as Dangers.DangerFloor).records:
		if r["kind"] == &"test_tile":
			return r
	return {}

## Walk player a onto the tile (from 1.5 m away, over a few ticks) at `gait`; return [events, state] after `secs` more.
static func _walk_on(seed: String, gait: StringName, secs: float, tuning: Dictionary = {}) -> Array:
	var rs := _run(seed, 2, tuning)
	var r: HostRules = rs[0]
	var s: Run.RunState = rs[1]
	var tile := _tile(s)
	var evs: Array[Dictionary] = []
	var steps := 10
	for k in steps + roundi(secs / DT):
		var f := minf(1.0, float(k) / steps)
		var b := Move.Body.make(float(tile["x"]) - 1.5 * (1.0 - f), float(tile["z"]), int(tile["level"]), float(tile["y"]))
		var res := r.step(s, _inputs(s, {"a": b}, gait), DT)
		s = res.state
		for e in res.events:
			if str(e["type"]).begins_with("danger"):
				evs.append(e)
	return [evs, s]

func test_placed_from_the_seed(t: T) -> void:
	var a: Run.RunState = _run("dg0-tile")[1]
	var b: Run.RunState = _run("dg0-tile")[1]
	var ta := _tile(a)
	t.check(not ta.is_empty(), "the Clinic gets its tile")
	t.eq([ta["x"], ta["z"], ta["level"]], [_tile(b)["x"], _tile(b)["z"], _tile(b)["level"]], "the same seed puts it on the same spot")
	t.eq(StringName(ta["state"]), &"idle", "it starts idle")
	var c: Run.RunState = _run("dg0-tile-other")[1]
	t.check(not _tile(c).is_empty(), "another seed has one too")
	var clear := Dangers.keep_clear_of(a, null)
	var near := false
	for k in clear:
		if int(k["level"]) == int(ta["level"]) and Vector2(float(k["x"]) - float(ta["x"]), float(k["z"]) - float(ta["z"])).length() < float(k["r"]) + 0.6:
			near = true
	t.check(not near, "it is clear of the lift, the doorways and every hide")

func test_click_then_noise_a_second_later(t: T) -> void:
	var out := _walk_on("dg0-tile", &"walk", 2.0)
	var evs: Array = out[0]
	var click := -1.0
	var noise := -1.0
	for e: Dictionary in evs:
		if e["type"] == "dangerCue" and click < 0.0:
			click = float(e["t"])
		if e["type"] == "dangerNoise" and noise < 0.0:
			noise = float(e["t"])
			t.eq(str(e["by"]), "a", "the noise is blamed on who stepped on it")
	t.check(click >= 0.0 and noise >= 0.0, "a walk onto it clicks, then makes its noise")
	t.check(noise - click >= 1.0 - 1e-6, "the click comes at least a second before the noise (%.2f s)" % (noise - click))
	t.eq(StringName(_tile(out[1])["state"]), &"spent", "then it is spent")

func test_a_creep_passes(t: T) -> void:
	var out := _walk_on("dg0-tile", &"creep", 2.0)
	t.eq((out[0] as Array).size(), 0, "creeping over it sets nothing off")
	t.eq(StringName(_tile(out[1])["state"]), &"idle", "it stays idle")

func test_never_in_all(t: T) -> void:
	t.check(not Dangers.all_kinds().has(&"test_tile"), "all never turns the template on")
	t.eq(Dangers.resolve(["test_tile"]), [&"test_tile"] as Array[StringName], "asked by name it is on")

func test_setting_test_tile_delay(t: T) -> void:
	var out := _walk_on("dg0-tile", &"walk", 3.0, {&"danger.test_tile.delay": 2.0})
	var click := -1.0
	var noise := -1.0
	for e: Dictionary in out[0]:
		if e["type"] == "dangerCue":
			click = float(e["t"])
		if e["type"] == "dangerNoise":
			noise = float(e["t"])
	t.check(noise - click >= 2.0 - 1e-6 and noise - click < 2.0 + 2 * DT, "danger.test_tile.delay 2 s: the noise 2 s after the click (%.2f)" % (noise - click))

func test_setting_test_tile_loud(t: T) -> void:
	var out := _walk_on("dg0-tile", &"walk", 2.0, {&"danger.test_tile.loud": 20.0})
	var loud := -1.0
	for e: Dictionary in out[0]:
		if e["type"] == "dangerNoise":
			loud = float(e["loud"])
	t.eq(loud, 20.0, "danger.test_tile.loud 20 m: the noise carries 20 m")
