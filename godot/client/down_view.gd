# Down first, then out, on screen (North Star B6; T8a's rules, T8c). Everything here is the host's: the
# downs block of the newest snapshot (net/client.gd downs() and spots(): who is down, the host time they
# went down and the host time they are out unless healed, who holds F beside them since when, and this
# floor's red spots), counted against the host clock as this screen estimates it (play_link.gd "hostNow").
# Nothing is predicted: the timer is `until - hostNow`, the heal's bar `(hostNow - healFrom) / HEAL_TIME` (the host's own `healFor` when it sends one).
#  - Down (your own status "down"): the timer big and red at the top, "DOWN  7", with a bar that drains
#    over the run's own down time (until - at), and two lines: what can happen ("A CREWMATE CAN HOLD F
#    BESIDE YOU", or with nobody left on their feet "NOBODY IS LEFT TO HELP YOU UP") and what you can do
#    ("CRAWL: W A S D"). While a crewmate holds F beside you: "BOB IS HELPING YOU UP" and their hold's bar.
#    The view is on the floor (eye_height.gd DOWN) and the body crawls (play_link.gd).
#  - A crewmate down within reach (the rules' HEAL_REACH, a little inside it, on your level), you on your
#    feet: the prompt "HOLD F TO HELP" with the hold's bar. The bar is the host's hold: it fills only while
#    the host has you as their healer and you are holding F, and empties when you let go or step out of
#    reach, as the rules do (they start the count again).
#  - Out (your own status "out", with the down rule on): the screen goes dark: "OUT", "YOU REJOIN WHEN THE
#    CAR NEXT MOVES". (The cameras on F3 are a later task.)
#  - Red spots: one stain on the floor where each player who went out lay, for everyone, this floor only.
extends RefCounted

const Run = preload("res://sim/run.gd")

## A crewmate this close (metres, feet to feet, same level) can be helped: the rules' reach, a little
## inside it so the prompt never shows where the host would not count the hold.
const HELP_REACH := Run.HEAL_REACH - 0.05

# The HUD's words and bars this frame (see hud.gd).
var head := ""
var left := -1.0
var line := ""
var line2 := ""
var heal := -1.0
var out := false
var out_lines: Array = []
## The helper's prompt ("" for none), its bar (0..1, -1 for none) and whom it is for.
var prompt := ""
var fill := -1.0
var target := ""
## Seconds left on your own timer (-1 when you are not down), as shown.
var seconds := -1.0
## The host reports the Annex drag even when both bodies are stationary.
var dragged := false
var drag_yaw: Variant = null
var _drag_at := -1.0
var _drag_rear: Variant = null
var _drag_manual := false
## The red spots drawn (keys: player id and host time), and their root in the world.
var _spots := {}
var _root: Node3D = null

func reset() -> void:
	_clear_drag()
	head = ""
	left = -1.0
	line = ""
	line2 = ""
	heal = -1.0
	out = false
	out_lines = []
	prompt = ""
	fill = -1.0
	target = ""
	seconds = -1.0
	_spots = {}
	_root = null

## This frame. `s` the snapshot (play_link.gd), `my` this player's id, `names` by id, `holding` F held.
func update(s: Dictionary, my: String, names: Dictionary, holding: bool, place := "") -> void:
	head = ""
	left = -1.0
	line = ""
	line2 = ""
	heal = -1.0
	out = false
	out_lines = []
	prompt = ""
	fill = -1.0
	target = ""
	seconds = -1.0
	var block: Variant = s.get("downs")
	if not block is Dictionary:
		_clear_drag()
		return
	var downs: Array = (block as Dictionary)["down"]
	var hn := float(s.get("hostNow", 0.0))
	var me: Dictionary = s["me"]
	var status := str(me["status"])
	if status != "down":
		_clear_drag()
	if status == "out":
		out = true
		out_lines = ["OUT", "", "YOU REJOIN WHEN THE CAR NEXT MOVES"]
		return
	if status == "down":
		var d: Variant = _row(downs, my)
		if d == null:
			_clear_drag()
			return
		var dd: Dictionary = d
		_step_drag(dd, place)
		var until := float(dd["until"])
		var span := maxf(0.001, until - float(dd["at"]))
		seconds = maxf(0.0, until - hn)
		head = "DOWN  %d" % ceili(seconds)
		left = clampf(seconds / span, 0.0, 1.0)
		var healer := str(dd["healer"])
		if healer != "" and dd["healFrom"] != null:
			line = "%s IS HELPING YOU UP" % _name(names, healer)
			heal = clampf((hn - float(dd["healFrom"])) / float(dd.get("healFor", Run.HEAL_TIME)), 0.0, 1.0)
		elif _anyone_standing(s):
			line = "A CREWMATE CAN HOLD F BESIDE YOU"
		else:
			line = "NOBODY IS LEFT TO HELP YOU UP"
		line2 = "BEING DRAGGED" if dragged else "CRAWL: W A S D"
		return
	if status != "ok":
		return
	# On your feet: a downed crewmate in reach, the nearest.
	var best := HELP_REACH
	var who: Dictionary = {}
	for o: Dictionary in s.get("others", []):
		if str(o["status"]) != "down" or int(o["level"]) != int(me["level"]):
			continue
		var dist := Vector2(float(o["x"]) - float(me["x"]), float(o["z"]) - float(me["z"])).length()
		if dist <= best:
			best = dist
			who = o
	if who.is_empty():
		return
	target = str(who["id"])
	var row: Variant = _row(downs, target)
	if row == null:
		return
	var rd: Dictionary = row
	var healer := str(rd["healer"])
	if healer != "" and healer != my:
		prompt = "%s IS HELPING" % _name(names, healer)
		return
	prompt = "HOLD F TO HELP"
	fill = 0.0
	if holding and healer == my and rd["healFrom"] != null:
		fill = clampf((hn - float(rd["healFrom"])) / float(rd.get("healFor", Run.HEAL_TIME)), 0.0, 1.0)

func _clear_drag() -> void:
	dragged = false
	drag_yaw = null
	_drag_at = -1.0
	_drag_rear = null
	_drag_manual = false

func keep_drag_look() -> void:
	if _drag_at >= 0.0:
		_drag_manual = true
		drag_yaw = null

func _step_drag(down: Dictionary, place: String) -> void:
	var drag: Variant = down.get("drag")
	if place != "annex" or down.get("by") != "catch" or not drag is Dictionary:
		_clear_drag()
		return
	var at := float(down["at"])
	if _drag_at != at:
		_clear_drag()
		_drag_at = at
	dragged = true
	var rear: Variant = drag["rear"]
	if rear == null:
		return
	if _drag_rear == null or absf(angle_difference(float(_drag_rear), float(rear))) > PI / 3.0:
		_drag_rear = rear
		if not _drag_manual:
			drag_yaw = rear


static func _row(downs: Array, id: String) -> Variant:
	for d: Dictionary in downs:
		if str(d["id"]) == id:
			return d
	return null

static func _name(names: Dictionary, id: String) -> String:
	return str(names.get(id, id)).to_upper()

## Whether any crewmate is still on their feet (one who could come and help).
static func _anyone_standing(s: Dictionary) -> bool:
	for o: Dictionary in s.get("others", []):
		if str(o["status"]) == "ok":
			return true
	return false

# --- the red spots --------------------------------------------------------------------------------

## Draws this floor's red spots under `root` (a node in the world, rebuilt with each floor): one stain per
## spot in the host's list, added once, removed when the host no longer has it.
func show_spots(root: Node3D, spots: Array) -> void:
	if root != _root:
		_root = root
		_spots = {}
	if root == null:
		return
	var want := {}
	for sp: Dictionary in spots:
		var key := "%s@%s" % [str(sp["playerId"]), str(sp["t"])]
		want[key] = true
		if not _spots.has(key):
			var n := _stain(key)
			n.position = Vector3(float(sp["x"]), float(sp["y"]) + 0.012, float(sp["z"]))
			root.add_child(n)
			_spots[key] = n
	for key: String in _spots.keys():
		if not want.has(key):
			(_spots[key] as Node).queue_free()
			_spots.erase(key)

## A stain: a dark red pool and a few splashes round it, laid out from the key (the same on every screen).
static func _stain(key: String) -> Node3D:
	var n := Node3D.new()
	n.name = "RedSpot"
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.01, 0.015)
	mat.roughness = 0.2
	mat.metallic_specular = 0.8
	# A little of its own light, so it reads in the dark and under the emergency lights.
	mat.emission_enabled = true
	mat.emission = Color(0.45, 0.02, 0.02)
	mat.emission_energy_multiplier = 0.2
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key)
	# The pool: a few overlapping ovals, flattened and turned, so its edge is uneven.
	var blobs: Array = []
	for i in 4:
		var a := rng.randf() * TAU
		var r := 0.0 if i == 0 else rng.randf_range(0.12, 0.26)
		blobs.append([cos(a) * r, sin(a) * r, rng.randf_range(0.2, 0.34), rng.randf_range(0.55, 1.0), rng.randf() * PI])
	# Drops and a smear thrown out from it.
	for i in 9:
		var a := rng.randf() * TAU
		var r := rng.randf_range(0.42, 0.85)
		blobs.append([cos(a) * r, sin(a) * r, rng.randf_range(0.025, 0.08), rng.randf_range(0.4, 1.0), a])
	for b: Array in blobs:
		var mi := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = float(b[2])
		cyl.bottom_radius = float(b[2])
		cyl.height = 0.004
		cyl.radial_segments = 18
		cyl.rings = 1
		mi.mesh = cyl
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(float(b[0]), 0.0, float(b[1]))
		mi.rotation = Vector3(0.0, float(b[4]), 0.0)
		mi.scale = Vector3(1.0, 1.0, float(b[3]))
		n.add_child(mi)
	return n

## The spots drawn on this screen: [[x, y, z], ...] (tests).
func spots_drawn() -> Array:
	var out_list: Array = []
	for key: String in _spots:
		var n: Node3D = _spots[key]
		if is_instance_valid(n):
			out_list.append([n.position.x, n.position.y, n.position.z])
	return out_list

func describe() -> Dictionary:
	return {"head": head, "left": left, "seconds": seconds, "line": line, "line2": line2, "heal": heal, "out": out, "outLines": out_lines,
		"prompt": prompt, "fill": fill, "target": target, "spots": spots_drawn(), "dragged": dragged}
