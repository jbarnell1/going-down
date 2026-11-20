# RN3: what a real-window look at the rebuilt Reactor (floor 7) showed, fixed and held here. Headless: no window.
#   - the lift's indicator text for every depth 1 to 21 (client/main.gd _floor_label) and that it fits the display;
#   - the cassette on its table glows (its shell, a halo, its own small light) with the mains on and in the cut;
#   - with the mains on, the hall, landing and gallery floors are lit at least as well as a Clinic's floor through
#     the same light numbers (the level's own lights, the same falloff Godot uses), and the cut is a real drop;
#     the battens stay within the light budget (client/level.gd CHUNK: no chunk busier than the Clinic's busiest);
#   - the crawl under the gallery is creep-only: a standing player is stopped at its mouth with a prompt, a creeping
#     one goes in and cannot stand inside (client/play_link.gd), and the host refuses the same standing step
#     (net/host.gd _on_input), both from sim/station.gd crawl_step_ok.
extends RefCounted

const T = preload("res://tests/t.gd")
const Station = preload("res://sim/station.gd")
const Clinic = preload("res://sim/clinic.gd")
const PlanDump = preload("res://client/plan_dump.gd")
const Run = preload("res://sim/run.gd")
const View = preload("res://client/station_view.gd")
const Crew = preload("res://client/station_crew_view.gd")
const Main = preload("res://client/main.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const PlayLink = preload("res://client/play_link.gd")
const LocalRoom = preload("res://net/local_room.gd")
const Session = preload("res://net/session.gd")
const Places = preload("res://sim/places.gd")
const Protocol = preload("res://net/protocol.gd")
const EyeHeight = preload("res://client/eye_height.gd")
const Host = preload("res://net/host.gd")

const DT := 1.0 / 60.0
## The main game's ambient light energy with the lights on (client/main.gd env.ambient_light_energy).
const AMBIENT_ENERGY := 0.12

static func _level(plan: RefCounted) -> Level:
	Crew.borrow_clips = false
	var level := Level.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(level)
	var fp: Floor.FloorPlan = plan
	level.build(PlanDump.dump(fp, Run.car_geometry(fp)), fp.seed, fp)
	return level

# --- 1. the indicator -----------------------------------------------------------------------------------

func test_the_indicator_reads_every_depth_and_fits(t: T) -> void:
	var two := PixelFont.width("88")
	for d in range(1, 22):
		var want := "B%d" % d if d < 10 else str(d)
		var got := Main._floor_label(d)
		t.eq(got, want, "depth %d reads %s" % [d, want])
		t.check(PixelFont.width(got) <= two, "depth %d: '%s' fits the display's two places (%d <= %d px)" % [d, got, PixelFont.width(got), two])
	t.eq(Main._floor_label(0), "G", "the ground floor reads G")

# --- 2. the cassette ------------------------------------------------------------------------------------

func _block(power: int, tape_at: Vector3) -> Dictionary:
	return {"native": true, "power": power, "time": 3.0, "holder": 0, "fuseUses": 0, "cassette": false, "lift": false,
		"players": {"p1": [0.0, 0.0, 0.0]}, "crew": [], "status": {"p1": "up"}, "cassetteHolder": "",
		"extracted": false, "fuseAt": [4.0, 0.07, 10.0], "tapeAt": [tape_at.x, tape_at.y, tape_at.z], "seats": [1, 2, 3, 4]}

func test_the_cassette_glows_with_the_mains_and_in_the_cut(t: T) -> void:
	var fp := Station.generate_station("rn3-tape", 7)
	var level := _level(fp)
	var view: Node3D = level.get_meta(&"station")
	var plinth := View.v3(fp.station["plinth"])
	for power: int in [0, 1, 2]:
		view.call(&"show_block", _block(power, plinth + Vector3(0, View.PLINTH_TOP, 0)), "p1")
		view.call(&"_apply")
		var g: Dictionary = view.call(&"tape_glow")
		var name: String = ["the mains", "the cut", "restored"][power]
		t.check(bool(g["drawn"]), "%s: the cassette is on its table" % name)
		t.check(float(g["shell"]) >= 0.9, "%s: its whole shell glows (energy %.2f)" % [name, g["shell"]])
		t.check(bool(g["light"]) and float(g["energy"]) >= 1.0, "%s: its own warm light is on (%.2f)" % [name, g["energy"]])
		t.check(float(g["reach"]) <= 2.0, "%s: that light reaches the table, not the landing (%.1f m)" % [name, g["reach"]])
		t.check(bool(g["halo"]), "%s: its halo is drawn" % name)
	var tape_light: OmniLight3D = view.get(&"_tape_light")
	t.check(not level.main_lights.has(tape_light), "the cassette's light is not on the mains")
	level.free()

# --- 3. the mains -----------------------------------------------------------------------------------------

## Godot's light falloff (scene_forward_lights_inc / light distance and spot cone), on a floor point facing up.
static func _irradiance(lights: Array, p: Vector3) -> float:
	var e := 0.0
	for l: Light3D in lights:
		if not l.visible or l.light_energy <= 0.0:
			continue
		var lp := l.global_position if l.is_inside_tree() else l.position
		var rel := lp - p
		var d := rel.length()
		var reach := (l as SpotLight3D).spot_range if l is SpotLight3D else (l as OmniLight3D).omni_range
		var decay := (l as SpotLight3D).spot_attenuation if l is SpotLight3D else (l as OmniLight3D).omni_attenuation
		if d >= reach or d < 1e-4:
			continue
		var nd := pow(d / reach, 4.0)
		var att := pow(maxf(1.0 - nd, 0.0), 2.0) * pow(d, -decay)
		var lambert := maxf(0.0, rel.normalized().y)
		if l is SpotLight3D:
			var s := l as SpotLight3D
			var cutoff := cos(deg_to_rad(s.spot_angle))
			var down := -(s.global_transform.basis.z if s.is_inside_tree() else s.transform.basis.z)
			var scos := maxf((-rel.normalized()).dot(down), cutoff)
			var rim := maxf(0.0001, (1.0 - scos) / (1.0 - cutoff))
			att *= 1.0 - pow(rim, s.spot_angle_attenuation)
		e += l.light_energy * att * lambert
	return e

static func _lum(c: Color) -> float:
	return c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722

## The mean linear brightness of a texture (what the surface gives back of the light on it).
static func albedo(tex: Texture2D) -> float:
	var img := tex.get_image()
	if img.is_compressed():
		img.decompress()
	var s := 0.0
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			s += _lum(img.get_pixel(x, y).srgb_to_linear())
			n += 1
	return s / maxf(1.0, n)

## How bright the floor looks at `cells` (level 0): albedo x (lights + the floor's own self light + ambient).
static func floor_seen(level: Level, lights: Array, cells: Array[Vector2i], floor_albedo: float, self_light: float, ambient: Color) -> float:
	var sum := 0.0
	for c in cells:
		var p := level.cell_center(0, c.x, c.y)
		p.y = 0.0
		sum += floor_albedo * (_irradiance(lights, p) + self_light + AMBIENT_ENERGY * _lum(ambient))
	return sum / maxf(1.0, cells.size())

static func _cells_in(level: Level, rects: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in level.H:
		for x in level.W:
			if not level.walkable(0, x, y):
				continue
			var mid := Vector2((x + 0.5) * View.S, (y + 0.5) * View.S)
			for r: Rect2 in rects:
				if r.has_point(mid):
					out.append(Vector2i(x, y))
					break
	return out

## The Clinic's floor brightness: its own lights, its linoleum, its ambient, over every walkable cell of level 0.
static func clinic_reference() -> float:
	var level := _level(Clinic.generate_clinic("rn3-reference", 1))
	var cells := _cells_in(level, [Rect2(0, 0, level.W * View.S, level.H * View.S)])
	var lights: Array = level.main_lights.duplicate()
	var lino: Texture2D = load("res://assets/textures/clinic_linoleum.png")
	var v := floor_seen(level, lights, cells, albedo(lino), 0.0, Level.AMBIENT_LIT)
	clinic_worst_chunk = _worst_chunk(level, lights)
	level.free()
	return v

## The most lights reaching one chunk of the Clinic built with clinic_reference (its own budget, for comparison).
static var clinic_worst_chunk := 0

static func _station_lights(level: Level, view: Node3D) -> Array:
	var out: Array = level.main_lights.duplicate()
	for d: Dictionary in view.get(&"lamps"):
		out.append(d["light"])
	return out

func test_the_mains_light_the_station_like_a_clinic_and_the_cut_drops(t: T) -> void:
	var ref := clinic_reference()
	t.note("the Clinic's floor through its own lights: %.4f; the most lights on one of its chunks: %d" % [ref, clinic_worst_chunk])
	var floor_a := albedo(View.floor_tex())
	var most := 0
	for i in 6:
		var fp := Station.generate_station("rn3-light-%d" % i, 7)
		var level := _level(fp)
		var view: Node3D = level.get_meta(&"station")
		var a: Dictionary = fp.station
		var cells := _cells_in(level, [View.rect(a["hall"]), View.rect(a["landing"]), View.rect(a["gallery"])])
		view.call(&"set_power", 0)
		view.call(&"_apply")
		var on := floor_seen(level, _station_lights(level, view), cells, floor_a, View.SELF_LIT, level.ambient_lit)
		view.call(&"set_power", 1)
		view.call(&"_apply")
		var cut := floor_seen(level, _station_lights(level, view), cells, floor_a, View.SELF_CUT, level.ambient_lit)
		t.note("seed %d: the station's hall, landing and gallery with the mains %.4f, in the cut %.4f" % [i, on, cut])
		t.check(on >= ref, "seed %d: with the mains the hall, landing and gallery are at least as bright as a Clinic (%.4f >= %.4f)" % [i, on, ref])
		t.check(cut <= 0.15 * on, "seed %d: the cut is a real drop (%.4f <= 15%% of %.4f)" % [i, cut, on])
		t.check(cut > 0.0, "seed %d: the emergency lamps still light something" % i)
		# The light budget: no 8 m chunk of the station within reach of more lights than the Clinic's busiest (the
		# frame cost the game already carries on every Clinic floor), and the battens under the station's cap.
		view.call(&"set_power", 0)
		view.call(&"_apply")
		var worst := _worst_chunk(level, _station_lights(level, view))
		t.note("seed %d: %d battens, %d lamps, at most %d lights on one chunk" % [i, level.main_lights.size(), (view.get(&"lamps") as Array).size(), worst])
		t.check(worst <= clinic_worst_chunk, "seed %d: no chunk reached by more lights than the Clinic's busiest (%d <= %d)" % [i, worst, clinic_worst_chunk])
		most = maxi(most, level.main_lights.size())
		level.free()
	t.check(most <= View.BATTEN_LIMIT, "the battens stay under the station's cap (%d <= %d)" % [most, View.BATTEN_LIMIT])
	# The paint stays green through the warm light: old green paint, amber lamps, the pale screens all differ.
	t.check(View.C_GREEN.g > View.C_GREEN.r + 0.1 and View.C_GREEN.g > View.C_GREEN.b + 0.08, "the paint is still green")

static func _worst_chunk(level: Level, lights: Array) -> int:
	var size := View.S * Level.CHUNK
	var worst := 0
	for cz in ceili(level.H / float(Level.CHUNK)):
		for cx in ceili(level.W / float(Level.CHUNK)):
			var box := AABB(Vector3(cx * size, 0.0, cz * size), Vector3(size, View.LH, size))
			var n := 0
			for l: Light3D in lights:
				if not l.visible:
					continue
				var reach := (l as SpotLight3D).spot_range if l is SpotLight3D else (l as OmniLight3D).omni_range
				var p := l.position
				var q := Vector3(clampf(p.x, box.position.x, box.end.x), clampf(p.y, box.position.y, box.end.y), clampf(p.z, box.position.z, box.end.z))
				n += int(p.distance_to(q) < reach)
			worst = maxi(worst, n)
	return worst

# --- 4. the crawl -------------------------------------------------------------------------------------------

## The crawl's mouths of a plan as [outside cell, crawl cell].
static func _mouths(fp: Floor.FloorPlan) -> Array:
	var out: Array = []
	for m: Array in fp.station["crawl_mouths"]:
		var a := Vector2i(int(m[0]), int(m[1]))
		var b := Vector2i(int(m[2]), int(m[3]))
		if Station.creep_only(fp, a.x, a.y):
			out.append([b, a])
		else:
			out.append([a, b])
	return out

func test_the_rule_for_a_step_into_the_crawl(t: T) -> void:
	for i in 6:
		var fp := Station.generate_station("rn3-crawl-%d" % i, 7)
		for m: Array in _mouths(fp):
			var o: Vector2i = m[0]
			var c: Vector2i = m[1]
			var ox := (o.x + 0.5) * 2.0
			var oz := (o.y + 0.5) * 2.0
			var cx := (c.x + 0.5) * 2.0
			var cz := (c.y + 0.5) * 2.0
			t.check(not Station.crawl_step_ok(fp, 0, ox, oz, cx, cz, false), "seed %d: standing, the step in at %s is refused" % [i, c])
			t.check(Station.crawl_step_ok(fp, 0, ox, oz, cx, cz, true), "seed %d: creeping, it is taken" % i)
			t.check(Station.crawl_step_ok(fp, 0, cx, cz, ox, oz, false), "seed %d: stepping out is always fine" % i)
			t.check(Station.in_crawl(fp, 0, cx, cz) and not Station.in_crawl(fp, 0, ox, oz), "seed %d: in the crawl only inside it" % i)
	var clinic := Clinic.generate_clinic("rn3-crawl-clinic", 1)
	t.check(Station.crawl_step_ok(clinic, 0, 1.0, 1.0, 3.0, 1.0, false), "other places have no crawl")

## A solo room on floor 7 (the station) and the link the game plays through.
func _station_link() -> Array:
	var original := Session.deck
	Session.deck = Places.FULL
	var room := LocalRoom.new()
	room.open_local("rn3-crawl-room", "Tester", true)
	room.late_archive_root = ""
	room.reactor_place = true
	var ok := room.start_playtest(7)
	Session.deck = original
	return [room, PlayLink.new(room, true), ok]

func _frame(link: PlayLink, now: float, f: float, yaw: float, creep: bool, sprint := false) -> Dictionary:
	return link.step(now, {"dt": DT, "f": f, "r": 0.0, "sprint": sprint, "creep": creep, "yaw": yaw, "pitch": 0.0, "hfov": 90.0, "vfov": 70.0})

func test_the_client_stops_a_standing_player_at_the_mouth_and_creeps_one_inside(t: T) -> void:
	var made := _station_link()
	var room: LocalRoom = made[0]
	var link: PlayLink = made[1]
	if not t.check(bool(made[2]), "floor 7 starts"):
		return
	var now := 0.0
	var s := {}
	for i in 900:
		now += DT
		s = _frame(link, now, 0.0, 0.0, false)
		if s.has("me") and link.body != null and link.plan != null and not link.plan.station.is_empty():
			break
	if not t.check(link.body != null and link.plan != null and not link.plan.station.is_empty(), "placed on the station"):
		room.leave()
		return
	var fp := link.plan
	var m: Array = _mouths(fp)[1]   # the hall's opening
	var o: Vector2i = m[0]
	var c: Vector2i = m[1]
	var dir := Vector2(c - o)
	var yaw := atan2(-dir.x, -dir.y)
	var placed := link.teleport(0, o.x, o.y)
	t.check(bool(placed.get("ok", false)), "teleported beside the hall's opening")
	var entered := false
	var refused := false
	for leg: Array in [[false, false], [false, true]]:
		for i in 150:
			now += DT
			s = _frame(link, now, 1.0, yaw, leg[0], leg[1])
			entered = entered or Station.in_crawl(fp, link.body.level, link.body.x, link.body.z)
			refused = refused or bool(s.get("me", {}).get("crawlRefused", false))
	t.check(not entered, "walking and sprinting at the mouth, the body never enters the crawl")
	t.check(refused, "and the prompt to creep is up")
	t.eq(Main.CRAWL_PROMPT.begins_with("CTRL"), true, "the prompt names the creep key")
	for i in 200:
		now += DT
		s = _frame(link, now, 1.0, yaw, true)
	var inside := Station.in_crawl(fp, link.body.level, link.body.x, link.body.z)
	t.check(inside, "creeping, the body goes in")
	if inside:
		var stood := false
		for i in 60:
			now += DT
			s = _frame(link, now, 0.0, yaw, false, true)
			stood = stood or link.gait != &"creep"
		t.check(not stood, "inside, letting go of creep (and asking to sprint) still creeps")
		t.check(absf(link.eye - EyeHeight.CREEP) < 0.02, "and the eyes stay at the creep height under the trays (%.2f)" % link.eye)
	room.leave()

func test_the_host_refuses_a_standing_step_in(t: T) -> void:
	var made := _station_link()
	var room: LocalRoom = made[0]
	if not t.check(bool(made[2]), "floor 7 starts"):
		return
	var host: Host = room.host
	var fp: Floor.FloorPlan = host.state.plan
	if not t.check(not fp.station.is_empty(), "the host's floor is the station"):
		room.leave()
		return
	var m: Array = _mouths(fp)[1]
	var o: Vector2i = m[0]
	var c: Vector2i = m[1]
	var p: Host.HostPlayer = host._players.values()[0]
	host._trusted.erase(p.id)
	var seq := [100]
	for want: Array in [["walk", false], ["sprint", false], ["creep", true]]:
		var from := Move.body_at_cell(fp, Floor.Pos.make(0, o.x, o.y))
		# Just over the edge into the crawl cell (0.1 m in from the mouth).
		var into := (Vector2((c.x + 0.5) * 2.0, (c.y + 0.5) * 2.0) - Vector2(c - o) * 0.9)
		var to := Move.Body.make(into.x, into.y, 0, from.y)
		p.body = from
		p.body_ct = null
		p.place = null
		p.claim = null
		p.last_ct = null
		seq[0] += 1
		var msg := {"ackEvent": 0, "ackHt": 0.0, "renderTime": 0.0, "placeAck": 0, "seen": [], "seq": seq[0], "ct": float(seq[0]),
			"calls": p.calls, "pickUps": p.pick_ups, "body": to, "raised": false, "gait": want[0]}
		var kept: Variant = p.input
		host._on_input(p, msg, 0.0)
		p.input = kept   # the snapshot reads the newest real input's look; only the body is under test
		var took := Station.in_crawl(fp, p.body.level, p.body.x, p.body.z)
		t.eq(took, bool(want[1]), "the host %s a %s step into the crawl" % ["takes" if want[1] else "refuses", want[0]])
	room.leave()
