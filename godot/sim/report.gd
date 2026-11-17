# The end-of-day incident report (docs/floors/prison.md, section 5 and task P5; North Star H2).
# Pure rules: given one day's TRUE facts per player and a seed, give EVERY player exactly one award and,
# when the day's quota was missed, the line that says which upgrades the roll took and whose they were.
# No engine random, no clock: the same inputs give the same report on every machine. Every name and
# number in a line is copied from the facts; the roast is about what a player DID in the game.
# The awards and lines are in data/report_awards.json.
#
# THE DAY DICTIONARY (build() reads it; missing keys count as zero or empty):
#   "day":         int            the day number (shown in some lines)
#   "players":     Array          one Dictionary per player, in a fixed order the same for everyone:
#       "name":            String   non-empty, no braces (names are used as given)
#       "credits":         int      credits this player banked today
#       "readings":        int      documents read
#       "downs":           int      times caught and downed
#       "heals":           int      times they healed a downed crewmate
#       "tapes_dropped":   int      tapes dropped
#       "tapes_recovered": int      tapes picked up
#       "stare_seconds":   int      whole seconds looking at the Orderly
#       "distance_m":      int      metres walked
#       "emotes":          int      emotes used
#       "marks":           int      marks placed
#       "sprints":         int      sprints
#   "quota_met":   bool           true when the day quota was met (default true)
#   "missed_days": int            missed days this game night INCLUDING today (needed when quota_met is false)
#   "upgrade_taken": Array        every upgrade the day's roll took (sim/day.gd take_by_roll: one from EACH player who owns any),
#                                 each {"owner": player name, "upgrade": upgrade name}; absent or empty when nobody owned any
#   "game_over":   bool           true when this miss ends the game night (default false)
#   "missed_limit": int           optional, the number of misses that ends the night (default 3, from the data file; display only)
# The report never rolls: it writes the line for the result the day gives it.
# Counts are clamped to at least 0 and must be ints.
#
# NOT YET: loudest scream, flares spent on friends and the reveal of false sights (North Star H2) have no
# facts in the game today. When they do, add an award to the JSON and a key above; nothing here changes.
#
# HOW AWARDS ARE GIVEN. A "tier 1" award goes only to a crew-wide leader of its fact (the maximum, or for
# the Ghost the minimum), so the title is true. Ties are broken by the seed. A player may lead several
# stats, so tier 1 is a maximum matching (each award to at most one player, each player at most one
# award). Players left over get a neutral "tier 2" award on their strongest remaining stat, chosen
# without a superlative claim. If there are somehow more players than awards, the last resort
# ("attended") is given and may repeat. So nobody is left out and no award is given twice while others remain.
extends RefCounted

const Rng = preload("res://sim/rng.gd")
const DATA_PATH := "res://data/report_awards.json"

static var _cache: Dictionary = {}

## The awards file, parsed once.
static func data() -> Dictionary:
	if _cache.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
		if parsed is Dictionary:
			_cache = parsed
		else:
			push_error("report_awards.json did not parse")
	return _cache

## A count fact, clamped to at least 0 (anything that is not a number is 0).
static func fact_of(player: Dictionary, key: String) -> int:
	var v: Variant = player.get(key, 0)
	if v is int or v is float:
		return maxi(0, int(v))
	return 0

static func _shuffled(items: Array, rng: Rng) -> Array:
	var out: Array = items.duplicate()
	for i in range(out.size() - 1, 0, -1):
		var j: int = rng.int_in(0, i)
		var tmp: Variant = out[i]
		out[i] = out[j]
		out[j] = tmp
	return out

static func _fill(template: String, slots: Dictionary) -> String:
	var text := template
	for k: String in slots:
		text = text.replace("{%s}" % k, str(slots[k]))
	return text

## The players who may hold a tier 1 award: the crew-wide leaders of its fact.
static func _leaders(award: Dictionary, players: Array) -> Array:
	var out: Array = []
	if players.is_empty():
		return out
	var key: String = award["fact"]
	var lo := 1 << 60
	var hi := -1
	for p: Dictionary in players:
		var v := fact_of(p, key)
		lo = mini(lo, v)
		hi = maxi(hi, v)
	if award.get("mode", "max") == "min":
		if players.size() < 2 or hi <= lo:
			return out
		for i in players.size():
			if fact_of(players[i], key) == lo:
				out.append(i)
	else:
		if hi < int(award.get("min", 1)):
			return out
		for i in players.size():
			if fact_of(players[i], key) == hi:
				out.append(i)
	return out

## Kuhn's augmenting path: try to give award `a` a player, moving earlier choices if needed.
static func _augment(a: int, adj: Array, seen: Dictionary, holder: Dictionary) -> bool:
	for p: int in adj[a]:
		if seen.has(p):
			continue
		seen[p] = true
		if not holder.has(p) or _augment(holder[p], adj, seen, holder):
			holder[p] = a
			return true
	return false

## The awards. Returns an Array with one Dictionary per player, in the players' order:
## {"index": int, "name": String, "id": String, "title": String, "line": String, "fact": String, "value": int}
## ("fact" is "" and "value" 0 for the last resort).
static func awards(seed: String, day: Dictionary) -> Array[Dictionary]:
	var players: Array = day.get("players", [])
	var day_no := int(day.get("day", 0))
	var rng := Rng.make_rng("%s:report:%d" % [seed, day_no])
	var all: Array = data()["awards"]
	var tier1: Array = []
	var tier2: Array = []
	for aw: Dictionary in all:
		if int(aw["tier"]) == 1:
			tier1.append(aw)
		else:
			tier2.append(aw)
	tier1 = _shuffled(tier1, rng)
	tier2 = _shuffled(tier2, rng)
	# Tier 1: a maximum matching of awards to their leaders.
	var adj: Array = []
	for aw: Dictionary in tier1:
		adj.append(_shuffled(_leaders(aw, players), rng))
	var holder := {}   # player index -> tier1 index
	for a in tier1.size():
		_augment(a, adj, {}, holder)
	var chosen := {}   # player index -> award
	for p: int in holder:
		chosen[p] = tier1[holder[p]]
	# Tier 2: the rest, each on their strongest unused fact.
	var unmatched: Array = []
	for i in players.size():
		if not chosen.has(i):
			unmatched.append(i)
	unmatched = _shuffled(unmatched, rng)
	var used := {}
	for pi: int in unmatched:
		var best: Dictionary = {}
		var best_v := -1
		for aw: Dictionary in tier2:
			if used.has(aw["id"]):
				continue
			var v := fact_of(players[pi], aw["fact"])
			if v > best_v:
				best_v = v
				best = aw
		if best.is_empty():
			chosen[pi] = data()["last_resort"]
		else:
			used[best["id"]] = true
			chosen[pi] = best
	var out: Array[Dictionary] = []
	for i in players.size():
		var aw: Dictionary = chosen[i]
		var p: Dictionary = players[i]
		var key: String = aw["fact"]
		var value := fact_of(p, key) if key != "" else 0
		var pname: String = str(p.get("name", ""))
		out.append({
			"index": i, "name": pname, "id": aw["id"], "title": aw["title"], "fact": key, "value": value,
			"line": _fill(aw["line"], {"name": pname, "n": value, "day": day_no}),
		})
	return out
## The "upgrade lost" announcement for a missed day quota, or {} when the quota was met.
## Only WRITES the line: the roll itself is sim/day.gd's (via sim/upgrades.gd), and the day hands the result in as facts
## ("upgrade_taken", "missed_days", "game_over"). The seed only picks which wording of the line is used.
## Returns {"line": String, "taken": Array[Dictionary], "misses": int, "game_over": bool}
## taken is the list of {"owner", "upgrade"} named in the line (every one the day gave, in the given order),
## empty in the "nothing owned" case.
static func upgrade_lost(seed: String, day: Dictionary) -> Dictionary:
	if bool(day.get("quota_met", true)):
		return {}
	var day_no := int(day.get("day", 0))
	var limit := int(day.get("missed_limit", data()["upgrade_limit"]))
	var misses := maxi(1, int(day.get("missed_days", 1)))
	var final := bool(day.get("game_over", false))
	var given: Variant = day.get("upgrade_taken", [])
	var taken: Array[Dictionary] = []
	var phrases := PackedStringArray()
	if given is Array:
		for k: Variant in given:
			if k is Dictionary:
				var owner := str(k.get("owner", ""))
				var upgrade := str(k.get("upgrade", ""))
				if owner != "" and upgrade != "":
					taken.append({"owner": owner, "upgrade": upgrade})
					phrases.append("%s's %s" % [owner, upgrade])
	var kind := ("taken" if not taken.is_empty() else "empty") + ("_final" if final else "")
	var rng := Rng.make_rng("%s:upgrade-words:%d" % [seed, day_no])
	var templates: Array = data()["upgrade_lines"][kind]
	var text: String = templates[rng.int_in(0, templates.size() - 1)]
	return {
		"line": _fill(text, {"what": _list_words(phrases), "misses": misses, "limit": limit, "day": day_no}),
		"taken": taken, "misses": misses, "game_over": final,
	}

## "A", "A and B", "A, B and C".
static func _list_words(items: PackedStringArray) -> String:
	if items.size() <= 1:
		return "".join(items)
	return "%s and %s" % [", ".join(items.slice(0, items.size() - 1)), items[items.size() - 1]]

## The whole report: {"awards": Array[Dictionary], "upgrade": Dictionary ({} when the quota was met)}.
static func build(seed: String, day: Dictionary) -> Dictionary:
	return {"awards": awards(seed, day), "upgrade": upgrade_lost(seed, day)}
