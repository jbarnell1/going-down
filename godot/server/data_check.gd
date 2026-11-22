# The data files the rules read at run time, and the dedicated server's start-up check of them
# (server/server.gd). On 18 Nov the Linux server preset left data/* out of the build: the rules could not
# load the Temp's sticky notes, the report's awards or the upgrades, and nothing noticed, because every
# network test runs the server from the project folder, where the files exist. Now the server reads each
# file below through the rules' own loader before it listens, and refuses to start if one is missing or
# empty: `not started: the build is missing data/<file>`.
#
# FILES is the one list. tests/test_data_check.gd fails if a res:// path to a data/<name>.json file appears anywhere in
# sim/, net/ or server/ without being in it, and if any file in it does not read in the project; adding a
# file here without a loader in read() fails the check (and that test) too.
# data/tapes.json and data/pixel_font.json are the client's (client/), never read by a server.
extends RefCounted

const Notes = preload("res://sim/notes.gd")
const Report = preload("res://sim/report.gd")
const Upgrades = preload("res://sim/upgrades.gd")
const Findables = preload("res://sim/findables.gd")
const Inventory = preload("res://sim/inventory.gd")
const Homes = preload("res://sim/ward/homes.gd")

## Every data file the rules (sim/, net/, server/) read at run time.
const FILES: Array[String] = [
	"res://data/annex_notes.json",  # sim/notes.gd: the Temp's sticky notes
	"res://data/report_awards.json",  # sim/report.gd: the day's report awards
	"res://data/upgrades.json",  # sim/upgrades.gd: the upgrade tree
	"res://data/poems.json",  # sim/findables.gd: the poem notes and lore pages found by searching
	"res://data/items.json",  # sim/inventory.gd: the items a slot can hold
	"res://data/ward_homes.json",  # sim/ward/homes.gd: the Hanging Ward's house types (WH1, ward_homes)
]

## How much of `path` the rules' own loader read: the count of its entries (templates, awards, nodes);
## 0 when it did not parse or is empty, -1 when this check has no loader for it.
static func read(path: String) -> int:
	match path:
		"res://data/annex_notes.json":
			return (Notes.data().get("templates", []) as Array).size()
		"res://data/report_awards.json":
			return (Report.data().get("awards", []) as Array).size()
		"res://data/upgrades.json":
			for id: String in ["deep_pockets", "second_wind", "soft_shoes", "long_burn"]:
				if Upgrades.induction_node(id).is_empty():
					return 0
			return Upgrades.nodes().size() + 3
		"res://data/poems.json":
			return (Findables.data().get("poems", []) as Array).size()
		"res://data/items.json":
			return (Inventory.data().get("items", []) as Array).size()
		"res://data/ward_homes.json":
			return Homes.types().size()
	return -1

## Reads every file in FILES. Returns {"ok": bool, "files": int (read), "missing": "<file name>" (the
## first that failed), "why": "did not read" | "no loader"}. `unreadable`: test hook, a file name (for
## example "annex_notes.json") this check treats as not read, so the refusal can be proved without
## touching the files (server argument `test_unreadable=`).
static func run(unreadable: String = "") -> Dictionary:
	var n := 0
	for path in FILES:
		var got := 0 if path.get_file() == unreadable else read(path)
		if got <= 0:
			return {"ok": false, "files": n, "missing": path.get_file(), "why": "no loader" if got < 0 else "did not read"}
		n += 1
	return {"ok": true, "files": n, "missing": "", "why": ""}
