# The Temp's sticky notes (sim/notes.gd). Over many seeded runs of random true facts: every name and
# number in a note equals the fact it came from (the oracle for each template is written here, by
# template id, and reads the note's text back); no note holds a direction word or an arrow; the same
# inputs give the same notes; at most 14 notes a floor; a missing fact never leaves a broken note.
extends RefCounted

const T = preload("res://tests/t.gd")
const Notes = preload("res://sim/notes.gd")
const Rng = preload("res://sim/rng.gd")

const TRIGGERS: Array[String] = ["lobby", "wake", "hunt", "catch", "heal", "tape", "quota", "lift", "chase", "relocate"]
const POOL: Array[String] = ["Ada", "Bram", "Cleo", "Dov", "Edda", "Finn"]
const FACT_KEYS: Array[String] = ["names", "alone", "close_pairs", "door_passes", "sprints", "look_seconds", "notes_for", "furthest", "marks_used", "marks_cap", "caught", "healed", "healer", "tape_dropper", "quota_top", "lift_caller", "gone_to"]
## The words and signs a note must never hold (A2: the only directions to trust are the crew's own marks).
const DIRECTION_WORDS: Array[String] = ["left", "right", "ahead", "behind", "north", "south", "east", "west", "northeast", "northwest", "southeast", "southwest", "forward", "forwards", "backward", "backwards", "upstairs", "downstairs", "clockwise", "anticlockwise", "arrow", "arrows", "direction", "this way", "that way", "turn"]
const ARROW_SIGNS: Array[String] = ["->", "<-", "=>", "<=", "→", "←", "↑", "↓", "↔", "➜", "➔", "➡", "⬅", "⬆", "⬇", "▶", "◀", "^", ">>", "<<"]

func _rand_facts(rng: Rng) -> Dictionary:
	var pool: Array[String] = POOL.duplicate()
	var names: Array[String] = []
	for i in rng.int_in(2, 4):
		names.append(pool.pop_at(rng.int_in(0, pool.size() - 1)))
	var f := {"names": names}
	var counts := ["door_passes", "sprints", "look_seconds", "notes_for"]
	for k: String in counts:
		var d := {}
		for n in names:
			if rng.chance(0.85):
				d[n] = rng.int_in(0, 40)
		f[k] = d
	var alone: Array[String] = []
	for n in names:
		if rng.chance(0.3):
			alone.append(n)
	f["alone"] = alone
	if names.size() >= 2 and rng.chance(0.6):
		f["close_pairs"] = [[names[0], names[1]]]
	f["furthest"] = rng.pick(names)
	f["marks_used"] = rng.int_in(0, 3)
	f["marks_cap"] = rng.int_in(3, 9)
	for k: String in ["caught", "healed", "healer", "tape_dropper", "quota_top", "lift_caller", "gone_to"]:
		if rng.chance(0.7):
			f[k] = rng.pick(names)
	# Knock out whole facts at random: a template that needs one must be skipped.
	for k: String in FACT_KEYS:
		if rng.chance(0.15):
			f.erase(k)
	return f

func _regex_for(text: String) -> RegEx:
	var pattern := "^"
	var i := 0
	while i < text.length():
		var c := text[i]
		if c == "{":
			var j := text.find("}", i)
			var slot := text.substr(i + 1, j - i - 1)
			pattern += "(?<%s>%s)" % [slot, "\\d+" if slot == "n" or slot == "cap" else "[A-Za-z]+"]
			i = j + 1
		else:
			if "\\.^$|?*+()[]{}".contains(c):
				pattern += "\\"
			pattern += c
			i += 1
	var re := RegEx.new()
	re.compile(pattern + "$")
	return re

func _templates_by_id() -> Dictionary:
	var by_id := {}
	for tpl: Dictionary in Notes.data()["templates"]:
		by_id[int(tpl["id"])] = tpl
	return by_id

## The oracle: does the text's name or number equal the fact it must come from? `g` holds the captures.
func _matches_facts(id: int, g: Dictionary, f: Dictionary, trigger: String) -> bool:
	match id:
		1, 5, 9, 20:
			return (f["names"] as Array).has(g["name"])
		2:
			return (f["names"] as Array).has(g["name"]) and f["door_passes"][g["name"]] == int(g["n"])
		3:
			return (f["names"] as Array).has(g["name"]) and f["sprints"][g["name"]] == int(g["n"])
		4:
			return f["furthest"] == g["name"]
		6:
			return (f["names"] as Array).has(g["name"]) and f["look_seconds"][g["name"]] == int(g["n"])
		7:
			return (f["alone"] as Array).has(g["name"])
		8:
			for pr: Array in f["close_pairs"]:
				if pr[0] == g["name"] and pr[1] == g["name2"]:
					return true
			return false
		10:
			return f["marks_used"] == int(g["n"]) and f["marks_cap"] == int(g["cap"])
		11, 19:
			return trigger == "catch" and f["caught"] == g["name"]
		12:
			return trigger == "heal" and f["healed"] == g["name"] and f["healer"] == g["name2"]
		13:
			return trigger == "tape" and f["tape_dropper"] == g["name"]
		14:
			return trigger == "quota" and f["quota_top"] == g["name"]
		15:
			return trigger == "lift" and f["lift_caller"] == g["name"]
		16:
			return trigger == "heal" and f["healer"] == g["name"]
		17:
			return true
		18:
			return (f["names"] as Array).has(g["name"]) and f["notes_for"][g["name"]] == int(g["n"])
		21:
			return trigger == "relocate" and f["gone_to"] == g["name"]
	return false

func _floor_notes(seed: String, floor_number: int, facts: Dictionary, rng: Rng, tries: int) -> Array[Dictionary]:
	var state := Notes.new_state()
	var out: Array[Dictionary] = []
	for i in tries:
		var trig: String = TRIGGERS[rng.int_in(0, TRIGGERS.size() - 1)]
		var r := Notes.post(seed, floor_number, trig, facts, state)
		state = r["state"]
		r["trigger"] = trig
		out.append(r)
	return out

func test_every_name_and_number_equals_the_fact(t: T) -> void:
	var by_id := _templates_by_id()
	t.eq(by_id.size(), 21, "templates in the file")
	var runs := 300 if t.quick else 1500
	var made := 0
	var seen_ids := {}
	var bad := 0
	for run in runs:
		var rng := Rng.make_rng("notes-facts-%d" % run)
		var facts := _rand_facts(rng)
		for r in _floor_notes("run-%d" % run, 3, facts, rng, 12):
			if not r["ok"]:
				continue
			made += 1
			var id: int = r["id"]
			seen_ids[id] = true
			var m := _regex_for(String(by_id[id]["text"])).search(r["text"])
			var ok := m != null
			if ok:
				var g := {}
				for k: String in m.names:
					g[k] = m.get_string(k)
				ok = _matches_facts(id, g, facts, r["trigger"])
			if not ok:
				bad += 1
				t.check(false, "run %d, template %d, trigger %s: '%s' does not match the facts %s" % [run, id, r["trigger"], r["text"], str(facts)])
	t.eq(bad, 0, "notes that differ from their facts")
	t.check(made > runs * 4, "notes made: %d" % made)
	t.check(seen_ids.size() == 21, "every one of the twenty-one templates was used at least once (%d)" % seen_ids.size())
	t.note("%d notes over %d runs, all twenty-one templates seen, every name and number equal to its fact" % [made, runs])

func test_no_directions_and_no_arrows(t: T) -> void:
	var word_re := RegEx.new()
	word_re.compile("(?i)\\b(" + "|".join(DIRECTION_WORDS) + ")\\b")
	# The words are checked on every template as written (in all fills), and on produced notes.
	for tpl: Dictionary in Notes.data()["templates"]:
		var text: String = tpl["text"]
		t.check(word_re.search(text) == null, "template %s holds a direction word: %s" % [str(tpl["id"]), text])
		for s in ARROW_SIGNS:
			t.check(not text.contains(s), "template %s holds the sign %s" % [str(tpl["id"]), s])
	var produced := 0
	for run in 200:
		var rng := Rng.make_rng("notes-dir-%d" % run)
		for r in _floor_notes("d-%d" % run, 3, _rand_facts(rng), rng, 14):
			if r["ok"]:
				produced += 1
				t.check(word_re.search(r["text"]) == null, "direction word in '%s'" % r["text"])
				for s in ARROW_SIGNS:
					t.check(not String(r["text"]).contains(s), "arrow sign in '%s'" % r["text"])
	t.check(produced > 500, "notes produced: %d" % produced)

func test_same_inputs_same_notes(t: T) -> void:
	var differ := 0
	for run in 150:
		var rng_a := Rng.make_rng("notes-same-%d" % run)
		var facts := _rand_facts(rng_a)
		var seq_a := _floor_notes("same-%d" % run, 3, facts, rng_a, 14)
		var rng_b := Rng.make_rng("notes-same-%d" % run)
		_rand_facts(rng_b)
		var seq_b := _floor_notes("same-%d" % run, 3, facts.duplicate(true), rng_b, 14)
		for i in seq_a.size():
			if seq_a[i]["text"] != seq_b[i]["text"] or seq_a[i]["ok"] != seq_b[i]["ok"]:
				differ += 1
	t.eq(differ, 0, "notes that differ between two identical runs")
	# A different seed gives different notes somewhere (the seed is used).
	var rng := Rng.make_rng("notes-seed-use")
	var facts := _rand_facts(rng)
	var texts := {}
	for s in 20:
		var r := Notes.post("seed-%d" % s, 3, "hunt", facts, Notes.new_state())
		texts[r["text"]] = true
	t.check(texts.size() > 1, "twenty seeds all gave the same note")

func test_the_cap_holds(t: T) -> void:
	var rng := Rng.make_rng("notes-cap")
	var facts := {"names": ["Ada", "Bram", "Cleo"], "alone": ["Ada"], "close_pairs": [["Bram", "Cleo"]], "door_passes": {"Ada": 4, "Bram": 2, "Cleo": 9}, "sprints": {"Ada": 3, "Bram": 1, "Cleo": 5}, "look_seconds": {"Ada": 2, "Bram": 6, "Cleo": 1}, "notes_for": {"Ada": 1, "Bram": 2, "Cleo": 3}, "furthest": "Cleo", "marks_used": 2, "marks_cap": 3, "caught": "Ada", "healed": "Ada", "healer": "Bram", "tape_dropper": "Cleo", "quota_top": "Bram", "lift_caller": "Ada", "gone_to": "Cleo"}
	var cap := Notes.cap_per_floor()
	t.eq(cap, 14, "the cap")
	for run in 40:
		var state := Notes.new_state()
		var posted := 0
		for i in 60:
			var trig: String = TRIGGERS[rng.int_in(0, TRIGGERS.size() - 1)]
			var r := Notes.post("cap-%d" % run, 3, trig, facts, state)
			state = r["state"]
			if r["ok"]:
				posted += 1
			elif posted >= cap:
				t.eq(r["reason"], "cap", "why the note after the cap failed")
		t.check(posted <= cap, "posted %d notes, over the cap" % posted)
		t.eq(posted, cap, "full facts: notes posted up to the cap")
		t.eq(state["count"], posted, "the state's count")

func test_missing_facts_never_make_a_broken_note(t: T) -> void:
	var leftovers := 0
	var empty_ok := 0
	var skipped := 0
	for trig in TRIGGERS:
		var r := Notes.post("empty", 3, trig, {}, Notes.new_state())
		if r["ok"]:
			# With no facts only the template that needs none may post.
			t.eq(r["id"], 17, "with no facts only template 17 may post")
			empty_ok += 1
		else:
			skipped += 1
			t.eq(r["text"], "", "a failed post has no text")
	t.check(empty_ok >= 1 and skipped >= 1, "empty facts: %d posted, %d skipped" % [empty_ok, skipped])
	var brace := RegEx.new()
	brace.compile("[{}]")
	for run in 300:
		var rng := Rng.make_rng("notes-miss-%d" % run)
		var facts := _rand_facts(rng)
		# Break facts in other ways: a count of the wrong type, a zero, a name with braces.
		if rng.chance(0.3):
			facts["sprints"] = "many"
		if rng.chance(0.3):
			facts["furthest"] = "{name}"
		if rng.chance(0.3):
			facts["door_passes"] = {}
		for r in _floor_notes("m-%d" % run, 3, facts, rng, 14):
			if r["ok"]:
				if brace.search(r["text"]) != null:
					leftovers += 1
				t.check(r["id"] != 3 or facts["sprints"] is Dictionary, "template 3 posted from a bad sprints fact")
				t.check(r["id"] != 4 or facts["furthest"] != "{name}", "template 4 posted a name with braces")
				t.check(String(r["text"]).strip_edges() != "", "an empty note posted")
	t.eq(leftovers, 0, "notes with a leftover placeholder or brace")
	t.note("empty facts post only the need-nothing template; broken facts never leave a brace")
