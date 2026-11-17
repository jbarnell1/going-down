# The incident report (sim/report.gd). Over many seeded random days of 1 to 8 players: every player gets
# exactly one award; no award twice; every name and number in a line equals the fact it came from (the
# oracle is written here, by award id, and reads the line back); a leader award goes to a true crew-wide
# leader; no placeholder is left; the same input gives the same report; the "upgrade lost" line appears
# exactly when the day was missed and names every upgrade and owner the day gave it (and only those).
extends RefCounted

const T = preload("res://tests/t.gd")
const Report = preload("res://sim/report.gd")
const Rng = preload("res://sim/rng.gd")

const POOL: Array[String] = ["Ada", "Bram", "Cleo", "Dov", "Edda", "Finn", "Gus", "Hana"]
const FACTS: Array[String] = ["credits", "readings", "downs", "heals", "tapes_dropped", "tapes_recovered", "stare_seconds", "distance_m", "emotes", "marks", "sprints"]
const UPGRADES: Array[String] = ["Second Wind", "Doorstop", "Flashbulb", "Whistle", "Marker Pad"]
## Tier 1 award id -> [the fact it is chosen by, "max" or "min"].
const LEADS := {
	"top_earner": ["credits", "max"], "top_reader": ["readings", "max"], "most_downed": ["downs", "max"],
	"top_healer": ["heals", "max"], "top_dropper": ["tapes_dropped", "max"], "top_recoverer": ["tapes_recovered", "max"],
	"top_starer": ["stare_seconds", "max"], "top_walker": ["distance_m", "max"], "top_emoter": ["emotes", "max"],
	"top_marker": ["marks", "max"], "top_sprinter": ["sprints", "max"], "ghost": ["distance_m", "min"],
}

func _rand_day(rng: Rng) -> Dictionary:
	var pool: Array[String] = POOL.duplicate()
	var players: Array = []
	var n := rng.int_in(1, 8)
	# A small range makes ties and zeros common; a large one makes distinct leaders.
	var hi: int = [0, 1, 2, 5, 60][rng.int_in(0, 4)]
	for i in n:
		var p := {"name": pool.pop_at(rng.int_in(0, pool.size() - 1))}
		for k in FACTS:
			p[k] = rng.int_in(0, hi) if rng.chance(0.8) else 0
		players.append(p)
	# The day's result (sim/day.gd's roll is not run here): one upgrade from each of several players
	# (possibly all, possibly none).
	var taken: Array = []
	if rng.chance(0.75):
		for p: Dictionary in players:
			if rng.chance(0.6):
				taken.append({"owner": p["name"], "upgrade": rng.pick(UPGRADES)})
	var misses := rng.int_in(1, 3)
	return {
		"day": rng.int_in(1, 30), "players": players, "quota_met": rng.chance(0.5),
		"missed_days": misses, "upgrade_taken": taken, "game_over": misses >= 3,
	}

## The award's fact key, by id, written here and not read from the file's "fact" field.
func _fact_for(id: String) -> String:
	if LEADS.has(id):
		return LEADS[id][0]
	if id.begins_with("fill_"):
		return id.substr(5)
	return ""

func _regex_for(text: String) -> RegEx:
	var pattern := "^"
	var i := 0
	while i < text.length():
		var c := text[i]
		if c == "{":
			var j := text.find("}", i)
			var slot := text.substr(i + 1, j - i - 1)
			pattern += "(?<%s>%s)" % [slot, "[A-Za-z]+" if slot == "name" else "\\d+"]
			i = j + 1
		else:
			if "\\.^$|?*+()[]{}".contains(c):
				pattern += "\\"
			pattern += c
			i += 1
	var re := RegEx.new()
	re.compile(pattern + "$")
	return re

func _template_of(id: String) -> String:
	for aw: Dictionary in Report.data()["awards"]:
		if aw["id"] == id:
			return aw["line"]
	return Report.data()["last_resort"]["line"]

func _groups(re: RegEx, text: String) -> Dictionary:
	var m := re.search(text)
	var g := {}
	if m == null:
		return g
	for k: String in ["name", "n", "day"]:
		var s := m.get_string(k)
		if s != "":
			g[k] = s
	return g

func test_data_is_well_formed(t: T) -> void:
	var seen := {}
	var tier1 := 0
	var tier2 := 0
	for aw: Dictionary in Report.data()["awards"]:
		t.check(not seen.has(aw["id"]), "duplicate award id %s" % aw["id"])
		seen[aw["id"]] = true
		t.check(FACTS.has(aw["fact"]), "%s names an unknown fact" % aw["id"])
		t.eq(aw["fact"], _fact_for(aw["id"]), "%s fact" % aw["id"])
		t.check(str(aw["title"]) != "" and str(aw["line"]).contains("{name}") and str(aw["line"]).contains("{n}"), "%s needs a title, a name and a number" % aw["id"])
		if int(aw["tier"]) == 1:
			tier1 += 1
		else:
			tier2 += 1
	t.check(tier1 + tier2 >= 12, "at least twelve awards")
	t.check(tier2 >= 8, "enough neutral awards for a crew of eight")

func test_everyone_gets_exactly_one_true_award(t: T) -> void:
	var runs := 300 if t.quick else 2000
	var checked := 0
	var leader_awards := 0
	var seen_ids := {}
	for run in runs:
		var rng := Rng.make_rng("report-days-%d" % run)
		var day := _rand_day(rng)
		var players: Array = day["players"]
		var out := Report.awards("seed-%d" % run, day)
		if not t.eq(out.size(), players.size(), "run %d: awards for players" % run):
			continue
		var ids := {}
		for i in players.size():
			var a: Dictionary = out[i]
			var p: Dictionary = players[i]
			t.eq(a["index"], i, "run %d: index" % run)
			t.eq(a["name"], p["name"], "run %d: award %d goes to the right player" % [run, i])
			t.check(not ids.has(a["id"]), "run %d: %s given twice" % [run, a["id"]])
			ids[a["id"]] = true
			seen_ids[a["id"]] = true
			var line: String = a["line"]
			t.check(not line.contains("{") and not line.contains("}"), "run %d: placeholder left in %s" % [run, line])
			var fact := _fact_for(a["id"])
			t.eq(a["fact"], fact, "run %d: %s fact" % [run, a["id"]])
			var g := _groups(_regex_for(_template_of(a["id"])), line)
			if not t.check(not g.is_empty(), "run %d: line does not match its template: %s" % [run, line]):
				continue
			t.eq(g["name"], p["name"], "run %d: name in line" % run)
			t.eq(int(g["n"]), int(p[fact]), "run %d: number in line %s" % [run, line])
			t.eq(int(a["value"]), int(p[fact]), "run %d: value" % run)
			if g.has("day"):
				t.eq(int(g["day"]), int(day["day"]), "run %d: day in line" % run)
			if LEADS.has(a["id"]):
				leader_awards += 1
				var vals: Array = []
				for q: Dictionary in players:
					vals.append(int(q[fact]))
				var extreme: int = vals.max() if LEADS[a["id"]][1] == "max" else vals.min()
				t.eq(int(p[fact]), extreme, "run %d: %s must go to a crew-wide leader" % [run, a["id"]])
		checked += 1
	t.check(checked > 0 and leader_awards > runs, "not vacuous: %d leader awards over %d days" % [leader_awards, runs])
	t.check(seen_ids.size() >= 15, "many different awards appear (%d)" % seen_ids.size())
	t.note("%d days, %d leader awards, %d distinct awards" % [checked, leader_awards, seen_ids.size()])

func test_same_input_same_report(t: T) -> void:
	var runs := 100 if t.quick else 400
	for run in runs:
		var day := _rand_day(Rng.make_rng("report-same-%d" % run))
		var a := Report.build("s-%d" % run, day)
		var b := Report.build("s-%d" % run, day.duplicate(true))
		t.check(a == b, "run %d: two builds differ" % run)

func test_upgrade_line_only_when_missed(t: T) -> void:
	var runs := 300 if t.quick else 1500
	var with_line := 0
	var many := 0
	for run in runs:
		var day := _rand_day(Rng.make_rng("report-up-%d" % run))
		var met: bool = day["quota_met"]
		var up := Report.upgrade_lost("up-%d" % run, day)
		t.check(up.is_empty() == met, "run %d: line must appear exactly when the day was missed" % run)
		t.check(Report.build("up-%d" % run, day)["upgrade"].is_empty() == met, "run %d: build agrees" % run)
		if met:
			continue
		with_line += 1
		var line: String = up["line"]
		t.check(not line.contains("{") and not line.contains("}"), "run %d: placeholder left: %s" % [run, line])
		t.eq(up["misses"], int(day["missed_days"]), "run %d: misses" % run)
		t.eq(up["game_over"], bool(day["game_over"]), "run %d: game over as given" % run)
		t.check(line.contains("%d of 3" % int(day["missed_days"])), "run %d: missed days in the line: %s" % [run, line])
		var taken: Array = day["upgrade_taken"]
		t.eq(str(up["taken"]), str(taken), "run %d: the taken list is the one given" % run)
		var names_in_line := 0
		for u: String in UPGRADES:
			names_in_line += line.count(u)
		t.eq(names_in_line, taken.size(), "run %d: exactly one upgrade name per taken upgrade: %s" % [run, line])
		if taken.size() > 1:
			many += 1
		for k: Dictionary in taken:
			t.check(line.contains("%s's %s" % [k["owner"], k["upgrade"]]), "run %d: %s's %s in the line: %s" % [run, k["owner"], k["upgrade"], line])
		# Only taken ones are named: no player is named in the possessive unless they lost one.
		var owners_named := 0
		for pl: Dictionary in day["players"]:
			if line.contains(str(pl["name"]) + "'s "):
				owners_named += 1
		t.eq(owners_named, taken.size(), "run %d: only taken upgrades are named: %s" % [run, line])
	t.check(with_line > 100 and many > 50, "not vacuous: %d missed days, %d with several upgrades" % [with_line, many])
