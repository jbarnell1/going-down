# The cabinet in your cell, on screen (S2b, tracker T29; docs/floors/skill-tree.md section 2b; North Star G1: "Only items
# in your cabinet when you sleep, or when the game is shut, are kept; everything else is cleared overnight").
# Drawn from the host's shop and inv blocks (net/client.gd shop(), inventory()); nothing is predicted.
#   - F at your own cabinet (beside your bunk: sim/shop.gd cabinet_cell) opens a card over the game: your four slots
#     on the left, the cabinet's slots on the right (cabinet.slots, 6 unless the host says 4 to 8).
#   - 1 to 4 put that slot of yours in; SHIFT and 1 to 8 take that cabinet slot out; a click on a square does the same.
#     F or ESC closes it, and so does walking away. The host decides every move (main.gd sends it as a request).
#   - One line under the card says what the night does.
extends Control

const Inventory = preload("res://sim/inventory.gd")
const Shop = preload("res://sim/shop.gd")
const Settings = preload("res://sim/settings.gd")

const AMBER := Color("#ffd27a")
const PALE := Color("#f4f4ec")
const DIM := Color(0.62, 0.64, 0.6, 0.8)
const PANEL := Color(0.03, 0.035, 0.03, 0.88)
const LINE := "ONLY WHAT IS IN HERE WHEN YOU SLEEP IS KEPT."
const KEYS := "1-4 PUT IN   SHIFT 1-8 TAKE OUT   F CLOSE"
## The sound hooks for the owner's recordings (docs/ASSETS-TO-GET.md): nothing plays until client/sfx.gd has them.
## The cabinet opening, an item going in, an item coming out (the host's "stashed" and "fetched").
const SOUND_OPEN := "cabinet_open"
const SOUND_PUT := "cabinet_put"
const SOUND_TAKE := "cabinet_take"

var open := false
## This player's four slots and the cabinet's CAB_MAX slots, from the host's blocks; how many cabinet slots are open.
var mine: Array = []
var cab: Array = []
var cab_open := Shop.CAB_SLOTS
## The squares as last drawn (screen rects): [rect, "bag"|"cab", index].
var _hits: Array = []

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

func is_open() -> bool:
	return open

func show_card() -> void:
	open = true

func close() -> void:
	open = false

## This frame: the host's shop and inv blocks, who I am, and the tuning in force (cabinet.slots).
func update(shop: Variant, inv: Variant, my_id: String, tuning: Settings.Values) -> void:
	mine = []
	cab = Shop.empty_cabinet()
	cab_open = Shop.cab_slots(tuning)
	if inv is Dictionary:
		for b: Dictionary in (inv as Dictionary)["bags"]:
			if str(b["playerId"]) == my_id:
				mine = (b["slots"] as Array).duplicate(true)
	if mine.is_empty():
		for _k in Inventory.SLOTS:
			mine.append(["", 0])
	if shop is Dictionary:
		for c: Dictionary in (shop as Dictionary)["cabinets"]:
			if str(c["playerId"]) == my_id:
				cab = (c["slots"] as Array).duplicate(true)

## A key while the card is open: [op, arg] to ask the host for, ["close", null], or [] when it is not the card's.
func key(k: InputEventKey) -> Array:
	if k.physical_keycode == KEY_F or k.physical_keycode == KEY_ESCAPE:
		return ["close", null]
	var n := k.physical_keycode - KEY_1
	if n >= 0 and n < 8:
		if k.shift_pressed:
			return ["fetch", n] if n < Shop.CAB_MAX else []
		return ["stash", n] if n < Inventory.SLOTS else []
	return []

## A click at a screen position: [op, arg] for the square under it, or [].
func click(pos: Vector2) -> Array:
	for h: Array in _hits:
		if (h[0] as Rect2).has_point(pos):
			return ["stash", h[2]] if h[1] == "bag" else ["fetch", h[2]]
	return []

func _process(_d: float) -> void:
	var want := get_parent_area_size() if get_parent() is Control else get_viewport_rect().size
	if size != want:
		position = Vector2.ZERO
		size = want
	queue_redraw()

func _square(r: Rect2, item: String, n: int, label: String, px: float, lit: bool) -> void:
	draw_rect(r, Color(0.02, 0.02, 0.025, 0.7))
	draw_rect(r, AMBER if lit else DIM, false, px)
	PixelFont.draw(self, label, r.position + Vector2(2, 2) * px, px, Color(0.75, 0.76, 0.72, 0.8))
	if n > 0 and item != "":
		var name := Inventory.short_name(item)
		var sc := px if PixelFont.width(name) * px <= r.size.x - 4.0 * px else maxf(1.0, px * 0.5)
		var lw := PixelFont.width(name) * sc
		PixelFont.draw_shadowed(self, name, Vector2(floorf(r.position.x + (r.size.x - lw) * 0.5), floorf(r.position.y + r.size.y * 0.5 - 3.0 * sc)), sc, PALE)
		if n > 1:
			var cnt := "x%d" % n
			PixelFont.draw_shadowed(self, cnt, r.position + Vector2(r.size.x - PixelFont.width(cnt) * px - 2.0 * px, r.size.y - 9.0 * px), px, PALE)

func _draw() -> void:
	_hits = []
	if not open:
		return
	var px := maxf(2.0, floor(size.y / 320.0))
	var box := 18.0 * px
	var gap := 3.0 * px
	var shown := cab_open
	for k in range(cab_open, Shop.CAB_MAX):
		if k < cab.size() and int(cab[k][1]) > 0:
			shown = k + 1
	var cols := 4
	var rows_cab := ceili(float(shown) / cols)
	var w := (Inventory.SLOTS + cols) * (box + gap) + 18.0 * px
	var h := 30.0 * px + maxi(1, rows_cab) * (box + gap) + 28.0 * px
	var p0 := Vector2(floorf((size.x - w) * 0.5), floorf((size.y - h) * 0.42))
	draw_rect(Rect2(p0, Vector2(w, h)), PANEL)
	draw_rect(Rect2(p0, Vector2(w, h)), AMBER, false, px)
	PixelFont.draw_shadowed(self, "YOUR CABINET", p0 + Vector2(6, 5) * px, px, AMBER)
	var y0 := p0.y + 18.0 * px
	PixelFont.draw(self, "YOU CARRY", Vector2(p0.x + 6.0 * px, y0), px, DIM)
	PixelFont.draw(self, "IN THE CABINET", Vector2(p0.x + 12.0 * px + Inventory.SLOTS * (box + gap), y0), px, DIM)
	y0 += 9.0 * px
	for k in Inventory.SLOTS:
		var r := Rect2(Vector2(p0.x + 6.0 * px + k * (box + gap), y0), Vector2(box, box))
		_square(r, str(mine[k][0]), int(mine[k][1]), str(k + 1), px, false)
		_hits.append([r, "bag", k])
	var cx := p0.x + 12.0 * px + Inventory.SLOTS * (box + gap)
	for k in shown:
		var r := Rect2(Vector2(cx + (k % cols) * (box + gap), y0 + (k / cols) * (box + gap)), Vector2(box, box))
		var it := str(cab[k][0]) if k < cab.size() else ""
		var n := int(cab[k][1]) if k < cab.size() else 0
		_square(r, it, n, str(k + 1), px, k >= cab_open)
		_hits.append([r, "cab", k])
	var fy := p0.y + h - 20.0 * px
	PixelFont.draw_shadowed(self, LINE, Vector2(p0.x + 6.0 * px, fy), px, PALE)
	PixelFont.draw(self, KEYS, Vector2(p0.x + 6.0 * px, fy + 9.0 * px), px, DIM)

## Tests: what this card shows.
func describe() -> Dictionary:
	return {"open": open, "mine": mine.duplicate(true), "cabinet": cab.duplicate(true), "slots": cab_open}
