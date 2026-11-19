extends Control

const Upgrades = preload("res://sim/upgrades.gd")
const Shop = preload("res://sim/shop.gd")
const AMBER := Color("#ffd27a")
const PALE := Color("#f4f4ec")

var open := false
var credits := 0
var selected := 0
var ownership: int:
	get:
		return _states[selected]
var _states: Array[int] = [0, 0, 0]
var _cards: Array[int] = [0]
var notice := ""
var notice_until := 0
var _action := Rect2()
var _tabs: Array[Rect2] = []
const NODES := ["deep_pockets", "second_wind", "soft_shoes"]
const BUY_ARGS := [0, 2, 4]

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

func is_open() -> bool:
	return open

func show_card() -> void:
	notice = ""
	selected = 0
	open = true

func close() -> void:
	open = false

func update(skills: Variant, wind: Variant, shoes: Variant, id: String, balance: int, events: Array, now: int) -> void:
	credits = balance
	_states[0] = int(skills.get(id, 0)) if skills is Dictionary else 0
	_states[1] = int(wind.get(id, 0)) if wind is Dictionary else 0
	_states[2] = int(shoes.get(id, 0)) if shoes is Dictionary else 0
	_cards.assign([0])
	if wind is Dictionary:
		_cards.append(1)
	if shoes is Dictionary:
		_cards.append(2)
	if not _cards.has(selected):
		selected = 0
	for e: Dictionary in events:
		if e.get("playerId", "") != id:
			continue
		match e.get("type", ""):
			"trained":
				var node := Upgrades.induction_node(str(e.get("node", NODES[0])))
				notice = "%s LEARNED." % str(node.get("name", "TRAINING")).to_upper()
			"trainingUndone":
				notice = "TRAINING UNDONE. CREDITS REFUNDED."
			"invRefused":
				if e.get("op") != "skill":
					continue
				var why := str(e.get("why", ""))
				notice = {
					"poor": "NOT ENOUGH CREDITS.",
					"owned": "YOU ALREADY KNOW THIS SKILL.",
					"unstack": "DROP OR STORE EXTRA ITEMS, THEN UNDO.",
					"nothing_to_undo": "YOUR TRAINING IS ALREADY FINAL.",
				}.get(why, "TRAINING IS UNAVAILABLE.")
			_:
				continue
		notice_until = now + 3500
	queue_redraw()

func key(event: InputEventKey) -> Array:
	match event.physical_keycode:
		KEY_F, KEY_ESCAPE:
			return ["close", null]
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			return _buy_request()
		KEY_U:
			return ["skill", 1] if ownership == 2 else []
		KEY_1, KEY_2, KEY_3:
			var card := event.physical_keycode - KEY_1
			if card < _cards.size():
				selected = _cards[card]
			return ["pick", null]
		KEY_LEFT, KEY_RIGHT:
			var offset := -1 if event.physical_keycode == KEY_LEFT else 1
			selected = _cards[clampi(_cards.find(selected) + offset, 0, _cards.size() - 1)]
			return ["pick", null]
	return []

func click(at: Vector2) -> Array:
	for i in _tabs.size():
		if _tabs[i].has_point(at):
			selected = _cards[i]
			return ["pick", null]
	if not _action.has_point(at):
		return []
	return ["skill", 1] if ownership == 2 else _buy_request()

func _buy_request() -> Array:
	return ["skill", BUY_ARGS[selected]] if ownership == 0 else []

func _draw() -> void:
	if not open:
		return
	var has_tabs := _cards.size() > 1
	var px := minf(2.0, minf(size.x / 286.0, size.y / (127.0 if has_tabs else 102.0)))
	var panel := Vector2(274, 115 if has_tabs else 90) * px
	var origin := ((size - panel) * 0.5).floor()
	draw_rect(Rect2(origin, panel), Color(0.03, 0.035, 0.03, 0.95))
	draw_rect(Rect2(origin, panel), AMBER, false, px)
	var node := Upgrades.induction_node(NODES[selected])
	_row("SKILLS", 6, origin, px, AMBER)
	_tabs.clear()
	if has_tabs:
		var stride := 125 if _cards.size() == 2 else 88
		for i in _cards.size():
			var idx := _cards[i]
			var title := "%d%s%s" % [i + 1, "  " if _cards.size() == 2 else " ", str(Upgrades.induction_node(NODES[idx]).name).to_upper()]
			var x := 6 + stride * i
			var tab := Rect2(origin + Vector2(x - 2, 16) * px, Vector2(113 if _cards.size() == 2 else 85, 10) * px)
			_tabs.append(tab)
			if idx == selected:
				draw_rect(tab, AMBER, false, px)
			PixelFont.draw(self, title, origin + Vector2(x, 18) * px, px, AMBER if idx == selected else PALE)
	else:
		_row(str(node.name).to_upper(), 29, origin, px, AMBER)
	_row("%s  /  INDUCTION" % str(node.branch).to_upper(), 33 if has_tabs else 18, origin, px, PALE)
	if selected == 1:
		_row("WHEN WINDED, PRESS SPRINT AGAIN.", 45, origin, px, PALE)
		_row("REFILL ONCE A FLOOR. YOU GASP LOUDLY.", 55, origin, px, PALE)
	else:
		_row(str(node.description).to_upper(), 45 if has_tabs else 40, origin, px, PALE)
		if node.has("drawback"):
			_row(str(node.drawback).to_upper(), 55, origin, px, PALE)
	_row("SPENDABLE CREDITS %d" % credits, 69 if has_tabs else 52, origin, px, PALE)
	var action := "ENTER  BUY FOR %d" % Shop.SHARE
	if ownership > 0:
		action = "U  UNDO UNTIL BED" if ownership == 2 else "LEARNED"
	var action_y := 83 if has_tabs else 63
	_action = Rect2(origin + Vector2(5, action_y - 1) * px, Vector2(191, 10) * px)
	_row(action, action_y, origin, px, AMBER)
	PixelFont.draw(self, "F CLOSE", origin + Vector2(217, action_y) * px, px, PALE)
	if Time.get_ticks_msec() < notice_until:
		_row(notice, 99 if has_tabs else 76, origin, px, PALE)

func _row(line: String, y: float, origin: Vector2, px: float, ink: Color) -> void:
	PixelFont.draw(self, line, origin + Vector2(6, y) * px, px, ink)
