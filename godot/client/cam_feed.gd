# CAM1: out, you watch the building's security cameras (North Star F3: "A downed player watches the building's security
# cameras. Only some rooms have one, the feeds cycle, and the picture is too grainy to read a sign or a face." "They can
# hear the living near whichever camera they are watching."). Client-side only: the cameras are sim/cameras.gd's (the
# same on every screen, from the floor's seed), and what an out player watches never reaches the host.
#  - The bodies: a small camera on a wall arm (or a lamp post's), with a red lamp that blinks, at every camera, drawn
#    for everyone, so the living can see where they are watched. The one being watched through is hidden on that screen.
#  - The feeds: the floor's cameras in their order, then each living crewmate's eyes (client/crew_watch.gd, as before).
#    Out, the first feed is up at once: the camera that sees where you fell (or the nearest). They cycle by themselves
#    every CYCLE_MS, to the next camera that has someone living in its picture (else simply the next); LEFT CLICK or E
#    steps to the next feed, Q or RIGHT CLICK to the one before, and the cycling waits HOLD_MS after a key. A crewmate's
#    eyes, once chosen, stay until a key.
#  - LS1 (North Star B7: "every camera feed locks onto them"): with one living player left, the feeds are only the
#    cameras that show them (the keys step among those); with none, their eyes.
#  - The picture: the scene's own camera moves to the lens (one render, the game's 480 by 270 picture), so the 3D
#    listener moves with it and you hear the living near it; client/tape.gdshader's `cctv` makes it coarse, grey and
#    grainy (client/main.gd sets it). The caption names the camera plainly: "CAM 3  FLOOR 2  EAST CORRIDOR".
extends RefCounted

const Cameras = preload("res://sim/cameras.gd")
const CrewWatch = preload("res://client/crew_watch.gd")

const CYCLE_MS := 6000
const HOLD_MS := 15000
## The lens's field of view (degrees, vertical): a little wider than a player's.
const FOV := 62.0
## The feed's picture: its 3D drawn at this share of the game's picture each way, a new frame every RATE_MS (12 a second).
const SCALE := 0.5
const RATE_MS := 83
## Tests and pictures only: the feed without its grain.
var raw := false
const KEYS := "LEFT CLICK OR E: NEXT   Q: BACK"

## The cameras in use (the floor's, or the Ward's while it is played here), the floor's number for the captions.
var cams: Array[Dictionary] = []
var depth := 0
var _plan_cams: Array[Dictionary] = []
var _ward_cams: Array[Dictionary] = []
var _ward_seed := -1

## This frame: watching through a camera (index into cams), or a crewmate's eyes (eyes_id), or neither.
var on_cam := false
var index := -1
var eyes_id := ""
var locked := false
var lock_id := ""
var eye := Vector3.ZERO
var yaw := 0.0
var pitch := 0.0
var caption := ""
## Host-free times (this screen's ms): when the feed went up, when it last changed, the last key.
var out_at := -1
var changed_at := -1
var key_at := -100000
## How many feeds went up by themselves (tests).
var cycles := 0
var _step := 0
var _on_crew := false
var _crew_at := -1

## The bodies drawn.
var _plan_root: Node3D = null
var _ward_root: Node3D = null
var _lamp_mat: StandardMaterial3D = null

# --- the cameras of this floor -------------------------------------------------------------------------

## A floor plan was built: its cameras, drawn under `parent` (the level, so they go where it goes).
func use_plan(parent: Node3D, list: Array[Dictionary], floor_depth: int) -> void:
	_plan_cams = list
	depth = floor_depth
	_plan_root = draw(parent, list, "SecurityCameras")
	_ward_cams = []
	_ward_seed = -1
	_ward_root = null
	cams = _plan_cams
	reset()

## The Hanging Ward played here: its cameras (sim/cameras.gd for_ward), drawn under `parent` (the Ward's node).
func use_ward(parent: Node3D, list: Array[Dictionary], ward_seed: int) -> void:
	_ward_cams = list
	_ward_seed = ward_seed
	_ward_root = draw(parent, list, "WardCameras")
	cams = _ward_cams
	reset()

func ward_seed() -> int:
	return _ward_seed if _ward_root != null and is_instance_valid(_ward_root) else -1

## The Ward has gone: the floor plan's cameras again.
func leave_ward() -> void:
	if _ward_seed < 0:
		return
	_ward_cams = []
	_ward_seed = -1
	_ward_root = null
	cams = _plan_cams
	reset()

func reset() -> void:
	on_cam = false
	index = -1
	eyes_id = ""
	locked = false
	lock_id = ""
	caption = ""
	out_at = -1
	changed_at = -1
	key_at = -100000
	_step = 0
	_on_crew = false
	_show_body(-1)

## LEFT CLICK or E (+1), Q or RIGHT CLICK (-1): taken on the next update.
func step(dir: int) -> void:
	_step = dir

## Whether the feeds are up (out, on this floor's cameras or a crewmate's eyes chosen among them).
func active() -> bool:
	return out_at >= 0

## Tests and pictures: straight to camera `i` (index), as a key would.
func jump(i: int, now: int) -> void:
	if cams.is_empty():
		return
	index = clampi(i, 0, cams.size() - 1)
	_on_crew = false
	eyes_id = ""
	changed_at = now
	key_at = now

# --- this frame ------------------------------------------------------------------------------------------

## `out`: this player is out and the view may be used (client/main.gd decides, as for the crewmate's eyes). `s` the
## snapshot, `lock` LS1's last one up ("" for none), `now` this screen's ms, `shows` Callable(cam, at: Vector3,
## level: int) -> bool (sim/cameras.gd shows over this floor). After it: on_cam with eye, yaw, pitch and caption; or
## eyes_id, the crewmate whose eyes to look through (client/crew_watch.gd does that); or neither.
func update(out: bool, s: Dictionary, my_id: String, lock: String, now: int, shows: Callable) -> void:
	_blink(now)
	if not out or cams.is_empty():
		if index >= 0 or eyes_id != "":
			reset()
		return
	var crew := CrewWatch.targets(s.get("others", []), my_id)
	var rows := {}
	for o: Dictionary in s.get("others", []):
		rows[str(o["id"])] = o
	var n := cams.size()
	var dir := _step
	_step = 0
	if dir != 0:
		key_at = now
	locked = lock != "" and crew.has(lock)
	lock_id = lock if locked else ""
	if index < 0 and not _on_crew:
		# The first feed: the camera that sees where you fell, the nearest one, else the first.
		out_at = now
		index = _first(s.get("me", {}), shows)
		changed_at = now
	if locked:
		var at := _feet(rows[lock])
		var lv := int((rows[lock] as Dictionary).get("level", 0))
		var seeing: Array[int] = []
		for i in n:
			if shows.call(cams[i], at, lv):
				seeing.append(i)
		_on_crew = false
		if seeing.is_empty():
			eyes_id = lock
			on_cam = false
		else:
			if not seeing.has(index):
				index = _nearest_of(seeing, at)
				changed_at = now
			elif dir != 0 and seeing.size() > 1:
				index = seeing[(seeing.find(index) + dir + seeing.size()) % seeing.size()]
				changed_at = now
			eyes_id = ""
			on_cam = true
	else:
		# The feeds: cameras 0..n-1, then the crewmates' eyes.
		var feeds := n + crew.size()
		var at_feed := index if not _on_crew else n + maxi(0, crew.find(eyes_id))
		if _on_crew and not crew.has(eyes_id):
			# The one watched went out or left: back to the cameras.
			_on_crew = false
			at_feed = clampi(index, 0, n - 1)
		if dir != 0:
			at_feed = (at_feed + dir + feeds) % feeds
			changed_at = now
		elif not _on_crew and now - changed_at >= CYCLE_MS and now - key_at >= HOLD_MS:
			at_feed = _next_busy(at_feed, s, crew, rows, shows)
			changed_at = now
			cycles += 1
		if at_feed < n:
			_on_crew = false
			index = at_feed
			eyes_id = ""
			on_cam = true
		else:
			_on_crew = true
			eyes_id = crew[at_feed - n]
			on_cam = false
	if on_cam:
		var c := cams[index]
		eye = c["pos"]
		yaw = float(c["yaw"])
		pitch = float(c["pitch"])
		caption = Cameras.caption(c, depth) + ("   THE LAST ONE UP" if locked else "   " + KEYS)
		_show_body(index)
	else:
		caption = ""
		_show_body(-1)

## The camera to start on: the one that shows `me` (nearest first), else the nearest on their level, else the first.
func _first(me: Dictionary, shows: Callable) -> int:
	if me.is_empty():
		return 0
	var at := _feet(me)
	var lv := int(me.get("level", 0))
	var best := -1
	var best_d := INF
	for i in cams.size():
		var d := (cams[i]["pos"] as Vector3).distance_to(at)
		if d < best_d and shows.call(cams[i], at, lv):
			best = i
			best_d = d
	if best >= 0:
		return best
	for i in cams.size():
		var d := (cams[i]["pos"] as Vector3).distance_to(at) + (0.0 if int(cams[i]["level"]) == lv else 1000.0)
		if d < best_d:
			best = i
			best_d = d
	return maxi(best, 0)

func _nearest_of(list: Array[int], at: Vector3) -> int:
	var best := list[0]
	for i in list:
		if (cams[i]["pos"] as Vector3).distance_to(at) < (cams[best]["pos"] as Vector3).distance_to(at):
			best = i
	return best

## The next camera after `from` (not `from` itself) that has a living crewmate in its picture, else simply the next.
func _next_busy(from: int, _s: Dictionary, crew: Array[String], rows: Dictionary, shows: Callable) -> int:
	var n := cams.size()
	for k in range(1, n):
		var i := (from + k) % n
		for id in crew:
			var o: Dictionary = rows[id]
			if shows.call(cams[i], _feet(o), int(o.get("level", 0))):
				return i
	return (from + 1) % n

static func _feet(o: Dictionary) -> Vector3:
	return Vector3(float(o.get("x", 0.0)), float(o.get("y", 0.0)), float(o.get("z", 0.0)))

func describe() -> Dictionary:
	return {"count": cams.size(), "onCam": on_cam, "index": index, "n": int(cams[index]["n"]) if on_cam else -1,
		"eyes": eyes_id, "locked": locked, "lockOn": lock_id, "caption": caption, "outAt": out_at, "cycles": cycles,
		"eye": [eye.x, eye.y, eye.z], "ward": _ward_seed >= 0,
		"cams": cams.map(func(c: Dictionary) -> Dictionary: return {"n": c["n"], "kind": c["kind"], "level": c["level"],
			"pos": [(c["pos"] as Vector3).x, (c["pos"] as Vector3).y, (c["pos"] as Vector3).z],
			"aim": [(c["aim"] as Vector3).x, (c["aim"] as Vector3).y, (c["aim"] as Vector3).z], "area": c["area"]})}

# --- the bodies -------------------------------------------------------------------------------------------

const BODY := Color(0.26, 0.26, 0.28)
const DARK := Color(0.07, 0.07, 0.08)
const LAMP := Color(1.0, 0.08, 0.05)
const LAMP_OFF := Color(0.18, 0.03, 0.03)
## The red lamp's glow while lit (emission only: it lights nothing in the room).
const LAMP_ON := 9.0
## The housing's length, and how far its back sits behind the lens point (metres): about half a metre, to be seen.
const LONG := 0.6
const BACK := 0.06

## Draws a camera body at each camera under a new node named `name` in `parent`; returns that node.
func draw(parent: Node3D, list: Array[Dictionary], name: String) -> Node3D:
	if parent == null:
		return null
	var root := Node3D.new()
	root.name = name
	parent.add_child(root)
	var paint := StandardMaterial3D.new()
	paint.albedo_color = BODY
	paint.roughness = 0.6
	var dark := StandardMaterial3D.new()
	dark.albedo_color = DARK
	dark.roughness = 0.35
	dark.metallic = 0.4
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.02, 0.025, 0.03)
	glass.roughness = 0.05
	glass.metallic_specular = 1.0
	_lamp_mat = StandardMaterial3D.new()
	# Unshaded: as red in the dark as in the light, and it lights nothing.
	_lamp_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_lamp_mat.albedo_color = LAMP
	_lamp_mat.emission_enabled = true
	_lamp_mat.emission = LAMP
	_lamp_mat.emission_energy_multiplier = LAMP_ON
	for c in list:
		root.add_child(_body(c, paint, dark, glass, _lamp_mat))
	return root

static func _box(size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.position = at
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

static func _body(c: Dictionary, paint: Material, dark: Material, glass: Material, lamp: Material) -> Node3D:
	var pos: Vector3 = c["pos"]
	var anchor: Vector3 = c["anchor"]
	var n := Node3D.new()
	n.name = "Cam%d" % int(c["n"])
	# The housing hangs in front of the lens point (its back just behind it), looking where the camera looks.
	var head := Node3D.new()
	head.name = "Head"
	head.position = pos
	head.rotation = Vector3(float(c["pitch"]), float(c["yaw"]), 0.0)
	n.add_child(head)
	# The short bracket, from the wall (or post) plate to the housing's back.
	var back := pos + head.basis * Vector3(0, 0.0, BACK)
	var arm := back - anchor
	if arm.length() > 0.02:
		var rod := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.022
		cyl.bottom_radius = 0.022
		cyl.height = arm.length()
		cyl.radial_segments = 8
		rod.mesh = cyl
		rod.material_override = dark
		rod.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		rod.position = (anchor + back) * 0.5
		var up := arm.normalized()
		var side := up.cross(Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
		rod.basis = Basis(side, up, side.cross(up)).orthonormalized()
		n.add_child(rod)
		var plate := _box(Vector3(0.16, 0.2, 0.025), anchor, dark)
		var out := Vector3(arm.x, 0, arm.z).normalized() if Vector2(arm.x, arm.z).length() > 0.01 else Vector3.FORWARD
		plate.rotation.y = atan2(out.x, out.z)
		n.add_child(plate)
	# Housing, sun hood, a knuckle under it, the lens ring and glass at the front, the red lamp beside the lens.
	var mid := BACK - LONG * 0.5
	head.add_child(_box(Vector3(0.28, 0.24, LONG), Vector3(0, 0, mid), paint))
	head.add_child(_box(Vector3(0.34, 0.025, LONG + 0.1), Vector3(0, 0.135, mid - 0.05), paint))
	head.add_child(_box(Vector3(0.1, 0.08, 0.1), Vector3(0, -0.15, BACK - 0.1), dark))
	var front := BACK - LONG
	var ring := _box(Vector3(0.24, 0.2, 0.03), Vector3(0, 0, front - 0.01), dark)
	head.add_child(ring)
	var lens := MeshInstance3D.new()
	var lc := CylinderMesh.new()
	lc.top_radius = 0.075
	lc.bottom_radius = 0.08
	lc.height = 0.03
	lc.radial_segments = 16
	lens.mesh = lc
	lens.material_override = glass
	lens.rotation = Vector3(PI * 0.5, 0, 0)
	lens.position = Vector3(0, -0.005, front - 0.03)
	lens.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	head.add_child(lens)
	var dot := MeshInstance3D.new()
	var sp := SphereMesh.new()
	sp.radius = 0.05
	sp.height = 0.1
	sp.radial_segments = 10
	sp.rings = 5
	dot.mesh = sp
	dot.material_override = lamp
	dot.position = Vector3(0.1, 0.075, front - 0.04)
	dot.name = "Lamp"
	head.add_child(dot)
	return n

## The one watched through is hidden on this screen (its housing would fill the picture); the rest are shown.
func _show_body(i: int) -> void:
	var root := _ward_root if _ward_seed >= 0 else _plan_root
	if root == null or not is_instance_valid(root):
		return
	for k in root.get_child_count():
		(root.get_child(k) as Node3D).visible = k != i

## The red lamps blink together: on most of each second and a quarter.
func _blink(now: int) -> void:
	if _lamp_mat != null:
		var lit := now % 1250 < 900
		_lamp_mat.albedo_color = LAMP if lit else LAMP_OFF
		_lamp_mat.emission_energy_multiplier = LAMP_ON if lit else 0.05
