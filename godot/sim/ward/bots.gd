# WD1: bot crews for the Hanging Ward, to measure how hard the Rigger is (tools/ward_hunt.gd, tests/test_ward_rigger.gd).
# Pure and deterministic: one stay is the Ward's own rules (sim/ward/state.gd, stepped as net/host.gd _step_ward_review
# steps it) and the crew's own instruments (sim/instrument.gd step_crew, as sim/run.gd step_ward reads the posed limb),
# with bots walking a waypoint graph of the floor in place of players. Nothing here is used by the game.
#
# A bot knows only what a player could see or hear: the lift's clock and the Company's lines, the loaded line (heard
# anywhere, its house told by where the sound is), the Rigger climbing that house's line, and the arm and hand while it
# is in the house the bot is in. Three skills:
#   careless  wanders house to house and room to room, sprints often, works the winch whenever it passes one, records
#             standing wherever it is when he is near, never runs from the hand, heads for the lift when it returns.
#   sensible  goes with the crew from house to house; one of them sprints to bring him (the lure) and walks out; the
#             others creep by the loaded line and record the climb from the gallery; while the crew is short of the
#             quota they record the search from inside the house (an entry corner), and walk away when the hand comes
#             within 2.2 m; they board with 75 s on the clock.
#   expert    the same with a 2.0 m margin, every one of them records inside, goes upstairs out of the arm's reach
#             when there is a stair; boards with 45 s on the clock.
# Every bot looks at the hand and decides every REACTION seconds; a careless one steps away only when it is within
# 0.9 m, and only half the time.
# The positions are the graph's straight lines between rooms, doorways, galleries and bridges (not the walk model's
# exact collision), which is close enough for the arm's touch and the instrument's distance.
extends RefCounted

const Ward = preload("res://sim/ward/state.gd")
const House = preload("res://sim/ward/house.gd")
const Layout = preload("res://sim/ward/layout.gd")
const Instr = preload("res://sim/instrument.gd")
const Entity = preload("res://sim/entity.gd")
const Move = preload("res://sim/move.gd")
const Settings = preload("res://sim/settings.gd")
const TapeLib = preload("res://sim/tape.gd")
const Stamina = preload("res://sim/stamina.gd")

const DEPTH := 6
const DEPTH_PAY := 4.4840334 # 1.35^5, sim/run.gd depth_multiplier(6)
const BOARD_SECONDS := 30.0
## The hypothetical heal uses the down rule's own reach and time (sim/run.gd HEAL_REACH, HEAL_TIME).
const HEAL_REACH := 1.5
const HEAL_TIME := 3.0
## How often a bot looks at the hand and decides (a player's reaction), seconds.
const REACTION := 0.4

# ------------------------------------------------------------------------------------------------
# The graph: nodes are points (world, feet); edges carry whether they are the winch bridge.

class Graph:
	var pts: Array[Vector3] = []
	var adj: Array = []
	## node -> [house, area] for room nodes.
	var room: Dictionary = {}
	var door_out: Array[int] = []
	var door_in: Array[int] = []
	var rooms: Array = []        # per house: {area: node}
	var corner: Array = []       # per house: [entry corner node]
	var rings: Array = []        # per house: {"sw".."nw": gallery node}
	var upstairs: Array[int] = [] # per house: node or -1
	var lift_car := -1
	var lift_mouth := -1

	func add(p: Vector3) -> int:
		pts.append(p)
		adj.append([])
		return pts.size() - 1

	func link(a: int, b: int, winch := false) -> void:
		var c := pts[a].distance_to(pts[b])
		adj[a].append([b, c, winch])
		adj[b].append([a, c, winch])

	func nearest(p: Vector3) -> int:
		var best := -1
		var d := INF
		for i in pts.size():
			var e := pts[i].distance_squared_to(p)
			if e < d:
				d = e
				best = i
		return best

	var _cache := {}

	## Node path from a to b (a included), or [] when unreachable.
	func route(a: int, b: int, bridge: bool) -> Array[int]:
		var key := (a * 4096 + b) * 2 + (1 if bridge else 0)
		if _cache.has(key):
			var hit: Array[int] = _cache[key]
			return hit.duplicate()
		var found := _route(a, b, bridge)
		_cache[key] = found
		return found.duplicate()

	func _route(a: int, b: int, bridge: bool) -> Array[int]:
		var n := pts.size()
		var cost := PackedFloat64Array()
		cost.resize(n)
		cost.fill(INF)
		var par := PackedInt32Array()
		par.resize(n)
		par.fill(-1)
		var done := PackedByteArray()
		done.resize(n)
		cost[a] = 0.0
		while true:
			var cur := -1
			var best := INF
			for i in n:
				if done[i] == 0 and cost[i] < best:
					best = cost[i]
					cur = i
			if cur < 0 or cur == b:
				break
			done[cur] = 1
			for e: Array in adj[cur]:
				if e[2] and not bridge:
					continue
				var c: float = best + float(e[1])
				if c < cost[e[0]]:
					cost[e[0]] = c
					par[e[0]] = cur
		var out: Array[int] = []
		if cost[b] == INF:
			return out
		var k := b
		while k >= 0:
			out.push_front(k)
			k = par[k]
		return out

static func build_graph(w: Ward) -> Graph:
	var g := Graph.new()
	var layout := w.layout
	var mids := []  # per house: {side: node}
	for i in w.houses.size():
		var site: Dictionary = layout.houses[i]
		var h: House = w.houses[i]
		var cx := float(site.x)
		var cz := float(site.y)
		var hw := float(site.w) * 0.5 + 0.8
		var hd := float(site.d) * 0.5 + 0.8
		var gy := float(site.z) + 0.15
		var ring := {}
		for key: String in ["sw", "s", "se", "e", "ne", "n", "nw", "w"]:
			var x := cx + (-hw if key.contains("w") else (hw if key.contains("e") else 0.0))
			var z := cz + (-hd if key.begins_with("s") else (hd if key.begins_with("n") else 0.0))
			ring[key] = g.add(Vector3(x, gy, z))
		var order := ["sw", "s", "se", "e", "ne", "n", "nw", "w"]
		for k in order.size():
			g.link(ring[order[k]], ring[order[(k + 1) % order.size()]])
		mids.append({"south": ring["s"], "north": ring["n"], "east": ring["e"], "west": ring["w"]})
		g.rings.append(ring)
		# The front door: outside on the gallery, just inside, then the three ground-floor rooms in a line.
		var out_p := h.to_world(Vector3(0, 0, -0.75))
		out_p.y = gy
		var dout := g.add(out_p)
		var din := g.add(h.to_world(Vector3(0, 0, 0.35)))
		g.link(dout, din)
		var best_mid := -1
		var bd := INF
		for key: String in ring:
			var d := g.pts[ring[key]].distance_to(out_p)
			if d < bd:
				bd = d
				best_mid = ring[key]
		g.link(dout, best_mid)
		g.door_out.append(dout)
		g.door_in.append(din)
		var r := {}
		for area: StringName in [&"entry", &"middle", &"rear"]:
			var a: Vector3 = h.areas[area]
			r[area] = g.add(h.to_world(Vector3(a.x, 0, a.z)))
			g.room[r[area]] = [i, area]
		var d0 := g.add(h.to_world(Vector3(h.room_doors[0].x, 0, h.room_doors[0].z)))
		var d1 := g.add(h.to_world(Vector3(h.room_doors[1].x, 0, h.room_doors[1].z)))
		g.room[d0] = [i, &"middle"]
		g.room[d1] = [i, &"rear"]
		g.link(din, r[&"entry"])
		g.link(r[&"entry"], d0)
		g.link(din, d0)
		g.link(d0, r[&"middle"])
		g.link(r[&"middle"], d1)
		g.link(d0, d1)
		g.link(d1, r[&"rear"])
		g.rooms.append(r)
		# An entry corner away from the first room door (where a careful recorder stands).
		var half := h.floor_bounds.size.x * 0.5
		var side := -signf(h.room_doors[0].x) if h.room_doors[0].x != 0.0 else 1.0
		var cn := g.add(h.to_world(Vector3(side * (half - 0.42), 0, 0.5)))
		g.room[cn] = [i, &"entry"]
		g.link(cn, r[&"entry"])
		g.link(cn, din)
		g.corner.append(cn)
		# Upstairs: the first stair's top, out of the arm's reach (the slab stops it).
		if h.stairs.size() > 0:
			var st: House.Stair = h.stairs[0]
			var foot := g.add(h.to_world(st.from))
			var top := g.add(h.to_world(st.to + Vector3(-signf(st.to.x) * 0.6, 0, 0)))
			g.room[foot] = [i, h.area_at(st.from + Vector3.UP * 1.25)]
			g.link(foot, r[&"rear"] if h.area_at(st.from + Vector3.UP * 1.25) == &"rear" else r[&"entry"])
			g.link(foot, top)
			g.upstairs.append(top)
		else:
			g.upstairs.append(-1)
	# The lift: the car, its mouth, into the parlour.
	var ld := w.lift_door()
	g.lift_car = g.add(ld + Vector3(0, 0, -1.4))
	g.lift_mouth = g.add(ld + Vector3(0, 0, 0.45))
	g.link(g.lift_car, g.lift_mouth)
	var parlour: House = w.houses[0]
	var inside := parlour.to_local(ld + Vector3(0, 0, 0.45) + Vector3.UP * 1.25)
	var area := parlour.area_at(inside)
	g.link(g.lift_mouth, g.rooms[0][area if area != &"" else &"middle"])
	# Bridges: chained path points; the ends join the side's gallery middle.
	for edge: Dictionary in layout.bridges:
		var path: Array = edge.path
		var winch: bool = edge.kind == "winch"
		var prev: int = mids[int(edge.a)][edge.a_side]
		for k in path.size():
			var raw: Array = path[k]
			var node := g.add(Vector3(raw[0], raw[2], raw[1]))
			g.link(prev, node, winch and k > 0)
			prev = node
		g.link(prev, mids[int(edge.b)][edge.b_side])
	return g

# ------------------------------------------------------------------------------------------------
# One bot.

class Bot:
	var id: String
	var skill: StringName
	var pos: Vector3
	var path: Array[int] = []
	var gait: StringName = &"walk"
	var raised := false
	var use := false
	var wait_until := 0.0
	var tank := Stamina.SPRINT_SECONDS
	var tired := false
	var caught := false
	var down := false   # the hypothetical heal: caught, lying where they were, waiting for a crewmate
	var downed_at := -1.0
	var heal_for := 0.0
	var boarding := false
	var role: StringName = &""
	var lure_until := -1.0
	var closest := INF  # nearest the hand came to this bot while it was free
	var searched_in := false # a search of the house this bot stood in
	var fled := false # walked away from the hand: stays out of this search
	var react_at := 0.0

# ------------------------------------------------------------------------------------------------
# One stay: seed, crew size, skill; opts {tuning: Settings.Values, heal: bool, dt: float}.

static func stay(seed_value: int, crew_n: int, skill: StringName, opts: Dictionary = {}) -> Dictionary:
	var dt := float(opts.get("dt", 0.1))
	var tuning: Settings.Values = opts.get("tuning", null)
	var heal: bool = opts.get("heal", false)
	# WG1: opts.layout, a generated layout's options (sim/ward/layout.gd options); absent, today's Ward.
	var w := Ward.new(seed_value, opts.get("layout", {}))
	w.tuning = tuning
	# RR1: the solid, crawling Rigger (sim/ward/roam.gd; opts.roam), his chase included.
	if opts.get("roam", false):
		w.enable_roam()
	w.crew_size = crew_n
	var trace: bool = opts.get("trace", false)
	var clock0 := Time.get_ticks_msec()
	var g := build_graph(w)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 7919 + crew_n * 104729 + hash(String(skill))
	var bots: Array[Bot] = []
	var ids: Array[String] = []
	for i in crew_n:
		var b := Bot.new()
		b.id = "p%d" % (i + 1)
		b.skill = skill
		var slot := Vector3(-0.28 + float(i % 2) * 0.56, 0.02, -0.55 - 0.59 * float(i / 2) * (0.5 if i >= 4 else 1.0))
		b.pos = w.lift_door() + slot
		bots.append(b)
		ids.append(b.id)
	var crew := Instr.create_crew(ids)
	var still := Entity.OrderlyState.new()
	still.body = Move.Body.make(0, -1000, 0, -1000)
	var needed := floori(roundf(400.0 * crew_n * pow(Settings.f(tuning, &"quota.step", 1.45), DEPTH - 1) / 5.0) * 5.0)
	var res := {"seed": seed_value, "crew": crew_n, "skill": String(skill), "comes": 0, "caught": [], "earned": 0.0,
		"banked": 0.0, "left": 0, "home": 0, "needed": needed, "danger": false, "near": INF, "searched_in": 0,
		"warn_min": INF, "met_at": -1.0, "heals": 0,
		"climb_s": 0.0, "search_s": 0.0, "rec_climb_s": 0.0, "rec_search_s": 0.0}
	if heal:
		res["heal_on"] = true
	var plan := {"house": -1, "stage": &"", "lurer": 0, "hunts": 0, "since": 0.0}
	var now := 0.0
	var last_minute := false
	var returned := false
	var seen_encounter_at := -1.0
	var encounter_started := {}
	var t_end := float(opts.get("t_end", 700.0))
	while now < t_end and w.phase != &"departed":
		now += dt
		if trace and fmod(now + 0.001, 10.0) < dt:
			print("t=%.0f ms=%d phase=%s enc=%s pos0=%s path=%d" % [now, Time.get_ticks_msec() - clock0, w.phase, w.encounter, str(bots[0].pos), bots[0].path.size()])
		# Decide and move every bot.
		var limb := w.posed_limb(now)
		var hand: Variant = null
		if w.encounter == &"searching" and limb.size() > 1:
			hand = limb[limb.size() - 1]
		var clock_left := w.collection_at - now if w.phase == &"away" else (0.0 if w.phase == &"boarding" else 600.0)
		if w.phase == &"boarding":
			returned = true
		if w.phase == &"away" and clock_left <= 60.0:
			last_minute = true
		for b in bots:
			b.use = false
			if b.caught and not b.down:
				continue
			if b.down:
				continue
			_think(b, bots, w, g, rng, now, dt, limb, hand, clock_left, last_minute, returned, plan, res, crew_n)
			_move(b, w, g, dt)
		# The hypothetical heal: a crewmate within 1 m for 3 s stands a caught player back up.
		if heal:
			for b in bots:
				if not b.down:
					continue
				var helper := false
				for o in bots:
					if o != b and not o.caught and not o.boarding and o.pos.distance_to(b.pos) <= HEAL_REACH:
						helper = true
				b.heal_for = b.heal_for + dt if helper else 0.0
				if b.heal_for >= HEAL_TIME:
					b.down = false
					b.caught = false
					w.caught.erase(b.id)
					res.heals += 1
		# The host's rows and lift (net/host.gd _step_ward_review).
		var rows := {}
		var any_out := false
		var any_in := false
		for b in bots:
			var row := {"position": b.pos, "aboard": w.in_lift(b.pos), "active": not w.caught.has(b.id), "use": b.use,
				"sprint": b.gait == &"sprint" and not b.path.is_empty(), "creep": b.gait == &"creep" or b.path.is_empty()}
			rows[b.id] = row
			if row.active:
				if row.aboard or not w.clear_of_lift(b.pos):
					any_in = true
				else:
					any_out = true
		var evs: Array[Dictionary] = []
		if any_out and not any_in:
			evs.append_array(w.leave(now))
		var enc_before := w.encounter_at
		evs.append_array(w.step(now, dt, BOARD_SECONDS, rows))
		var caught_now: Array[Dictionary] = []
		for e in evs:
			if e.kind == &"weight" and e.surface == &"line":
				# RR1: the line taking his weight is heard where it is: which corner of which house.
				plan["line"] = [int(e.house), int(e.corner)]
			if e.kind == &"line_loaded":
				res.comes += 1
				encounter_started[int(e.house)] = float(e.at)
				seen_encounter_at = float(e.at)
			elif e.kind == &"contact":
				var who := _bot(bots, String(e.id))
				who.caught = true
				who.raised = false
				who.path.clear()
				var warn := now - (w.encounter_at if w.encounter_at >= 0.0 else enc_before)
				res.warn_min = minf(res.warn_min, warn)
				if int(e.house) < 0:
					# RR1: taken out of doors at the end of a chase.
					res.caught.append({"id": who.id, "t": snappedf(now, 0.1), "phase": String(w.phase), "house": -1,
						"room": "chase", "warn": snappedf(warn, 0.01), "style": "", "local": "", "fled": who.fled, "role": String(plan.stage)})
				else:
					var room := w.houses[int(e.house)].area_at(w.houses[int(e.house)].to_local(who.pos + Vector3.UP * 1.25))
					res.caught.append({"id": who.id, "t": snappedf(now, 0.1), "phase": String(w.phase), "house": int(e.house),
						"room": String(room), "warn": snappedf(warn, 0.01), "style": String(w.layout.houses[int(e.house)].style),
						"local": str(w.houses[int(e.house)].to_local(who.pos).snappedf(0.01)), "fled": who.fled, "role": String(plan.stage)})
				caught_now.append({"type": "caught", "t": now, "playerId": who.id})
				if heal:
					who.down = true
		if opts.get("trace_search", false) and w.encounter != res.get("_last_enc", ""):
			var who_in := []
			for b in bots:
				who_in.append("%s:%s%s%s" % [b.id, str(_house_of(w, b.pos)), "R" if b.raised else "", "F" if b.fled else ""])
			print("t=%.1f %s -> %s house %d opening %d plan %s/%s  bots %s" % [now, res.get("_last_enc", ""), w.encounter, w.resident_house, w.roam.opening if w.roam != null else -1, str(plan.house), plan.stage, " ".join(who_in)])
			res["_last_enc"] = w.encounter
		# Where the time goes (tools/ward_hunt.gd prints it): his climb and his search, and bot-seconds recording each.
		var limb_now := w.posed_limb(now)
		var phase_key := "climb" if w.encounter == &"climbing" else ("search" if w.encounter == &"searching" else "")
		if phase_key != "":
			res[phase_key + "_s"] += dt
			var who_may: Variant = w.recorders(rows, now)
			for b in bots:
				if phase_key == "search" and not b.caught and _house_of(w, b.pos) == w.resident_house:
					res["inside_s"] = float(res.get("inside_s", 0.0)) + dt
					if b.raised:
						res["inside_raised_s"] = float(res.get("inside_raised_s", 0.0)) + dt
				if b.raised and not b.caught and limb_now.size() > 1 and _limb_distance(limb_now, b.pos) <= Instr.RECORD_RANGE and (who_may == null or (who_may as Dictionary).has(b.id)):
					res["rec_" + phase_key + "_s"] += dt
		# Danger: the hand near a free bot in the searched house.
		if w.encounter == &"searching":
			limb = w.posed_limb(now)
			var house := w.houses[w.resident_house]
			for b in bots:
				if b.caught or w.in_lift(b.pos):
					continue
				if house.area_at(house.to_local(b.pos + Vector3.UP * 1.25)) == &"":
					continue
				if not b.searched_in:
					b.searched_in = true
					res.searched_in += 1
				if limb.size() > 1:
					var torso := b.pos + Vector3.UP * 1.25
					var d := torso.distance_to(limb[limb.size() - 1])
					b.closest = minf(b.closest, d)
					res.near = minf(res.near, d)
					if d <= 2.0:
						res.danger = true
		elif w.encounter == &"idle":
			for b in bots:
				b.searched_in = false
		# The instruments (sim/run.gd step_ward).
		var holders: Array[Instr.CrewPlayer] = []
		for b in bots:
			var active := not w.caught.has(b.id) and not w.in_lift(b.pos)
			crew = Instr.set_raised(crew, b.id, active and b.raised)
			holders.append(Instr.CrewPlayer.make(b.id, Move.Body.make(b.pos.x, b.pos.z, 0, b.pos.y), active))
		var entities: Array[Instr.EntityTick] = []
		limb = w.posed_limb(now)
		if not limb.is_empty() or not caught_now.is_empty():
			var et := Instr.EntityTick.make("rigger-%d" % DEPTH, &"rigger", still, still, caught_now)
			et.acting = limb.size() > 1
			et.limb = limb
			if w.has_method("recorders"):
				et.holders = w.call("recorders", rows, now)
			entities.append(et)
		var step := Instr.step_crew(null, crew, holders, entities, dt, tuning)
		crew = step.crew
		for e in step.events:
			if e["type"] == "readingClosed":
				res.earned += float(e["value"]) * DEPTH_PAY
				var key := "earn_" + String(w.encounter)
				res[key] = float(res.get(key, 0.0)) + float(e["value"]) * DEPTH_PAY
				res["readings"] = int(res.get("readings", 0)) + 1
				if opts.get("trace_search", false):
					var rd: TapeLib.Reading = e["reading"]
					print("  reading %s closed t=%.1f value %.0f dur %.1f peak %.1f (%s)" % [rd.player_id, now, float(e["value"]) * DEPTH_PAY, rd.duration, rd.peak_rate, w.encounter])
				if res.met_at < 0.0 and res.earned >= needed:
					res.met_at = snappedf(now, 0.1)
	# Departure: the open readings close (sim/run.gd _bank's flush), aboard tapes ride.
	var aboard: Array[String] = w.boarded.duplicate()
	var flush: Array[Instr.CrewPlayer] = []
	for b in bots:
		crew = Instr.set_raised(crew, b.id, false)
		flush.append(Instr.CrewPlayer.make(b.id, Move.Body.make(b.pos.x, b.pos.z, 0, b.pos.y), aboard.has(b.id)))
	var none: Array[Instr.EntityTick] = []
	for _k in 20:
		var f := Instr.step_crew(null, crew, flush, none, 0.1, tuning)
		crew = f.crew
		for e in f.events:
			if e["type"] == "readingClosed":
				res.earned += float(e["value"]) * DEPTH_PAY
	var dep := Instr.leave_floor(crew, aboard)
	res.banked = dep.carried_value * DEPTH_PAY
	res.home = aboard.size()
	res.left = w.left_behind.size()
	res.lost_uncaught = 0
	for id in w.left_behind:
		if not w.caught.has(id):
			res.lost_uncaught += 1
	res.caught_n = w.caught.size()
	return res

static func _bot(bots: Array[Bot], id: String) -> Bot:
	for b in bots:
		if b.id == id:
			return b
	return null

static func _go(b: Bot, g: Graph, w: Ward, target: int) -> void:
	var from := g.nearest(b.pos)
	var r := g.route(from, target, w.bridge_lowered)
	if r.is_empty():
		r = g.route(from, target, true)
	# Already on the way from the first node to the second: go on to the second.
	if r.size() >= 2 and b.pos.distance_to(g.pts[r[1]]) <= g.pts[r[0]].distance_to(g.pts[r[1]]):
		r.pop_front()
	b.path = r

static func _in_house(w: Ward, house: int, p: Vector3) -> bool:
	var h := w.houses[house]
	return h.area_at(h.to_local(p + Vector3.UP * 1.25)) != &""

static func _house_of(w: Ward, p: Vector3) -> int:
	for i in w.houses.size():
		if _in_house(w, i, p):
			return i
	return -1

static func _limb_distance(limb: PackedVector3Array, p: Vector3) -> float:
	var held := p + Vector3.UP * Instr.INSTRUMENT_HEIGHT
	var d := INF
	for i in range(1, limb.size()):
		d = minf(d, held.distance_to(Geometry3D.get_closest_point_to_segment(held, limb[i - 1], limb[i])))
	return d

static func _think(b: Bot, bots: Array[Bot], w: Ward, g: Graph, rng: RandomNumberGenerator, now: float, dt: float,
		limb: PackedVector3Array, hand: Variant, clock_left: float, last_minute: bool, returned: bool, plan: Dictionary,
		res: Dictionary, crew_n: int) -> void:
	var active := w.encounter == &"climbing" or w.encounter == &"searching"
	var here := _house_of(w, b.pos)
	# Going home.
	var home_at: float = {&"careless": 0.0, &"sensible": 75.0, &"expert": 45.0}[b.skill]
	var go_home: bool = (w.phase == &"away" and clock_left <= home_at) or returned or (b.skill == &"careless" and last_minute and rng.randf() < 0.01)
	if w.phase == &"unloading":
		if b.path.is_empty() and (w.in_lift(b.pos) or not w.clear_of_lift(b.pos)):
			_go(b, g, w, g.rooms[0][&"entry"])
			b.gait = &"walk"
		return
	# The hypothetical heal (opts.heal): a careful crewmate goes to a downed one once he is not searching their house
	# (a careless one too, half the stays), and stands by them; then the crew carries on.
	if res.has("heal_on") and not b.boarding and clock_left > 40.0 and (b.skill != &"careless" or res.seed % 2 == 0):
		for o in bots:
			if o.down and o != b:
				if active and w.resident_house == _house_of(w, o.pos):
					break
				if b.pos.distance_to(o.pos) > HEAL_REACH * 0.8:
					if b.path.is_empty():
						_go(b, g, w, g.nearest(o.pos))
					b.gait = &"walk"
					b.raised = false
				return
	if go_home and not b.boarding:
		b.boarding = true
		b.raised = false
		_go(b, g, w, g.lift_car)
		b.gait = &"sprint" if (returned and b.skill == &"careless") else &"walk"
	if b.boarding:
		if b.path.is_empty() and not w.in_lift(b.pos):
			_go(b, g, w, g.lift_car)
		if b.gait == &"sprint" and b.tired:
			b.gait = &"walk"
		return
	# The hand near me (I can see it in the house I am in): the careful skills walk away from it.
	# A player sees and decides about every REACTION seconds (a careless one only once the hand is all but on them,
	# and only half the time: the other half they freeze).
	if hand != null and here == w.resident_house and now >= b.react_at:
		b.react_at = now + REACTION
		var margin: float = {&"careless": 0.9, &"sensible": 2.2, &"expert": 2.0}[b.skill]
		var palm: Vector3 = hand
		var torso := b.pos + Vector3.UP * 1.25
		if torso.distance_to(palm) <= margin and (b.skill != &"careless" or rng.randf() < 0.5):
			_flee(b, w, g, palm)
			return
	if b.fled and b.skill == &"careless" and hand != null:
		return
	match b.skill:
		&"careless":
			_careless(b, w, g, rng, now, limb, active)
		_:
			_careful(b, bots, w, g, rng, now, limb, active, here, plan, res, crew_n)

static func _flee(b: Bot, w: Ward, g: Graph, palm: Vector3) -> void:
	var house := w.resident_house
	var options: Array[int] = [g.door_out[house], g.rooms[house][&"entry"], g.rooms[house][&"middle"], g.rooms[house][&"rear"], g.corner[house]]
	if b.skill == &"expert" and g.upstairs[house] >= 0:
		options.push_front(g.upstairs[house])
	var best := -1
	var score := -INF
	for o in options:
		var r := g.route(g.nearest(b.pos), o, w.bridge_lowered)
		if r.is_empty():
			continue
		# How near the palm the walk passes, and how far from it it ends.
		var worst := INF
		var at := b.pos
		for k in r:
			var p := g.pts[k]
			var mid := Geometry3D.get_closest_point_to_segment(palm, at + Vector3.UP * 1.25, p + Vector3.UP * 1.25)
			worst = minf(worst, mid.distance_to(palm))
			at = p
		# Out of the house is best (he searches room by room); a room's middle is where the hand will go.
		var s := minf(worst, 1.2) * 4.0 + (g.pts[o] + Vector3.UP * 1.25).distance_to(palm) - (20.0 if worst < 0.8 else 0.0)
		if o == g.upstairs[house]:
			s += 6.0
		elif o == g.door_out[house]:
			s += 5.0
		elif o != g.corner[house]:
			s -= 3.0
		if s > score:
			score = s
			best = o
	if best >= 0 and (b.path.is_empty() or b.path[-1] != best):
		_go(b, g, w, best)
	b.gait = &"walk"
	b.raised = false
	b.fled = true

static func _careless(b: Bot, w: Ward, g: Graph, rng: RandomNumberGenerator, now: float, limb: PackedVector3Array, active: bool) -> void:
	if not active:
		b.fled = false
	if active and limb.size() > 1 and _limb_distance(limb, b.pos) <= 9.0:
		# He is here: stop and record, wherever this is.
		b.path.clear()
		b.raised = true
		return
	b.raised = false
	for s: Dictionary in w.switches:
		if b.pos.distance_to(s.position) <= Ward.WINCH_REACH and rng.randf() < 0.03:
			b.use = true
	if b.path.is_empty():
		if now < b.wait_until:
			return
		var house := rng.randi_range(0, w.houses.size() - 1)
		var areas := [&"entry", &"middle", &"rear"]
		_go(b, g, w, g.rooms[house][areas[rng.randi_range(0, 2)]])
		b.gait = &"sprint" if rng.randf() < 0.4 else &"walk"
		b.wait_until = now + rng.randf_range(3.0, 10.0) + b.path.size() * 0.5

## The careful skills: the crew goes house to house; the lurer sprints in the entry room and walks out; the others wait
## on the gallery, record the climb by the loaded line and, while short of the quota, the search from the entry corner.
static func _careful(b: Bot, bots: Array[Bot], w: Ward, g: Graph, rng: RandomNumberGenerator, now: float,
		limb: PackedVector3Array, active: bool, here: int, plan: Dictionary, res: Dictionary, crew_n: int) -> void:
	var idx := int(b.id.substr(1)) - 1
	var free: Array[Bot] = []
	for o in bots:
		if not o.caught and not o.boarding:
			free.append(o)
	if free.is_empty():
		return
	if plan.house < 0 or (plan.stage == &"done" and _calm(w)):
		# The next house: any but the one just done.
		var next := rng.randi_range(1, w.houses.size() - 1)
		if next == plan.house:
			next = (next % (w.houses.size() - 1)) + 1
		plan.house = next
		plan.stage = &"gather"
		plan.hunts += 1
		plan.lurer = free[plan.hunts % free.size()].id
		plan.since = now
	var house: int = plan.house
	var short: bool = res.earned < res.needed
	var inside := short or b.skill == &"expert"
	var lurer: bool = plan.lurer == b.id
	match plan.stage:
		&"gather":
			if not _calm(w) and w.roam != null and w.resident_house >= 1:
				# RR1: he is already at a house (the crew's own steps brought him): go and record him there.
				plan.house = w.resident_house
				plan.stage = &"hunt"
				plan.since = now
				return
			if not _calm(w):
				# Someone else brought him: wait it out where we are, out of houses.
				return
			if b.path.is_empty() and b.pos.distance_to(g.pts[g.door_out[house]]) > 1.5:
				_go(b, g, w, g.door_out[house])
				b.gait = &"walk"
			var all_here := true
			for o in free:
				if o.pos.distance_to(g.pts[g.door_out[house]]) > 2.5:
					all_here = false
			if all_here or now - plan.since > 60.0:
				plan.stage = &"lure"
				plan.since = now
		&"lure":
			if lurer:
				if _calm(w):
					if here != house or b.path.is_empty():
						_go(b, g, w, g.rooms[house][&"entry"] if b.pos.distance_to(g.pts[g.rooms[house][&"entry"]]) > 0.5 else g.door_in[house])
					b.gait = &"sprint" if here == house else &"walk"
				else:
					plan.stage = &"hunt"
			elif not _calm(w):
				plan.stage = &"hunt"
			if now - plan.since > 40.0:
				plan.stage = &"done"
		&"hunt":
			if _calm(w):
				plan.stage = &"done"
				b.raised = false
				b.fled = false
				return
			var climbing := w.encounter == &"warning" or w.encounter == &"climbing"
			if lurer and crew_n == 1 and climbing and inside:
				# Alone: from the lure straight to the entry corner to record.
				if b.path.is_empty() and b.pos.distance_to(g.pts[g.corner[house]]) > 0.4 and not b.fled:
					_go(b, g, w, g.corner[house])
				b.gait = &"creep"
				b.raised = limb.size() > 1 and _limb_distance(limb, b.pos) <= 9.0
			elif lurer and here == house and climbing and b.path.is_empty():
				_go(b, g, w, g.door_out[house])
				b.gait = &"walk"
			elif climbing and not lurer:
				# Record the climb; those who will record the search creep in to the entry corner before the hand comes.
				var goes_in := inside and w.resident_house == house and (b.skill == &"expert" or idx % 2 == 0 or crew_n == 1)
				if goes_in and b.path.is_empty() and b.pos.distance_to(g.pts[g.corner[house]]) > 0.4 and not b.fled:
					_go(b, g, w, g.corner[house])
				elif not goes_in and plan.has("line") and int(plan.line[0]) == house:
					# RR1: to the gallery corner where his line takes the weight, to record the climb beside it.
					var at_line: int = g.rings[house][["sw", "nw", "se", "ne"][int(plan.line[1])]]
					if b.path.is_empty() and b.pos.distance_to(g.pts[at_line]) > 0.4 and not b.fled:
						_go(b, g, w, at_line)
				b.gait = &"creep"
				b.raised = limb.size() > 1 and _limb_distance(limb, b.pos) <= 9.0
			elif w.encounter == &"searching" and w.resident_house == house:
				# Never in through the door while the hand may be in it.
				b.raised = limb.size() > 1 and _limb_distance(limb, b.pos) <= 9.0
			else:
				b.raised = false
		&"done":
			b.raised = false
			b.fled = false

## He is not hunting: in his lair, staying after a search or going home (RR1's last two).
static func _calm(w: Ward) -> bool:
	return w.encounter == &"idle" or w.encounter == &"lingering" or w.encounter == &"returning"

static func _move(b: Bot, w: Ward, g: Graph, dt: float) -> void:
	if b.path.is_empty():
		_rest(b, dt)
		return
	var speed := Stamina.WALK_SPEED
	if b.gait == &"creep":
		speed = Stamina.CREEP_SPEED
	elif b.gait == &"sprint" and not b.tired:
		speed = Stamina.SPRINT_SPEED
		b.tank -= dt
		if b.tank <= 0.0:
			b.tired = true
	if b.gait != &"sprint" or b.tired:
		_rest(b, dt)
	if b.raised:
		speed = minf(speed, Stamina.CREEP_SPEED)
	var budget := speed * dt
	while budget > 0.0 and not b.path.is_empty():
		var to := g.pts[b.path[0]]
		var d := b.pos.distance_to(to)
		if d <= budget:
			b.pos = to
			budget -= d
			b.path.pop_front()
		else:
			b.pos = b.pos.lerp(to, budget / d)
			budget = 0.0
	if b.path.is_empty() and b.gait == &"sprint":
		b.gait = &"walk"

static func _rest(b: Bot, dt: float) -> void:
	b.tank = minf(Stamina.SPRINT_SECONDS, b.tank + dt * Stamina.SPRINT_SECONDS / Stamina.RECOVER_WALKING)
	if b.tired and b.tank >= Stamina.SPRINT_SECONDS * 0.5:
		b.tired = false
