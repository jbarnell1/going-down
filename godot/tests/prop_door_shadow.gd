extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Move = preload("res://sim/move.gd")
const Places = preload("res://sim/places.gd")

static func doorway_view(s: Run.RunState, id: String) -> Run.PlayerInput:
	for d in s.plan.doors:
		if d.level != 0:
			continue
		var centre := Vector2(d.ax + d.bx + 1, d.ay + d.by + 1) * (0.5 * s.plan.cell_size)
		var normal := Vector2(d.bx - d.ax, d.by - d.ay)
		for side: float in [-1.0, 1.0]:
			var foot := centre + normal * side * 3.0
			var body := Move.Body.make(foot.x, foot.y, 0, 0.0)
			var i := Run.PlayerInput.make(id, body, 1.55, atan2(normal.x * side, normal.y * side), -0.18, 80, 58)
			if not Run._shadow_door(s, i).is_empty():
				return i
	return null

static func state_for(seed: String) -> Run.RunState:
	var s := Run.create_run(seed, ["reader", "friend"] as Array[String], Places.FULL)
	s.phase = &"away"
	s.orderly.mode = &"dormant"
	s.orderly.body = Move.Body.make(-50, -50, 0, 0)
	for p in s.players:
		p.aboard = false
	return s

static func tick(s: Run.RunState, i: Run.PlayerInput, read := "") -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	if read != "":
		events.append({"type":"readingClosed", "value":3.0, "playerId":read})
	Run.step_doorway_shadow(s, [i], 1.0, events)
	return events.filter(func(e: Dictionary) -> bool: return e.type == "doorwayShadow")

func test_quiet_reader_only_once_and_seeded(t: T) -> void:
	for seed: String in ["clinic-shadow-a", "clinic-shadow-b"]:
		var s := state_for(seed)
		var i := doorway_view(s, "reader")
		t.check(i != null, "seed exposes a real visible doorway")
		if i == null: continue
		t.check(tick(s, i, "reader").is_empty() and s.shadow_readers.is_empty(), "flag off ignores exposure and cue")
		s.doorway_shadow = true
		tick(s, i, "friend")
		for n in 4: t.check(tick(s, i).is_empty(), "another player's reading does not qualify this viewer")
		s.orderly.mode = &"hunting"
		tick(s, i, "reader")
		for n in 4: t.check(tick(s, i).is_empty(), "chase cannot produce or bank a scare")
		s.orderly.mode = &"dormant"
		tick(s, i)
		tick(s, i)
		var old_pitch := i.pitch
		i.pitch = PI / 2
		t.check(Run._shadow_door(s, i).is_empty(), "looking at the ceiling cannot consume the doorway event")
		i.pitch = old_pitch
		var before := s.copy()
		var events := tick(s, i)
		t.eq(events.size(), 1, "third quiet second fires")
		if events.is_empty(): continue
		t.eq(events, tick(before, i), "same seed and authoritative inputs replay exactly")
		t.eq(events[0].playerId, "reader", "only the reader receives it")
		t.check(tick(s, i).is_empty(), "one per run")
