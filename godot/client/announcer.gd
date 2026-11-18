# The cheerful synthetic announcer (H5): plays the right recorded line for each moment, one at a time,
# at one even loudness (the recordings are all at -16 LUFS; the Voice bus is a band-limited speaker
# with a compressor), never the same line twice running (each moment's lines are dealt from a shuffled
# deck), with subtitles. The moments and what triggers them follow src/game/announcer.ts onEvents.
#
# The Playroom's count (client/hide_view.gd; docs/floors/playarea.md 10): say_count(line, text) shows
# every line as a caption in the pixel font and plays its recording by id (client/count_lines.gd, T15i),
# not through request() (that deals a random line of a moment). The lines go on their own player; the
# numbers on another, each stopping the one before. Both are on the Voice bus, like this player.
#
# The floor quota met ("quotaMet", North Star C9): the moment "quota" (quota_1 to quota_3).
#
# The hints (docs/floors/announcer-hints.md, AH1): hint(id) asks client/hints.gd's gate, and a hint goes
# through the same queue as every line, with these differences: it starts only when none of the three
# players is playing and the count allows (Hints.may_start); it never cuts a line; it is heard only once
# it starts (a cut hint is given back); it lives 6 s in the queue (3 s at priority 4). "Replaces": where
# a hint stands in for a line (hint_board for "arrived", the arrival hints for "doors"), the line is
# asked for only when the gate refuses the hint. The conditions only this screen knows (winded, a hide,
# your own status, the waiting car) are client/hint_cues.gd's. The player's record of what they have
# heard (the first-timer hints retire after two nights) and HINTS: ON / OFF are kept in user://hints.cfg.
#
# Lines the place makes wrong (announcer-hints.md 4): doors_1 and slip_2 (a hospital) are dealt only on
# the Clinic; arrived_5 and blackout_3 (running) are never dealt on the Playroom.
#
# The waiting car (FD4) and nobody coming back (findables-and-day.md): the moments "car_waiting" (asked
# for by hint_cues.gd with the panel's CAR WAITING FOR as a second caption line) and "day_wiped" (home
# after a wipe that took someone's upgrade).
#
# The day quota (FD3, findables-and-day.md "The lines"): "bankRefused" asks for "bank_refused" (one line dealt
# per refusal, never the same twice running) in place of that bell's ride line, and "dayMet" for "day_met";
# both with the caption "EARNED 1650 OF 2400" from the event (the recordings carry no numbers); a day_met
# line stands in for the floor's quota line when both come in one tick (it says the call works, and more). hint_day
# stands in for the ride line on the night's first ride down of its first day (days on).
class_name Announcer
extends Node

const CountLines = preload("res://client/count_lines.gd")
const Hints = preload("res://client/hints.gd")
const DayCaption = preload("res://client/day_view.gd")

const EXPIRE_MS := 4000
const EXPIRE_LONG_MS := 9000
const EXPIRE_BOARD_MS := 12000
const GAP_MS := 450
## The floor quota met, when no "quota" line is recorded.
const QUOTA_CAPTION := "Quota met! The car may now be called."
## The player's own hint record and setting.
const SAVE_PATH := "user://hints.cfg"
## Lines dealt only on some places: id -> the places it may be dealt on ("only") or never ("never").
const PLACE_ONLY := {"doors_1": ["clinic"], "slip_2": ["clinic"]}
const PLACE_NEVER := {"arrived_5": ["playroom"], "blackout_3": ["playroom"]}

var voice := "bella"
var lines := {}          # id -> {moment, plain}
var by_moment := {}      # moment -> [ids]
var priority := {}       # moment -> int
var decks := {}
var last_of := {}
var queue: Array = []    # [{id, moment, priority, expires, hint, caption2}]
var current := {}
var subtitle := ""
var history: Array = []  # [{id, moment, at, end, hint}]
var blackout_on := false
var player: AudioStreamPlayer
var _gap_until := 0
var _rng := RandomNumberGenerator.new()
## The count's lines: the caption shown (and until when, ms), the two players, and what was said
## ({line, text, at, id}: tests).
var caption := ""
var caption_until := 0
var count_player: AudioStreamPlayer
var number_player: AudioStreamPlayer
var said_count: Array = []

## The hints' gate (client/hints.gd) and what it needs from the game: this screen's player id, the place
## of the floor ("clinic", "annex", "playroom", "prison"), whether the run has days, and the Playroom
## count as this screen has it ({phase, left, len, last}: set by main.gd each frame).
var hints := Hints.new()
var my_id := ""
var place := ""
var days_on := false
## The run has the day quota's lock (the day block carries earned; set by main.gd each frame): the monitor shows the day.
var day_lock_on := false
var count_ctx := {}
## Save the player's hint record (off under automation and in tests).
var persist := true
## Tests: a clock (ms) in place of the engine's, and no audio: a line "plays" for its estimated length.
var clock_ms := -1
var fake := false
var _fake_until := {"main": 0, "count": 0, "number": 0}
## Tests: every hint asked for, started, cut or expired [{what, id, moment, at, busy}].
var hint_log: Array = []
## Tests: every line asked for with request() [{moment, id, at, place}].
var request_log: Array = []
## Hints and lines due later [{at, id, unless}] and hints waiting for a count line to end [{id, delay}].
var _later: Array = []
var _after_count: Array = []
# What the hints' triggers remember: days since the night began, boardings this night, the vote hint
# asked for, an Annex seen tonight, marks placed this floor, someone in bed since home, a wipe today and
# whether it took an upgrade.
var _day_n := 0
var _rides := 0
var _boardings := 0
var _vote_cued := false
var _annex_seen := false
var _marks_floor := 0
var _bed_seen := false
var _wiped_day := false
var _day_took := false

func _ready() -> void:
	_rng.randomize()
	player = AudioStreamPlayer.new()
	player.bus = "Voice"
	# -5 dB: in the browser the Voice bus's compressor does not apply, and at -1 the lines clipped.
	player.volume_db = -5.0
	add_child(player)
	player.finished.connect(_on_finished)
	count_player = AudioStreamPlayer.new()
	count_player.bus = "Voice"
	count_player.volume_db = -5.0
	add_child(count_player)
	number_player = AudioStreamPlayer.new()
	number_player.bus = "Voice"
	number_player.volume_db = -5.0
	add_child(number_player)
	var m: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/voice/manifest.json"))
	if m is Dictionary:
		use_manifest(m)
	_load()

## The manifest's moments and lines (res://assets/voice/manifest.json; tests pass it in).
func use_manifest(m: Dictionary) -> void:
	for mo: String in m.moments:
		priority[mo] = int(m.moments[mo].priority)
	for l: Dictionary in m.lines:
		lines[l.id] = l
		if not by_moment.has(l.moment):
			by_moment[l.moment] = []
		by_moment[l.moment].append(l.id)

func _log(d: Dictionary) -> void:
	hint_log.append(d)
	if hint_log.size() > 600:
		hint_log = hint_log.slice(hint_log.size() - 400)

func _ms() -> int:
	return clock_ms if clock_ms >= 0 else Time.get_ticks_msec()

## A run begins (a new night), or a new day's morning (new_night false): the boarding line.
func start_run(new_night := true, night_key := "") -> void:
	queue.clear()
	_later.clear()
	_after_count.clear()
	blackout_on = false
	var now := _ms()
	if new_night:
		hints.new_night(night_key if night_key != "" else "%d-%d" % [int(Time.get_unix_time_from_system()), _rng.randi() % 100000], now)
		_day_n = 0
		_rides = 0
		_boardings = 0
		_vote_cued = false
		_annex_seen = false
	else:
		hints.new_day(now)
		_day_n += 1
	_marks_floor = 0
	_wiped_day = false
	_day_took = false
	request("board", EXPIRE_BOARD_MS)

## The run's events from a frame.
func on_events(events: Array, first_depth := 1) -> void:
	var now := _ms()
	var wiped := false
	# Down first, then out: a catch that puts its player down is not yet a loss (a crewmate may get them
	# up), so the "taken" line waits for the "out".
	var downed := {}
	# The day lock (FD3): a refused BANK's line stands in for the ride line of the same bell.
	var refused := false
	# The day quota met (FD3) says more than the floor's quota line of the same tick: it stands in for it.
	var day_met := false
	for e: Dictionary in events:
		if e.type == "wiped":
			wiped = true
		elif e.type == "downed":
			downed[str(e.get("playerId", ""))] = true
		elif e.type == "bankRefused":
			refused = true
		elif e.type == "dayMet":
			day_met = true
	for e: Dictionary in events:
		match str(e.type):
			"doorsOpened":
				if e.reason == "arrival":
					_arrival(int(e.depth), first_depth, now)
			"rodeDown", "rodeUp":
				_new_floor()
			"carLeft":
				if e.reason == "unloaded" or e.reason == "empty":
					request("left")
				elif e.reason == "ride" and not refused:
					# The night's first ride down of its first day (with the day quota on the monitor): hint_day
					# in place of the ride line; refused, the ride line plays.
					_rides += 1
					if not (day_lock_on and _day_n == 0 and _rides == 1 and hint("hint_day")):
						request("ride")
			"bankRefused":
				# The vote said BANK, the day is not paid: the car goes down anyway, and says so. The line
				# carries no numbers; the caption under it does.
				request("bank_refused", EXPIRE_LONG_MS, DayCaption.caption(e))
			"dayMet":
				request("day_met", EXPIRE_BOARD_MS, DayCaption.caption(e))
			"called":
				# On the Playroom the call starts the last count: the count's own line says so (hide_view.gd).
				if not bool(e.get("last", false)):
					request("called", EXPIRE_LONG_MS)
			"callRefused":
				hint("hint_call_dead")
			"blinkStart":
				if e.blackout:
					blackout_on = true
					request("blackout")
			"carArrived":
				_boardings += 1
				if blackout_on:
					queue = queue.filter(func(q: Dictionary) -> bool: return q.moment != "blackout")
					request("lights", EXPIRE_LONG_MS)
					hint("hint_board")
				elif not hint("hint_board"):
					request("arrived")
				blackout_on = false
			"voteChanged":
				# The night's first boarding: 3 s after the first player steps onto a side.
				if e.get("side") != null and _boardings == 1 and not _vote_cued:
					_vote_cued = true
					later("hint_vote", 3000)
			"banked":
				request("banked", EXPIRE_LONG_MS)
			"wiped":
				request("wipe", EXPIRE_LONG_MS)
				if days_on:
					_wiped_day = true
			"dayEnded":
				var r: Variant = e.get("result")
				_day_took = r is Dictionary and not ((r as Dictionary).get("taken", []) as Array).is_empty()
			"caught":
				if not wiped and not downed.has(str(e.get("playerId", ""))):
					request("taken")
			"downed":
				hint("hint_down_you" if str(e.get("playerId", "")) == my_id else "hint_down_crew")
			"out":
				if not wiped:
					request("taken")
					hint("hint_out")
			"startedHunting":
				hint("hint_listen")
			"markPlaced":
				_marks_floor += 1
			"bed":
				if bool(e.get("inBed", false)):
					_bed_seen = true
			"quotaMet":
				# The floor quota (North Star C9): the call button now works. Without a recording, a caption.
				if day_met:
					pass   # the day_met line says it, and more
				elif by_moment.has("quota"):
					request("quota", EXPIRE_LONG_MS)
				else:
					caption = QUOTA_CAPTION
					caption_until = now + EXPIRE_MS

## The doors open on arrival at `depth` (0: home in the prison).
func _arrival(depth: int, first_depth: int, now: int) -> void:
	if depth == 0:
		# Home. After a wipe that took an upgrade, "nobody came back" (true only then).
		if _wiped_day and _day_took:
			request("day_wiped", EXPIRE_LONG_MS)
		_wiped_day = false
		_day_took = false
		_bed_seen = false
		later("hint_bed", 30000, "bed")
		return
	if depth > first_depth:
		var asked := false
		if place == "playroom":
			asked = hint("hint_play_arrive")
		elif depth == 3:
			asked = hint("hint_new_floor")
		elif depth >= 5:
			asked = hint("hint_reroll")
		if not asked:
			request("doors")
	if depth == first_depth and _day_n == 0:
		later("hint_job", 6000)
	if place == "annex" and not _annex_seen:
		_annex_seen = true
		later("hint_marks", 75000, "marks")

func _new_floor() -> void:
	hints.new_floor()
	_marks_floor = 0
	_later = _later.filter(func(l: Dictionary) -> bool: return str(l.get("unless", "")) == "keep")
	_after_count.clear()

## Asks for hint `id` (client/hints.gd TABLE) through the gate: queued, or refused (false). A refused
## hint is not heard and may be asked for again at its next trigger.
func hint(id: String) -> bool:
	var now := _ms()
	var why := hints.may_request(id, now, place)
	if why == "" and not by_moment.has(id):
		why = "no recording"
	if why != "":
		_log({"what": "refused", "id": "", "moment": id, "at": now, "why": why})
		return false
	var line := _deal(id)
	if line == "":
		return false
	queue = queue.filter(func(q: Dictionary) -> bool: return q.moment != id)
	queue.append({"id": line, "moment": id, "priority": Hints.priority(id), "expires": now + Hints.life_ms(id), "hint": true})
	queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.priority > b.priority)
	_log({"what": "requested", "id": line, "moment": id, "at": now, "place": place})
	if Hints.test_break == "heard_on_request":
		hints.started(id, now)
	return true

## Asks for hint `id` (or a moment) `delay_ms` from now. `unless`: "marks" (skipped once the crew has
## placed a mark this floor), "bed" (skipped once anyone has climbed into bed, or away from the prison).
func later(id: String, delay_ms: int, unless := "") -> void:
	_later.append({"at": _ms() + delay_ms, "id": id, "unless": unless})

## One of the count's lines: `line` is a key of CountLines.LINES ("hide", "search", "found", "done",
## "last_called"), or "number" with `number` the seconds left; `text` the caption. The recording plays
## when there is one (for a number, only the numbers recorded).
func say_count(line: String, text: String, ms: int, number := -1, length := 0) -> void:
	var now := _ms()
	caption = text
	caption_until = now + ms
	var id := ""
	if line == "number":
		id = CountLines.number_line(number, length)
	else:
		id = str(CountLines.LINES.get(line, ""))
	said_count.append({"line": line, "text": text, "at": now, "id": id})
	if said_count.size() > 80:
		said_count.pop_front()
	# The Playroom's hints wait for these lines to end: "Hide." (a provoked count), "Coming, ready or
	# not!" (the search), "All done!" (and 2 s more).
	match line:
		"hide":
			hints.new_count()
			_after_count.append({"id": "hint_play_instruments", "delay": 0})
		"search":
			_after_count.append({"id": "hint_play_no_run", "delay": 0})
		"done":
			_after_count.append({"id": "hint_play_after", "delay": 2000})
	if id == "":
		return
	var which := "number" if line == "number" else "count"
	if fake:
		_fake_until[which] = now + _length_ms(id, ms)
	else:
		var path := "res://assets/voice/%s/%s.mp3" % [voice, id]
		if not ResourceLoader.exists(path):
			return
		var p := number_player if line == "number" else count_player
		p.stop()
		p.stream = load(path)
		p.play()
	# A count line stops a low hint mid-word (priority 1 or 2), like any other urgent line.
	if bool(current.get("hint", false)) and int(current.get("priority", 1)) <= 2:
		_cut()

## The subtitle to show: the announcer's own line, else the count's caption while it lasts.
func shown() -> String:
	if subtitle != "":
		return subtitle
	return caption if _ms() < caption_until else ""

## Whether any voice is playing (the beds duck under it).
func speaking() -> bool:
	return _busy("main") or _busy("count") or _busy("number")

func _busy(which: String) -> bool:
	if fake:
		return _ms() < int(_fake_until[which]) or (which == "main" and not current.is_empty())
	match which:
		"count":
			return count_player != null and count_player.playing
		"number":
			return number_player != null and number_player.playing
	return player != null and player.playing

func bell_soon() -> void:
	request("bell", 7000)

## Asks for a line of `moment`. `caption2`: a second caption line under it (the waiting car's names).
func request(moment: String, expire_ms := EXPIRE_MS, caption2 := "") -> void:
	var id := _deal(moment)
	if id == "":
		return
	var now := _ms()
	request_log.append({"moment": moment, "id": id, "at": now, "place": place})
	if request_log.size() > 300:
		request_log = request_log.slice(request_log.size() - 200)
	queue = queue.filter(func(q: Dictionary) -> bool: return q.moment != moment)
	queue.append({"id": id, "moment": moment, "priority": priority.get(moment, 1), "expires": now + expire_ms, "hint": false, "caption2": caption2})
	queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.priority > b.priority)
	# A more urgent line cuts a less urgent one short. Hints never cut.
	if not current.is_empty() and int(priority.get(moment, 1)) > int(current.priority) + 1:
		_cut()

## Stops the playing line now. A hint stopped this way is not heard.
func _cut() -> void:
	if current.is_empty():
		return
	if bool(current.get("hint", false)):
		hints.cut(current.get("undo", {}))
		_log({"what": "cut", "id": current.id, "moment": current.moment, "at": _ms()})
	if not fake and player != null:
		player.stop()
	_fake_until["main"] = 0
	_on_finished()

## Whether line `id` may be dealt on this place (doors_1, slip_2: the Clinic only; arrived_5, blackout_3:
## never on the Playroom).
func line_ok(id: String) -> bool:
	if PLACE_ONLY.has(id) and not (PLACE_ONLY[id] as Array).has(place):
		return false
	return not (PLACE_NEVER.has(id) and (PLACE_NEVER[id] as Array).has(place))

func _deal(moment: String) -> String:
	if not by_moment.has(moment):
		return ""
	var options: Array = by_moment[moment]
	var deck: Array = decks.get(moment, [])
	for _round in 2:
		if deck.is_empty():
			deck = options.filter(func(x: String) -> bool: return line_ok(x))
			for i in range(deck.size() - 1, 0, -1):
				var j := _rng.randi_range(0, i)
				var t: Variant = deck[i]
				deck[i] = deck[j]
				deck[j] = t
			# A new deck never starts with the line said last.
			if deck.size() > 1 and deck[0] == last_of.get(moment, ""):
				deck.push_back(deck.pop_front())
		while not deck.is_empty():
			var id: String = deck.pop_front()
			if line_ok(id):
				decks[moment] = deck
				return id
	decks[moment] = deck
	return ""

func _on_finished() -> void:
	if not current.is_empty() and not history.is_empty() and history[-1].get("end", -1) < 0:
		history[-1]["end"] = _ms()
	current = {}
	subtitle = ""
	_gap_until = _ms() + GAP_MS

## A test's estimate of a line's length (words at 2.5 a second, at least 1 s).
func _length_ms(id: String, fallback: int) -> int:
	if not lines.has(id):
		return fallback
	var words := str(lines[id].plain).split(" ", false).size()
	return maxi(1000, int(words * 400.0) + 400)

func update() -> void:
	var now := _ms()
	if fake and not current.is_empty() and now >= int(_fake_until["main"]):
		_on_finished()
	# What is due: hints asked for later, and hints waiting for a count line to end.
	var due: Array = []
	var keep: Array = []
	for l: Dictionary in _later:
		(due if now >= int(l.at) else keep).append(l)
	_later = keep
	for l: Dictionary in due:
		match str(l.get("unless", "")):
			"marks":
				if _marks_floor > 0:
					continue
			"bed":
				if _bed_seen or place != "prison":
					continue
		if Hints.is_hint(str(l.id)):
			hint(str(l.id))
		else:
			request(str(l.id))
	if not _after_count.is_empty() and not _busy("count"):
		for a: Dictionary in _after_count:
			if a.id == "hint_play_instruments" and bool(count_ctx.get("last", false)):
				continue   # the last count is the call's, not a provoked one
			later(str(a.id), int(a.delay))
		_after_count.clear()
	var expired := queue.filter(func(q: Dictionary) -> bool: return q.expires <= now)
	for q: Dictionary in expired:
		if bool(q.get("hint", false)):
			_log({"what": "expired", "id": q.id, "moment": q.moment, "at": now})
	queue = queue.filter(func(q: Dictionary) -> bool: return q.expires > now)
	if not current.is_empty() or now < _gap_until or queue.is_empty():
		return
	# The first line in priority order that may start now: a hint only when nothing else is playing and
	# the count allows (client/hints.gd may_start).
	var busy := _busy("main") or _busy("count") or _busy("number")
	var pick := -1
	for i in queue.size():
		var q: Dictionary = queue[i]
		if bool(q.get("hint", false)) and hints.may_start(str(q.moment), now, place, busy, count_ctx) != "":
			continue
		pick = i
		break
	if pick < 0:
		return
	var next: Dictionary = queue[pick]
	queue.remove_at(pick)
	if fake:
		_fake_until["main"] = now + _length_ms(str(next.id), 2000)
	else:
		var path := "res://assets/voice/%s/%s.mp3" % [voice, next.id]
		var stream: Resource = load(path) if ResourceLoader.exists(path) else null
		if stream == null:
			return
		player.stream = stream
		player.play()
	current = next
	if bool(next.get("hint", false)):
		current["undo"] = hints.started(str(next.moment), now) if Hints.test_break != "heard_on_request" else {}
		_log({"what": "started", "id": next.id, "moment": next.moment, "at": now, "busy": busy})
		_save()
	last_of[next.moment] = next.id
	subtitle = str(lines[next.id].plain)
	if str(next.get("caption2", "")) != "":
		subtitle += "\n" + str(next.caption2)
	history.append({"id": next.id, "moment": next.moment, "at": now, "end": -1, "hint": bool(next.get("hint", false))})

## HINTS: ON / OFF (the Esc menu). Off drops the hints waiting; a hint already playing finishes.
func set_hints_on(on: bool) -> void:
	hints.enabled = on
	if not on:
		queue = queue.filter(func(q: Dictionary) -> bool: return not bool(q.get("hint", false)))
		_later = _later.filter(func(l: Dictionary) -> bool: return not Hints.is_hint(str(l.id)))
		_after_count.clear()
	_save()

func _load() -> void:
	if not persist or fake:
		return
	var cf := ConfigFile.new()
	if cf.load(SAVE_PATH) != OK:
		return
	var nights: Variant = JSON.parse_string(str(cf.get_value("hints", "nights", "{}")))
	hints.from_save({"enabled": bool(cf.get_value("hints", "enabled", true)), "nights": nights if nights is Dictionary else {}})

func _save() -> void:
	if not persist or fake:
		return
	var d := hints.to_save()
	var cf := ConfigFile.new()
	cf.set_value("hints", "enabled", d["enabled"])
	cf.set_value("hints", "nights", JSON.stringify(d["nights"]))
	cf.save(SAVE_PATH)
