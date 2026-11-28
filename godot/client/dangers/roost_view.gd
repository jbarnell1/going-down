# The roosting birds on screen and in the ear (rules: sim/dangers/roost.gd). Decides nothing: every pose and every
# sound comes from the record's state, the host time it began (`since`) and the host time now, so every screen shows
# and plays the same moment.
#
# A roost is a broad-leaved tree (its cell's two to four trunks) with six to ten big dark birds perched on short
# twigs high up, each pair of pale eyes catching what light there is and blinking on its own slow beat. Under it the
# litter is spattered pale across exactly the ground that sets it off; the trunks are plain bark. Heard first: a
# settled roost murmurs and shuffles from the canopy (roost_idle), restless when someone walks near (roost_stir);
# flushed, the birds burst out and up with a clap of wings and alarm calls heard across half the garden
# (roost_flush), then circle high overhead for a while (roost_circle), and drop back in (roost_settle). The murmur
# fades inside the Groundskeeper's ring of silence as the garden's crickets do.
# Birds are full 3D low-poly figures built here in code (three poses swapped as stop motion), never sprites.
extends "res://client/dangers/kind_view.gd"

const Arboretum = preload("res://sim/arboretum.gd")
const Furniture = preload("res://sim/furniture.gd")
const Noises = preload("res://sim/noise.gd")
const ArbView = preload("res://client/arboretum_view.gd")
const SfxScript = preload("res://client/sfx.gd")

const DIR := "res://assets/sfx/dangers/roost/"
## Sound: [file, loops, unit size, max distance, trim dB (never above 0), the mix's category]. Every one plays on its
## category's bus (kind_view.gd CATS) at the voice's own level (Sfx.BASE_DB) plus its trim and never louder than its
## file however close (max_db 0); the files carry their loudness inside the category's band (kind_view.gd BANDS, tested
## in test_danger_roost), so whoever stands under the tree as it goes up hears it at most at the flush file's own level.
const SOUNDS := {
	&"idle": ["roost_idle", true, 5.0, 18.0, 0.0, &"effect"],
	&"stir": ["roost_stir", true, 4.0, 20.0, 0.0, &"effect"],
	&"flush": ["roost_flush", false, 8.0, 45.0, 0.0, &"effect"],
	&"circle": ["roost_circle", true, 5.0, 25.0, -14.0, &"effect"],
	&"settle": ["roost_settle", false, 3.0, 16.0, 0.0, &"effect"],
}

## The mix category a sound plays as (its band and bus).
static func category_of(name: StringName) -> StringName:
	return StringName((SOUNDS[name] as Array)[5])

static func bus_of(name: StringName) -> StringName:
	return StringName((CATS[category_of(name)] as Array)[0])
## Loops change over with a short fade (seconds).
const XFADE := 0.15
const CANOPY_Y := 4.8
const C_BIRD := Color(0.045, 0.055, 0.048)
const C_BEAK := Color(0.14, 0.14, 0.12)
const C_EYE := Color(0.75, 0.80, 0.20)
## Open wings show the birds pale, like doves in moonlight (and like the droppings under them): body, underwing, and
## the dark wingtips and tail that make one readable shape. Drawn unshaded so they never depend on the floor's light,
## with no emission and no light added.
const C_PALE := Color(0.33, 0.33, 0.31)
const C_UNDERWING := Color(0.50, 0.50, 0.47)
const C_TIP := Color(0.06, 0.06, 0.055)
## The pale feathers the flush shakes down.
const C_FEATHER := Color(0.47, 0.48, 0.44)
## A dry leaf's pale underside (near the litter's colour), so falling leaves flicker as they turn.
const C_LEAF_BACK := Color(0.42, 0.34, 0.22)
const C_SPATTER := Color(0.80, 0.78, 0.71)
const C_BARK := Color(0.46, 0.30, 0.16)
## The eyes' glow while the room is lit, and in the dark (they still catch the crew's own light).
const EYE_LIT := 0.9
const EYE_DARK := 0.7
const BIRDS_MIN := 8
const BIRDS_MAX := 10
## Wingbeats a second going up (a crow taking off), and circling (with a glide held for a third of each beat).
const FLAP_HZ := 5.0
const CIRCLE_HZ := 3.5
const CIRCLERS := 5
## The drawn poses: 0 perched, 1 wings up, 2 wings down, GLIDE wings out flat.
const POSES := 4
const GLIDE := 3
## The flight: how long a bird is drawn after it leaves its perch (s).
const FLIGHT := 3.6
## The burst: for the first BURST_DROP seconds the flock drops out of the crown and fans out below it, between the
## trunks, at LOW_MIN to LOW_MAX m (never under HEAD_CLEAR, so nothing clips a standing head), FAN_MIN to FAN_MAX m
## out; then it climbs out and away.
const BURST_DROP := 0.8
const LOW_MIN := 2.6
const LOW_MAX := 4.4
const HEAD_CLEAR := 2.2
const FAN_MIN := 3.5
const FAN_MAX := 6.0
## How far a flying bird keeps from any trunk's axis (m): a trunk is at most 0.15 m thick, a bird's body 0.15 m.
const TRUNK_CLEAR := 0.4
## How far a perch keeps from any other trunk's axis (m).
const PERCH_CLEAR := 0.45
## The birds are drawn this much over the crow-sized model, so their shapes read against the painted sky.
const SCALE := 1.4
## Flying birds climb out of the tree tops (up to 9 m) to this, so they cross the open sky as shapes, and keep 1.5 m
## under the painted sky (12 m); they dwindle away between these distances from the tree.
const FLY_CEILING := 10.5
const FADE_NEAR := 12.0
const FADE_FAR := 15.0
## The shower the flush shakes down: leaf cards and feathers, and how fast they fall (m/s).
const LEAVES := 32
const FEATHERS := 12
## The canopy's own leaf tone (client/arboretum_view.gd _tree).
const C_LEAF := Color(0.10, 0.15, 0.07)

static var _meshes: Array = []        # [perched, wings up, wings down, eyes, gliding]
static var _streams: Dictionary = {}

var _rec: Dictionary = {}
var _birds: Array = []                # {perch: Vector3, yaw, out: Vector3, off, period, delay, land}
var _mm: Array[MultiMeshInstance3D] = []   # perched, up, down
var _eyes: MultiMeshInstance3D
var _eye_mat: ShaderMaterial
var _loop: AudioStreamPlayer3D
var _spare: AudioStreamPlayer3D
var _loop_name := &""
## This tree's place in its loops (a share of their length, from its cell): roosts do not murmur in step.
var _phase := 0.0
## Leaves and feathers shaken down by the flush: {at: Vector3 (start), fall, sway, phase, spin, feather}.
var _fall: Array = []
var _leaves: MultiMeshInstance3D = null
var _feathers: MultiMeshInstance3D = null
var _circle: AudioStreamPlayer3D
var _shot: AudioStreamPlayer3D = null
var _garden: Node = null
var _trigger := 2.5
var _settle := 3.0
var _burst := 3.0
## Tests and the look script: what is drawn.
var drawn := {}
## The roost's trunks as _trunks() gives them (tests).
var trunk_list: Array = []
## Every trunk near the roost, as _trunks() gives them (the routes keep clear of them; tests read it).
var near_trunks: Array = []

# ---------------------------------------------------------------------------------------------
# Building.

func build(rec: Dictionary, ctx: Dictionary) -> void:
	_rec = rec
	var n: Array = rec.get("n", [])
	var cell := int(n[0]) if n.size() > 0 else 0
	_trigger = float(n[2]) if n.size() > 2 else 2.5
	_settle = float(n[3]) if n.size() > 3 else 3.0
	_burst = float(n[4]) if n.size() > 4 else 3.0
	_phase = ArbView._hash01(cell, 17, 3)
	var plan: Variant = ctx.get("plan")
	var level: Node = ctx.get("level")
	if level != null and level.has_meta(&"arboretum"):
		_garden = level.get_meta(&"arboretum")
	var trunks := _trunks(plan, cell)
	trunk_list = trunks
	var seed_text := "%s:roost:%d" % [str(ctx.get("floor_seed", "")), cell]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed_text)
	_near(plan)
	_perches(trunks, rng)
	_routes(plan, seed_text)
	_figures()
	_spatter(plan, trunks, rng)
	_shower(trunks, rng)
	_sounds()
	if n.size() > 1 and int(n[1]) == 1 and plan != null:
		_notice(plan)
	changed(rec, {}, float(rec.get("since", 0.0)))

## The trunks in the roost's cell: [world position, the tree's hash r, its height] (as client/arboretum_view.gd draws
## each tree).
func _trunks(plan: Variant, cell: int) -> Array:
	var out: Array = []
	if plan == null:
		return out
	for p in Furniture.pieces_for(plan):
		if p.kind != &"trunk":
			continue
		if (p.y / Arboretum.CM) * Arboretum.W + p.x / Arboretum.CM != cell:
			continue
		var r := ArbView._hash01(p.x, p.y, 5)
		out.append([Vector3(p.x / 100.0, 0, p.y / 100.0) - position, r, 5.5 + 3.5 * r, p.x, p.y])
	return out

## A point on a tree's leaning trunk at height y (client/arboretum_view.gd _tree's profile).
static func trunk_at(at: Vector3, r: float, tall: float, y: float) -> Vector3:
	var a := TAU * r
	var along := Vector3(cos(a), 0, sin(a))
	var shoulder := at + Vector3.UP * 2.14
	var fork := shoulder.lerp(at + Vector3.UP * tall, 0.36) + along * (0.13 + 0.26 * r)
	var tip := at + Vector3.UP * tall + along * (0.3 + 0.55 * r)
	var pts := [at, shoulder, fork, tip]
	for i in pts.size() - 1:
		var p0: Vector3 = pts[i]
		var p1: Vector3 = pts[i + 1]
		if y <= p1.y or i == pts.size() - 2:
			return p0.lerp(p1, clampf((y - p0.y) / maxf(p1.y - p0.y, 0.001), 0.0, 1.0))
	return tip

func _perches(trunks: Array, rng: RandomNumberGenerator) -> void:
	if trunks.is_empty():
		return
	var count := rng.randi_range(BIRDS_MIN, BIRDS_MAX)
	var twigs := SurfaceTool.new()
	twigs.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in count:
		var t: Array = trunks[i % trunks.size()]
		var tall: float = t[2]
		# A perch clear of every other trunk (a bird never sits inside a neighbouring tree): up to eight draws.
		var y := 0.0
		var a := 0.0
		var dir := Vector3.ZERO
		var stem := Vector3.ZERO
		var perch := Vector3.ZERO
		for attempt in 8:
			y = rng.randf_range(3.6, minf(6.4, tall * 0.74))
			a = rng.randf() * TAU
			dir = Vector3(cos(a), 0, sin(a))
			stem = trunk_at(t[0], t[1], tall, y)
			perch = stem + dir * rng.randf_range(0.45, 0.85) + Vector3.UP * 0.04
			if trunk_gap(perch, int(t[3]), int(t[4])) >= PERCH_CLEAR:
				break
		_twig(twigs, stem, perch + dir * 0.12 + Vector3.UP * 0.03, 0.02)
		var yaw := atan2(dir.x, dir.z) + rng.randf_range(-1.2, 1.2)
		var spread := rng.randf_range(-0.6, 0.6)
		var out := Vector3(cos(a + spread), 0, sin(a + spread))
		_birds.append({"perch": perch, "yaw": yaw, "out": out, "off": rng.randf() * 40.0, "period": rng.randf_range(2.0, 5.0),
			"blink": rng.randf_range(1.5, 4.0), "delay": rng.randf_range(0.0, 0.12), "land": rng.randf_range(0.3, 1.0),
			"climb": rng.randf_range(1.8, 2.8)})
	var mi := MeshInstance3D.new()
	mi.name = "Twigs"
	mi.mesh = twigs.commit()
	var m := StandardMaterial3D.new()
	m.albedo_color = C_BARK * 0.8
	m.roughness = 1.0
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	drawn["birds"] = count

static func _twig(st: SurfaceTool, a: Vector3, b: Vector3, r: float) -> void:
	var axis := (b - a).normalized()
	var u := axis.cross(Vector3.UP).normalized()
	var v := u.cross(axis).normalized()
	for k in 4:
		var s0 := (u * cos(k * TAU / 4) + v * sin(k * TAU / 4))
		var s1 := (u * cos((k + 1) * TAU / 4) + v * sin((k + 1) * TAU / 4))
		var p := [a + s0 * r, a + s1 * r, b + s1 * r * 0.4, a + s0 * r, b + s1 * r * 0.4, b + s0 * r * 0.4]
		for q: Vector3 in p:
			st.set_normal(s0)
			st.add_vertex(q)

## Every trunk and dead tree within reach of the roost, as _trunks() gives them.
func _near(plan: Variant) -> void:
	near_trunks = []
	if plan == null:
		return
	for p in Furniture.pieces_for(plan):
		if p.kind != &"trunk" and p.kind != &"dead_tree":
			continue
		var at := Vector3(p.x / 100.0, 0, p.y / 100.0) - position
		if Vector2(at.x, at.z).length() > FADE_FAR + 2.0:
			continue
		var r := ArbView._hash01(p.x, p.y, 5)
		var dead: bool = p.kind == &"dead_tree"
		near_trunks.append([at, r, (7.6 + 1.5 * r) if dead else (5.5 + 3.5 * r), p.x, p.y])

## The least distance from `at` to any nearby trunk's axis at its height, leaving out the trunk at cm (cx, cy).
func trunk_gap(at: Vector3, cx := -1, cy := -1) -> float:
	var least := 1e9
	for tr: Array in near_trunks:
		if int(tr[3]) == cx and int(tr[4]) == cy or at.y > float(tr[2]):
			continue
		var c := trunk_at(tr[0], tr[1], tr[2], maxf(at.y, 0.0))
		least = minf(least, Vector2(at.x - c.x, at.z - c.z).length())
	return least

## Each bird's burst: a fan direction, a low height and a fan distance, from its own seeded draw (the same on every
## screen). The direction is the first of a sweep round its outward heading whose whole route keeps TRUNK_CLEAR from
## every trunk within reach, at the height the bird is at (each trunk leans); if none does, the clearest.
func _routes(plan: Variant, seed_text: String) -> void:
	var lo := Vector2(-position.x, -position.z)
	var hi := lo + (Vector2(plan.width, plan.height) * 2.0 if plan != null else Vector2(1e4, 1e4))
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed_text + ":routes")
	for b: Dictionary in _birds:
		b["low"] = rng.randf_range(LOW_MIN, LOW_MAX)
		b["fan"] = rng.randf_range(FAN_MIN, FAN_MAX)
		var out: Vector3 = b["out"]
		var base := atan2(out.z, out.x)
		var best := -1.0
		var fan0: float = b["fan"]
		var low0: float = b["low"]
		# Its own draw first; then the other fan distances and drop heights, each swept round 25 headings.
		for variant: Array in [[1.0, 0.0], [1.4, 0.0], [0.75, 0.0], [1.0, 0.7], [1.0, -0.7], [1.4, 0.7], [0.6, 0.0], [1.8, 0.0], [0.6, 0.7], [1.8, -0.7]]:
			b["fan"] = clampf(fan0 * float(variant[0]), FAN_MIN * 0.6, 7.0)
			b["low"] = clampf(low0 + float(variant[1]), LOW_MIN, LOW_MAX + 0.4)
			for k in 25:
				var a := base + (0.0 if k == 0 else (0.25 * ((k + 1) / 2)) * (1.0 if k % 2 == 1 else -1.0))
				b["dir"] = Vector3(cos(a), 0, sin(a))
				var c := route_clearance(b, lo, hi)
				if c > best:
					best = c
					b["best"] = [b["dir"], b["fan"], b["low"]]
				if c >= TRUNK_CLEAR:
					break
			if best >= TRUNK_CLEAR:
				break
		# Still not clear (a crowded stand of trunks): a wider search, every 0.1 rad, over a grid of fans and heights.
		if best < TRUNK_CLEAR:
			for fi in 6:
				for li in 7:
					b["fan"] = 2.0 + fi * 1.0
					b["low"] = LOW_MIN + li * 0.4
					for k in 63:
						var a := base + k * 0.1
						b["dir"] = Vector3(cos(a), 0, sin(a))
						var c := route_clearance(b, lo, hi)
						if c > best:
							best = c
							b["best"] = [b["dir"], b["fan"], b["low"]]
						if best >= TRUNK_CLEAR:
							break
					if best >= TRUNK_CLEAR:
						break
				if best >= TRUNK_CLEAR:
					break
		b["dir"] = b["best"][0]
		b["fan"] = b["best"][1]
		b["low"] = b["best"][2]
		b["clear"] = best

## The least distance from bird `b`'s route to any trunk's axis at the bird's height (0 if it leaves the floor).
func route_clearance(b: Dictionary, lo := Vector2(-1e4, -1e4), hi := Vector2(1e4, 1e4)) -> float:
	var least := 1e9
	var t := 0.0
	while t < FLIGHT:
		var got := route_at(b, t)
		if float(got[1]) <= 0.0:
			break
		var p: Vector3 = got[0]
		if p.x < lo.x + 0.3 or p.z < lo.y + 0.3 or p.x > hi.x - 0.3 or p.z > hi.y - 0.3:
			return 0.0
		for tr: Array in near_trunks:
			if p.y > float(tr[2]):
				continue
			var c := trunk_at(tr[0], tr[1], tr[2], maxf(p.y, 0.0))
			least = minf(least, Vector2(p.x - c.x, p.z - c.z).length())
		t += 0.05
	return least

## Where bird `b` is `t` seconds after it leaves its perch: [position, scale, velocity, climbing]. First it drops out
## of the crown and fans out below it (BURST_DROP s), then climbs out to the open band over the tops and away,
## shrinking between FADE_NEAR and FADE_FAR from the tree.
static func route_at(b: Dictionary, t: float) -> Array:
	var perch: Vector3 = b["perch"]
	var dir: Vector3 = b.get("dir", b["out"])
	var low: float = b.get("low", 3.5)
	var fan: float = b.get("fan", 4.5)
	var p: Vector3
	var vel: Vector3
	var climbing := true
	if t < BURST_DROP:
		var u := t / BURST_DROP
		var e := 1.5 * u - 0.5 * u * u * u
		var dy := (low - perch.y) * (u * u * (3.0 - 2.0 * u))
		p = perch + dir * (fan * e) + Vector3.UP * dy
		vel = dir * (fan * 1.5 * (1.0 - u * u) / BURST_DROP + 0.5) + Vector3.UP * ((low - perch.y) * 6.0 * u * (1.0 - u) / BURST_DROP)
	else:
		var s := t - BURST_DROP
		var room := FLY_CEILING - low
		var rise := minf(7.0 * s - 0.8 * s * s, room)
		climbing = rise < room - 1e-3
		p = perch + dir * (fan + 4.0 * s + 0.9 * s * s) + Vector3.UP * (low - perch.y + rise)
		vel = dir * (4.0 + 1.8 * s) + Vector3.UP * ((7.0 - 1.6 * s) if climbing else 0.0)
	var h := Vector2(p.x, p.z).length()
	var sc := clampf((FADE_FAR - h) / (FADE_FAR - FADE_NEAR), 0.0, 1.0)
	return [p, sc, vel, climbing]

# --- the bird --------------------------------------------------------------------------------------------

## One bird facing +z, feet at the origin, about 45 cm beak to tail: `wing` 0 folded, 1 up, -1 down, 2 out flat
## (gliding: the clearest silhouette from below).
static func bird_mesh(wing: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tri := func(a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
		var nrm := (b - a).cross(c - a).normalized()
		for q: Vector3 in [a, b, c]:
			st.set_normal(nrm)
			st.set_color(col)
			st.add_vertex(q * SCALE)
	# Body: a stretched diamond, the chest fuller than the back.
	var nose := Vector3(0, 0.15, 0.13)
	var back := Vector3(0, 0.12, -0.15)
	var top := Vector3(0, 0.21, 0.0)
	var under := Vector3(0, 0.05, 0.02)
	var l := Vector3(-0.085, 0.13, 0.01)
	var r := Vector3(0.085, 0.13, 0.01)
	var body := C_BIRD if wing == 0 else C_PALE
	for pair: Array in [[nose, l], [l, back], [back, r], [r, nose]]:
		tri.call(pair[0], pair[1], top, body * 1.15)
		tri.call(pair[1], pair[0], under, body * 0.8)
	# Head, hunched forward on the body, and the heavy beak.
	var hc := Vector3(0, 0.225, 0.14)
	var hr := 0.055
	var hp := [hc + Vector3(0, hr, 0), hc + Vector3(0, -hr, 0), hc + Vector3(hr, 0, 0), hc + Vector3(0, 0, hr),
		hc + Vector3(-hr, 0, 0), hc + Vector3(0, 0, -hr)]
	for k in 4:
		var a: Vector3 = hp[2 + k]
		var b: Vector3 = hp[2 + (k + 1) % 4]
		tri.call(a, b, hp[0], body * 1.2)
		tri.call(b, a, hp[1], body * 0.9)
	var tipb := Vector3(0, 0.205, 0.285)
	var bq := [hc + Vector3(0, 0.022, 0.04), hc + Vector3(0.022, -0.01, 0.04), hc + Vector3(-0.022, -0.01, 0.04), hc + Vector3(0, -0.03, 0.035)]
	tri.call(bq[0], bq[1], tipb, C_BEAK)
	tri.call(bq[2], bq[0], tipb, C_BEAK)
	tri.call(bq[1], bq[3], tipb, C_BEAK * 0.8)
	tri.call(bq[3], bq[2], tipb, C_BEAK * 0.8)
	# The tail: a fan, both faces.
	var tl := Vector3(-0.065, 0.07, -0.33)
	var tr := Vector3(0.065, 0.07, -0.33)
	var tail := body if wing == 0 else C_TIP
	tri.call(back, tl, tr, tail)
	tri.call(back, tr, tl, tail * 0.8)
	# Wings, both faces each.
	for side: float in [-1.0, 1.0]:
		var sh_f := Vector3(side * 0.075, 0.165, 0.07)
		var sh_b := Vector3(side * 0.07, 0.15, -0.1)
		var tip: Vector3
		var trail: Vector3
		if wing == 0:
			tip = Vector3(side * 0.08, 0.12, -0.27)
			trail = Vector3(side * 0.085, 0.09, -0.12)
		elif wing == 2:
			tip = Vector3(side * 0.40, 0.17, -0.05)
			trail = Vector3(side * 0.28, 0.15, -0.2)
		elif wing > 0:
			tip = Vector3(side * 0.36, 0.42, -0.06)
			trail = Vector3(side * 0.25, 0.27, -0.2)
		else:
			tip = Vector3(side * 0.38, -0.06, -0.02)
			trail = Vector3(side * 0.26, 0.02, -0.17)
		# Folded, two dark faces. Open, the wing is pale (paler underneath) with a dark tip: the inner part split so
		# the last third toward the tip is its own dark triangle.
		var faces: Array = [[sh_f, tip, sh_b, -1], [sh_b, tip, trail, -1]]
		if wing != 0:
			var m1 := sh_f.lerp(tip, 0.68)
			var m2 := trail.lerp(tip, 0.55)
			faces = [[sh_f, m1, sh_b, 0], [sh_b, m1, m2, 0], [sh_b, m2, trail, 0], [m1, tip, m2, 1]]
		for f: Array in faces:
			for order: Array in [[f[0], f[1], f[2]], [f[0], f[2], f[1]]]:
				var a: Vector3 = order[0]
				var b: Vector3 = order[1]
				var c: Vector3 = order[2]
				var down := (b - a).cross(c - a).y < 0.0
				var col: Color
				if int(f[3]) < 0:
					col = body * (0.95 if not down else 0.75)
				elif int(f[3]) == 1:
					col = C_TIP
				else:
					col = C_UNDERWING if down else C_PALE * 1.05
				tri.call(a, b, c, col)
	return st.commit()

## Both eyes as tiny diamonds either side of the head (drawn in the floor's glow).
static func eyes_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r := 0.022
	for side: float in [-1.0, 1.0]:
		var c := Vector3(side * 0.042, 0.238, 0.172)
		var p := [c + Vector3(0, r, 0), c + Vector3(0, -r, 0), c + Vector3(r, 0, 0), c + Vector3(0, 0, r),
			c + Vector3(-r, 0, 0), c + Vector3(0, 0, -r)]
		for k in 4:
			var a: Vector3 = p[2 + k]
			var b: Vector3 = p[2 + (k + 1) % 4]
			for q: Vector3 in [a, b, p[0], b, a, p[1]]:
				st.set_normal((q - c).normalized())
				st.add_vertex(q * SCALE)
	return st.commit()

static func meshes() -> Array:
	if _meshes.is_empty():
		_meshes = [bird_mesh(0), bird_mesh(1), bird_mesh(-1), eyes_mesh(), bird_mesh(2)]
	return _meshes

static func triangles(mesh: ArrayMesh) -> int:
	var total := 0
	for s in mesh.get_surface_count():
		total += (mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return total

func _figures() -> void:
	var ms := meshes()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.metallic_specular = 0.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var open := StandardMaterial3D.new()
	open.vertex_color_use_as_albedo = true
	open.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	open.cull_mode = BaseMaterial3D.CULL_DISABLED
	for k in POSES:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = ms[4] if k == GLIDE else ms[k]
		mm.instance_count = _birds.size()
		var mmi := MultiMeshInstance3D.new()
		mmi.name = ["Perched", "WingsUp", "WingsDown", "Gliding"][k]
		mmi.multimesh = mm
		mmi.material_override = mat if k == 0 else open
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
		_mm.append(mmi)
	var em := MultiMesh.new()
	em.transform_format = MultiMesh.TRANSFORM_3D
	em.mesh = ms[3]
	em.instance_count = _birds.size()
	_eyes = MultiMeshInstance3D.new()
	_eyes.name = "Eyes"
	_eyes.multimesh = em
	_eye_mat = Level.glow_material(C_EYE, EYE_LIT)
	_eyes.material_override = _eye_mat
	_eyes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_eyes)
	drawn["bird_triangles"] = triangles(ms[0])

# --- the ground under it ----------------------------------------------------------------------------------

## Pale droppings across the trigger's disc (dense in the middle, still clear at the edge); nothing on the trunks.
## Lit like the gravel, so it shows in the dark as gravel does; patchy, with the litter between.
func _spatter(plan: Variant, trunks: Array, rng: RandomNumberGenerator) -> void:
	var g := Arboretum.garden_of(plan) if plan != null else null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var blobs := 0
	var want := int(52.0 * _trigger * _trigger)
	for i in want:
		var a := rng.randf() * TAU
		var d := _trigger * pow(rng.randf(), 0.62)
		var c := Vector3(cos(a) * d, 0.0, sin(a) * d)
		var w := c + position
		var under := g.surface(int(floor(w.x / 2.0)), int(floor(w.z / 2.0))) if g != null else Noises.LITTER
		if under == Noises.NONE or under == Noises.GRAVEL:
			continue
		var size := rng.randf_range(0.03, 0.12) * (1.25 - 0.5 * d / _trigger)
		var col := C_SPATTER * rng.randf_range(0.82, 1.08)
		col.a = 1.0
		var y := 0.011 + 0.0004 * (i % 7)
		var sides := 6
		var radii: Array[float] = []
		for k in sides:
			radii.append(size * rng.randf_range(0.5, 1.15))
		for k in sides:
			var a0 := k * TAU / sides
			var a1 := (k + 1) * TAU / sides
			for q: Vector3 in [c + Vector3(0, y, 0), c + Vector3(cos(a1) * radii[(k + 1) % sides], y, sin(a1) * radii[(k + 1) % sides]),
					c + Vector3(cos(a0) * radii[k], y, sin(a0) * radii[k])]:
				st.set_normal(Vector3.UP)
				st.set_color(col)
				st.add_vertex(q)
		blobs += 1
	var mi := MeshInstance3D.new()
	mi.name = "Spatter"
	mi.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 1.0
	m.metallic_specular = 0.1
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	drawn["spatter"] = blobs

## The company's notice beside the pavilion's doorway (first roost of a floor only).
func _notice(plan: Variant) -> void:
	var lx: int = plan.landing.x
	var mid := (lx + 0.5) * 2.0
	var z1 := (Arboretum.Y0 + 2) * 2.0 + 0.09
	var g := Arboretum.garden_of(plan)
	var x := mid + 1.55
	if g != null and not g.landmarks.is_empty() and absf(g.landmarks[0].lamp.x / 100.0 - x) < 0.8:
		x = mid - 1.55
	var root := Node3D.new()
	root.name = "Notice"
	root.top_level = true
	add_child(root)
	root.global_transform = Transform3D(Basis.IDENTITY, Vector3(x, 0, z1))
	var board := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.2, 0.5, 0.025)
	board.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.17, 0.2, 0.16)
	mat.roughness = 0.8
	board.material_override = mat
	board.position = Vector3(0, 1.55, 0.012)
	root.add_child(board)
	var label := Label3D.new()
	label.text = "QUIET HOURS ARE OBSERVED\nFOR THE COMFORT OF\nTHE COLLECTION."
	label.font_size = 64
	label.pixel_size = 0.0012
	label.modulate = Color(0.85, 0.82, 0.7)
	label.outline_size = 0
	label.shaded = true
	label.double_sided = false
	label.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.position = Vector3(0, 1.53, 0.027)
	root.add_child(label)
	drawn["notice"] = label.text

# --- sound ------------------------------------------------------------------------------------------------

static func stream(name: StringName) -> AudioStream:
	if _streams.has(name):
		return _streams[name]
	var spec: Array = SOUNDS[name]
	var path := DIR + String(spec[0]) + ".ogg"
	var st: AudioStream = null
	if ResourceLoader.exists(path):
		st = load(path)
		if st is AudioStreamOggVorbis:
			st = (st as AudioStreamOggVorbis).duplicate()
			(st as AudioStreamOggVorbis).loop = bool(spec[1])
	_streams[name] = st
	return st

func _player(name: StringName) -> AudioStreamPlayer3D:
	var spec: Array = SOUNDS[name]
	var p := AudioStreamPlayer3D.new()
	p.bus = bus_of(name)
	p.unit_size = float(spec[2])
	p.max_distance = float(spec[3])
	p.max_db = 0.0
	p.position = Vector3(0, CANOPY_Y, 0)
	add_child(p)
	return p

func _sounds() -> void:
	_loop = _player(&"idle")
	_spare = _player(&"idle")
	_circle = _player(&"circle")

## Sfx.BASE_DB plus the sound's trim (never above 0).
func _db(name: StringName) -> float:
	return SfxScript.BASE_DB + minf(float((SOUNDS[name] as Array)[4]), 0.0)

## Every player this view has made (tests: none may play louder than its file).
func players() -> Array[AudioStreamPlayer3D]:
	var out: Array[AudioStreamPlayer3D] = []
	for c in get_children():
		if c is AudioStreamPlayer3D:
			out.append(c)
	return out

## Start a loop part way in, at the record's own moment, so every screen hears the same bar; the tree's own loops
## are put out of step with the other roosts' by a fixed share of their length from its cell (the same everywhere).
func _start_loop(p: AudioStreamPlayer3D, name: StringName, since_s: float) -> void:
	var st := stream(name)
	if st == null:
		p.stop()
		return
	var spec: Array = SOUNDS[name]
	p.stream = st
	p.bus = bus_of(name)
	p.unit_size = float(spec[2])
	p.max_distance = float(spec[3])
	p.max_db = 0.0
	p.volume_db = _db(name)
	var length := maxf(st.get_length(), 0.01)
	p.play(fmod(maxf(since_s, 0.0) + _phase * length, length))

## Changes the tree's loop: the old one fades out over XFADE while the new one starts.
func _swap_loop(want: StringName, since_s: float) -> void:
	if _loop.playing:
		var old := _loop
		_loop = _spare
		_spare = old
		var fade := create_tween() if is_inside_tree() else null
		if fade != null:
			fade.tween_property(old, "volume_db", -60.0, XFADE)
			fade.tween_callback(old.stop)
		else:
			old.stop()
	if want == &"":
		_loop.stop()
	else:
		_start_loop(_loop, want, since_s)

func _one_shot(name: StringName, since_s: float) -> void:
	var st := stream(name)
	if st == null or since_s >= st.get_length():
		return
	var spec: Array = SOUNDS[name]
	_shot = play_cue(st, global_position + Vector3(0, CANOPY_Y - 0.3, 0), category_of(name), minf(float(spec[4]), 0.0), maxf(since_s, 0.0))
	if _shot != null:
		_shot.unit_size = float(spec[2])
		_shot.max_distance = float(spec[3])
		_shot.max_db = 0.0

## Which loop each state plays at the tree ("" none).
static func loop_of(state: StringName) -> StringName:
	match state:
		&"settled", &"settling":
			return &"idle"
		&"stirring":
			return &"stir"
	return &""

func changed(rec: Dictionary, before: Dictionary, ht: float) -> void:
	_rec = rec
	var state := StringName(rec.get("state", &"settled"))
	var was := StringName(before.get("state", &""))
	var in_s := seconds_in(rec, ht)
	var want := loop_of(state)
	if want != _loop_name:
		_loop_name = want
		_swap_loop(want, in_s)
	if state == &"flushed" and was != &"flushed":
		_one_shot(&"flush", in_s)
	elif state == &"settling" and was != &"settling":
		_one_shot(&"settle", in_s)
	var circling := state == &"away" or state == &"flushed"
	if circling and not _circle.playing:
		var into := in_s if state == &"away" else 0.0
		_start_loop(_circle, &"circle", into)
	elif not circling and _circle.playing:
		_circle.stop()

func event(_e: Dictionary, _ht: float) -> void:
	pass

# ---------------------------------------------------------------------------------------------
# Every frame: poses from host time.

static func _h(a: int, b: int) -> float:
	return ArbView._hash01(a, b, 77)

func frame(rec: Dictionary, ht: float, delta: float) -> void:
	_rec = rec
	if _birds.is_empty():
		return
	var state := StringName(rec.get("state", &"settled"))
	var since := float(rec.get("since", 0.0))
	var tau := ht - since
	var hidden := Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO)
	var lit_here := lit(global_position + Vector3(0, CANOPY_Y, 0))
	_eye_mat.set_shader_parameter("energy", EYE_LIT if lit_here else EYE_DARK)
	for i in _birds.size():
		var got := bird_at(i, state, tau, ht)
		var xf: Transform3D = got[0]
		var pose: int = got[1]
		for k in POSES:
			_mm[k].multimesh.set_instance_transform(i, xf if k == pose else hidden)
		_eyes.multimesh.set_instance_transform(i, xf if bool(got[2]) else hidden)
	_shower_frame(state, tau)
	# The settled murmur fades inside the Groundskeeper's ring of silence, as the crickets do. The restless loop never
	# does: it is the warning, and must be heard however near he is.
	if _loop != null and _loop.playing and _loop_name != &"":
		var hush := 1.0
		if _loop_name == &"idle" and _garden != null and is_instance_valid(_garden):
			hush = clampf(float(_garden.get("_hush")), 0.0, 1.0)
		_loop.volume_db = _db(_loop_name) + linear_to_db(maxf(hush, 0.0001))
	if _circle != null and _circle.playing:
		var a := ht * 0.45
		var cr := circle_radius(CIRCLERS / 2)
		_circle.position = Vector3(cos(a) * cr, FLY_CEILING - 0.4, sin(a) * cr)

func bird_count() -> int:
	return _birds.size()

## Bird `i` in `state`, `tau` seconds into it, at host time `ht`: [transform (zero scale: not drawn), pose (0 perched,
## 1 wings up, 2 wings down), whether its eyes show]. Pure arithmetic on the record's time (frame() draws it; tests read it).
func bird_at(i: int, state: StringName, tau: float, ht: float) -> Array:
	var hidden := Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO)
	var b: Dictionary = _birds[i]
	var pose := 0
	var xf := hidden
	var eyes := false
	var perch: Vector3 = b["perch"]
	var out: Vector3 = b["out"]
	match state:
		&"settled", &"stirring":
			var restless := state == &"stirring"
			var period: float = float(b["period"]) * (0.25 if restless else 1.0)
			var beat := int(floor((ht + float(b["off"])) / period))
			var turn := (_h(i, beat) - 0.5) * (1.6 if restless else 0.9)
			var hop := 0.0
			if restless and _h(i + 50, beat) > 0.4:
				var k := fmod(ht + float(b["off"]), period) / period
				if k < 0.18:
					pose = 1
					hop = 0.04 * sin(PI * k / 0.18)
			xf = Transform3D(Basis.from_euler(Vector3(0, float(b["yaw"]) + turn, 0)), perch + Vector3.UP * hop)
			eyes = fmod(ht + float(b["off"]) * 3.0, float(b["blink"])) > 0.16
		&"flushed", &"away":
			# One clock from the moment the roost went up, whichever state it is in now.
			var ft := tau if state == &"flushed" else tau + _burst
			var got := _flight(i, ft, ht)
			xf = got[0]
			pose = got[1]
			eyes = got[2]
		&"settling":
			var land: float = _settle * (0.3 + 0.7 * float(b["land"]))
			if tau >= land:
				xf = Transform3D(Basis.from_euler(Vector3(0, float(b["yaw"]), 0)), perch)
				eyes = true
			elif i < CIRCLERS:
				# A circler glides down from where it was circling when the roost turned to settle (full size: it was
				# in sight), wings out, flapping only for the last part.
				var u := (land - tau) / land
				var from := _circler(i, ht - tau, 1e3, out).origin
				var p := perch.lerp(from, u) + Vector3.UP * (1.2 * u * (1.0 - u))
				var vel := perch - from
				pose = GLIDE if u > 0.35 else (1 if fmod(tau * FLAP_HZ + i * 0.37, 1.0) < 0.5 else 2)
				xf = Transform3D(Basis.looking_at(Vector3(vel.x, vel.y * 0.3, vel.z).normalized(), Vector3.UP, true), p)
				eyes = u < 0.5
			else:
				# Back in out of the dark: each grows from nothing over the first quarter of its way in.
				var u := (land - tau) / land
				var p := perch + out * (3.2 * u) + Vector3.UP * (3.0 * u * u)
				var vel := -out * 3.2 - Vector3.UP * (6.0 * u)
				pose = 1 if fmod(tau * FLAP_HZ + i * 0.37, 1.0) < 0.5 else 2
				var fwd := Vector3(vel.x, vel.y * 0.3, vel.z).normalized()
				var s := clampf((1.0 - u) / 0.25, 0.0, 1.0)
				xf = Transform3D(Basis.looking_at(fwd, Vector3.UP, true).scaled(Vector3.ONE * s), p)
				eyes = s >= 1.0
	return [xf, pose, eyes]

## The shower's pieces where they are `ft` seconds after the flush began (host time): falling, swaying, turning; gone
## once on the ground.
func _shower_frame(state: StringName, tau: float) -> void:
	if _leaves == null:
		return
	var ft := -1.0
	if state == &"flushed":
		ft = tau
	elif state == &"away":
		ft = tau + _burst
	var shown := 0
	for i in _fall.size():
		var xf := leaf_at(i, ft)
		if xf.basis.get_scale().x > 1e-4:
			shown += 1
		if i < LEAVES:
			_leaves.multimesh.set_instance_transform(i, xf)
		else:
			_feathers.multimesh.set_instance_transform(i - LEAVES, xf)
	drawn["falling"] = shown

func leaf_count() -> int:
	return _fall.size()

## Shower piece `i`, `ft` seconds after the flush began (negative: not yet): its transform (zero scale: not drawn).
func leaf_at(i: int, ft: float) -> Transform3D:
	var hidden := Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO)
	var f: Dictionary = _fall[i]
	var t := ft - float(f["delay"])
	if ft < 0.0 or t < 0.0:
		return hidden
	var at: Vector3 = f["at"]
	var y := at.y + 0.35 * t * exp(-4.0 * t) - float(f["fall"]) * t
	if y <= 0.03:
		return hidden
	var ph: float = f["phase"]
	var sway := float(f["sway"]) * sin(TAU * float(f["hz"]) * t + ph)
	var p := Vector3(at.x + sway * cos(ph), y, at.z + sway * sin(ph))
	var b := Basis.from_euler(Vector3(sin(t * 2.3 + ph) * 1.2, t * float(f["spin"]) + ph, cos(t * 1.7 + ph) * 0.9)).scaled(f["size"])
	return Transform3D(b, p)

func _shower(trunks: Array, rng: RandomNumberGenerator) -> void:
	if trunks.is_empty():
		return
	# A leaf: a 14 x 10 cm card cut from the floor's own leaf texture (alpha scissor), its two faces drawn apart: the
	# top in the canopy's green, the underside dry and pale, so a turning leaf flickers in the crew's light.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hw := 0.07
	var hd := 0.05
	var corners := [Vector3(-hw, 0, -hd), Vector3(hw, 0, -hd), Vector3(hw, 0, hd), Vector3(-hw, 0, hd)]
	var uvs := [Vector2(0.3, 0.3), Vector2(0.7, 0.3), Vector2(0.7, 0.7), Vector2(0.3, 0.7)]
	for side: int in [0, 1]:
		var order := [0, 1, 2, 0, 2, 3] if side == 0 else [0, 2, 1, 0, 3, 2]
		for k: int in order:
			st.set_normal(Vector3.UP if side == 0 else Vector3.DOWN)
			st.set_color(C_LEAF if side == 0 else C_LEAF_BACK)
			st.set_uv(uvs[k])
			st.add_vertex(corners[k])
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = st.commit()
	mm.instance_count = LEAVES
	# A feather: a plain pale card, both faces.
	var fs := SurfaceTool.new()
	fs.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k: int in [0, 1, 2, 0, 2, 3]:
		fs.set_normal(Vector3.UP)
		fs.set_color(Color.WHITE)
		fs.add_vertex(corners[k] * Vector3(0.85, 1, 0.8))
	var fm := MultiMesh.new()
	fm.transform_format = MultiMesh.TRANSFORM_3D
	fm.use_colors = true
	fm.mesh = fs.commit()
	fm.instance_count = FEATHERS
	var hidden := Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO)
	for i in LEAVES + FEATHERS:
		var feather := i >= LEAVES
		var t: Array = trunks[i % trunks.size()]
		var a := rng.randf() * TAU
		var at: Vector3 = trunk_at(t[0], t[1], t[2], rng.randf_range(3.4, 5.6)) + Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.3, 1.8)
		_fall.append({"at": at, "delay": rng.randf_range(0.0, 0.4), "fall": rng.randf_range(0.7, 1.0) if feather else rng.randf_range(1.0, 1.5),
			"sway": rng.randf_range(0.2, 0.5), "hz": rng.randf_range(0.8, 1.6), "phase": rng.randf() * TAU, "spin": rng.randf_range(-3.0, 3.0),
			"size": Vector3(1.5, 1.0, 0.4) if feather else Vector3.ONE})
		var shade := rng.randf_range(0.8, 1.0)
		if feather:
			fm.set_instance_transform(i - LEAVES, hidden)
			fm.set_instance_color(i - LEAVES, C_FEATHER * shade)
		else:
			mm.set_instance_transform(i, hidden)
			mm.set_instance_color(i, Color(shade, shade, shade))
	_leaves = MultiMeshInstance3D.new()
	_leaves.name = "Shower"
	_leaves.multimesh = mm
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = ArbView._leaf_tex()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = 0.5
	m.roughness = 1.0
	m.cull_mode = BaseMaterial3D.CULL_BACK
	_leaves.material_override = m
	_leaves.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_leaves)
	_feathers = MultiMeshInstance3D.new()
	_feathers.name = "Feathers"
	_feathers.multimesh = fm
	var fmat := StandardMaterial3D.new()
	fmat.vertex_color_use_as_albedo = true
	fmat.roughness = 1.0
	fmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_feathers.material_override = fmat
	_feathers.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_feathers)

## A bird circling high over the tree, wings working (`t` seconds into its circling, >= 0 rises into place).
func _circler(i: int, ht: float, t: float, out: Vector3) -> Transform3D:
	if t < 0.0:
		return Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO)
	var a := ht * (0.42 + 0.05 * i) + i * 2.1 + atan2(out.z, out.x)
	var radius := circle_radius(i)
	var p := Vector3(cos(a) * radius, FLY_CEILING - 0.4 + 0.3 * sin(ht * 0.7 + i), sin(a) * radius)
	var tangent := Vector3(-sin(a), 0, cos(a))
	# Comes in out of the dark over a second and a half (never pops into being).
	var s := clampf(t / 1.5, 0.0, 1.0)
	return Transform3D(Basis.looking_at(tangent, Vector3.UP, true).scaled(Vector3.ONE * s), p)

## The circling birds keep over the roost's own crown, so whoever stands near the tree sees them against the sky.
static func circle_radius(i: int) -> float:
	return 3.5 + 1.0 * i

## Bird `i` `ft` seconds after the roost went up: [transform, pose, eyes], along its route (route_at): down and out
## below the crown past whoever is there, then up and away; the circlers then come back in over the crown.
func _flight(i: int, ft: float, ht: float) -> Array:
	var hidden := Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO)
	var b: Dictionary = _birds[i]
	var perch: Vector3 = b["perch"]
	var out: Vector3 = b["out"]
	var t := ft - float(b["delay"])
	if t < 0.0:
		return [Transform3D(Basis.from_euler(Vector3(0, float(b["yaw"]), 0)), perch), 1, true]
	if t < FLIGHT:
		var got := route_at(b, t)
		var sc: float = got[1]
		if sc <= 0.0:
			return [hidden, 0, false]
		var vel: Vector3 = got[2]
		var k := fmod(t * FLAP_HZ + i * 0.37, 1.0)
		var pose := (1 if k < 0.5 else 2) if bool(got[3]) else (GLIDE if k < 0.34 else (1 if k < 0.67 else 2))
		var fwd := Vector3(vel.x, vel.y * 0.5, vel.z)
		if fwd.length() < 1e-3:
			fwd = b["dir"]
		var xf := Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP, true).scaled(Vector3.ONE * sc), got[0])
		return [xf, pose, true]
	if i < CIRCLERS:
		var k := fmod(ht * CIRCLE_HZ + i * 0.5, 1.0)
		return [_circler(i, ht, t - FLIGHT, out), GLIDE if k < 0.34 else (1 if k < 0.67 else 2), false]
	return [hidden, 0, false]
