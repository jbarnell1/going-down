# The four-slot inventory on screen (docs/floors/skill-tree.md S1; North Star C7: "four squares at the bottom of the
# screen"). Everything here is drawn from the host's inv block (net/client.gd inventory()); nothing is predicted.
#   - Four squares, bottom centre, in the camcorder's pixel font: the item's short name (data/items.json) and, over
#     one, how many. The square in the hand has an amber frame and a notch over it, and its item's name is printed
#     beside the row ("IN HAND: A CARTON OF JUICE"), clear of the subtitles above it. The instrument is in the other hand and has no square.
#   - What F does here (main.gd asks prompt(); heal, the bunk, the lift, a dropped tape and a hide come first): at a
#     pickup "F  PICK UP JUICE"; facing a crewmate within the hand reach while holding something "F  GIVE JUICE TO BO".
#   - One line for 2.5 s when the host refuses something ("YOUR HANDS ARE FULL.") or a crewmate hands you something.
#   - The floor's pickups (cartons, badges and pinecones), drawn where they lie.
extends Control

const Inventory = preload("res://sim/inventory.gd")
const Settings = preload("res://sim/settings.gd")

const MESSAGE_MS := 2500
## Facing a crewmate for a hand-over: within this many degrees of where you look.
const GIVE_FACE_DEG := 50.0
const AMBER := Color("#ffd27a")
const PALE := Color("#f4f4ec")
## What a refusal says, by the host's why.
const REFUSED := {
	"full": "YOUR HANDS ARE FULL.",
	"theirFull": "THEIR HANDS ARE FULL.",
	"reach": "TOO FAR AWAY.",
	"empty": "NOTHING IN YOUR HAND.",
	"gone": "IT IS NOT THERE ANY MORE.",
	"busy": "NOT NOW.",
	"throw": "YOU CAN'T THROW A CONE HERE.",
	"throw_toy": "YOU CAN'T THROW A TOY HERE.",
	# The shop and the cabinet (S2, sim/run.gd _step_shop).
	"cabFull": "THE CABINET IS FULL.",
	"poor": "NOT ENOUGH CREDITS.",
	"window": "BUY AT SHOP WINDOW 1 OR 2.",
	"closed": "THE SHOP IS SHUT TILL TONIGHT.",
	"nobody": "NOBODY DOWN IN REACH. FACE THEM.",
	"noHeals": "NO HEALS LEFT ON THIS FLOOR.",
	"annexOnly": "MARKS ONLY STICK IN THE ANNEX.",
	"unusable": "THAT IS NOT SOMETHING YOU USE.",
}

## The host's block this frame (null: the run has no inventory, nothing is drawn).
var block: Variant = null
## This player's slots ([item, count] x4) and the slot in the hand.
var slots: Array = []
var sel := 0
## What F would do here: "take" (arg the pickup id), "give" (arg the crewmate id) or "" for nothing; its prompt.
var f_op := ""
var f_arg: Variant = null
var prompt := ""
## The one-line message and when it goes (engine ms).
var message := ""
var message_until := 0
## Tests and screenshots: slots to draw instead of the host's (a picture of a row nothing in the game can fill yet).
var demo_slots: Array = []
var demo_sel := -1
## Hidden behind the black cut, the end screen, the menu.
var hidden_now := false

## HUD1b (the screen plan, stage 1): the squares dim to IDLE_ALPHA after the fade's 4 s with nothing changed, and are
## full again on any change (an item, a count, the hand) or while Tab (DISPLAY) is held; IN HAND shows HELD_MS after a
## change, then fades. Only how visible they are changes, never what they say.
const HudFade = preload("res://client/hud_fade.gd")
const IDLE_ALPHA := 0.3
const HELD_MS := 2000
var display := false
var _fade := HudFade.new()

var _meshes := {}
var _last_spill := {}

## How visible the row of squares is at `now` (ms): IDLE_ALPHA at rest, 1 on change or Tab.
func row_alpha(now: int) -> float:
	return maxf(IDLE_ALPHA, _fade.see("row", str(drawn_slots()) + "|" + str(drawn_sel()), now, false, display))

## The IN HAND line's words ("" for none), and how visible it is at `now` (ms).
func held_text() -> String:
	var list := drawn_slots()
	var hand := drawn_sel()
	if hand >= 0 and hand < list.size() and int(list[hand][1]) > 0:
		return "IN HAND: " + Inventory.long_name(str(list[hand][0]))
	return ""

func held_alpha(now: int) -> float:
	var held := held_text()
	var a := _fade.see("held", held, now, false, display, HELD_MS)
	return a if held != "" else 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

func reset() -> void:
	_last_spill.clear()
	block = null
	slots = []
	sel = 0
	f_op = ""
	f_arg = null
	prompt = ""
	message = ""
	message_until = 0
	for id: int in _meshes:
		if is_instance_valid(_meshes[id]):
			(_meshes[id] as Node).queue_free()
	_meshes.clear()

## This frame: the host's block, who I am and where (snapshot "me"), the others (snapshot "others"), my yaw.
func update(inv: Variant, my_id: String, me: Dictionary, others: Array, yaw: float, tuning: Settings.Values) -> void:
	block = inv
	slots = []
	sel = 0
	f_op = ""
	f_arg = null
	prompt = ""
	if not inv is Dictionary:
		return
	for b: Dictionary in (inv as Dictionary)["bags"]:
		if str(b["playerId"]) == my_id:
			slots = (b["slots"] as Array).duplicate(true)
			sel = int(b["sel"])
	if slots.is_empty():
		for _k in Inventory.SLOTS:
			slots.append(["", 0])
	if me.is_empty() or str(me.get("status", "ok")) != "ok":
		return
	var mx := float(me["x"])
	var my := float(me["y"])
	var mz := float(me["z"])
	var ml := int(me["level"])
	# A pickup in reach: the nearest.
	var best := INF
	for p: Dictionary in (inv as Dictionary)["pickups"]:
		var at: Variant = p["at"]
		var ax: float = at.x if at is Object else float((at as Dictionary)["x"])
		var ay: float = at.y if at is Object else float((at as Dictionary)["y"])
		var az: float = at.z if at is Object else float((at as Dictionary)["z"])
		var al: int = at.level if at is Object else int((at as Dictionary)["level"])
		if al != ml:
			continue
		var d := Vector3(ax - mx, ay - my, az - mz).length()
		if d <= Inventory.PICKUP_REACH and d < best:
			best = d
			f_op = "take"
			f_arg = int(p["id"])
			prompt = "F  PICK UP %s" % Inventory.short_name(str(p["item"]))
	if f_op != "":
		return
	# Holding something, facing a crewmate on their feet within the hand reach: hand it over.
	if sel < slots.size() and int(slots[sel][1]) > 0:
		var reach := Inventory.hand_reach(tuning)
		var fx := -sin(yaw)
		var fz := -cos(yaw)
		var cos_max := cos(deg_to_rad(GIVE_FACE_DEG))
		var near := INF
		for o: Dictionary in others:
			if str(o.get("status", "ok")) != "ok" or not bool(o.get("active", true)) or int(o["level"]) != ml:
				continue
			var dx := float(o["x"]) - mx
			var dz := float(o["z"]) - mz
			var d := Vector3(dx, float(o["y"]) - my, dz).length()
			var flat := Vector2(dx, dz).length()
			if d > reach or (flat > 0.05 and (dx * fx + dz * fz) / flat < cos_max):
				continue
			if d < near:
				near = d
				f_op = "give"
				f_arg = str(o["id"])
				prompt = "F  GIVE %s TO %s" % [Inventory.short_name(str(slots[sel][0])), str(o.get("name", o["id"])).to_upper()]

## The host's answers this frame, each delivered once by PlayLink. A single fall can empty several slots.
func on_events(events: Array, my_id: String, names: Dictionary, now: int, sfx: Object) -> void:
	for e: Dictionary in events:
		var ty := str(e.get("type", ""))
		var who := str(e.get("playerId", ""))
		if ty == "invRefused" and who == my_id and e.get("op") != "skill":
			say(str(REFUSED.get(str(e.get("why", "")), "NOT NOW.")), now)
		elif ty == "searchFull" and who == my_id:
			var item := "BADGE" if e.get("item") == "badge" else "IT"
			say("YOUR HANDS ARE FULL. %s IS STILL IN THERE." % item, now)
		elif ty == "itemGiven":
			var recipient := str(e.get("to", ""))
			if recipient == my_id:
				say("%s GAVE YOU %s" % [str(names.get(who, "SOMEONE")).to_upper(), Inventory.long_name(str(e["item"]))], now)
			if sfx != null and (who == my_id or recipient == my_id):
				sfx.call("play", "item_handoff")
		elif ty == "itemTaken" and who == my_id and sfx != null:
			sfx.call("play", "item_pickup")
		elif ty == "itemDropped" and sfx != null:
			if e.get("why") == "down":
				# The host's event budget can split a spill across snapshots.
				var spill_time: float = float(e["t"])
				if _last_spill.get(who) == spill_time:
					continue
				_last_spill[who] = spill_time
			var at: Dictionary = e["at"]
			sfx.call("play_at", "item_drop", Vector3(float(at["x"]), float(at["y"]) + 0.1, float(at["z"])))

func say(text: String, now: int) -> void:
	message = text
	message_until = now + MESSAGE_MS

func message_now(now: int) -> String:
	return message if now < message_until else ""

static func cone_mesh() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var shape := CylinderMesh.new()
	shape.top_radius = 0.029
	shape.bottom_radius = 0.055
	shape.height = 0.135
	shape.radial_segments = 6
	mi.mesh = shape
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.22, 0.10)
	mat.emission_enabled = true
	mat.emission = Color(0.16, 0.078, 0.025)
	mat.emission_energy_multiplier = 0.28
	mi.material_override = mat
	return mi

## The floor's pickups as small things lying where they were dropped.
func show_pickups(root: Node3D) -> void:
	if root == null or not is_instance_valid(root):
		_meshes.clear()
		return
	var keep := {}
	if block is Dictionary:
		for p: Dictionary in (block as Dictionary)["pickups"]:
			var id := int(p["id"])
			keep[id] = true
			if _meshes.has(id) and is_instance_valid(_meshes[id]):
				continue
			var at: Variant = p["at"]
			var pos := Vector3(at.x, at.y, at.z) if at is Object else Vector3(float(at["x"]), float(at["y"]), float(at["z"]))
			var item := str(p["item"])
			var mi := cone_mesh() if item == "pinecone" else MeshInstance3D.new()
			var mat := mi.material_override as StandardMaterial3D if item == "pinecone" else StandardMaterial3D.new()
			if item == "juice":
				var bm := BoxMesh.new()
				bm.size = Vector3(0.07, 0.12, 0.05)
				mi.mesh = bm
				mat.albedo_color = Color(0.86, 0.62, 0.2)
				pos.y += 0.06
			elif item == "pinecone":
				pos.y += 0.068
			else:
				var cm := CylinderMesh.new()
				cm.top_radius = 0.04
				cm.bottom_radius = 0.04
				cm.height = 0.01
				mi.mesh = cm
				mat.albedo_color = Color(0.7, 0.66, 0.5)
				mat.metallic = 0.6
				pos.y += 0.006
			mat.emission_enabled = true
			mat.emission = mat.albedo_color * 0.25
			mi.material_override = mat
			mi.position = pos
			mi.rotation.y = float(id) * 1.3
			mi.name = "Pickup%d" % id
			root.add_child(mi)
			_meshes[id] = mi
	for id: int in _meshes.keys():
		if not keep.has(id):
			if is_instance_valid(_meshes[id]):
				(_meshes[id] as Node).queue_free()
			_meshes.erase(id)

## The slots drawn (the demo's when set).
func drawn_slots() -> Array:
	return demo_slots if not demo_slots.is_empty() else slots

func drawn_sel() -> int:
	return demo_sel if not demo_slots.is_empty() and demo_sel >= 0 else sel

func _process(_d: float) -> void:
	var want := get_parent_area_size() if get_parent() is Control else get_viewport_rect().size
	if size != want:
		position = Vector2.ZERO
		size = want
	queue_redraw()

func _draw() -> void:
	if hidden_now or (block == null and demo_slots.is_empty()):
		return
	var px := maxf(2.0, floor(size.y / 320.0))
	var list := drawn_slots()
	var hand := drawn_sel()
	var box := 18.0 * px
	var gap := 3.0 * px
	var total := Inventory.SLOTS * box + (Inventory.SLOTS - 1) * gap
	var x0 := floorf((size.x - total) * 0.5)
	var y0 := floorf(size.y - box - 3.0 * px)
	var now_ms := Time.get_ticks_msec()
	var ra := row_alpha(now_ms)
	var sh := Color(0, 0, 0, 0.55 * ra)
	for k in Inventory.SLOTS:
		var r := Rect2(Vector2(x0 + k * (box + gap), y0), Vector2(box, box))
		var on := k == hand
		draw_rect(r, Color(0.02, 0.02, 0.025, (0.72 if on else 0.5) * ra))
		draw_rect(r, Color(AMBER if on else Color(0.62, 0.64, 0.6, 0.8), (1.0 if on else 0.8) * ra), false, px * (2.0 if on else 1.0))
		# The key's number, top left.
		PixelFont.draw(self, str(k + 1), r.position + Vector2(2, 2) * px, px, Color(0.75, 0.76, 0.72, 0.8 * ra))
		var item := str(list[k][0]) if k < list.size() else ""
		var n := int(list[k][1]) if k < list.size() else 0
		if n > 0 and item != "":
			var label := Inventory.short_name(item)
			var lw := PixelFont.width(label) * px
			var sc := px if lw <= box - 4.0 * px else maxf(1.0, px * 0.5)
			lw = PixelFont.width(label) * sc
			PixelFont.draw_shadowed(self, label, Vector2(floorf(r.position.x + (box - lw) * 0.5), floorf(r.position.y + box * 0.5 - 3.0 * sc)), sc, Color(AMBER if on else PALE, ra), sh)
			if n > 1:
				var cnt := "x%d" % n
				PixelFont.draw_shadowed(self, cnt, r.position + Vector2(box - PixelFont.width(cnt) * px - 2.0 * px, box - 9.0 * px), px, Color(PALE, ra), sh)
		if on:
			# The notch over the square in the hand.
			var cx := r.position.x + box * 0.5
			draw_colored_polygon(PackedVector2Array([Vector2(cx - 3.0 * px, y0 - 4.0 * px), Vector2(cx + 3.0 * px, y0 - 4.0 * px), Vector2(cx, y0 - 1.0 * px)]), Color(AMBER, ra))
	# What is in the hand, over the row: for HELD_MS after a change (HUD1b), and on Tab.
	var held := held_text()
	var ha := held_alpha(now_ms)
	if held != "" and ha > 0.01:
		if str(list[hand][0]) == "pinecone":
			held += "  [MIDDLE MOUSE: THROW]"
		PixelFont.draw_shadowed(self, held, Vector2(x0 + total + 6.0 * px, floorf(y0 + box * 0.5 - 3.0 * px)), px, Color(PALE, ha), Color(0, 0, 0, 0.55 * ha))
	var line_y := y0 - 16.0 * px
	var msg := message_now(now_ms)
	if msg != "":
		var mw := PixelFont.width(msg) * px
		var mp := Vector2(floorf((size.x - mw) * 0.5), line_y)
		draw_rect(Rect2(mp - Vector2(4, 3) * px, Vector2(mw + 8 * px, 13 * px)), Color(0, 0, 0, 0.5))
		PixelFont.draw_shadowed(self, msg, mp, px, AMBER)

## Tests: what this screen shows.
func describe() -> Dictionary:
	return {"on": block != null, "slots": slots.duplicate(true), "sel": sel, "prompt": prompt, "fOp": f_op, "fArg": f_arg,
		"message": message_now(Time.get_ticks_msec()), "pickupsDrawn": _meshes.size(), "demo": not demo_slots.is_empty(),
		"inHand": Inventory.long_name(str(slots[sel][0])) if sel < slots.size() and int(slots[sel][1]) > 0 else ""}
