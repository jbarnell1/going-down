# CS1: the caught player's own scene, one per resident (the owner, 21 Nov: "Can we also make custom caught screens for
# each resident?  Frightening jump scare style?"; North Star B6: "Being caught is a short scene, and each resident has
# its own", "Being caught should be a scene with picture noise", "The Groundskeeper's catch is a kill. Quick, no gore").
#
# What it is: for the first LENGTH_MS after the host's catch event reaches this screen, the resident's real figure (its
# own Blender model, the same file its world view draws, posed by its own clips) is drawn close in front of this
# screen's camera, lit by its own small light, with the tape's picture noise pushed hard, a flash or a cut drawn over
# the picture (CaughtOverlay) and a shove of the camera. Then it is gone and the downed state the host already holds
# (the ring, the crawl, the heal; client/down_view.gd) is on screen as before. Nothing here reaches the host, reads a
# rule or changes who is caught or when. The scene runs on this screen's own clock from the moment the event arrived,
# so it plays the same frames whatever the link's delay; the down timer under it counts against the host's clock.
#
# Only the caught player's screen plays it, and a player who is out and watching through that player's eyes
# (client/crew_watch.gd): client/main.gd caught_scene_kind decides. Everyone else sees the world figure do its catch.
# No sound is added here: each resident's catch already sounds (client/sfx.gd caught: the roar, the Orderly's chew, the
# Temp's staples; the Groundskeeper's shears from its own view; the Minder's found sting).
#
# The scenes (kind, from the floor's place):
#   orderly  the Clinic. A black instant, then its printed mask fills the frame and it bends in, roaring (its
#            mixamo_roar clip), the picture shaking harder as it comes.
#   temp     the Annex. Its photocopied paper face thrust right up to the lens, ink running down from the paper's eyes
#            (drawn into a copy of the page its world view wears), a photocopier's bright bar sweeping the picture.
#   minder   the Playroom. The smiley party mask drops into frame upside down from above, the long eyeless skull
#            behind it, swaying (its catch clip); then the drag to the party table as before.
#   keeper   the Arboretum. Out of the dark, from where it was, the blind face and the cord of badges lunge in (its
#            snatch clip); on the snatch the picture cuts to black.
#   crew     the Reactor. One of the wasted crew (the players' own figure dressed as that seat, its zombie crawl):
#            hands and the cracked screen face come up at you from floor level.
# None for the Hanging Ward (its web sequence is the Rigger's catch: client/ward/web_view.gd), the practice floor and
# the prison, or for going down from health on the Playroom (no resident is involved).
#
# CAUGHT SCENES: FULL / SOFT (client/caught_pref.gd, the player's own setting): SOFT keeps the scene without the camera
# snap or shove, with the flash and the noise halved.
extends Node3D

const OrderlyView = preload("res://client/orderly_view.gd")
const TempView = preload("res://client/temp_view.gd")
const MinderView = preload("res://client/minder_view.gd")
const Keeper = preload("res://client/groundskeeper_view.gd")
const StationCrew = preload("res://client/station_crew_view.gd")

## How long a scene lasts on screen (ms): within the owner's limit of about 1.2 s before the downed state shows.
const LENGTH_MS := 1100
## The kinds that have a scene.
const KINDS: Array[String] = ["orderly", "temp", "minder", "keeper", "crew"]
## The clips each kind plays, the first one its model has.
const CLIPS := {"orderly": ["mixamo_roar", "reach"], "temp": ["reach", "bend", "chase"], "minder": ["catch"],
	"keeper": ["snatch", "lean"], "crew": ["station/zombie_crawl", "crawl"]}
## The bone whose point is put in front of the lens, the first one the model has (matched at the end of the name).
const FACE_BONES: Array[String] = ["headfront", "head"]
## Where the face is from that bone's point, in the figure's own space, for a model without a face surface.
const FACE_OFFSET := {"orderly": Vector3(0.0, 0.17, 0.14), "keeper": Vector3(0.0, 0.24, 0.12)}
## The surface whose middle is the face, where a model has one (its material's name begins with this), else FACE_BONES.
const FACE_SURFACES := {"temp": "temp_face_sheet", "minder": "Minder_mask", "crew": "face_screen"}
## SOFT: the flash and the noise times this.
const SOFT_K := 0.5

var kind := ""
var soft := false
## When (msec, this screen's clock) the scene started, -1 for none.
var started := -1
## Whether the scene is for this screen's own player (false: watching a crewmate through their eyes).
var own := true
## The figure being shown and what it is made of.
var figure: Node3D = null
var model_path := ""
var clip := ""
var overlay: CaughtOverlay = null
## This frame's values (see step), for client/main.gd and the tests.
var snow := 0.0
var glitch := 0.0
var shove := Vector2.ZERO
var face_dist := 0.0
var clip_t := 0.0
## The scenes started on this screen and the last one's kind (the state, for scripted checks).
var starts := 0
var last := ""

var _figures := {}       # kind -> {root, ap, skel, bone, rel, path, clip, len, extra}
var _light: OmniLight3D
var _ink: Array[Texture2D] = []
var _paper_mat: StandardMaterial3D = null
var _crew_seat := 1

func _init() -> void:
	name = "CaughtScene"
	overlay = CaughtOverlay.new()
	overlay.name = "CaughtOverlay"
	_light = OmniLight3D.new()
	_light.name = "CaughtLight"
	_light.omni_range = 2.2
	_light.omni_attenuation = 1.2
	_light.shadow_enabled = false
	_light.visible = false
	add_child(_light)

## The scene for a floor's place ("" for none). `ward`: the Hanging Ward is played here (its web is its catch).
static func kind_for(place: String, ward := false) -> String:
	if ward:
		return ""
	match place:
		"clinic":
			return "orderly"
		"annex":
			return "temp"
		"playroom":
			return "minder"
		"arboretum":
			return "keeper"
		"reactor":
			return "crew"
	return ""

## The model file each kind draws: the one its world view draws in this run (client/figures.gd).
static func path_for(k: String) -> String:
	match k:
		"orderly":
			return OrderlyView.MODEL_V2 if OrderlyView.new_figures() and ResourceLoader.exists(OrderlyView.MODEL_V2) else OrderlyView.MODEL
		"temp":
			return TempView.model_path()
		"minder":
			return MinderView.MODEL_V2 if MinderView.new_figures() and ResourceLoader.exists(MinderView.MODEL_V2) else MinderView.MODEL
		"keeper":
			return Keeper.model_path()
		"crew":
			return "res://assets/entities/crewmate.glb"
	return ""

## Builds `k`'s figure ahead of its catch (on the floor's build), hidden, so the catch itself never waits for a load.
## `ctx`: "paper" (the Temp's page as its world view wears it, an Image) and "seed" (for a page made here).
func prepare(k: String, ctx: Dictionary = {}) -> void:
	if not KINDS.has(k):
		return
	if k == "temp":
		_make_ink(ctx)
	if _figures.has(k):
		return
	var f := _build(k)
	if not f.is_empty():
		_figures[k] = f

## Starts `k`'s scene now (`now_ms` this screen's clock). `own`: for this screen's own player (else watched).
## `ctx` as prepare, and "seat" (the Reactor's crew member, 1 to 4). False when `k` has no scene.
func start(k: String, now_ms: int, for_own := true, ctx: Dictionary = {}) -> bool:
	if not KINDS.has(k):
		return false
	prepare(k, ctx)
	if not _figures.has(k):
		return false
	_hide_all()
	kind = k
	started = now_ms
	own = for_own
	starts += 1
	last = k
	var f: Dictionary = _figures[k]
	figure = f["root"]
	model_path = str(f["path"])
	clip = str(f["clip"])
	if k == "crew":
		_dress_crew(f, int(ctx.get("seat", 1)))
	if k == "temp" and _paper_mat != null and not _ink.is_empty():
		_paper_mat.albedo_texture = _ink[0]
	return true

func playing(now_ms: int) -> bool:
	return started >= 0 and now_ms - started < LENGTH_MS

func stop() -> void:
	started = -1
	kind = ""
	_hide_all()
	snow = 0.0
	glitch = 0.0
	shove = Vector2.ZERO
	if overlay != null:
		overlay.clear()

## Whether the camera is snapped to face the resident at the start (FULL, and only on the caught player's own view).
func snaps() -> bool:
	return not soft and own

## This frame at `now_ms`, in front of `cam`: poses and places the figure, sets the overlay, and returns what the
## picture needs: {on, snow, glitch, shove (camera offset, m)}. After LENGTH_MS it stops and returns on false.
func step(now_ms: int, cam: Camera3D) -> Dictionary:
	if started < 0:
		return {"on": false}
	var e := now_ms - started
	if e >= LENGTH_MS or e < 0:
		stop()
		return {"on": false}
	var u := float(e) / float(LENGTH_MS)
	var f: Dictionary = _figures[kind]
	var look := _timeline(kind, float(e))
	var k_noise := SOFT_K if soft else 1.0
	snow = clampf(float(look["snow"]) * k_noise, 0.0, 1.0)
	glitch = clampf(float(look["glitch"]) * k_noise, 0.0, 1.0)
	var shake := float(look["shake"])
	shove = Vector2.ZERO
	if not soft:
		shove = Vector2(sin(e * 0.091) + 0.6 * sin(e * 0.233 + 1.3), cos(e * 0.077) + 0.6 * sin(e * 0.197 + 0.4)) * shake
		var kick := maxf(0.0, 1.0 - float(e) / 160.0)
		shove += Vector2(0.06, -0.025) * kick * kick
	overlay.flash = clampf(float(look["flash"]) * k_noise, 0.0, 1.0)
	overlay.black = clampf(float(look["black"]), 0.0, 1.0)
	overlay.bar = float(look["bar"])
	overlay.bar_a = clampf(float(look["bar_a"]) * k_noise, 0.0, 1.0)
	overlay.tint = look.get("tint", Color(1, 1, 1))
	overlay.queue_redraw()
	# The figure: its clip at this moment, its face point put where the timeline says, turned to the lens.
	var root: Node3D = f["root"]
	var shown := bool(look["shown"])
	root.visible = shown
	_light.visible = shown
	face_dist = float(look["dist"])
	if shown:
		clip_t = fmod(float(look["clip"]) * float(f["len"]), maxf(0.001, float(f["len"]))) if bool(look.get("loop", false)) else clampf(float(look["clip"]), 0.0, 1.0) * float(f["len"])
		_pose(f, clip_t)
		var cxf := cam.global_transform
		var target := Vector3(float(look["x"]), float(look["y"]), -face_dist)
		var local_basis := Basis(Vector3(0, 0, 1), float(look["roll"])) * Basis(Vector3(1, 0, 0), float(look["tilt"])) * Basis(Vector3(0, 1, 0), float(look["turn"]))
		if bool(look.get("square", false)):
			local_basis = local_basis * _square(f)
		var face := _face_point(f)
		var place := cxf * Transform3D(local_basis, target) * Transform3D(Basis.IDENTITY, -face)
		root.global_transform = place
		_light.global_position = cxf * Vector3(look["light_at"])
		_light.light_energy = float(look["light"])
		_light.light_color = look.get("light_color", Color(0.85, 0.9, 1.0))
		if kind == "temp" and _paper_mat != null and _ink.size() == 3:
			_paper_mat.albedo_texture = _ink[mini(2, int(u * 3.2))]
	return {"on": true, "snow": snow, "glitch": glitch, "shove": shove}

## What each scene looks like at `e` ms (see the file's head). dist: metres from the lens to the face point; x, y: its
## place across the picture (camera space, m); roll, tilt, turn: the figure's turn in camera space (radians); clip: the
## share of its clip (or, with loop, of one cycle); light: its light's energy and where it is (camera space).
static func _timeline(k: String, e: float) -> Dictionary:
	var d := {"shown": true, "dist": 0.5, "x": 0.0, "y": 0.0, "roll": 0.0, "tilt": 0.0, "turn": 0.0, "clip": 0.0, "loop": false,
		"snow": 0.4, "glitch": 0.8, "flash": 0.0, "black": 0.0, "bar": -1.0, "bar_a": 0.0, "shake": 0.0,
		"light": 1.6, "light_at": Vector3(0.0, 0.05, -0.08)}
	match k:
		"orderly":
			# A black instant and a pop of light: it is there, its printed face filling the frame (the whole mask, the
			# gown's collar under it), lit from the front. Held still long enough to be seen, then it lunges in, roaring.
			d["black"] = 1.0 if e < 45.0 else 0.0
			d["flash"] = 0.6 * _bump(e, 45.0, 140.0)
			var come := _ease_out(clampf((e - 45.0) / 260.0, 0.0, 1.0))
			var lunge := _ease_in(clampf((e - 640.0) / 200.0, 0.0, 1.0))
			d["dist"] = lerpf(0.75, 0.31, come) - 0.015 * _ramp(e, 305.0, 640.0) - 0.075 * lunge
			d["y"] = -0.015
			d["tilt"] = 0.1 * lunge
			# Its roar from the start, never as far as the head thrown back.
			d["clip"] = clampf((e - 40.0) / 900.0, 0.0, 1.0) * 0.3
			d["snow"] = 0.06 + 0.5 * _bump(e, 90.0, 170.0) + 0.45 * _bump(e, 860.0, 930.0) + 0.9 * _ramp(e, 960.0, 1100.0)
			d["glitch"] = 0.2 + 0.25 * _bump(e, 90.0, 200.0) + 0.5 * _bump(e, 640.0, 900.0) + 0.5 * _ramp(e, 900.0, 1100.0)
			d["shake"] = 0.004 + 0.03 * _bump(e, 640.0, 1000.0)
			d["light"] = 0.6
			d["light_at"] = Vector3(0.0, 0.1, 0.05)
			d["light_color"] = Color(0.95, 0.97, 1.0)
			d["shown"] = e < 1020.0
		"temp":
			# The page thrust at the lens in a blink; the ink runs; the copier's bar sweeps the picture.
			var a := _ease_out(clampf(e / 170.0, 0.0, 1.0))
			d["dist"] = lerpf(0.95, 0.19, a) - 0.03 * _ramp(e, 300.0, 900.0)
			d["x"] = lerpf(0.06, 0.0, a)
			d["y"] = lerpf(-0.08, 0.005, a)
			d["roll"] = lerpf(-0.28, -0.07, a)
			d["clip"] = clampf(e / 600.0, 0.0, 1.0) * 0.6 + 0.4
			d["bar"] = clampf((e - 380.0) / 430.0, -0.2, 1.2)
			d["bar_a"] = 0.95 if e >= 380.0 and e < 830.0 else 0.0
			d["flash"] = 0.35 * _bump(e, 380.0, 520.0) + 0.25 * _bump(e, 0.0, 90.0)
			d["tint"] = Color(0.8, 1.0, 0.85)
			d["snow"] = 0.08 + 0.5 * _bump(e, 170.0, 250.0) + 0.9 * _ramp(e, 940.0, 1100.0)
			d["glitch"] = 0.3 + 0.5 * _bump(e, 380.0, 820.0) + 0.5 * _ramp(e, 900.0, 1100.0)
			d["shake"] = 0.012 + 0.012 * _bump(e, 0.0, 250.0)
			d["light"] = 1.4
			d["light_at"] = Vector3(0.05, 0.1, 0.02)
			d["shown"] = e < 980.0
		"minder":
			# The mask drops into frame upside down, overshoots and swings, the long skull above it.
			var drop := clampf(e / 260.0, 0.0, 1.0)
			var swing := 0.0
			if e >= 260.0:
				swing = 0.05 * exp(-(e - 260.0) / 260.0) * cos((e - 260.0) / 95.0)
			d["y"] = lerpf(0.62, 0.0, _ease_in(drop)) - swing
			d["x"] = 0.02 * sin(e / 210.0)
			d["dist"] = lerpf(0.5, 0.3, _ramp(e, 300.0, 950.0))
			d["roll"] = PI + 0.12 * sin(e / 260.0)
			d["tilt"] = -0.15
			d["clip"] = clampf(e / 1100.0, 0.0, 1.0) * 0.5
			d["flash"] = 0.45 * _bump(e, 230.0, 330.0)
			d["snow"] = 0.1 + 0.5 * _bump(e, 190.0, 260.0) + 0.4 * _bump(e, 600.0, 680.0) + 0.9 * _ramp(e, 940.0, 1100.0)
			d["glitch"] = 0.35 + 0.45 * _bump(e, 200.0, 420.0) + 0.5 * _ramp(e, 900.0, 1100.0)
			d["shake"] = 0.022 * _bump(e, 240.0, 600.0) + 0.006
			d["light"] = 1.8
			d["light_at"] = Vector3(0.0, -0.2, 0.05)
			d["light_color"] = Color(1.0, 0.92, 0.8)
			d["shown"] = e < 1000.0
		"keeper":
			# Out of the dark it lunges, blind, its face turned square to you, the badges at its throat; it holds a
			# moment, lit hard and cold from below, then snatches: the picture cuts to black.
			var come := _ease_out(clampf(e / 220.0, 0.0, 1.0))
			var lunge := _ease_in(clampf((e - 400.0) / 140.0, 0.0, 1.0))
			d["dist"] = lerpf(1.7, 0.8, come) - 0.06 * _ramp(e, 220.0, 400.0) - 0.3 * lunge
			d["y"] = 0.17 - 0.08 * lunge
			d["square"] = true
			# Its snatch held at its start through the hold (the shears down), then struck in the lunge.
			d["clip"] = 0.05 + 0.55 * lunge
			d["black"] = 1.0 if e >= 540.0 else 0.5 * (1.0 - come)
			d["snow"] = (0.03 + 0.5 * _bump(e, 90.0, 160.0) + 0.3 * _bump(e, 440.0, 540.0)) if e < 540.0 else 0.06
			d["glitch"] = (0.1 + 0.3 * _bump(e, 60.0, 200.0) + 0.5 * lunge) if e < 600.0 else 0.2
			d["shake"] = (0.004 + 0.03 * lunge) if e < 540.0 else 0.0
			d["light"] = 2.4
			d["light_at"] = Vector3(0.0, -0.32, -0.05)
			d["light_color"] = Color(0.65, 0.8, 1.0)
			d["shown"] = e < 540.0
		"crew":
			# From the floor: the hands and the cracked screen face come up at you.
			var a := _ease_out(clampf(e / 620.0, 0.0, 1.0))
			d["y"] = lerpf(-0.62, -0.03, a)
			d["dist"] = lerpf(0.75, 0.3, _ramp(e, 120.0, 950.0))
			d["tilt"] = lerpf(-0.55, 0.15, a)
			d["roll"] = 0.12 * sin(e / 170.0)
			d["clip"] = e / 1000.0 * 1.4
			d["loop"] = true
			d["flash"] = 0.3 * _bump(e, 520.0, 640.0)
			d["snow"] = 0.1 + 0.5 * _bump(e, 470.0, 540.0) + 0.9 * _ramp(e, 940.0, 1100.0)
			d["glitch"] = 0.35 + 0.45 * _bump(e, 480.0, 760.0) + 0.5 * _ramp(e, 900.0, 1100.0)
			d["shake"] = 0.01 + 0.018 * a
			d["light"] = 1.5
			d["light_at"] = Vector3(0.0, 0.1, 0.02)
			d["light_color"] = Color(1.0, 0.75, 0.7)
			d["shown"] = e < 1000.0
	return d

static func _ramp(e: float, a: float, b: float) -> float:
	return clampf((e - a) / maxf(1.0, b - a), 0.0, 1.0)

## 0 to 1 and back between a and b.
static func _bump(e: float, a: float, b: float) -> float:
	if e < a or e > b:
		return 0.0
	return sin(PI * (e - a) / maxf(1.0, b - a))

static func _ease_in(x: float) -> float:
	return x * x * x

static func _ease_out(x: float) -> float:
	return 1.0 - pow(1.0 - x, 3.0)

# --- the figures ----------------------------------------------------------------------------------------------------

func _build(k: String) -> Dictionary:
	var root: Node3D
	var ap: AnimationPlayer = null
	var skel: Skeleton3D = null
	var path := path_for(k)
	if k == "crew":
		if not is_inside_tree():
			return {}   # the players' figure loads its model on entering the tree
		var v := CrewView.new()
		v.name = "CrewFigure"
		add_child(v)   # its _ready loads the model
		ap = v.ap
		skel = v.skel
		var lib := StationCrew.zombie_library(v)
		if lib != null and not ap.has_animation_library(&"station"):
			ap.add_animation_library(&"station", lib)
		var dresser := StationCrew.new()
		dresser._dress(v, 1)
		dresser.free()
		v.set_process(false)
		root = v
	else:
		if path == "" or not ResourceLoader.exists(path):
			return {}
		var ps := load(path) as PackedScene
		if ps == null:
			return {}
		root = ps.instantiate() as Node3D
		root.name = "%sFigure" % k.capitalize()
		add_child(root)
		var aps := root.find_children("*", "AnimationPlayer", true, false)
		ap = aps[0] as AnimationPlayer if not aps.is_empty() else null
		var sks := root.find_children("*", "Skeleton3D", true, false)
		skel = sks[0] as Skeleton3D if not sks.is_empty() else null
	if ap == null or skel == null:
		root.queue_free()
		return {}
	ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	ap.active = true
	var use := ""
	for c: String in CLIPS[k]:
		if ap.has_animation(c):
			use = c
			break
	if use == "":
		var list := ap.get_animation_list()
		use = String(list[0]) if not list.is_empty() else ""
	var bone := -1
	for want: String in FACE_BONES:
		for b in skel.get_bone_count():
			if skel.get_bone_name(b).to_lower().ends_with(want.to_lower()):
				bone = b
				break
		if bone >= 0:
			break
	# The skeleton's place inside the figure, so the face point can be found in the figure's own space.
	var rel := Transform3D.IDENTITY
	var n: Node = skel
	while n != null and n != root:
		if n is Node3D:
			rel = (n as Node3D).transform * rel
		n = n.get_parent()
	var mask_off: Variant = null
	var offset: Vector3 = FACE_OFFSET.get(k, Vector3(0.0, 0.03, 0.09))
	if bone >= 0 and FACE_SURFACES.has(k):
		mask_off = _surface_offset(root, skel, rel, bone, str(FACE_SURFACES[k]))
	if bone >= 0 and mask_off == null:
		# The face a little in front of the head bone at rest, carried with the head as it moves.
		var rest := skel.get_bone_global_rest(bone)
		mask_off = rest.affine_inverse() * (rel.affine_inverse() * (rel * rest.origin + offset))
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if k == "temp":
			for i in mi.mesh.get_surface_count():
				var src := mi.get_active_material(i)
				if src != null and src.resource_name.begins_with("temp_face_sheet"):
					_paper_mat = StandardMaterial3D.new()
					_paper_mat.albedo_texture = _ink[0] if not _ink.is_empty() else null
					_paper_mat.emission_enabled = true
					_paper_mat.emission = Color(0.18, 0.18, 0.17)
					_paper_mat.roughness = 0.9
					mi.set_surface_override_material(i, _paper_mat)
	root.visible = false
	return {"root": root, "ap": ap, "skel": skel, "bone": bone, "rel": rel, "mask": mask_off, "offset": offset, "path": path, "clip": use,
		"len": ap.get_animation(use).length if use != "" else 1.0}

func _pose(f: Dictionary, t: float) -> void:
	var ap: AnimationPlayer = f["ap"]
	var c := str(f["clip"])
	if c == "":
		return
	if ap.current_animation != c:
		ap.play(c, 0.0)
	ap.seek(t, true)

## The face point in the figure's own space, as posed now.
func _face_point(f: Dictionary) -> Vector3:
	var skel: Skeleton3D = f["skel"]
	var b := int(f["bone"])
	if b < 0:
		return Vector3(0, 1.6, 0.1)
	if f.get("mask") is Vector3:
		return (f["rel"] as Transform3D) * (skel.get_bone_global_pose(b) * (f["mask"] as Vector3))
	return (f["rel"] as Transform3D) * skel.get_bone_global_pose(b).origin + (f["offset"] as Vector3)

## The turn that puts the face square to the lens and upright: the head bone's forward (its own +Y, as the
## Groundskeeper's rig has it) turned onto the figure's +Z, which faces the camera.
static func _square(f: Dictionary) -> Basis:
	var skel: Skeleton3D = f["skel"]
	var b := int(f["bone"])
	if b < 0:
		return Basis.IDENTITY
	var fwd := ((f["rel"] as Transform3D).basis * skel.get_bone_global_pose(b).basis * Vector3(0, 1, 0)).normalized()
	var yaw := -atan2(fwd.x, fwd.z)
	var flat := Basis(Vector3(0, 1, 0), yaw) * fwd
	return Basis(Vector3(1, 0, 0), atan2(flat.y, flat.z)) * Basis(Vector3(0, 1, 0), yaw)

## The middle of the surface whose material is named `mat` (at rest), in the head bone's own space, or null.
static func _surface_offset(root: Node3D, skel: Skeleton3D, rel: Transform3D, bone: int, mat: String) -> Variant:
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		for i in mi.mesh.get_surface_count():
			var m := mi.get_active_material(i)
			if m == null or not m.resource_name.begins_with(mat):
				continue
			var verts: PackedVector3Array = mi.mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX]
			if verts.is_empty():
				continue
			var c := Vector3.ZERO
			for v in verts:
				c += v
			c /= float(verts.size())
			var mrel := Transform3D.IDENTITY
			var n: Node = mi
			while n != null and n != root:
				if n is Node3D:
					mrel = (n as Node3D).transform * mrel
				n = n.get_parent()
			var in_skel := rel.affine_inverse() * (mrel * c)
			return skel.get_bone_global_rest(bone).affine_inverse() * in_skel
	return null

func _hide_all() -> void:
	for k: String in _figures:
		((_figures[k] as Dictionary)["root"] as Node3D).visible = false
	if _light != null:
		_light.visible = false
	figure = null

func _dress_crew(f: Dictionary, seat: int) -> void:
	var v := f["root"] as CrewView
	if v == null:
		return
	_crew_seat = clampi(seat, 1, 4)
	v.set_number(_crew_seat)
	v.set_skin((_crew_seat - 1) % 4)
	v.set_face(StationCrew.face_for(_crew_seat))

# --- the Temp's page, with the ink running from its eyes ------------------------------------------------------------

func _make_ink(ctx: Dictionary) -> void:
	var paper: Variant = ctx.get("paper")
	var page: Image = null
	if paper is Image:
		page = (paper as Image).duplicate() as Image
	elif _ink.is_empty():
		page = TempView.photocopy(TempView.blank_face(), str(ctx.get("seed", "caught")))
	if page == null:
		return
	_ink = []
	for k: float in [0.3, 0.65, 1.0]:
		var img := ink_run(page, k)
		img.generate_mipmaps()
		_ink.append(ImageTexture.create_from_image(img))
	if _paper_mat != null:
		_paper_mat.albedo_texture = _ink[0]

## The page with ink running down from the dark of its eyes, `k` (0..1) of the way. The same page always runs the same.
static func ink_run(page: Image, k: float) -> Image:
	var img := page.duplicate() as Image
	img.clear_mipmaps()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGB8)
	var w := img.get_width()
	var h := img.get_height()
	var fr := Rect2(Vector2(TempView.FACE_RECT.position) / Vector2(TempView.PAGE), Vector2(TempView.FACE_RECT.size) / Vector2(TempView.PAGE))
	var x0 := int(fr.position.x * w)
	var x1 := int(fr.end.x * w)
	var band0 := int((fr.position.y + fr.size.y * 0.26) * h)
	var band1 := int((fr.position.y + fr.size.y * 0.52) * h)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("cs1-ink")
	var starts: Array[Vector2i] = []
	for x in range(x0, x1):
		var best := 1.0
		var by := -1
		for y in range(band0, band1):
			var l := img.get_pixel(x, y).get_luminance()
			if l < best:
				best = l
				by = y
		if by >= 0 and best < 0.4 and rng.randf() < 0.3:
			starts.append(Vector2i(x, by))
	if starts.is_empty():
		# No dark there (a blank drawing): two eyes where a face's would be.
		for fx: float in [0.33, 0.67]:
			for j in 5:
				starts.append(Vector2i(int(lerpf(fr.position.x, fr.end.x, fx) * w) + j - 2, int((fr.position.y + fr.size.y * 0.4) * h)))
	var ink := Color(0.04, 0.04, 0.06)
	for s: Vector2i in starts:
		var length := int(k * rng.randf_range(0.12, 0.42) * h)
		var wob := rng.randf() * TAU
		var thick := 1 + int(rng.randf() < 0.35)
		for i in length:
			var y := s.y + i
			if y >= h:
				break
			var x := s.x + int(roundf(0.8 * sin(i * 0.21 + wob)))
			var fade := 1.0 - 0.45 * float(i) / maxf(1.0, float(length))
			for dx in thick:
				var xx := clampi(x + dx, 0, w - 1)
				img.set_pixel(xx, y, img.get_pixel(xx, y).lerp(ink, 0.85 * fade))
		# The drop at its end.
		var ey := mini(h - 1, s.y + length)
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var xx := clampi(s.x + dx, 0, w - 1)
				var yy := clampi(ey + dy, 0, h - 1)
				img.set_pixel(xx, yy, img.get_pixel(xx, yy).lerp(ink, 0.7))
	return img

## Tests and the state: what is on screen now.
func describe(now_ms: int) -> Dictionary:
	var meshes := 0
	var skinned := 0
	var flat := 0
	if figure != null:
		for mi: MeshInstance3D in figure.find_children("*", "MeshInstance3D", true, false):
			meshes += 1
			if mi.skin != null or mi.skeleton != NodePath():
				skinned += 1
		flat = figure.find_children("*", "Sprite3D", true, false).size() + figure.find_children("*", "SpriteBase3D", true, false).size()
	return {"kind": kind, "last": last, "starts": starts, "on": playing(now_ms), "ms": now_ms - started if started >= 0 else -1, "own": own, "soft": soft,
		"model": model_path, "clip": clip, "shown": figure != null and figure.visible, "meshes": meshes, "skinned": skinned,
		"flat": flat, "snow": snow, "glitch": glitch, "flash": overlay.flash if overlay != null else 0.0,
		"black": overlay.black if overlay != null else 0.0, "bar": overlay.bar_a if overlay != null else 0.0,
		"shove": [shove.x, shove.y], "dist": face_dist}

## Over the picture, under the HUD: the scene's black, its flash and the Temp's photocopier bar.
class CaughtOverlay:
	extends Control
	var flash := 0.0
	var black := 0.0
	var bar := -1.0
	var bar_a := 0.0
	var tint := Color(1, 1, 1)

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_FULL_RECT)

	func clear() -> void:
		flash = 0.0
		black = 0.0
		bar = -1.0
		bar_a = 0.0
		queue_redraw()

	func _process(_d: float) -> void:
		var want := get_viewport_rect().size
		if size != want:
			position = Vector2.ZERO
			size = want

	func _draw() -> void:
		var w := size.x
		var h := size.y
		if black > 0.0:
			draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, black))
		if flash > 0.0:
			draw_rect(Rect2(Vector2.ZERO, size), Color(tint, flash))
		if bar_a > 0.0 and bar > -0.2 and bar < 1.2:
			# The copier's lamp: a hard bright line with its glow, the page lit above it as it passed.
			var y := bar * h
			draw_rect(Rect2(0, 0, w, maxf(0.0, y)), Color(0.75, 1.0, 0.8, 0.12 * bar_a))
			for i in 6:
				var hh := h * (0.012 + 0.03 * i)
				draw_rect(Rect2(0, y - hh * 0.5, w, hh), Color(0.8, 1.0, 0.85, bar_a * 0.22 / (i + 1)))
			draw_rect(Rect2(0, y - h * 0.008, w, h * 0.016), Color(0.95, 1.0, 0.95, bar_a))
