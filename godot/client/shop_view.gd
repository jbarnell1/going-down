# The shop on screen, and what its items do on screen (S2, tracker T28; docs/floors/skill-tree.md section 5; North
# Star F1: "A shop item takes a slot, is used up, and can be dropped or handed over"). Drawn from the host's shop and
# inv blocks and its events; nothing is predicted.
#   - F at shop window 1 or 2 (Prison.SHOP_WINDOWS) opens the card: each item with its price in credits (the host's
#     shop.price.<item>, printed before you commit), what it does, your credits, and BUY. 1 to 6 or a click picks a
#     row; ENTER, SPACE or a click on BUY asks the host to buy it. A row you cannot afford is dim. F or ESC closes it.
#     The host's refusal is the inventory's one line ("NOT ENOUGH CREDITS.", "YOUR HANDS ARE FULL.").
#   - The items in the world: a glow stick lying lit (a green light on every screen until the host's time runs out), a
#     wind-up toy (it shakes while it rattles; the rattle's sound is the owner's to make: SOUND_TOY is the hook, silent
#     until there is a recording), the flash (your own screen white for Shop.FLASH_WHITE_SECONDS, the dark ahead lit
#     for Shop.FLASH_SECONDS), and speed juice's seconds left under the squares.
extends Control

const Inventory = preload("res://sim/inventory.gd")
const Shop = preload("res://sim/shop.gd")
const Settings = preload("res://sim/settings.gd")

const AMBER := Color("#ffd27a")
const PALE := Color("#f4f4ec")
const DIM := Color(0.62, 0.64, 0.6, 0.8)
const PANEL := Color(0.03, 0.035, 0.03, 0.9)
const GLOW := Color(0.45, 1.0, 0.35)
## The sound hooks for the owner's recordings to come (docs/ASSETS-TO-GET.md). Nothing plays until sfx.gd has them.
const SOUND_TOY := "toy_rattle"
const SOUND_GLOW := "glow_snap"
const SOUND_FLASH := "flashbulb"
const KEYS := "1-6 PICK   ENTER BUY   F CLOSE"

var open := false
var sel := 0
## The host's numbers this frame: my credits, the prices in force, whether the shop is shut (the morning).
var credits := 0
var prices: Array[int] = []
var shut := false
## The flash on my screen: engine ms it began (-1 for none).
var flash_at := -1
## Speed juice: seconds left by the host clock (-1 for none).
var juice_left := -1.0
var _rows: Array = []
var _buy_rect := Rect2()
var _glows := {}
var _toys := {}
var _flash_light: SpotLight3D

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	for item in Shop.ITEMS:
		prices.append(Shop.base_price(item))

func is_open() -> bool:
	return open

func show_card() -> void:
	open = true

func close() -> void:
	open = false

## This frame: the host's shop block, who I am, the tuning in force, the host clock as estimated here.
func update(shop: Variant, my_id: String, tuning: Settings.Values, host_now: float) -> void:
	credits = 0
	shut = false
	juice_left = -1.0
	prices = []
	for item in Shop.ITEMS:
		prices.append(Shop.price(tuning, item))
	if not shop is Dictionary:
		return
	var sb: Dictionary = shop
	for r: Dictionary in sb["credits"]:
		if str(r["playerId"]) == my_id:
			credits = int(r["credits"])
	shut = float(sb["wake"]) >= 0.0
	for r: Dictionary in sb["timers"]:
		if str(r["playerId"]) == my_id and float(r["juice"]) > host_now:
			juice_left = float(r["juice"]) - host_now

## A key while the card is open: ["buy", index], ["close", null], ["pick", null], or [] when it is not the card's.
func key(k: InputEventKey) -> Array:
	match k.physical_keycode:
		KEY_F, KEY_ESCAPE:
			return ["close", null]
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			return ["buy", sel]
		KEY_UP, KEY_W:
			sel = posmod(sel - 1, Shop.ITEMS.size())
			return ["pick", null]
		KEY_DOWN, KEY_S:
			sel = posmod(sel + 1, Shop.ITEMS.size())
			return ["pick", null]
	var n := k.physical_keycode - KEY_1
	if n >= 0 and n < Shop.ITEMS.size():
		sel = n
		return ["pick", null]
	return []

## A click: a row picks it, BUY buys the picked one. ["buy", index], ["pick", null] or [].
func click(pos: Vector2) -> Array:
	if _buy_rect.has_point(pos):
		return ["buy", sel]
	for k in _rows.size():
		if (_rows[k] as Rect2).has_point(pos):
			sel = k
			return ["pick", null]
	return []

## The host's events this frame: my flash.
func on_events(events: Array, my_id: String, now: int) -> void:
	for e: Dictionary in events:
		if str(e.get("type", "")) == "itemUsed" and str(e.get("playerId", "")) == my_id and str(e.get("item", "")) == "flash":
			flash_at = now

## The flash's white on my screen now (0 to 1).
func white(now: int) -> float:
	if flash_at < 0:
		return 0.0
	var a := float(now - flash_at) / (Shop.FLASH_WHITE_SECONDS * 1000.0)
	return 0.0 if a >= 1.0 else 1.0 - a * a

## The items in the world: glow sticks and toys under `root`, the flash's light on `cam`. `host_now` is the host clock.
func show_world(root: Node3D, cam: Camera3D, shop: Variant, host_now: float, now: int) -> void:
	var keep_g := {}
	var keep_t := {}
	if root != null and is_instance_valid(root) and shop is Dictionary:
		for g: Dictionary in (shop as Dictionary)["glows"]:
			var id := int(g["id"])
			if float(g["until"]) <= host_now:
				continue
			keep_g[id] = true
			if not (_glows.has(id) and is_instance_valid(_glows[id])):
				_glows[id] = _glow_node(_pos(g["at"]), id)
				root.add_child(_glows[id])
		for g: Dictionary in (shop as Dictionary)["toys"]:
			var id := int(g["id"])
			keep_t[id] = true
			if not (_toys.has(id) and is_instance_valid(_toys[id])):
				_toys[id] = _toy_node(_pos(g["at"]), id)
				root.add_child(_toys[id])
			var rattling := host_now >= float(g["start"]) and host_now < float(g["end"])
			(_toys[id] as Node3D).rotation.y = float(id) * 1.1 + (sin(now * 0.06) * 0.25 if rattling else 0.0)
	for id: int in _glows.keys():
		if not keep_g.has(id):
			if is_instance_valid(_glows[id]):
				(_glows[id] as Node).queue_free()
			_glows.erase(id)
	for id: int in _toys.keys():
		if not keep_t.has(id):
			if is_instance_valid(_toys[id]):
				(_toys[id] as Node).queue_free()
			_toys.erase(id)
	# The flash: the dark ahead lit for Shop.FLASH_SECONDS, on this screen only.
	if cam != null and is_instance_valid(cam):
		if _flash_light == null or not is_instance_valid(_flash_light):
			_flash_light = SpotLight3D.new()
			_flash_light.name = "Flashbulb"
			_flash_light.light_color = Color(1.0, 0.98, 0.92)
			_flash_light.spot_range = 22.0
			_flash_light.spot_angle = 50.0
			_flash_light.light_energy = 0.0
			cam.add_child(_flash_light)
		var lit := flash_at >= 0 and now - flash_at < int(Shop.FLASH_SECONDS * 1000.0)
		_flash_light.light_energy = 9.0 if lit else 0.0
		_flash_light.visible = lit

static func _pos(at: Variant) -> Vector3:
	return Vector3(at.x, at.y, at.z) if at is Object else Vector3(float(at["x"]), float(at["y"]), float(at["z"]))

func _glow_node(pos: Vector3, id: int) -> Node3D:
	var n := Node3D.new()
	n.name = "GlowStick%d" % id
	n.position = pos
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.012
	cm.bottom_radius = 0.012
	cm.height = 0.16
	mi.mesh = cm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = GLOW
	mat.emission_enabled = true
	mat.emission = GLOW
	mat.emission_energy_multiplier = 4.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	mi.rotation = Vector3(0, float(id) * 1.3, PI * 0.5)
	mi.position = Vector3(0, 0.015, 0)
	n.add_child(mi)
	var o := OmniLight3D.new()
	o.light_color = GLOW
	o.light_energy = 1.6
	o.omni_range = 5.5
	o.omni_attenuation = 1.2
	o.position = Vector3(0, 0.25, 0)
	n.add_child(o)
	return n

func _toy_node(pos: Vector3, id: int) -> Node3D:
	var n := Node3D.new()
	n.name = "WindUpToy%d" % id
	n.position = pos
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.12, 0.09, 0.08)
	body.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.72, 0.18, 0.12)
	mat.metallic = 0.5
	body.material_override = mat
	body.position = Vector3(0, 0.045, 0)
	n.add_child(body)
	var key := MeshInstance3D.new()
	var km := CylinderMesh.new()
	km.top_radius = 0.008
	km.bottom_radius = 0.008
	km.height = 0.06
	key.mesh = km
	var km2 := StandardMaterial3D.new()
	km2.albedo_color = Color(0.8, 0.7, 0.4)
	km2.metallic = 0.8
	key.material_override = km2
	key.rotation = Vector3(0, 0, PI * 0.5)
	key.position = Vector3(0.08, 0.05, 0)
	n.add_child(key)
	return n

func _process(_d: float) -> void:
	var want := get_parent_area_size() if get_parent() is Control else get_viewport_rect().size
	if size != want:
		position = Vector2.ZERO
		size = want
	queue_redraw()

func _draw() -> void:
	var now := Time.get_ticks_msec()
	var px := maxf(2.0, floor(size.y / 320.0))
	var wh := white(now)
	if wh > 0.0:
		draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, wh))
	if juice_left >= 0.0:
		var line := "SPEED JUICE  %d" % ceili(juice_left)
		var lw := PixelFont.width(line) * px
		PixelFont.draw_shadowed(self, line, Vector2(floorf((size.x - lw) * 0.5), floorf(size.y - 44.0 * px)), px, AMBER)
	_rows = []
	_buy_rect = Rect2()
	if not open:
		return
	var w := 230.0 * px
	var row_h := 10.0 * px
	var h := 34.0 * px + Shop.ITEMS.size() * row_h + 30.0 * px
	var p0 := Vector2(floorf((size.x - w) * 0.5), floorf((size.y - h) * 0.4))
	draw_rect(Rect2(p0, Vector2(w, h)), PANEL)
	draw_rect(Rect2(p0, Vector2(w, h)), AMBER, false, px)
	PixelFont.draw_shadowed(self, "THE SHOP", p0 + Vector2(6, 5) * px, px, AMBER)
	var bal := "YOUR CREDITS %d" % credits
	PixelFont.draw_shadowed(self, bal, Vector2(p0.x + w - PixelFont.width(bal) * px - 6.0 * px, p0.y + 5.0 * px), px, PALE)
	PixelFont.draw(self, "ONE GOES IN YOUR HANDS. KEEP IT IN YOUR CABINET OVERNIGHT.", p0 + Vector2(6, 15) * px, px, DIM)
	var y := p0.y + 26.0 * px
	for k in Shop.ITEMS.size():
		var item: String = Shop.ITEMS[k]
		var r := Rect2(Vector2(p0.x + 3.0 * px, y - 2.0 * px), Vector2(w - 6.0 * px, row_h))
		_rows.append(r)
		var price: int = prices[k] if k < prices.size() else Shop.base_price(item)
		var can := price <= credits and not shut
		if k == sel:
			draw_rect(r, Color(0.35, 0.28, 0.08, 0.55))
			draw_rect(r, AMBER, false, px)
		var ink := (AMBER if k == sel else PALE) if can else DIM
		PixelFont.draw(self, "%d" % (k + 1), Vector2(p0.x + 6.0 * px, y), px, DIM)
		PixelFont.draw(self, Inventory.long_name(item), Vector2(p0.x + 16.0 * px, y), px, ink)
		var pt := "%d" % price
		PixelFont.draw(self, pt, Vector2(p0.x + 98.0 * px - PixelFont.width(pt) * px, y), px, ink)
		PixelFont.draw(self, str(Inventory.item_row(item).get("shop", "")), Vector2(p0.x + 104.0 * px, y), maxf(1.0, px * 0.5), DIM if not can else PALE)
		y += row_h
	var picked: String = Shop.ITEMS[sel]
	var bp: int = prices[sel] if sel < prices.size() else 0
	var label := "SHUT TILL TONIGHT" if shut else ("BUY %s  %d" % [Inventory.short_name(picked), bp])
	var bw := PixelFont.width(label) * px + 12.0 * px
	_buy_rect = Rect2(Vector2(p0.x + 6.0 * px, y + 3.0 * px), Vector2(bw, 11.0 * px))
	var ok := bp <= credits and not shut
	draw_rect(_buy_rect, Color(0.55, 0.4, 0.1, 0.85) if ok else Color(0.2, 0.2, 0.2, 0.7))
	draw_rect(_buy_rect, AMBER if ok else DIM, false, px)
	PixelFont.draw_shadowed(self, label, _buy_rect.position + Vector2(6, 2) * px, px, PALE if ok else DIM)
	PixelFont.draw(self, KEYS, Vector2(p0.x + w - PixelFont.width(KEYS) * px - 6.0 * px, y + 5.0 * px), px, DIM)

## Tests: what this card and the world show.
func describe() -> Dictionary:
	return {"open": open, "sel": sel, "credits": credits, "prices": prices.duplicate(), "shut": shut, "glowsDrawn": _glows.size(),
		"toysDrawn": _toys.size(), "white": white(Time.get_ticks_msec()), "flashLit": _flash_light != null and is_instance_valid(_flash_light) and _flash_light.visible,
		"juiceLeft": juice_left}
