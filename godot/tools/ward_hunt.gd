# WD1: how hard the Hanging Ward is. Bot crews (sim/ward/bots.gd) of each size and skill stay one Ward each, over many
# seeds, by the Ward's own rules; the table says how often the Rigger comes, who he catches, when and where, what is
# recorded against the quota and carried aboard, who is left behind, and how short the warning ever was.
#   "$GODOT" --headless --path godot --script res://tools/ward_hunt.gd -- seeds=200 crews=1,2,4,6 skills=careless,sensible,expert
# Extra arguments: from=<first seed>, heal=1 (a caught player can be stood up by a crewmate: the owner's open question,
# measured, not built), set=<id>:<value>,<id>:<value> (live settings, sim/settings.gd), json=<file> (every stay),
# roam=1 (RR1: the solid, crawling Rigger and his chase, the run flag rigger_roam).
extends SceneTree

const Bots = preload("res://sim/ward/bots.gd")
const Settings = preload("res://sim/settings.gd")

func _init() -> void:
	var seeds := 200
	var first := 1
	var crews: Array = [1, 2, 4, 6]
	var skills: Array = ["careless", "sensible", "expert"]
	var heal := false
	var given := {}
	var json := ""
	var roam := false
	for arg in OS.get_cmdline_user_args():
		var kv := arg.split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"seeds": seeds = int(kv[1])
			"from": first = int(kv[1])
			"crews": crews = Array(kv[1].split(",")).map(func(s: String) -> int: return int(s))
			"skills": skills = Array(kv[1].split(","))
			"heal": heal = kv[1] == "1"
			"json": json = kv[1]
			"roam": roam = kv[1] == "1"
			"set":
				for pair in kv[1].split(","):
					var p := pair.split(":")
					given[StringName(p[0])] = float(p[1])
	var tuning: Settings.Values = Settings.make(given) if not given.is_empty() else null
	var all := []
	print("seeds %d..%d heal=%s roam=%s set=%s" % [first, first + seeds - 1, heal, roam, str(given)])
	print("(per stay: climb s, search s, bot-seconds recording the climb, the search: printed after each row)")
	print("| crew | skill | comes/stay | stays he came | caught/stay | stays anyone caught | all home | recorded | quota met | carried aboard | left uncaught | no danger | near escape | warn min s | caught where | stood up/stay |")
	print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
	for skill: String in skills:
		for n: int in crews:
			var rows := []
			for k in seeds:
				rows.append(Bots.stay(first + k, n, StringName(skill), {"tuning": tuning, "heal": heal, "roam": roam}))
			all.append_array(rows)
			print(line(rows, n, skill))
			var sums := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
			for r: Dictionary in rows:
				sums[0] += float(r.get("climb_s", 0.0))
				sums[1] += float(r.get("search_s", 0.0))
				sums[2] += float(r.get("rec_climb_s", 0.0))
				sums[3] += float(r.get("rec_search_s", 0.0))
				sums[4] += float(r.get("inside_s", 0.0))
				sums[5] += float(r.get("inside_raised_s", 0.0))
			var by := {}
			for r: Dictionary in rows:
				for k: String in r:
					if k.begins_with("earn_") or k == "readings":
						by[k] = float(by.get(k, 0.0)) + float(r[k]) / rows.size()
			print("|   | earned by his state at the reading's close | %s |" % str(by))
			print("|   | time | climb %.0f s | search %.0f s | recording climb %.0f bot-s | recording search %.0f bot-s | in the searched house %.0f bot-s, raised %.0f |" % [sums[0] / rows.size(), sums[1] / rows.size(), sums[2] / rows.size(), sums[3] / rows.size(), sums[4] / rows.size(), sums[5] / rows.size()])
	if json != "":
		var f := FileAccess.open(json, FileAccess.WRITE)
		f.store_string(JSON.stringify(all))
	quit(0)

static func line(rows: Array, n: int, skill: String) -> String:
	var c := float(rows.size())
	var comes := 0.0
	var came := 0
	var caught := 0.0
	var any := 0
	var home := 0
	var earned := 0.0
	var met := 0
	var banked := 0.0
	var left := 0.0
	var calm := 0
	var near := 0
	var warn := INF
	var where := {}
	var heals := 0.0
	for r: Dictionary in rows:
		comes += r.comes
		came += 1 if r.comes > 0 else 0
		caught += r.caught_n
		any += 1 if r.caught_n > 0 else 0
		home += 1 if r.home == n else 0
		earned += r.earned
		met += 1 if r.earned >= r.needed else 0
		banked += r.banked
		left += r.lost_uncaught
		calm += 1 if (not r.danger and r.searched_in == 0 and r.caught_n == 0) else 0
		near += 1 if (r.caught_n == 0 and (r.danger or r.searched_in > 0)) else 0
		warn = minf(warn, r.warn_min)
		heals += r.heals
		for e: Dictionary in r.caught:
			var key := "%s/%s" % [e.phase, e.room]
			where[key] = int(where.get(key, 0)) + 1
	return "| %d | %s | %.2f | %d%% | %.2f | %d%% | %d%% | %d of %d | %d%% | %d | %.2f | %d%% | %d%% | %s | %s | %.2f |" % [n, skill, comes / c,
		roundi(100.0 * came / c), caught / c, roundi(100.0 * any / c), roundi(100.0 * home / c), roundi(earned / c),
		int(rows[0].needed), roundi(100.0 * met / c), roundi(banked / c), left / c, roundi(100.0 * calm / c),
		roundi(100.0 * near / c), ("%.2f" % warn) if warn < INF else "-", str(where), heals / c]
