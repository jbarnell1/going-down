# The Orderly against src/sim/entity.ts, state after every tick, in scripted scenes (mirrors
# entityScenes in godot/tools/dump_reference.ts): stared at, then turned away from (grace, release,
# frozen again); a blind hunt across levels to a catch and the dormant spell; waking at 60 s; a
# wind-up cancelled by a look; creeping up on still prey and running down fleeing prey; and the
# squeak's loudness for a listener it hunts unseen (hearing range, muffling).
extends RefCounted

const T = preload("res://tests/t.gd")
const Snap = preload("res://tests/snap.gd")
const Trace = preload("res://tests/trace.gd")
const Plans = preload("res://tests/plans.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Bot = preload("res://sim/bot.gd")
const M = preload("res://sim/jsmath.gd")

const DT := 0.05

static func view(id: String, b: Move.Body, yaw: float, pitch: float = 0.0) -> Array[Entity.PlayerView]:
	return [Entity.PlayerView.make(id, b, Bot.BOT_EYE, yaw, pitch, Bot.BOT_HFOV_DEG, Bot.BOT_VFOV_DEG, true)]

static func blind(id: String, b: Move.Body) -> Array[Entity.PlayerView]:
	return [Entity.PlayerView.make(id, b, Bot.BOT_EYE, 0.0, PI / 2.0, 0.0, 0.0, true)]

static func face_to(from: Move.Body, to: Move.Body) -> float:
	return M.atan2_js(-(to.x - from.x), -(to.z - from.z))

static func hunting(p: Floor.FloorPlan) -> Entity.OrderlyState:
	var s := Entity.create_orderly(p)
	s.mode = &"hunting"
	return s

static func _sign(x: int) -> int:
	return 1 if x > 0 else (-1 if x < 0 else 0)

## A sightline of at least `min_len` cells ending at the entity start, or null.
static func start_line(p: Floor.FloorPlan, min_len: int) -> Floor.Sightline:
	for l in p.sightlines:
		if l.level == p.entity_start.level and l.length >= min_len and ((l.x1 == p.entity_start.x and l.y1 == p.entity_start.y) or (l.x2 == p.entity_start.x and l.y2 == p.entity_start.y)):
			return l
	return null

func test_scenes(t: T) -> void:
	var ref: Array = Snap.load_ref("entity.json")
	var traces: Array[Trace] = []
	# (A lambda would capture a counter by value: the next trace is simply the next reference.)
	var next_trace := func() -> Trace:
		var tr := Trace.new(ref[traces.size()])
		traces.append(tr)
		return tr

	# Staring contest, three floors.
	var tried := 0
	var i := 0
	while tried < 3 and i < 200:
		var p := Plans.plan("stare-%d" % i, 1 + (i % 4))
		var s := start_line(p, 12)
		if s != null:
			tried += 1
			var at_start := s.x1 == p.entity_start.x and s.y1 == p.entity_start.y
			var dx := _sign(s.x2 - s.x1) * (1 if at_start else -1)
			var dy := _sign(s.y2 - s.y1) * (1 if at_start else -1)
			var me := Move.body_at_cell(p, Floor.Pos.make(s.level, p.entity_start.x + dx * 8, p.entity_start.y + dy * 8))
			var st := Entity.create_orderly(p)
			var facing := face_to(me, st.body)
			var tr: Trace = next_trace.call()
			for k in 730:
				var yaw := facing if k < 600 else (facing + PI if k < 630 else facing)
				var r := Entity.step_entity(p, st, view("me", me, yaw), DT)
				st = r.state
				var a := Entity.audibility(p, st, me, Bot.BOT_EYE)
				tr.tick(Snap.orderly(st), r.events, [a.gain, a.muffled])
		i += 1

	# Blind hunt across levels to a side room, the catch, and the dormant spell after it.
	var scenes := 0
	i = 0
	while scenes < 3 and i < 100:
		var p := Plans.plan("stairs-%d" % i, 1 + (i % 4))
		i += 1
		var other := 1 if p.entity_start.level == 0 else 0
		var room: Floor.Room = null
		for r in p.rooms:
			if r.level == other and r.kind != &"lobby" and r.kind != &"atrium" and r.branch == &"side":
				room = r
				break
		if room == null:
			continue
		var cell := Floor.Pos.make(other, room.x + room.w / 2, room.y + room.h / 2)
		if not Floor.is_walkable(p, cell.level, cell.x, cell.y) or Floor.find_path(p, p.entity_start, cell).is_empty():
			continue
		scenes += 1
		var me := Move.body_at_cell(p, cell)
		var st := hunting(p)
		var tr: Trace = next_trace.call()
		var caught_at := -1
		var k := 0
		while k < 120.0 / DT and (caught_at < 0 or k < caught_at + 260):
			var r := Entity.step_entity(p, st, blind("me", me), DT)
			st = r.state
			if caught_at < 0:
				for e in r.events:
					if e["type"] == "caught":
						caught_at = k
			tr.tick(Snap.orderly(st), r.events)
			k += 1

	# Wakes at 60 s.
	if true:
		var p := Plans.plan("wake", 1)
		var st := Entity.create_orderly(p)
		var tr: Trace = next_trace.call()
		for k in 1240:
			var r := Entity.step_entity(p, st, blind("me", Move.body_at_cell(p, p.landing)), DT)
			st = r.state
			tr.tick(Snap.orderly(st), r.events)

	# A wind-up, part way through, then a look.
	if true:
		var p := Plans.plan("windup", 1)
		var me := Move.body_at_cell(p, p.landing)
		var st := hunting(p)
		var tr: Trace = next_trace.call()
		for k in 2400:
			var r := Entity.step_entity(p, st, blind("me", me), DT)
			st = r.state
			tr.tick(Snap.orderly(st), r.events)
			var wound := false
			for e in r.events:
				if e["type"] == "windUp":
					wound = true
			if wound:
				break
		var r1 := Entity.step_entity(p, st, blind("me", me), DT)
		st = r1.state
		tr.tick(Snap.orderly(st), r1.events)
		var look := face_to(me, st.body)
		for k in 200:
			var r := Entity.step_entity(p, st, view("me", me, look), DT)
			st = r.state
			tr.tick(Snap.orderly(st), r.events)

	# Creep near still prey, full speed after fleeing prey.
	for seed: String in ["prey-a", "prey-b"]:
		var p: Floor.FloorPlan = null
		var s: Floor.Sightline = null
		var j := 0
		while j < 100 and s == null:
			p = Plans.plan("%s-%d" % [seed, j], 1 + (j % 4))
			s = start_line(p, 14)
			j += 1
		var at_start := s.x1 == p.entity_start.x and s.y1 == p.entity_start.y
		var dx := _sign(s.x2 - s.x1) * (1 if at_start else -1)
		var dz := _sign(s.y2 - s.y1) * (1 if at_start else -1)
		var o := Move.body_at_cell(p, p.entity_start)
		var max_d := (s.length - 1) * p.cell_size
		var d := 9.0
		var st := hunting(p)
		var tr: Trace = next_trace.call()
		for k in 500:
			if k >= 80:
				d = minf(max_d, d + 3.0 * DT)
			var x := o.x + dx * d
			var z := o.z + dz * d
			var me := Move.Body.make(x, z, p.entity_start.level, Move.feet_height(p, p.entity_start.level, x, z))
			var r := Entity.step_entity(p, st, view("me", me, M.atan2_js(-dx, -dz)), DT)
			st = r.state
			tr.tick(Snap.orderly(st), r.events, [st.prey_speed, st.speed])

	# Hearing: a listener at the landing facing away.
	for h in 4:
		var p := Plans.plan("hear-%d" % h, 1 + (h % 4))
		var me := Move.body_at_cell(p, p.landing)
		var st := hunting(p)
		var tr: Trace = next_trace.call()
		for k in 1200:
			var v := view("me", me, face_to(st.body, me))
			var r := Entity.step_entity(p, st, v, DT)
			st = r.state
			var a := Entity.audibility(p, st, me, Bot.BOT_EYE)
			tr.tick(Snap.orderly(st), r.events, [a.gain, a.muffled])

	t.eq(traces.size(), ref.size(), "scenes")
	var ticks := 0
	var total := Snap.Diff.new()
	var firsts := PackedStringArray()
	for tr in traces:
		ticks += tr.ticks
		total.add(tr.finish(t))
		firsts.append("%s: %s" % [tr.name, tr.first_difference()])
	t.note("%d scenes, %d ticks, every tick's state digest compared; events/snapshots/sound: %s" % [traces.size(), ticks, total.summary()])
	t.note("first differing tick per scene: " + ", ".join(firsts))
