# The Temp's sticky notes (docs/floors/annex.md, section 4 "The sticky notes"). Pure rules: given the
# run seed, the floor, a trigger and a dictionary of TRUE facts, pick a template with the seeded
# generator, fill it from the facts, and return the text. No engine random, no clock. Every note is
# real and the same for everyone (E3): the same inputs give the same note on every machine, and every
# name and number in it is copied from the facts. A template whose fact is missing is skipped.
# Notes never carry arrows or directions (A2): the templates are in data/annex_notes.json.
#
# THE FACTS DICTIONARY (every key optional; a template that needs a missing or invalid key is skipped):
#   "names":        Array[String]   the crew's names, in a fixed order the same for everyone
#   "alone":        Array[String]   names of crew with no crewmate near right now
#   "close_pairs":  Array           each entry [name, name2], two different crew standing very close
#   "door_passes":  Dictionary      name -> int, times that crew member walked past a lobby door
#   "sprints":      Dictionary      name -> int, times they sprinted this floor
#   "look_seconds": Dictionary      name -> int, whole seconds they looked at the Temp
#   "notes_for":    Dictionary      name -> int, this note's ordinal for them (notes about them so far, counting this one)
#   "furthest":     String          the crew member furthest from the lift
#   "marks_used":   int             marks the crew has laid this floor (0 allowed)
#   "marks_cap":    int             the shared pad size (3 by default)
#   "caught":       String          who was just caught        (trigger "catch")
#   "healed":       String          who was just healed        (trigger "heal")
#   "healer":       String          who healed them            (trigger "heal")
#   "tape_dropper": String          who dropped a tape         (trigger "tape")
#   "quota_top":    String          who did most of the quota  (trigger "quota")
#   "lift_caller":  String          who called the lift        (trigger "lift")
# Counts must be ints, at least 1 (marks_used at least 0). Names must be non-empty and hold no braces.
# Triggers: "lobby", "wake", "hunt" (every 25 s of hunting), "catch", "heal", "tape", "quota", "lift".
#
# THE STATE: new_state() gives {"count": int, "used": Array of template ids}. post() returns a new state;
# keep it with the run and pass it back, so the cap and the no-repeat rule hold.
extends RefCounted

const Rng = preload("res://sim/rng.gd")
const DATA_PATH := "res://data/annex_notes.json"

static var _cache: Dictionary = {}

## The templates file, parsed once.
static func data() -> Dictionary:
	if _cache.is_empty():
		var text := FileAccess.get_file_as_string(DATA_PATH)
		var parsed: Variant = JSON.parse_string(text)
		if parsed is Dictionary:
			_cache = parsed
		else:
			push_error("annex_notes.json did not parse")
	return _cache

static func cap_per_floor() -> int:
	return int(data().get("cap_per_floor", 14))

static func new_state() -> Dictionary:
	return {"count": 0, "used": []}

## Posts one note. Returns {"ok": bool, "text": String, "id": int, "state": Dictionary, "reason": String}.
## ok is false (with a reason) when the floor's cap is reached, the trigger is unknown or no template can be filled.
static func post(seed: String, floor_number: int, trigger: String, facts: Dictionary, state: Dictionary) -> Dictionary:
	var count: int = int(state.get("count", 0))
	var used: Array = (state.get("used", []) as Array).duplicate()
	var out := {"ok": false, "text": "", "id": 0, "state": {"count": count, "used": used}, "reason": ""}
	if count >= cap_per_floor():
		out["reason"] = "cap"
		return out
	var fresh: Array = []
	var stale: Array = []
	for tpl: Dictionary in data().get("templates", []):
		if not (tpl.get("triggers", []) as Array).has(trigger):
			continue
		if used.has(int(tpl["id"])):
			stale.append(tpl)
		else:
			fresh.append(tpl)
	if fresh.is_empty() and stale.is_empty():
		out["reason"] = "trigger"
		return out
	# One generator per posting, from the seed, the floor and how many notes came before.
	var rng := Rng.make_rng("%s:notes:%d:%d" % [seed, floor_number, count])
	for group: Array in [fresh, stale]:
		while not group.is_empty():
			var i: int = rng.int_in(0, group.size() - 1)
			var tpl: Dictionary = group[i]
			group.remove_at(i)
			var text := fill(tpl, facts, rng)
			if text != "":
				used.append(int(tpl["id"]))
				return {"ok": true, "text": text, "id": int(tpl["id"]), "state": {"count": count + 1, "used": used}, "reason": ""}
	out["reason"] = "facts"
	return out

## Fills one template from the facts, or "" when any slot cannot be filled.
static func fill(tpl: Dictionary, facts: Dictionary, rng: Rng) -> String:
	var values := {}
	var pair_index := {}
	var slots: Dictionary = tpl.get("slots", {})
	var min_n: int = int(tpl.get("min", 1))
	for slot: String in slots:
		var parts: PackedStringArray = String(slots[slot]).split(":")
		var v: Variant = null
		match parts[0]:
			"fact":
				v = facts.get(parts[1], null)
			"any":
				var list: Variant = facts.get(parts[1], null)
				if list is Array and not (list as Array).is_empty():
					v = (list as Array)[rng.int_in(0, (list as Array).size() - 1)]
			"pair":
				var pairs: Variant = facts.get(parts[1], null)
				if pairs is Array and not (pairs as Array).is_empty():
					if not pair_index.has(parts[1]):
						pair_index[parts[1]] = rng.int_in(0, (pairs as Array).size() - 1)
					var pr: Variant = (pairs as Array)[pair_index[parts[1]]]
					if pr is Array and (pr as Array).size() == 2:
						v = (pr as Array)[int(parts[2])]
			"by":
				var table: Variant = facts.get(parts[1], null)
				if table is Dictionary and values.has(parts[2]):
					v = (table as Dictionary).get(values[parts[2]], null)
		if v is String:
			if not _good_name(v):
				return ""
		elif typeof(v) == TYPE_INT:
			if int(v) < min_n:
				return ""
		else:
			return ""
		values[slot] = v
	if values.has("name") and values.has("name2") and values["name"] == values["name2"]:
		return ""
	return _substitute(String(tpl["text"]), values)

static func _good_name(s: String) -> bool:
	return s != "" and not s.contains("{") and not s.contains("}")

# One pass over the template, so a name that looks like a placeholder is never filled twice.
static func _substitute(text: String, values: Dictionary) -> String:
	var out := ""
	var i := 0
	while i < text.length():
		var c := text[i]
		if c == "{":
			var j := text.find("}", i)
			var key := text.substr(i + 1, j - i - 1)
			if j < 0 or not values.has(key):
				return ""
			out += str(values[key])
			i = j + 1
		else:
			out += c
			i += 1
	return out
