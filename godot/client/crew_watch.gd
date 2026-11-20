# DV1: out, you see through a crewmate's eyes, on every floor (the owner, 20 Nov: "Yeah downed players should see
# through teammates eyes"; North Star B6 and F3 send an out player to the cameras, which this stands in for).
# Client-side only, from what every snapshot already carries: each crewmate's interpolated feet, yaw, pitch, gait and
# status (client/play_link.gd `others`, from net/protocol.gd's player rows). Nothing here reaches the host.
#  - Out means the run has you waiting for the car: "out" (down and not healed in time), "caught" (a run without the
#    down rule: caught is the end of your floor), "leftBehind" (left out by the car, FD4). A player who is "down"
#    and can still be healed is not out: they keep their timer, their crawl and the floor view (client/down_view.gd).
#  - Whom you can watch: a crewmate still in it ("ok", or "down" and still to be healed), connected, in the run's
#    player order. The first is the first in that order; LEFT CLICK or E moves to the next; when the one you watch
#    goes out (or leaves), the view moves on by itself to the next after them.
#  - The camera sits at their eyes (their feet plus the eye height their status and gait give: client/eye_height.gd)
#    and looks where they look. The scene's camera is the 3D listener (client/sfx.gd hears from it), so you hear
#    the floor from where they are.
#  - With nobody left to watch, nothing changes: the out screen as before.
# On the Hanging Ward played as a normal level, a player on the Ward's caught list counts as out too (after the
# Ward's own WATCH_DELAY, as its old watching camera did), and caught crewmates are not watched. The old swapped-in
# Ward scene keeps its own camera (client/ward/view.gd). The Playroom's party table seats a taken player at it:
# client/main.gd does not use this view there.
extends RefCounted

const EyeHeight = preload("res://client/eye_height.gd")

## The player statuses that mean the run has you waiting for the car.
const OUT_STATES: Array[String] = ["out", "caught", "leftBehind"]
## A crewmate in these can be watched.
const WATCHABLE: Array[String] = ["ok", "down"]

var watching := false
var watch_id := ""
## Where the camera goes and where it looks, this frame (valid while watching).
var eye := Vector3.ZERO
var yaw := 0.0
var pitch := 0.0
## The caption under the picture, and the out screen's words in one line above it.
var caption := ""
var note := ""
## The ids that could be watched last frame, in order (for the next one and the hand-over).
var _order: Array[String] = []
var _next := false

## Whether a snapshot's own player is out (see the file's head).
static func is_out(s: Dictionary) -> bool:
	var me: Variant = s.get("me")
	return me is Dictionary and OUT_STATES.has(str((me as Dictionary).get("status", "")))

## The crewmates that can be watched in a snapshot's `others`, in the run's player order.
static func targets(others: Array, my_id: String) -> Array[String]:
	var rows: Array = []
	for o: Dictionary in others:
		var id := str(o["id"])
		if id == my_id or not bool(o.get("active", true)) or not WATCHABLE.has(str(o["status"])):
			continue
		rows.append([int(o.get("index", 0)), id])
	rows.sort()
	var out: Array[String] = []
	for r: Array in rows:
		out.append(str(r[1]))
	return out

static func watch_line(name: String) -> String:
	return "WATCHING THROUGH %s'S EYES   LEFT CLICK OR E: NEXT" % name.to_upper()

## LEFT CLICK or E while watching: the next crewmate (taken on the next update).
func next() -> void:
	if watching:
		_next = true

## The entry points for other code (WC1's web cocoon on the Ward, or any floor's own out scene):
##  - watch_crewmate(): look through a crewmate's eyes from the next frame on, whatever the run's status says (for a
##    player the rules hold but do not mark out: the Ward's web), until stop_watching().
##  - stop_watching(): back to the player's own view now (cut free); the run's own out states still watch.
##  - defer_watching(): not now, even out (a floor's own camera sequence is playing); watch_crewmate() or
##    stop_watching() ends it.
## client/main.gd has the same three names and passes them here.
var asked := false
var deferred := false

func watch_crewmate() -> void:
	asked = true
	deferred = false

func stop_watching() -> void:
	asked = false
	deferred = false
	reset()

func defer_watching() -> void:
	asked = false
	deferred = true
	reset()

## The view's state this frame (not the entry points' asks).
func reset() -> void:
	watching = false
	watch_id = ""
	caption = ""
	note = ""
	_order = []
	_next = false

## Everything, the asks too (a new run).
func clear() -> void:
	asked = false
	deferred = false
	reset()

## This frame. `s` the snapshot (play_link.gd), `allowed` false where this view is not used (the party table, the
## catch's own scene, the end), `out_lines` the out screen's words today (joined into `note`). `also_out`: out by a
## floor's own rule the run's status does not show (the Ward's caught list); `exclude`: crewmates held the same way,
## not watched.
func update(s: Dictionary, my_id: String, names: Dictionary, allowed: bool, out_lines: Array = [], also_out := false, exclude: Array = []) -> void:
	if not allowed or deferred or not (asked or also_out or is_out(s)):
		reset()
		return
	var list := targets(s.get("others", []), my_id)
	for id: Variant in exclude:
		list.erase(str(id))
	var pick := watch_id
	if pick == "" or not list.has(pick):
		pick = ""
		# The one watched went out or left: the next after them in the order they had.
		var at := _order.find(watch_id)
		if at >= 0:
			for k in range(1, _order.size() + 1):
				var cand := _order[(at + k) % _order.size()]
				if list.has(cand):
					pick = cand
					break
		if pick == "" and not list.is_empty():
			pick = list[0]
	elif _next and list.size() > 1:
		pick = list[(list.find(pick) + 1) % list.size()]
	_next = false
	_order = list
	watch_id = pick
	if pick == "":
		watching = false
		caption = ""
		note = ""
		return
	for o: Dictionary in s.get("others", []):
		if str(o["id"]) == pick:
			var h := EyeHeight.target(str(o["status"]), str(o.get("gait", "walk")))
			eye = Vector3(float(o["x"]), float(o["y"]) + h, float(o["z"]))
			yaw = float(o["yaw"])
			pitch = float(o.get("pitch", 0.0))
			break
	watching = true
	caption = watch_line(str(names.get(pick, pick)))
	var words: Array[String] = []
	for l: Variant in out_lines:
		if str(l) != "":
			words.append(str(l))
	note = "   ".join(words)

func describe() -> Dictionary:
	return {"watching": watching, "id": watch_id, "eye": [eye.x, eye.y, eye.z], "yaw": yaw, "pitch": pitch,
		"caption": caption, "note": note}
