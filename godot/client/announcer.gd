# The cheerful synthetic announcer (H5): plays the right recorded line for each moment, one at a time,
# at one even loudness (the recordings are all at -16 LUFS; the Voice bus is a band-limited speaker
# with a compressor), never the same line twice running (each moment's lines are dealt from a shuffled
# deck), with subtitles. The moments and what triggers them follow src/game/announcer.ts onEvents.
class_name Announcer
extends Node

const EXPIRE_MS := 4000
const EXPIRE_LONG_MS := 9000
const EXPIRE_BOARD_MS := 12000
const GAP_MS := 450

var voice := "bella"
var lines := {}          # id -> {moment, plain}
var by_moment := {}      # moment -> [ids]
var priority := {}       # moment -> int
var decks := {}
var last_of := {}
var queue: Array = []    # [{id, moment, priority, expires}]
var current := {}
var subtitle := ""
var history: Array = []  # [{id, moment, at}]
var blackout_on := false
var player: AudioStreamPlayer
var _gap_until := 0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.randomize()
	player = AudioStreamPlayer.new()
	player.bus = "Voice"
	# -5 dB: in the browser the Voice bus's compressor does not apply, and at -1 the lines clipped.
	player.volume_db = -5.0
	add_child(player)
	player.finished.connect(_on_finished)
	var m: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/voice/manifest.json"))
	if not (m is Dictionary):
		return
	for mo: String in m.moments:
		priority[mo] = int(m.moments[mo].priority)
	for l: Dictionary in m.lines:
		lines[l.id] = l
		if not by_moment.has(l.moment):
			by_moment[l.moment] = []
		by_moment[l.moment].append(l.id)

## A run begins: the boarding line.
func start_run() -> void:
	queue.clear()
	blackout_on = false
	request("board", EXPIRE_BOARD_MS)

## The run's events from a frame.
func on_events(events: Array, first_depth := 1) -> void:
	var wiped := false
	for e: Dictionary in events:
		if e.type == "wiped":
			wiped = true
	for e: Dictionary in events:
		match str(e.type):
			"doorsOpened":
				if e.reason == "arrival" and int(e.depth) > first_depth:
					request("doors")
			"carLeft":
				if e.reason == "unloaded" or e.reason == "empty":
					request("left")
				elif e.reason == "ride":
					request("ride")
			"called":
				request("called", EXPIRE_LONG_MS)
			"blinkStart":
				if e.blackout:
					blackout_on = true
					request("blackout")
			"carArrived":
				if blackout_on:
					queue = queue.filter(func(q: Dictionary) -> bool: return q.moment != "blackout")
					request("lights", EXPIRE_LONG_MS)
				else:
					request("arrived")
				blackout_on = false
			"banked":
				request("banked", EXPIRE_LONG_MS)
			"wiped":
				request("wipe", EXPIRE_LONG_MS)
			"caught":
				if not wiped:
					request("taken")

func bell_soon() -> void:
	request("bell", 7000)

func request(moment: String, expire_ms := EXPIRE_MS) -> void:
	var id := _deal(moment)
	if id == "":
		return
	var now := Time.get_ticks_msec()
	queue = queue.filter(func(q: Dictionary) -> bool: return q.moment != moment)
	queue.append({"id": id, "moment": moment, "priority": priority.get(moment, 1), "expires": now + expire_ms})
	queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.priority > b.priority)
	# A more urgent line cuts a less urgent one short.
	if not current.is_empty() and int(queue[0].priority) > int(current.priority) + 1:
		player.stop()
		_on_finished()

func _deal(moment: String) -> String:
	if not by_moment.has(moment):
		return ""
	var options: Array = by_moment[moment]
	var deck: Array = decks.get(moment, [])
	if deck.is_empty():
		deck = options.duplicate()
		for i in range(deck.size() - 1, 0, -1):
			var j := _rng.randi_range(0, i)
			var t: Variant = deck[i]
			deck[i] = deck[j]
			deck[j] = t
		# A new deck never starts with the line said last.
		if deck.size() > 1 and deck[0] == last_of.get(moment, ""):
			deck.push_back(deck.pop_front())
	var id: String = deck.pop_front()
	decks[moment] = deck
	return id

func _on_finished() -> void:
	current = {}
	subtitle = ""
	_gap_until = Time.get_ticks_msec() + GAP_MS

func update() -> void:
	var now := Time.get_ticks_msec()
	queue = queue.filter(func(q: Dictionary) -> bool: return q.expires > now)
	if not current.is_empty() or now < _gap_until or queue.is_empty():
		return
	var next: Dictionary = queue.pop_front()
	var path := "res://assets/voice/%s/%s.mp3" % [voice, next.id]
	var stream: Resource = load(path) if ResourceLoader.exists(path) else null
	if stream == null:
		return
	player.stream = stream
	player.play()
	current = next
	last_of[next.moment] = next.id
	subtitle = str(lines[next.id].plain)
	history.append({"id": next.id, "moment": next.moment, "at": now})
