# Searching on screen (docs/floors/findables-and-day.md section 3 and FD10; the rules are sim/findables.gd and
# sim/run.gd `findables`). Everything here is the host's: the find block of the newest snapshot (net/client.gd
# findables(): what has been opened, who is searching since when, who carries what) and the search events.
# Nothing is predicted: a piece looks open only once the host's block says it is, and the bar is the host's
# times counted against the host clock as this screen estimates it ("hostNow").
#  - The prompt: standing at an unopened searchable piece (Findables.piece_in_reach: in its room, within reach,
#    facing it), on your feet, out of the car, out of any hide, with no hide in reach and no other prompt:
#    "F  OPEN DRAWER" (Findables.prompt_for) and under it the trade, "SHIFT+F  RIFLE IT. FAST. LOUD. HALF THE
#    CREDITS." Holding F sends a search (sprint held with it, the rushed one); moving while a careful search
#    runs lets go of it (the host stops it: "moving cancels").
#  - The bar: while the host has you searching, under the prompt, (hostNow - from) / (done - from).
#  - The result: one line for 2 s when your search ends ("CREDITS +48", "NOTHING", "A CARTON OF JUICE",
#    "SOMEBODY'S PAGE"); a note or a page opens in the reader (client/note_reader.gd).
#  - At an opened piece that held a note or a page: "F  READ NOTE" opens it again (for anyone).
#  - The carton count: how many this player carries, as the host says (the HUD's small carton).
#  - What everyone sees: every opened piece drawn open (a drawer pulled out, a lid up), with a slip of paper on
#    it when it held a note or a page; the rushed search's noise where the piece is; the laminated sheet by the
#    lobby doors (Findables.sheet_text), and the same line on the lift monitor's third row on the ride down.
extends RefCounted

@warning_ignore_start("integer_division")

const Findables = preload("res://sim/findables.gd")
const Furniture = preload("res://sim/furniture.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Run = preload("res://sim/run.gd")
const Places = preload("res://sim/places.gd")

## How long the result line stays (ms).
const RESULT_MS := 2000
## A careful search is let go of when the player tries to move this much (input strength).
const MOVE_LETS_GO := 0.2

## The deliberate break (FD10): "predict_open" draws a piece open on the F press, before the host says so (a
## cancelled search then shows an open drawer).
static var test_break := ""

# This frame's words and bars (main.gd hands them to the HUD and client/note_reader.gd).
var prompt := ""
var prompt2 := ""
var fill := -1.0
## F held now means a search (sent as "search"; "searchFast" with sprint).
var want_search := false
var want_fast := false
## F now opens the note on the opened piece in reach (its note or page id, "" for none).
var read_id := ""
## The result line and until when it shows (ms); the cartons carried.
var result := ""
var result_until := 0
var juice := 0
## The piece in reach (id, -1 for none) and the one being searched by this player (-1).
var piece := -1
var mine := -1
## The newest result of this player's own search, for the tests: {piece, what, credits, note}.
var last_done := {}

var _plan: Floor.FloorPlan = null
var _garden_sites := false
var _storage_nodes := {}
var _ff: Findables.FindFloor = null
## The world: what is drawn open ({piece id: node}), under `_root`.
var _open_nodes := {}
var _root: Node3D = null
## The sheet: its text and node.
var sheet := ""
var _sheet_node: Node3D = null
var _sheet_key := ""
## Pieces this screen drew open early (the break only).
var _predicted := {}

func reset() -> void:
	prompt = ""
	prompt2 = ""
	fill = -1.0
	want_search = false
	want_fast = false
	read_id = ""
	result = ""
	result_until = 0
	juice = 0
	piece = -1
	mine = -1
	last_done = {}
	_plan = null
	_ff = null
	_open_nodes = {}
	_storage_nodes = {}
	_garden_sites = false
	_root = null
	sheet = ""
	_sheet_node = null
	_sheet_key = ""
	_predicted = {}

## Whether the host has this player searching (the find block's searching rows).
static func searching_in(block: Variant, id: String) -> bool:
	return _search_row(block, id) != null

static func _search_row(block: Variant, id: String) -> Variant:
	if not block is Dictionary:
		return null
	for r: Dictionary in (block as Dictionary)["searching"]:
		if str(r["playerId"]) == id:
			return r
	return null

## The pieces of this plan (Findables.spots_for), as a FindFloor the reach rule can read.
func use_plan(plan: Floor.FloorPlan, garden_sites: bool = false) -> void:
	if plan == _plan and garden_sites == _garden_sites:
		return
	_plan = plan
	_garden_sites = garden_sites
	_ff = null
	_predicted = {}
	if plan == null or not Findables.place_on(plan.place, garden_sites):
		return
	_ff = Findables.FindFloor.new()
	_ff.plan = plan
	_ff.depth = plan.depth
	_ff.pieces = Findables.spots_for(plan, "", -1, garden_sites)
	for p in _ff.pieces:
		_ff.by_id[p.id] = p

static func _opened(block: Variant) -> Dictionary:
	var out := {}
	if block is Dictionary:
		for o: Dictionary in (block as Dictionary)["opened"]:
			out[int(o["piece"])] = o
	return out

## This frame. `s` the snapshot (play_link.gd), `my` this player's id, `yaw` where they face, `f_held` F held,
## `sprint` sprint held, `moving` trying to move, `blocked` another prompt or a hide has F this frame.
func update(s: Dictionary, my: String, yaw: float, f_held: bool, sprint: bool, moving: bool, blocked: bool) -> void:
	prompt = ""
	prompt2 = ""
	fill = -1.0
	want_search = false
	want_fast = false
	read_id = ""
	piece = -1
	mine = -1
	juice = 0
	var block: Variant = s.get("find")
	if not block is Dictionary:
		return
	for it: Dictionary in (block as Dictionary)["items"]:
		if str(it["playerId"]) == my:
			juice = int(it["juice"])
	if _ff == null:
		return
	var me: Dictionary = s["me"]
	var opened := _opened(block)
	_ff.opened = opened
	var row: Variant = _search_row(block, my)
	if row != null:
		var r: Dictionary = row
		mine = int(r["piece"])
		var p: Furniture.Piece = _ff.by_id.get(mine)
		prompt = Findables.prompt_for(p.kind) if p != null else "F  SEARCH"
		prompt2 = "RIFLING..." if bool(r["fast"]) else ""
		var span := maxf(0.001, float(r["done"]) - float(r["from"]))
		fill = clampf((float(s.get("hostNow", 0.0)) - float(r["from"])) / span, 0.0, 1.0)
		# A careful search goes on while F is held and you keep still; a rushed one cannot be let go.
		want_search = bool(r["fast"]) or (f_held and not moving)
		want_fast = bool(r["fast"])
		if test_break == "predict_open" and f_held:
			_predicted[mine] = true
		return
	if blocked or str(me["status"]) != "ok" or bool(me.get("aboard", false)):
		return
	var my_seek: Variant = s.get("mySeek")
	if my_seek is Dictionary and str((my_seek as Dictionary)["phase"]) != "out":
		return
	var body := Move.Body.make(float(me["x"]), float(me["z"]), int(me["level"]), float(me["y"]))
	var p2 := Findables.piece_in_reach(_ff, body, yaw)
	if p2 != null:
		piece = p2.id
		prompt = Findables.prompt_for(p2.kind)
		var porter: Variant = s.get("porter")
		var trained := porter is Dictionary and int(porter.get(my, 0)) in [1, 2]
		prompt2 = "SHIFT+F  RIFLE IT. FAST. SILENT. HALF THE CREDITS." if trained else Findables.RUSH_PROMPT
		want_search = f_held
		want_fast = f_held and sprint
		if test_break == "predict_open" and f_held:
			_predicted[p2.id] = true
		return
	# An opened piece in reach that held a note or a page: read it again.
	var notes := Findables.FindFloor.new()
	notes.plan = _ff.plan
	for id: int in opened:
		var o: Dictionary = opened[id]
		if str(o["note"]) != "" and _ff.by_id.has(id):
			notes.pieces.append(_ff.by_id[id])
	var pr := Findables.piece_in_reach(notes, body, yaw)
	if pr != null:
		read_id = str(opened[pr.id]["note"])
		prompt = Findables.READ_PROMPT

## Host events arrive once via PlayLink. Careful searches are only heard by the searcher. A rushed search's
## separate noise event is audible at the piece. Returns the note or page id to open in the reader, or "".
func on_events(events: Array, my: String, sfx: Object, now: int) -> String:
	var open := ""
	for e: Dictionary in events:
		var ty := str(e.get("type", ""))
		if ty == "searchDone" and not e.get("silent", false) and _garden_sites and sfx != null and not bool(e.get("fast", false)):
			var kind := str(e.get("kind", ""))
			var cue := "search_locker" if kind == "garden_bin" or kind == "garden_chest" else "search_drawer"
			sfx.call("play_at", cue, piece_point(int(e["piece"])))
		if ty == "searchNoise" and sfx != null and _ff != null and _ff.by_id.has(int(e["piece"])):
			sfx.call("play_at", "search_rifle", piece_point(int(e["piece"])))
		elif ty == "searchDone" and str(e.get("playerId", "")) == my:
			var what := str(e["what"])
			result = Findables.result_line(what, int(e["credits"]))
			result_until = now + RESULT_MS
			last_done = {"piece": int(e["piece"]), "what": what, "credits": int(e["credits"]), "note": str(e["note"])}
			if what == "note" or what == "page":
				open = str(e["note"])
			if sfx != null:
				match what:
					"juice":
						sfx.call("play", "search_carton")
					"note", "page":
						sfx.call("play", "search_paper")
					"credits":
						sfx.call("play", "teller_ding")
		elif ty == "searchStart" and not e.get("silent", false) and str(e.get("playerId", "")) == my and sfx != null and not bool(e.get("fast", false)):
			match str(e["kind"]):
				"drawers_low":
					sfx.call("play", "search_drawer", -10.0)
				"side_table", "filing":
					sfx.call("play", "search_locker", -10.0)
	return open

## The result line now ("" once its 2 s are up).
func result_now(now: int) -> String:
	return result if now < result_until else ""

## Where a piece is in the world (its footprint's centre, at about waist height).
func piece_point(id: int) -> Vector3:
	if _ff == null or not _ff.by_id.has(id):
		return Vector3.ZERO
	var p: Furniture.Piece = _ff.by_id[id]
	return Vector3(p.x / 100.0, (Move.LEVEL_HEIGHT if p.level == 1 else 0.0) + 0.7, p.y / 100.0)

## Where to stand to search a piece (tests and scripted runs): 45 cm in front of its side facing into the room.
static func stand_point(p: Furniture.Piece) -> Vector2:
	var at := Furniture.search_stand_cm(p)
	return Vector2(at.x / 100.0, at.y / 100.0)

## The floor's searchable pieces for a scripted run: [{id, kind, x, z, level, stand: [x, z], cell: [level, x, y]}].
func pieces_plain() -> Array:
	var out: Array = []
	if _ff == null:
		return out
	for p in _ff.pieces:
		var st := stand_point(p)
		out.append({"id": p.id, "kind": String(p.kind), "x": p.x / 100.0, "z": p.y / 100.0, "level": p.level, "stand": [st.x, st.y],
			"cell": [p.level, floori(st.x / _ff.plan.cell_size), floori(st.y / _ff.plan.cell_size)], "prompt": Findables.prompt_for(p.kind)})
	return out

# --- the world ------------------------------------------------------------------------------------

## Draws every opened piece open under `root` (a node rebuilt with each floor): a drawer pulled out (a lid up on
## a copier, a box's flaps open, a gurney's sheet thrown back) and a slip of paper on it when it held a note.
func show_opened(root: Node3D, block: Variant) -> void:
	if root != _root:
		_root = root
		_open_nodes = {}
		_storage_nodes = {}
	if root == null or _ff == null:
		return
	var want := _opened(block)
	if _garden_sites:
		for p in _ff.pieces:
			if not _storage_nodes.has(p.id):
				var n := _garden_storage(p)
				root.add_child(n)
				_storage_nodes[p.id] = n
			var shell: Node3D = _storage_nodes[p.id]
			shell.get_node("Shut").visible = not want.has(p.id)
	for id: int in _predicted:
		if not want.has(id):
			want[id] = {"piece": id, "note": ""}
	for id: int in want:
		if _open_nodes.has(id) or not _ff.by_id.has(id):
			continue
		var n := _open_node(_ff.by_id[id], str((want[id] as Dictionary).get("note", "")) != "")
		root.add_child(n)
		_open_nodes[id] = n
	for id: int in _open_nodes.keys():
		if not want.has(id):
			(_open_nodes[id] as Node).queue_free()
			_open_nodes.erase(id)

## The pieces drawn open on this screen, in id order (tests).
func open_drawn() -> Array:
	var ids: Array = _open_nodes.keys()
	ids.sort()
	return ids

static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.8
	return m

static func _box(size: Vector3, pos: Vector3, mat: Material, rot := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	mi.rotation = Vector3(0.0, rot, 0.0)
	return mi

## A low storage piece in the clearing while it is still closed.
static func _garden_storage(p: Furniture.Piece) -> Node3D:
	var n := Node3D.new()
	n.name = "Storage%d" % p.id
	var fv := Furniture.dir_vec(p.facing)
	n.position = Vector3(p.x / 100.0, 0.0, p.y / 100.0)
	n.rotation.y = atan2(float(fv.x), float(fv.y))
	var w := p.w / 100.0
	var d := p.d / 100.0
	var top := _garden_top(p.kind)
	var wood := _mat(Color(0.27, 0.16, 0.086))
	var iron := _mat(Color(0.17, 0.18, 0.14))
	var copper := _mat(Color(0.39, 0.22, 0.10))
	var shut := Node3D.new()
	shut.name = "Shut"
	n.add_child(shut)
	if _garden_drawer(p.kind):
		var leg := top - 0.20
		for side: float in [-1.0, 1.0]:
			n.add_child(_box(Vector3(0.065, leg, d * 0.86), Vector3(side * w * 0.40, leg * 0.5, 0.0), wood))
		n.add_child(_box(Vector3(w + 0.035, 0.055, d + 0.03), Vector3(0.0, top + 0.026, 0.0), wood))
		shut.add_child(_box(Vector3(w, 0.17, d), Vector3(0.0, top - 0.085, -0.01), wood))
		shut.add_child(_box(Vector3(w * 0.29, 0.024, 0.035), Vector3(0.0, top - 0.061, d * 0.5 + 0.011), copper))
	else:
		n.add_child(_box(Vector3(w, top, d), Vector3(0.0, top * 0.5, 0.0), iron if p.kind == &"garden_bin" else wood))
		shut.add_child(_box(Vector3(w + 0.035, 0.055, d + 0.03), Vector3(0.0, top + 0.026, 0.0), copper))
	return n

static func _garden_drawer(kind: StringName) -> bool:
	return kind == &"garden_bench" or kind == &"garden_drawer"

static func _garden_top(kind: StringName) -> float:
	return 0.37 if kind == &"garden_chest" else (0.58 if kind == &"garden_bin" else 0.72)

## One opened piece: built in the piece's own frame (x across its front, z out of its front).
static func _open_node(p: Furniture.Piece, note: bool) -> Node3D:
	var n := Node3D.new()
	n.name = "Opened%d" % p.id
	var fv := Furniture.dir_vec(p.facing)
	n.position = Vector3(p.x / 100.0, Move.LEVEL_HEIGHT if p.level == 1 else 0.0, p.y / 100.0)
	n.rotation = Vector3(0.0, atan2(float(fv.x), float(fv.y)), 0.0)
	var w := p.w / 100.0
	var d := p.d / 100.0
	var dark := _mat(Color(0.16, 0.15, 0.13))
	var inside := _mat(Color(0.05, 0.05, 0.05))
	var top := 0.9
	match p.kind:
		&"garden_chest", &"garden_bin":
			top = _garden_top(p.kind)
			var bottom := _box(Vector3(w * 0.89, 0.022, d * 0.86), Vector3(0.0, top + 0.012, 0.0), inside)
			n.add_child(bottom)
			var lid := _box(Vector3(w + 0.035, 0.055, d + 0.03), Vector3(0.0, top + d * 0.42, -d * 0.44), _mat(Color(0.39, 0.22, 0.10)))
			lid.rotation.x = -1.1
			n.add_child(lid)
		&"copier":
			# The lid up, hinged at the back.
			var lid := _box(Vector3(w * 0.7, 0.03, d * 0.6), Vector3(0.0, 1.25, -d * 0.2), dark)
			lid.rotation = Vector3(-1.1, 0.0, 0.0)
			n.add_child(lid)
			top = 1.0
		&"gurney":
			# The sheet thrown back off the end.
			n.add_child(_box(Vector3(w * 0.9, 0.04, 0.45), Vector3(0.0, 0.82, d * 0.5 + 0.1), _mat(Color(0.75, 0.78, 0.74)), 0.0))
			top = 0.85
		&"boxes":
			# The flaps open.
			for side: float in [-1.0, 1.0]:
				var flap := _box(Vector3(w * 0.45, 0.02, 0.2), Vector3(side * w * 0.42, 0.55, 0.0), _mat(Color(0.55, 0.42, 0.26)))
				flap.rotation = Vector3(0.0, 0.0, side * 0.9)
				n.add_child(flap)
			top = 0.5
		_:
			# A drawer pulled out of its front.
			var dh := 0.16
			var dy := _garden_top(p.kind) - 0.085 if _garden_drawer(p.kind) else (0.55 if p.tall else 0.45)
			n.add_child(_box(Vector3(w * 0.8, dh, 0.32), Vector3(0.0, dy, d * 0.5 + 0.14), dark))
			n.add_child(_box(Vector3(w * 0.7, 0.02, 0.26), Vector3(0.0, dy + dh * 0.5 - 0.005, d * 0.5 + 0.14), inside))
			top = dy + dh * 0.5 + 0.01
	if note:
		# The slip of paper, lying where it was found.
		var slip := _box(Vector3(0.16, 0.004, 0.22), Vector3(0.05, top + 0.01, d * 0.5 + 0.12), _mat(Color(0.92, 0.9, 0.82)), 0.3)
		slip.name = "Slip"
		n.add_child(slip)
	return n

## The laminated sheet by the lobby doors: the fill's numbers in the pixel font, on the landing beside the doors
## (the side away from the call button), on `lift` (a Node3D in the car's frame). Rebuilt when the text changes.
func show_sheet(lift: Node3D, block: Variant, seed: String, at: Vector3) -> void:
	if _ff == null or lift == null or not block is Dictionary:
		if _sheet_node != null and is_instance_valid(_sheet_node):
			_sheet_node.queue_free()
		_sheet_node = null
		sheet = ""
		_sheet_key = ""
		return
	var base := int((block as Dictionary)["base"])
	var key := "%s/%d/%d" % [seed, _ff.depth, base]
	if key == _sheet_key and _sheet_node != null and is_instance_valid(_sheet_node):
		return
	_sheet_key = key
	sheet = sheet_for(_ff.plan, seed, base, _garden_sites)
	if _sheet_node != null and is_instance_valid(_sheet_node):
		_sheet_node.queue_free()
	_sheet_node = sheet_node(sheet)
	_sheet_node.position = at
	lift.add_child(_sheet_node)

## The sheet's text for a floor (Findables.sheet_text of its fill; the counts never read the trait).
static func sheet_for(plan: Floor.FloorPlan, seed: String, base: int, garden_sites: bool = false) -> String:
	var key := "%s/%d/%d/%d/%d" % [seed, plan.depth, base, plan.get_instance_id(), int(garden_sites)]
	if key != _sheet_cache_key:
		_sheet_cache_key = key
		_sheet_cache = Findables.sheet_text(Findables.fill_for(plan, seed, plan.depth, base, &"listening" if garden_sites else &"stillness", 1, [], garden_sites))
	return _sheet_cache

static var _sheet_cache_key := ""
static var _sheet_cache := ""

## A laminated sheet showing `text` (wrapped), a quad facing +z.
static func sheet_node(text: String) -> Node3D:
	var cols := 18
	var lines := PixelFont.wrap(text, cols)
	var img := Image.create(cols * 6 + 6, lines.size() * 10 + 14, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.93, 0.92, 0.86))
	PixelFont.blit(img, "PLEASE NOTE", Vector2i(3, 3), Color(0.55, 0.12, 0.08))
	for i in lines.size():
		PixelFont.blit(img, lines[i], Vector2i(3, 14 + i * 10), Color(0.12, 0.12, 0.14))
	var tex := ImageTexture.create_from_image(img)
	var n := Node3D.new()
	n.name = "FindSheet"
	var q := QuadMesh.new()
	q.size = Vector2(0.42, 0.42 * img.get_height() / img.get_width())
	var mi := MeshInstance3D.new()
	mi.mesh = q
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.roughness = 0.35
	m.emission_enabled = true
	m.emission_texture = tex
	m.emission = Color(1, 1, 1)
	m.emission_energy_multiplier = 0.15
	mi.material_override = m
	n.add_child(mi)
	return n

func describe() -> Dictionary:
	return {"prompt": prompt, "prompt2": prompt2, "fill": fill, "piece": piece, "mine": mine, "read": read_id, "result": result,
		"juice": juice, "open": open_drawn(), "sheet": sheet, "lastDone": last_done,
		"sheetAt": [_sheet_node.global_position.x, _sheet_node.global_position.y, _sheet_node.global_position.z] if _sheet_node != null and is_instance_valid(_sheet_node) and _sheet_node.is_inside_tree() else []}
