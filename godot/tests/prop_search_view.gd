# Searching on screen, headless (docs/floors/findables-and-day.md FD10; client/search_view.gd, client/note_reader.gd).
# The two-client playthrough with pictures is godot/tools/play_search.mjs; here, on the host's own snapshots:
#   1. every prompt of section 3's tables, and the rushed search's second line;
#   2. the prompt never shows for an opened piece, in a hide, or when a hide (or any other prompt) has F;
#   3. the bar is the host's (from, done) against the host clock; the result line's number is the host event's;
#   4. a piece is drawn open only once the host's block says so: a cancelled search draws nothing;
#   5. the sheet's text is Findables.sheet_text of the host's fill;
#   6. the reader shows a poem's lines and a page's words, keeps what was read, and F puts it down.
# Break (the design's): SearchView.test_break "predict_open" (a piece drawn open on the F press, before the host
# says so: check 4 goes red). PROP_SEARCH_VIEW_BREAK=predict_open.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Findables = preload("res://sim/findables.gd")
const Furniture = preload("res://sim/furniture.gd")
const Move = preload("res://sim/move.gd")
const Entity = preload("res://sim/entity.gd")
const Places = preload("res://sim/places.gd")
const Protocol = preload("res://net/protocol.gd")
const Host = preload("res://net/host.gd")
const SearchView = preload("res://client/search_view.gd")
const NoteReader = preload("res://client/note_reader.gd")
const PropSearch = preload("res://tests/prop_search.gd")

const DT := 0.05

static func _apply_break() -> void:
	var b := OS.get_environment("PROP_SEARCH_VIEW_BREAK")
	SearchView.test_break = b if b == "predict_open" else ""

## The snapshot main.gd hands search_view: the host's block (as the wire carries it) and this player.
static func snap_of(st: Run.RunState, id: String, body: Move.Body, seek: Variant = null) -> Dictionary:
	var block: Variant = Host.find_block(st)
	if block != null:
		var c := Protocol._V.new()
		block = Protocol.dec_find(c, JSON.parse_string(JSON.stringify(Protocol.enc_find(block))))
	var me := {"id": id, "x": body.x, "z": body.z, "y": body.y, "level": body.level, "status": "ok", "aboard": false}
	return {"find": block, "me": me, "hostNow": st.t, "mySeek": seek}

func test_every_prompt_of_the_tables(t: T) -> void:
	var want := {&"gurney": "F  CHECK GURNEY", &"drawers_low": "F  OPEN DRAWER", &"side_table": "F  CHECK LOCKER", &"filing": "F  OPEN FILING DRAWER",
		&"copier": "F  LIFT COPIER LID", &"boxes": "F  CHECK BOX"}
	for k: StringName in want:
		t.eq(Findables.prompt_for(k), want[k], "the prompt at a %s" % k)
	t.eq(Findables.RUSH_PROMPT, "SHIFT+F  RIFLE IT. FAST. LOUD. HALF THE CREDITS.", "the rushed search's line")
	# Every searchable kind on the floors has its own prompt.
	for place: StringName in [&"clinic", &"annex"]:
		for rk: StringName in Findables.SEARCHABLE[place]:
			for k: StringName in Findables.SEARCHABLE[place][rk]:
				t.check(Findables.PROMPTS.has(k), "%s has a prompt" % k)

func test_the_prompt_only_where_f_means_a_search(t: T) -> void:
	_apply_break()
	var s := PropSearch.open_doors(PropSearch.find_run("view-prompt", PropSearch._ids(1)))
	var ff: Findables.FindFloor = s.find
	var list := PropSearch.reachable(ff)
	var v := SearchView.new()
	v.use_plan(s.plan)
	var p := list[0]
	var sp := PropSearch.stand(p)
	v.update(snap_of(s, "p0", sp[0]), "p0", sp[1], false, false, false, false)
	t.eq(v.prompt, Findables.prompt_for(p.kind), "at an unopened piece, its prompt")
	t.eq(v.prompt2, Findables.RUSH_PROMPT, "and the rushed search's line")
	t.check(not v.want_search, "nothing sent before F")
	v.update(snap_of(s, "p0", sp[0]), "p0", sp[1], true, true, false, false)
	t.check(v.want_search and v.want_fast, "F with sprint: a rushed search is sent")
	v.update(snap_of(s, "p0", sp[0]), "p0", sp[1], true, false, false, true)
	t.eq(v.prompt, "", "with a hide in reach or another prompt, no search prompt")
	t.check(not v.want_search, "and F is not a search")
	v.update(snap_of(s, "p0", sp[0], {"phase": "inside", "status": "ok"}), "p0", sp[1], true, false, false, false)
	t.eq(v.prompt, "", "in a hide, no search prompt")
	# Facing away: no prompt.
	v.update(snap_of(s, "p0", sp[0]), "p0", sp[1] + PI, false, false, false, false)
	t.check(v.prompt == "" or v.piece != p.id, "facing away from it, not its prompt")
	# Search it to the end: the bar is the host's, the piece is opened, its prompt is gone.
	var cur := s
	var fills: Array[float] = []
	for k in 60:
		var r := Run.step_run(cur, PropSearch.one(PropSearch.inp("p0", sp[0], sp[1], k > 0)), DT)
		cur = r.state
		var sn := snap_of(cur, "p0", sp[0])
		v.update(sn, "p0", sp[1], k > 0, false, false, false)
		if v.mine >= 0:
			var row: Dictionary = (sn["find"] as Dictionary)["searching"][0]
			var want := clampf((cur.t - float(row["from"])) / (float(row["done"]) - float(row["from"])), 0.0, 1.0)
			t.check(absf(v.fill - want) < 1e-6, "the bar is the host's: %.3f, want %.3f" % [v.fill, want])
			fills.append(v.fill)
		var nid := v.on_events(Protocol.plain(r.events), "p0", null, 0)
		for e: Dictionary in r.events:
			if e["type"] == "searchDone":
				t.eq(v.result, Findables.result_line(str(e["what"]), int(e["credits"])), "the result line is the host event's")
				t.eq(nid, str(e["note"]) if (e["what"] == "note" or e["what"] == "page") else "", "the reader opens the note it held")
	t.check(fills.size() > 30 and fills[-1] > 0.9, "the bar filled over the search: %d frames, last %.2f" % [fills.size(), fills[-1] if not fills.is_empty() else -1.0])
	v.update(snap_of(cur, "p0", sp[0]), "p0", sp[1], false, false, false, false)
	t.check(v.prompt != Findables.prompt_for(p.kind) or v.piece != p.id, "an opened piece has no search prompt (got '%s' at piece %d)" % [v.prompt, v.piece])
	SearchView.test_break = ""

func test_a_piece_is_drawn_open_only_when_the_host_says(t: T) -> void:
	_apply_break()
	var s := PropSearch.open_doors(PropSearch.find_run("view-open", PropSearch._ids(1)))
	var ff: Findables.FindFloor = s.find
	var p := PropSearch.reachable(ff)[0]
	var sp := PropSearch.stand(p)
	var v := SearchView.new()
	v.use_plan(s.plan)
	var root := Node3D.new()
	var cur := s
	var early := 0
	# F held a second, then let go: the host stops the careful search. Nothing may be drawn open.
	for k in 40:
		var held := k > 0 and k < 20
		var r := Run.step_run(cur, PropSearch.one(PropSearch.inp("p0", sp[0], sp[1], held)), DT)
		cur = r.state
		var sn := snap_of(cur, "p0", sp[0])
		v.update(sn, "p0", sp[1], held, false, false, false)
		v.show_opened(root, sn["find"])
		var host_open: Array = (sn["find"] as Dictionary)["opened"].map(func(o: Dictionary) -> int: return int(o["piece"]))
		for id: int in v.open_drawn():
			if not host_open.has(id):
				early += 1
	t.eq(early, 0, "frames a piece was drawn open before the host opened it (a cancelled search)")
	t.check(not (cur.find as Findables.FindFloor).opened.has(p.id), "the host did not open it")
	# Searched to the end: drawn open, with the slip when it held a note.
	for k in 60:
		var r := Run.step_run(cur, PropSearch.one(PropSearch.inp("p0", sp[0], sp[1], k > 0)), DT)
		cur = r.state
	var sn2 := snap_of(cur, "p0", sp[0])
	v.show_opened(root, sn2["find"])
	t.check(v.open_drawn().has(p.id), "drawn open once the host says so: %s" % str(v.open_drawn()))
	root.free()
	SearchView.test_break = ""

func test_the_sheet_is_the_hosts(t: T) -> void:
	for depth: int in [1, 2, 3]:
		var s := PropSearch.open_doors(PropSearch.find_run("view-sheet-%d" % depth, PropSearch._ids(3), depth))
		var ff: Findables.FindFloor = s.find
		t.eq(SearchView.sheet_for(s.plan, s.plan.seed, ff.fill.base), Findables.sheet_text(ff.fill), "depth %d (%s): the sheet" % [depth, s.plan.place])
		# The ride down's row: the next floor's sheet from the quota the crew will have.
		var next := Places.generate(s.seed, depth + 1, Places.FULL)
		if Findables.place_on(next.place):
			var base := Run.floor_quota(depth + 1, 3)
			t.eq(SearchView.sheet_for(next, next.seed, base), Findables.sheet_text(Findables.start_floor(next, next.seed, depth + 1, base, &"lonely", 1, []).fill),
				"depth %d: the ride down's sheet is the next floor's" % (depth + 1))

func test_the_reader(t: T) -> void:
	var r := NoteReader.new()
	r.open("stillness-1")
	t.eq(r.open_id, "stillness-1", "a poem opens")
	t.eq(Array(NoteReader.lines_of("stillness-1")), Array(Findables.note_lines("stillness-1")), "its own lines")
	var page := NoteReader.lines_of("C1")
	t.check(page.size() >= 3, "a page wraps: %d lines" % page.size())
	for l in page:
		t.check(l.length() <= NoteReader.PAGE_COLS, "a page's line fits: '%s'" % l)
	var f := InputEventKey.new()
	f.physical_keycode = KEY_F
	f.pressed = true
	t.check(r.key(f) and r.open_id == "", "F puts it down")
	r.open("C1")
	r.close()
	r.menu_on = true
	var n := InputEventKey.new()
	n.physical_keycode = KEY_N
	n.pressed = true
	t.check(r.key(n) and r.list_on, "N in the menu lists the notes read")
	t.eq(str(r.read), str(["stillness-1", "C1"]), "what was read tonight, in order")
	var two := InputEventKey.new()
	two.physical_keycode = KEY_2
	two.pressed = true
	t.check(r.key(two) and r.open_id == "C1", "2 opens the second again")
	r.free()
