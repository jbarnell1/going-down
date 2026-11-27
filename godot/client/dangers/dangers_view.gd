# Dangers (DG0) on screen: the base. client/main.gd makes one per floor that has a "dangers" block (net/protocol.gd
# "dg"; sim/dangers.gd block) and calls update() every frame and on_events() with the host's events. It makes one
# view per record (client/dangers/registry.gd), tells each its changes and events, shows the prompts kinds ask for,
# whites out a blinded player's own screen and staggers a stumbling one's camera (shake()). Everything here is the
# host's: times are host times, counted against the screen's estimate of the host clock.
extends Node3D

const Registry = preload("res://client/dangers/registry.gd")

## Set by client/main.gd each frame: the local player's id and whether the lift's blink or blackout darkens the floor.
var me := ""
var blink_dark := false
## The block as last seen, and the host time now.
var block: Dictionary = {}
var ht := 0.0
## The prompt for the local player this frame ("" for none), from a kind's ask.prompt.
var prompt := ""
var _ctx: Dictionary = {}
var _views := {}
var _recs := {}
var _white: ColorRect = null

func setup(ctx: Dictionary) -> void:
	_ctx = ctx
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	_white = ColorRect.new()
	_white.color = Color(1, 1, 1, 0)
	_white.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_white.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_white)

## One frame: the newest block (or null), the host time now, the local player's feet (or null) and the frame's delta.
func update(b: Variant, host_now: float, my_feet: Variant, delta: float) -> void:
	ht = host_now
	block = b if b is Dictionary else {}
	var seen := {}
	for r: Dictionary in block.get("r", []):
		var id := int(r["id"])
		seen[id] = true
		var v: Node = _views.get(id)
		if v == null and not _recs.has(id):
			var script := Registry.script_of(StringName(str(r["kind"])))
			_recs[id] = r
			if script == null:
				continue
			v = script.new()
			v.set("base", self)
			v.set("rec_id", id)
			v.set("kind", StringName(str(r["kind"])))
			add_child(v)
			(v as Node3D).position = Vector3(float(r["x"]), float(r["y"]), float(r["z"]))
			(v as Node3D).rotation.y = float(r["yaw"])
			_views[id] = v
			v.call("build", r, _ctx)
			continue
		var before: Dictionary = _recs.get(id, {})
		if v != null and (str(before.get("state")) != str(r["state"]) or float(before.get("since", 0.0)) != float(r["since"]) or before.get("n") != r["n"]):
			v.call("changed", r, before, ht)
		_recs[id] = r
	for id: int in _views.keys():
		if not seen.has(id) and block.has("r"):
			pass  # a record never disappears mid-floor; the next floor makes a new base
	for id: int in _views:
		if seen.has(id):
			(_views[id] as Node).call("frame", _recs[id], ht, delta)
	prompt = ""
	if my_feet is Vector3:
		for p: Array in block.get("prompts", []):
			var r: Variant = _recs.get(int(p[0]))
			if r is Dictionary and Vector3(float(r["x"]), float(r["y"]), float(r["z"])).distance_to(my_feet) <= float(p[2]):
				prompt = str(p[1])
				break
	if _white != null:
		var f: Variant = fx_of(me)
		var a := 0.0
		if f is Array and str(f[1]) == "blind":
			a = clampf((float(f[2]) - ht) / 0.6, 0.0, 0.92)
		_white.color.a = a

## The host's events: each danger event goes to its record's view.
func on_events(events: Array) -> void:
	for e: Dictionary in events:
		var ty := str(e.get("type", ""))
		if not ty.begins_with("danger") or not e.has("id"):
			continue
		var v: Node = _views.get(int(e["id"]))
		if v != null:
			v.call("event", e, ht)

## A player's running effect [id, kind, until] or null.
func fx_of(id: String) -> Variant:
	for f: Array in block.get("fx", []):
		if str(f[0]) == id and float(f[2]) > ht:
			return f
	return null

## A player's pin [id, style, x, y, z] or null.
func pin_of(id: String) -> Variant:
	for p: Array in block.get("pins", []):
		if str(p[0]) == id:
			return p
	return null

## The camera's stagger (radians of roll) for the local player's stumble, 0 otherwise.
func shake() -> float:
	var f: Variant = fx_of(me)
	if not f is Array or str(f[1]) != "stumble":
		return 0.0
	var left := float(f[2]) - ht
	return sin(left * 18.0) * 0.06 * clampf(left, 0.0, 1.0)

## Whether the room's light is on at `at` now (see kind_view.gd lit()).
func lit(at: Vector3) -> bool:
	if blink_dark:
		return false
	for r: Array in block.get("dark", []):
		if ht >= float(r[6]) and ht < float(r[5]) and at.x >= float(r[1]) and at.x <= float(r[3]) and at.z >= float(r[2]) and at.z <= float(r[4]):
			if int(r[0]) == (1 if at.y > 1.6 else 0):
				return false
	return true

func my_id() -> String:
	return me

## The test channel: the records as this screen has them.
func describe() -> Array:
	var out: Array = []
	for r: Dictionary in block.get("r", []):
		out.append(r)
	return out
