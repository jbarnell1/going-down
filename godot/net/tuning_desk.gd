# The desk: what the host has asked for (docs/floors/live-settings.md, piece LS2). It lives in the room (the
# server's server/room.gd, or net/local_room.gd when playing alone), outlasts runs, checks every change with
# Settings.check (the only door), keeps the settings file, and decides when each asked-for value goes into force.
#
#   asked      every value the host has asked for that differs from the game's ({id: number}, snapped)
#   in force   what the run reads (RunState.tuning, through net/host.gd set_tuning): the asked-for values whose
#              kind lets them in now. `now` and `next` go in at once (the rules stamp `next` clocks themselves);
#              `floor` waits for the run's "carLeft" and `day` for its "lightsOut" (on_events). With no run on,
#              and from the first tick of every run, everything asked for is in force.
#   rev        bumps on every accepted change (and on a hand edit of the file): the panel and the snapshots
#              say which revision they show.
#
# The file (`path`; "" for none: the values then last until the room is gone, and nothing is written):
#   {"v": 1, "rev": 12, "saved": "2026-11-20T21:14:03", "by": "JON", "set": {"orderly.speed": 3.6}}
#   Saved on every accepted change (to PATH.tmp, then renamed over PATH, so a crash never leaves half a file),
#   with one line a change appended to PATH.log (time, who, id, was, now). Loaded when the desk is made, and
#   again whenever its modified time changes (looked at every LOOK_EVERY seconds by poll): a hand edit is a
#   change like any other, announced as THE HOUSE. An entry the registry does not know, that is not a number,
#   or that is outside least to most (or breaks a pair rule) is skipped and logged; the rest is kept. Values
#   are never clamped. A file that does not parse is ignored whole and logged, and renamed PATH.bad at the
#   next save.
#
# Notes: every accepted change returns a note, {kind, by, id, was, v, when, line}: kind "set", "reset",
# "all" (reset all), "house" (a hand edit); `line` is the one line every screen shows (line_for).
extends RefCounted

const Settings = preload("res://sim/settings.gd")

const FILE_VERSION := 1
## At most this many changes a second from one connection; more are refused as "busy".
const MAX_PER_SECOND := 10
## Seconds between looks at the file's modified time.
const LOOK_EVERY := 2.0
## A wired setting only, unless a test says otherwise (accept_unwired: the floor and day holding is tested
## with a row nothing reads yet).
var accept_unwired := false
var asked := {}
var rev := 0
var path := ""
## When the file was last written or read ("" for never), and by whom.
var saved_at := ""
var saved_by := ""
## The log's lines ("settings: ..."), also kept for tests.
var logged: Array[String] = []
var _force := {}
var _running := false
var _log: Callable
var _mtime := 0
var _last_look := -INF
var _bad_file := false
var _rate := {}  # connection -> [times]

func _init(file_path: String = "", log: Callable = Callable()) -> void:
	path = file_path
	_log = log
	if not path.is_empty():
		_load(false)
		_mtime = _modified()

func _say(text: String) -> void:
	logged.append(text)
	if _log.is_valid():
		_log.call(text)

# ---------------------------------------------------------------------------------------------
# What is in force.

## The values in force ({id: number}; empty for none).
func in_force() -> Dictionary:
	return _force.duplicate()

## The asked-for values that are not in force yet ({id: [asked or null for the game's, in force or null]}).
func waiting() -> Dictionary:
	var out := {}
	for id: StringName in _all_ids():
		var a: Variant = asked.get(id)
		var f: Variant = _force.get(id)
		if a != f:
			out[id] = [a, f]
	return out

## A run starts: everything asked for is in force from its first tick.
func run_started() -> void:
	_running = true
	_force = asked.duplicate()

## The run is over: everything asked for is in force (nothing to wait for).
func run_ended() -> void:
	_running = false
	_force = asked.duplicate()

## A tick's events: "carLeft" lets the waiting `floor` values in, "lightsOut" the `day` values. True when the
## values in force changed.
func on_events(events: Array) -> bool:
	var kinds: Array[StringName] = []
	for e: Variant in events:
		if not e is Dictionary:
			continue
		var ty := str((e as Dictionary).get("type", ""))
		if ty == "carLeft" and not kinds.has(&"floor"):
			kinds.append(&"floor")
		elif ty == "lightsOut" and not kinds.has(&"day"):
			kinds.append(&"day")
	var changed := false
	for k in kinds:
		changed = _sync(k) or changed
	return changed

## Puts every asked-for value of kind `holds` in force (or every kind for &""). True when anything changed.
func _sync(holds: StringName) -> bool:
	var changed := false
	for id: StringName in _all_ids():
		var row := Settings.row(id)
		if row == null or (holds != &"" and row.holds != holds):
			continue
		var a: Variant = asked.get(id)
		if a == _force.get(id):
			continue
		changed = true
		if a == null:
			_force.erase(id)
		else:
			_force[id] = a
	return changed

func _all_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for id: StringName in asked:
		out.append(id)
	for id: StringName in _force:
		if not out.has(id):
			out.append(id)
	return out

## After a change to `id`: in force at once unless a run is on and it waits for the car or the night.
func _place(id: StringName) -> void:
	var row := Settings.row(id)
	if _running and row != null and (row.holds == &"floor" or row.holds == &"day"):
		return
	if asked.has(id):
		_force[id] = asked[id]
	else:
		_force.erase(id)

# ---------------------------------------------------------------------------------------------
# Changes.

## Whether `conn` may make another change at `now` (MAX_PER_SECOND a second).
func _rate_ok(conn: String, now: float) -> bool:
	if conn.is_empty():
		return true
	var times: Array = _rate.get(conn, [])
	var kept: Array = []
	for t: float in times:
		if now - t < 1.0:
			kept.append(t)
	if kept.size() >= MAX_PER_SECOND:
		_rate[conn] = kept
		return false
	kept.append(now)
	_rate[conn] = kept
	return true

## The asked-for values without `id`.
func _others(id: StringName) -> Dictionary:
	var out := asked.duplicate()
	out.erase(id)
	return out

## The host asks for `value` of `id`. Returns [reason, note]: reason &"" when accepted (note the change's
## note, or {} when it changed nothing), else &"id" | &"range" | &"pair" | &"busy" (note {}).
func ask(id: StringName, value: Variant, by: String, conn: String = "", now: float = 0.0) -> Array:
	var row := Settings.row(id)
	if row == null or (not row.wired and not accept_unwired):
		return [&"id", {}]
	var why := Settings.check(id, value, _others(id))
	if why != &"":
		return [why, {}]
	if not _rate_ok(conn, now):
		return [&"busy", {}]
	var v := Settings.snap(id, float(value))
	var was := float(asked.get(id, row.today))
	if absf(was - v) < Settings.EPS:
		return [&"", {}]
	if Settings.differs(id, v):
		asked[id] = v
	else:
		asked.erase(id)
	_place(id)
	var note := {"kind": "set" if Settings.differs(id, v) else "reset", "by": by, "id": String(id), "was": was, "v": v, "when": String(row.holds)}
	note["line"] = line_for(note)
	_changed(by, [[id, was, v]])
	return [&"", note]

## The host puts `id` back to the game's value. Same returns as ask().
func reset(id: StringName, by: String, conn: String = "", now: float = 0.0) -> Array:
	var row := Settings.row(id)
	if row == null:
		return [&"id", {}]
	return ask(id, row.today, by, conn, now)

## The host puts every setting back. A note of kind "all" ({} when nothing was changed).
func reset_all(by: String, conn: String = "", now: float = 0.0) -> Array:
	if not _rate_ok(conn, now):
		return [&"busy", {}]
	if asked.is_empty():
		return [&"", {}]
	var rows: Array = []
	for id: StringName in asked:
		rows.append([id, float(asked[id]), Settings.today(id)])
	asked = {}
	for r: Array in rows:
		_place(r[0])
	var note := {"kind": "all", "by": by, "id": "", "was": 0.0, "v": 0.0, "when": "now", "n": rows.size()}
	note["line"] = line_for(note)
	_changed(by, rows)
	return [&"", note]

func _changed(by: String, rows: Array) -> void:
	rev += 1
	_save(by, rows)

# ---------------------------------------------------------------------------------------------
# The words.

## A setting as the notice names it: a resident's section first ("ORDERLY HUNT SPEED"), else the row's name.
static func label(id: StringName) -> String:
	var row := Settings.row(id)
	if row == null:
		return String(id).to_upper()
	match row.section:
		&"orderly":
			return "ORDERLY " + row.name
		&"temp":
			return "TEMP " + row.name
		&"minder":
			return "MINDER " + row.name
	return row.name

## A value without its unit ("3.80").
static func bare(id: StringName, value: float) -> String:
	return ("%." + str(Settings.decimals(id)) + "f") % value

## The one line every screen shows for a note.
static func line_for(note: Dictionary) -> String:
	var by := str(note.get("by", "")).to_upper()
	if by.is_empty():
		by = "THE HOST"
	var id := StringName(str(note.get("id", "")))
	match str(note.get("kind", "")):
		"all":
			return "%s PUT EVERY SETTING BACK" % by
		"reset":
			return "%s PUT %s BACK TO %s%s" % [by, label(id), Settings.text(id, float(note["v"])), _waits(note)]
		"house":
			return "THE HOUSE SET %s %s > %s%s" % [label(id), bare(id, float(note["was"])), Settings.text(id, float(note["v"])), _waits(note)]
	return "%s SET %s %s > %s%s" % [by, label(id), bare(id, float(note["was"])), Settings.text(id, float(note["v"])), _waits(note)]

static func _waits(note: Dictionary) -> String:
	match str(note.get("when", "")):
		"floor":
			return ". FROM THE NEXT FLOOR."
		"day":
			return ". FROM TOMORROW."
	return ""

## The line a player who joins gets ("" when nothing is changed).
func join_line() -> String:
	var n := asked.size()
	if n == 0:
		return ""
	return ("1 SETTING IS CHANGED TONIGHT. F8 TO SEE." if n == 1 else "%d SETTINGS ARE CHANGED TONIGHT. F8 TO SEE." % n)

## The room message everyone gets ({"t": "tune", ...}): the revision, the host, every asked-for value, the
## values in force when they differ, when the file was saved (or that there is none), and the note's line.
func message(host: String, note: Dictionary = {}, line: String = "") -> Dictionary:
	var set := {}
	for id: StringName in asked:
		set[String(id)] = asked[id]
	var m := {"t": "tune", "rev": rev, "host": host, "set": set, "file": not path.is_empty(), "saved": saved_at}
	var w := waiting()
	if not w.is_empty():
		var force := {}
		for id: StringName in _force:
			force[String(id)] = _force[id]
		m["force"] = force
	var l := str(note.get("line", line))
	if not l.is_empty():
		m["line"] = l
	if not note.is_empty():
		m["note"] = note
	return m

# ---------------------------------------------------------------------------------------------
# The file.

func _modified() -> int:
	if path.is_empty() or not FileAccess.file_exists(path):
		return 0
	return FileAccess.get_modified_time(path)

static func _stamp() -> String:
	return Time.get_datetime_string_from_system(false, false)

## Looks at the file every LOOK_EVERY seconds; a file changed by hand is loaded. Returns the notes of what it
## changed ([] for nothing).
func poll(now: float) -> Array[Dictionary]:
	var none: Array[Dictionary] = []
	if path.is_empty() or now - _last_look < LOOK_EVERY:
		return none
	_last_look = now
	var m := _modified()
	if m == _mtime:
		return none
	_mtime = m
	return _load(true)

## Reads the file. `announce`: a hand edit (rev bumps, notes for every change, history lines).
func _load(announce: bool) -> Array[Dictionary]:
	var notes: Array[Dictionary] = []
	if not FileAccess.file_exists(path):
		return notes
	var text := FileAccess.get_file_as_string(path)
	var json := JSON.new()
	var p: Variant = json.data if json.parse(text) == OK else null
	if not p is Dictionary or not (p as Dictionary).get("set") is Dictionary:
		_bad_file = true
		_say("settings: %s does not parse, ignored (kept as .bad at the next save)" % path.get_file())
		return notes
	_bad_file = false
	var d: Dictionary = p
	var given: Dictionary = d["set"]
	# Each entry on its own first (known, a number, in range), then each against all the others (the pair rules
	# hold between the file's own values, whatever order they are written in).
	var fine := {}
	for k: Variant in given:
		var id := StringName(str(k))
		var row := Settings.row(id)
		var v: Variant = given[k]
		var why := &"id" if row == null or (not row.wired and not accept_unwired) else Settings.check(id, v, {})
		if why == &"pair":
			why = &""
		if why != &"":
			_say("settings: %s %s %s, skipped" % [str(k), str(v), _why_words(id, why)])
			continue
		fine[id] = Settings.snap(id, float(v))
	var got := {}
	for id: StringName in fine:
		var others := fine.duplicate()
		others.erase(id)
		if Settings.check(id, fine[id], others) != &"":
			_say("settings: %s %s %s, skipped" % [String(id), str(fine[id]), _why_words(id, &"pair")])
			continue
		if Settings.differs(id, fine[id]):
			got[id] = fine[id]
	var rows: Array = []
	for id: StringName in got:
		if asked.get(id) != got[id]:
			rows.append([id, float(asked.get(id, Settings.today(id))), float(got[id])])
	for id: StringName in asked:
		if not got.has(id):
			rows.append([id, float(asked[id]), Settings.today(id)])
	asked = got
	saved_at = str(d.get("saved", ""))
	saved_by = str(d.get("by", ""))
	rev = maxi(rev, int(d.get("rev", 0)) if (d.get("rev") is float or d.get("rev") is int) else 0)
	if not announce:
		_force = asked.duplicate()
		return notes
	if rows.is_empty():
		return notes
	rev += 1
	for r: Array in rows:
		_place(r[0])
		var row := Settings.row(r[0])
		var note := {"kind": "house" if Settings.differs(r[0], r[2]) else "reset", "by": "THE HOUSE", "id": String(r[0]), "was": r[1], "v": r[2], "when": String(row.holds)}
		note["line"] = line_for(note)
		notes.append(note)
	_history("THE HOUSE", rows)
	return notes

static func _why_words(id: StringName, why: StringName) -> String:
	var row := Settings.row(id)
	match why:
		&"id":
			return "is not a setting this build knows"
		&"range":
			return "is outside %s to %s" % [bare(id, row.lo), bare(id, row.hi)] if row != null else "is not a number"
		&"pair":
			return "breaks a pair rule"
	return "is refused (%s)" % why

func _save(by: String, rows: Array) -> void:
	saved_by = by
	if path.is_empty():
		return
	var abs := ProjectSettings.globalize_path(path)
	if _bad_file and FileAccess.file_exists(path):
		DirAccess.rename_absolute(abs, abs + ".bad")
		_bad_file = false
	var set := {}
	for id: StringName in asked:
		set[String(id)] = asked[id]
	saved_at = _stamp()
	var text := JSON.stringify({"v": FILE_VERSION, "rev": rev, "saved": saved_at, "by": by, "set": set})
	var f := FileAccess.open(abs + ".tmp", FileAccess.WRITE)
	if f == null:
		_say("settings: cannot write %s (error %d)" % [path.get_file(), FileAccess.get_open_error()])
		return
	f.store_string(text + "\n")
	f.close()
	# Renamed over the old file (POSIX rename replaces it at once; Godot's Windows rename replaces it too).
	var err := DirAccess.rename_absolute(abs + ".tmp", abs)
	if err != OK:
		_say("settings: cannot rename the new file into place (error %d)" % err)
	_mtime = _modified()
	_history(by, rows)

func _history(by: String, rows: Array) -> void:
	if path.is_empty():
		return
	var abs := ProjectSettings.globalize_path(path) + ".log"
	var f := FileAccess.open(abs, FileAccess.READ_WRITE if FileAccess.file_exists(abs) else FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	for r: Array in rows:
		f.store_line("%s\t%s\t%s\t%s\t%s" % [_stamp(), by, String(r[0]), bare(r[0], float(r[1])), bare(r[0], float(r[2]))])
	f.close()
