# The elevator deal on screen (ED1; sim/deal.gd has the rule, net/host.gd sends its "deal" block). Nothing is
# predicted: every line is drawn from the host's block of the newest snapshot, against its host time.
#   - During a ride with a card: the card, over the game's left half. Its face: the card's name, what each side of it
#     does (WIN and LOSE, one plain line each), who carries it. Its back, printed before anyone chooses: the odds
#     ("1 IN 2: HAZARD PAY. 1 IN 2: SQUEAKY SOLES."). Under it the keys and the count of answers, and the seconds
#     left in the ride. Y takes, N passes; a card the crew picks for is taken with the number key of the one picked
#     (1 to 8, the crew in seat order, shown on the card). The answer can change until the card is decided.
#   - Decided: TAKEN or PASSED, the roll and what it landed, on whom. After a boon the second card of double or
#     nothing is shown with its worse odds; its carrier draws again with Y or keeps the boon with N.
#   - On the floor the card was for: one line under the HUD's corner for everyone ("SAM: SQUEAKY SOLES"), and for a
#     Second Opinion not yet used, "O: SECOND OPINION (ONE 10 S LOOK)". The look itself is client/crew_watch.gd's view.
#   - The intercom reads it: `said` collects the lines for client/announcer.gd deal_say (subtitles; no recording yet).
# The answer this player sends (net/client.gd LocalFrame.deal) is `answer()`: [offer seq, choice, pick, double, use].
extends Control

const Deal = preload("res://sim/deal.gd")
const Settings = preload("res://sim/settings.gd")
const Rng = preload("res://sim/rng.gd")

const AMBER := Color("#ffd27a")
const PALE := Color("#f4f4ec")
const DIM := Color(0.62, 0.64, 0.6, 0.85)
const RED := Color("#ff7a6a")
const GREEN := Color("#9fe0a0")
const CARD_FACE := Color(0.09, 0.075, 0.05, 0.94)
const CARD_BACK := Color(0.16, 0.035, 0.03, 0.94)

## The host's block (decoded), or null; who I am; the crew's names in seat order; the tuning; the host's time now;
## the floor and day shown; whether the run is riding down.
var block: Variant = null
var my_id := ""
var crew: Array[String] = []
var names: Dictionary = {}
var tuning: Settings.Values = null
var host_now := 0.0
var depth := -1
var day := -1
var riding := false
## This player's answer to the card `_seq` (0 none), and the second opinion asked for.
var _seq := 0
var _choice := 0
var _pick := ""
var _dbl := 0
var _use := -1
## Intercom lines to say (client/main.gd drains it into the announcer), and what has been said already.
var said: Array[String] = []
var _said_offer := 0
var _said_state := ""
var _said_dbl := ""

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

# ---------------------------------------------------------------------------------------------
# The numbers the views use (pure).

## The Novelty Torch's strength, 0 to 1 (deal.torch_dim in 100).
static func torch_strength(tn: Settings.Values) -> float:
	return Settings.f(tn, &"deal.torch_dim", float(Deal.TORCH_DIM)) / 100.0

## The torch's flicker at host time `t`: the same on every screen. Mostly lit, with sags and short drop-outs.
static func torch_flicker(t: float) -> float:
	var k := int(floorf(t * 8.0))
	var r := Rng.hash_seed("torch:%d" % k) % 11
	if r == 0:
		return 0.1
	if r <= 2:
		return 0.55
	return 1.0

## The faces in force on floor `d` of day `dd` in `b` (a block): [[face, carrier id], ...].
static func faces_here(b: Variant, d: int, dd: int) -> Array:
	if not b is Dictionary or int(b["depth"]) != d or int(b["day"]) != dd:
		return []
	var out: Array = []
	for f: Array in b["active"]:
		out.append([Deal.FACES[int(f[0])], str(f[1])])
	return out

## The carrier of `face` on that floor, or "".
static func carrier_here(b: Variant, face: StringName, d: int, dd: int) -> String:
	for f: Array in faces_here(b, d, dd):
		if f[0] == face:
			return str(f[1])
	return ""

## Whether that floor's lights are out (Lights Out, either face).
static func lights_out(b: Variant, d: int, dd: int) -> bool:
	return carrier_here(b, &"dark_pay", d, dd) != "" or carrier_here(b, &"dark", d, dd) != ""

## Whether `id` is looking through a crewmate's eyes now (the Second Opinion's one use).
static func second_watching(b: Variant, id: String, now: float, tn: Settings.Values) -> bool:
	return b is Dictionary and str(b["secondBy"]) == id and id != "" and now >= float(b["secondAt"]) and now < float(b["secondAt"]) + Deal.second_time(tn)

# ---------------------------------------------------------------------------------------------
# This frame.

func update(b: Variant, me: String, crew_ids: Array[String], crew_names: Dictionary, tn: Settings.Values, now: float, d: int, dd: int, is_riding: bool) -> void:
	block = b
	my_id = me
	crew = crew_ids
	names = crew_names
	tuning = tn
	host_now = now
	depth = d
	day = dd
	riding = is_riding
	var o: Variant = _offer()
	if o != null and int(o["seq"]) != _seq:
		_seq = int(o["seq"])
		_choice = 0
		_pick = ""
		_dbl = 0
	_speak(o)
	queue_redraw()

func _offer() -> Variant:
	if block is Dictionary and bool(block["live"]) and block.get("offer") is Dictionary:
		return block["offer"]
	return null

func _name(id: String) -> String:
	return str(names.get(id, id)).to_upper()

## The card's own name.
static func card_of(o: Dictionary) -> StringName:
	return Deal.CARDS[int(o["card"])]

func _speak(o: Variant) -> void:
	if o == null:
		return
	var seq := int(o["seq"])
	var card := card_of(o)
	if seq != _said_offer:
		_said_offer = seq
		_said_state = "open"
		_said_dbl = ""
		said.append(Deal.read_line(card))
	var st := String(Deal.STATES[int(o["state"])])
	if st != _said_state:
		_said_state = st
		if st == "passed":
			said.append(Deal.passed_line())
		elif st == "taken":
			var face: StringName = Deal.CARD[card]["boon"] if int(o["outcome"]) == 1 else Deal.CARD[card]["curse"]
			said.append(Deal.outcome_line(face, str(names.get(str(o["carrier"]), ""))))
	var dbl: Array = o["dbl"]
	var ds := String(Deal.DOUBLE_STATES[int(dbl[2])])
	if ds != _said_dbl:
		_said_dbl = ds
		if ds == "offered":
			said.append(Deal.double_line())
		elif ds == "taken":
			var c2: StringName = Deal.CARDS[int(dbl[0])]
			var face2: StringName = Deal.CARD[c2]["boon"] if int(dbl[4]) == 1 else Deal.CARD[c2]["curse"]
			said.append(Deal.outcome_line(face2, str(names.get(str(o["carrier"]), ""))))

## A key press: true when the deal used it. Y / N / 1-8 on an open card; Y / N on a double for its carrier; O for a
## Second Opinion on its floor.
func key(k: InputEventKey) -> bool:
	var o: Variant = _offer()
	if o != null and riding:
		var st := int(o["state"])
		var vote_card: bool = Deal.CARD[card_of(o)]["who"] == Deal.WHO_VOTE
		if st == 0:
			if k.physical_keycode == KEY_Y:
				_choice = Deal.TAKE
				return true
			if k.physical_keycode == KEY_N:
				_choice = Deal.PASS
				_pick = ""
				return true
			var n := k.physical_keycode - KEY_1
			if vote_card and n >= 0 and n < mini(8, crew.size()):
				_choice = Deal.TAKE
				_pick = crew[n]
				return true
		var dbl: Array = o["dbl"]
		if st == 1 and int(dbl[2]) == 1 and str(o["carrier"]) == my_id:
			if k.physical_keycode == KEY_Y:
				_dbl = 1
				return true
			if k.physical_keycode == KEY_N:
				_dbl = 2
				return true
		return false
	if k.physical_keycode == KEY_O and second_available():
		_use = _second_seq()
		return true
	return false

func _second_seq() -> int:
	if not block is Dictionary:
		return -1
	var b: Dictionary = block
	if b.get("offer") is Dictionary:
		return int(b["offer"]["seq"])
	return -1

## Whether this player may use the Second Opinion now.
func second_available() -> bool:
	return not riding and carrier_here(block, &"second", depth, day) != "" and str((block as Dictionary)["secondBy"]) == ""

## What this player sends with each input, or null when there is nothing to answer.
func answer() -> Variant:
	if _offer() != null and riding:
		return [_seq, _choice, _pick, _dbl, -1]
	if _use >= 0 and block is Dictionary and str(block["secondBy"]) == "" and carrier_here(block, &"second", depth, day) != "":
		return [0, 0, "", 0, _use]
	_use = -1
	return null

## Tests and the tools: what is on the card now, as plain lines.
func lines() -> PackedStringArray:
	var out := PackedStringArray()
	var o: Variant = _offer()
	if o != null and riding:
		out.append_array(_card_lines(o))
	out.append_array(_floor_lines())
	return out

func _card_lines(o: Dictionary) -> PackedStringArray:
	var card := card_of(o)
	var c: Dictionary = Deal.CARD[card]
	var out := PackedStringArray()
	out.append("THE ELEVATOR DEAL")
	out.append(str(c["name"]))
	var carrier := str(o["carrier"])
	var who := _name(carrier) if carrier != "" else ""
	out.append("WIN: " + Deal.face_line(c["boon"], who, tuning))
	out.append("LOSE: " + Deal.face_line(c["curse"], who, tuning))
	out.append(Deal.who_line(c["who"]))
	out.append("ODDS: " + Deal.odds_line(card, int(o["n"])).to_upper())
	return out

func _floor_lines() -> PackedStringArray:
	var out := PackedStringArray()
	if riding:
		return out
	for f: Array in faces_here(block, depth, day):
		var face: StringName = f[0]
		var who := str(f[1])
		if Deal.PERSONAL.has(face):
			out.append("%s: %s" % ["YOU" if who == my_id else _name(who), Deal.FACE_NAME[face]])
		elif face == &"second":
			if str((block as Dictionary)["secondBy"]) == "":
				out.append("O: SECOND OPINION (ONE %d S LOOK)" % int(Deal.second_time(tuning)))
		else:
			out.append(Deal.FACE_NAME[face])
	return out

func _process(_d: float) -> void:
	var want := get_parent_area_size() if get_parent() is Control else get_viewport_rect().size
	if size != want:
		position = Vector2.ZERO
		size = want

func _draw() -> void:
	var px := maxf(2.0, floorf(size.y / 320.0))
	var o: Variant = _offer()
	if o != null and riding:
		_draw_card(o, px)
	var fl := _floor_lines()
	var y := floorf(size.y * 0.30)
	for l in fl:
		var mine := l.begins_with("YOU:")
		PixelFont.draw_shadowed(self, l, Vector2(10.0 * px, y), px, AMBER if mine else PALE)
		y += 10.0 * px

func _draw_card(o: Dictionary, px: float) -> void:
	var card := card_of(o)
	var c: Dictionary = Deal.CARD[card]
	var st := int(o["state"])
	var carrier := str(o["carrier"])
	var who := _name(carrier) if carrier != "" else ""
	var lh := 10.0 * px
	var w := minf(size.x - 20.0 * px, 300.0 * px)
	var x0 := floorf((size.x - w) * 0.5)
	var y0 := floorf(size.y * 0.12)
	# The face: a card with a thick amber border and a corner pip.
	var face_h := lh * 7.6
	var face := Rect2(Vector2(x0, y0), Vector2(w, face_h))
	draw_rect(face, CARD_FACE)
	draw_rect(face, AMBER, false, px * 2.0)
	draw_rect(Rect2(face.position + Vector2(4, 4) * px, Vector2(6, 6) * px), AMBER)
	var tx := x0 + 14.0 * px
	var y := y0 + 5.0 * px
	PixelFont.draw(self, "THE ELEVATOR DEAL", Vector2(tx, y), px, DIM)
	y += lh
	PixelFont.draw_shadowed(self, str(c["name"]), Vector2(tx, y), px * 2.0, AMBER)
	y += lh * 1.8
	y += _text(Deal.who_line(c["who"]), tx, y, w - 20.0 * px, px, PALE)
	y += _text("WIN: " + Deal.face_line(c["boon"], who, tuning), tx, y, w - 20.0 * px, px, GREEN)
	y += _text("LOSE: " + Deal.face_line(c["curse"], who, tuning), tx, y, w - 20.0 * px, px, RED)
	# The back: the odds, printed before anyone chooses.
	var back := Rect2(Vector2(x0, y0 + face_h + 3.0 * px), Vector2(w, lh * 3.4))
	draw_rect(back, CARD_BACK)
	draw_rect(back, AMBER, false, px)
	PixelFont.draw(self, "ON THE BACK", back.position + Vector2(14.0, 3.0) * px, px, DIM)
	_text(Deal.odds_line(card, int(o["n"])).to_upper(), tx, back.position.y + 3.0 * px + lh, w - 20.0 * px, px, PALE)
	y = back.end.y + 6.0 * px
	var left := maxi(0, ceili(float(o["closes"]) - host_now))
	var takes := 0
	var passes := 0
	for v: Array in o["votes"]:
		if int(v[1]) == Deal.TAKE:
			takes += 1
		else:
			passes += 1
	if st == 0:
		var keys := "Y TAKE   N PASS"
		if c["who"] == Deal.WHO_VOTE:
			var picks: Array[String] = []
			for i in mini(8, crew.size()):
				picks.append("%d %s" % [i + 1, _name(crew[i])])
			keys = "TAKE IT AND PICK WHO: " + "  ".join(picks) + "   N PASS"
		y += _text(keys, tx, y, w - 20.0 * px, px, AMBER)
		var mine := "YOU: TAKE" + ((" " + _name(_pick)) if _pick != "" else "") if _choice == Deal.TAKE else ("YOU: PASS" if _choice == Deal.PASS else "YOU HAVE NOT ANSWERED")
		y += _text("%s   TAKE %d  PASS %d  OF %d   %d S" % [mine, takes, passes, crew.size(), left], tx, y, w - 20.0 * px, px, PALE)
	elif st == 2:
		y += _text("PASSED. NOTHING CHANGES.", tx, y, w - 20.0 * px, px, PALE)
	else:
		var landed := int(o["outcome"]) == 1
		var face_name: String = Deal.FACE_NAME[c["boon"] if landed else c["curse"]]
		y += _text("TAKEN BY THE CREW. %s CARRIES IT." % who, tx, y, w - 20.0 * px, px, PALE)
		y += _text("ROLLED %d OF 12: %s" % [int(o["roll"]) + 1, face_name], tx, y, w - 20.0 * px, px, GREEN if landed else RED)
		var dbl: Array = o["dbl"]
		var ds := int(dbl[2])
		if ds >= 1 and int(dbl[0]) >= 0:
			y += lh * 1.4
			var c2: StringName = Deal.CARDS[int(dbl[0])]
			y += _text("DOUBLE OR NOTHING: %s" % str(Deal.CARD[c2]["name"]), tx, y, w - 20.0 * px, px, AMBER)
			y += _text(Deal.odds_line(c2, int(dbl[1])).to_upper(), tx, y, w - 20.0 * px, px, PALE)
			if ds == 1:
				var line := "Y DRAW AGAIN (LOSE: YOUR BOON GOES TOO)   N KEEP IT   %d S" % left if carrier == my_id else "%s MAY DRAW AGAIN   %d S" % [who, left]
				y += _text(line, tx, y, w - 20.0 * px, px, AMBER if carrier == my_id else PALE)
			elif ds == 2:
				var won := int(dbl[4]) == 1
				y += _text("DREW AGAIN, ROLLED %d OF 12: %s" % [int(dbl[3]) + 1, Deal.FACE_NAME[Deal.CARD[c2]["boon"] if won else Deal.CARD[c2]["curse"]]], tx, y, w - 20.0 * px, px, GREEN if won else RED)
			else:
				y += _text("KEPT. NO SECOND DRAW.", tx, y, w - 20.0 * px, px, PALE)

## One line, wrapped to the card's width.
func _text(s: String, x: float, y: float, width: float, px: float, col: Color) -> float:
	var chars := maxi(8, int(width / (6.0 * px)))
	var rows := PixelFont.wrap(s, chars)
	var yy := y
	for r in rows:
		PixelFont.draw_shadowed(self, r, Vector2(x, yy), px, col)
		yy += 9.0 * px
	return maxf(10.0 * px, yy - y + px)
