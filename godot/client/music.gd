# The soundtrack: the owner's five tracks (20 Nov; godot/assets/music/, rebuilt from his .wav files by
# assets_src/music/build_music.mjs at one loudness, the drone lower). One node on the tree's root, so it carries on
# across the Hanging Ward's own scene; client/main.gd tells it every frame where this player is (drive()).
#
#   title    the start screens and the lobby          abandoned_jingle   loops
#   lift     inside the car between floors, both ways  elevator_muzak     loops
#   prison   the prison between runs                   wistful_regret     loops
#   floor    on a floor, quietly, as a bed             sub_bass_drone     loops
#   report   the end-of-run report                     final_stamp        once
#
# The report: the stamp starts once for each settled day (the ride up's headline, key "day N") and for the end
# screen (key "end"); it carries on into the prison and plays to its end, then the prison's track comes in. A ride
# down or a floor stops it. After the end screen's stamp there is silence.
#
# Every change of track is a cross-fade of FADE seconds: the old one falls as the new one rises, so two tracks are
# never both at full. The music is on its own bus (BUS, the player's MUSIC slider, client/volume.gd) and always
# well under the effects (TRACKS' gains: every resident is heard before it is seen); it ducks by DUCK_DB while the
# announcer speaks, while a catch's scene plays, and while the ride-up reel or the prison's cassette plays.
# The Playroom's own nursery tune (client/sfx.gd, on Ambience) and its count's sag are left as they are.
#
# Buses (made here at run time, not in default_bus_layout.tres, which the import pass rewrites): BUS into Master,
# and EFFECTS_BUS into Master, with every other bus that went straight into Master now going through it (the
# player's EFFECTS slider). A player node added on Master (the Ward's cues, a video) is moved onto EFFECTS_BUS.
extends Node

const DIR := "res://assets/music/"
const BUS := "Music"
const EFFECTS_BUS := "EffectsGroup"
const NODE_NAME := "Music"
## state -> [file, gain dB, loops]. The files are at -20 LUFS (the drone -24); the voice reaches the speakers at
## about -21, the effects around it: the beds sit 10 to 14 dB under, the start screen (no effects) nearer.
const TRACKS := {
	"title": ["abandoned_jingle", -6.0, true],
	"lift": ["elevator_muzak", -11.0, true],
	"prison": ["wistful_regret", -11.0, true],
	"floor": ["sub_bass_drone", -12.0, true],
	"report": ["final_stamp", -9.0, false],
}
const FADE := 1.5
const DUCK_DB := -8.0
const DUCK_RATE := 16.0          # dB per second, in and out
## No word from the game this long: on the Ward's own scene the floor's bed; elsewhere (the cassette deck's film)
## the last track, ducked.
const UNDRIVEN_MS := 1000
## One-shots (client/sfx.gd `played`) that mean a catch's scene is playing, and for how long after.
const CATCH_SOUNDS: Array[String] = ["roar", "found", "caught", "catch_staple_1", "tenant_slam"]
const CATCH_MS := 6000

## What the game said last (drive()).
var state := ""
var report_key := ""
var ducked := false
## The track playing to full or rising ("" for none), and each track's level 0..1.
var track := ""
var levels := {}
var duck_db := 0.0
var _players := {}               # state -> AudioStreamPlayer
var _stamped := ""               # the report key the stamp last started for
var _stamp_on := false
var _driven_ms := -1

# ---------------------------------------------------------------------------------------------
# Pure: what plays where (tests/test_music.gd).

## Where this player is: "title", "lift", "prison", "floor" or "report" (the end screen).
static func state_of(in_game: bool, phase: String, prison: bool, ended: bool) -> String:
	if not in_game:
		return "title"
	if ended:
		return "report"
	if phase == "riding":
		return "lift"
	if prison:
		return "prison"
	return "floor"

## The report's key in a snapshot: "end" on the end screen, "day N" while the settled day N rides up, else "".
static func report_key_of(s: Dictionary, ended: bool) -> String:
	if ended:
		return "end"
	var day: Variant = s.get("day")
	if bool(s.get("goingUp", false)) and day is Dictionary and (day as Dictionary).get("result") is Dictionary:
		return "day %d" % int(((day as Dictionary)["result"] as Dictionary).get("day", 0))
	return ""

## The track for a state when no stamp is holding: "" for none.
static func track_of(st: String) -> String:
	return st if TRACKS.has(st) and st != "report" else ""

## Whether a catch's scene is playing: one of CATCH_SOUNDS in `played` ([{name, ms}]) within CATCH_MS of `now_ms`.
static func catch_recent(played: Array, now_ms: int) -> bool:
	for p: Variant in played:
		if p is Dictionary and CATCH_SOUNDS.has(str(p.get("name", ""))) and now_ms - int(p.get("ms", -CATCH_MS)) < CATCH_MS:
			return true
	return false

## Whether the music ducks: the announcer speaking, a catch's scene, or the announcer's chatter held (the ride-up
## reel, the prison's cassette).
static func duck_wanted(voice: bool, catch: bool, held: bool) -> bool:
	return voice or catch or held

## The duck's target for this frame.
static func duck_target(is_ducked: bool) -> float:
	return DUCK_DB if is_ducked else 0.0

# ---------------------------------------------------------------------------------------------
# The buses.

## Makes BUS and EFFECTS_BUS if they are missing and puts every other bus that sends straight to Master through
## EFFECTS_BUS. Safe to call any number of times.
static func ensure_buses() -> void:
	for b: String in [EFFECTS_BUS, BUS]:
		if AudioServer.get_bus_index(b) < 0:
			AudioServer.add_bus()
			var i := AudioServer.bus_count - 1
			AudioServer.set_bus_name(i, b)
			AudioServer.set_bus_send(i, "Master")
	for i in range(1, AudioServer.bus_count):
		var n := AudioServer.get_bus_name(i)
		if n != BUS and n != EFFECTS_BUS and AudioServer.get_bus_send(i) == &"Master":
			AudioServer.set_bus_send(i, EFFECTS_BUS)

## The one music node on `tree`'s root (made on the first call).
static func on(tree: SceneTree) -> Node:
	var n := tree.root.get_node_or_null(NODE_NAME)
	if n != null:
		return n
	ensure_buses()
	n = (load("res://client/music.gd") as GDScript).new()
	n.name = NODE_NAME
	tree.root.add_child.call_deferred(n)
	return n

func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for st: String in TRACKS:
		var spec: Array = TRACKS[st]
		var p := AudioStreamPlayer.new()
		p.bus = BUS
		var path := DIR + str(spec[0]) + ".ogg"
		if ResourceLoader.exists(path):
			var stream := load(path) as AudioStreamOggVorbis
			if stream != null:
				stream.loop = bool(spec[2])
				p.stream = stream
		p.volume_db = -80.0
		add_child(p)
		_players[st] = p
		levels[st] = 0.0

func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)

## A sound player added on Master goes through EFFECTS_BUS instead, so the EFFECTS slider reaches it.
func _on_node_added(n: Node) -> void:
	if n is AudioStreamPlayer or n is AudioStreamPlayer2D or n is AudioStreamPlayer3D or n is VideoStreamPlayer:
		if n.get_parent() != self and StringName(n.get("bus")) == &"Master":
			n.set("bus", EFFECTS_BUS)

## Every frame from the game: where this player is, the report's key ("" for none), and whether to duck.
func drive(st: String, key: String, is_ducked: bool) -> void:
	state = st
	report_key = key
	ducked = is_ducked
	_driven_ms = Time.get_ticks_msec()

## The track wanted now, from the last word and the stamp (advances the stamp's own state).
func wanted() -> String:
	var st := state
	if _driven_ms >= 0 and Time.get_ticks_msec() - _driven_ms > UNDRIVEN_MS:
		# The Ward's own scene is a floor; anything else (the cassette deck's film) keeps the last track, ducked.
		var cur := get_tree().current_scene if is_inside_tree() else null
		if cur != null and cur.scene_file_path.begins_with("res://client/ward/"):
			st = "floor"
			ducked = false
		else:
			ducked = true
	if st == "title":
		_stamped = ""
	if report_key != "" and report_key != _stamped:
		_stamped = report_key
		_stamp_on = true
		levels["report"] = 0.0
		var sp: AudioStreamPlayer = _players["report"]
		if sp.is_inside_tree() and sp.stream != null:
			sp.play(0.0)
	if _stamp_on:
		var sp: AudioStreamPlayer = _players["report"]
		var finished := sp.is_inside_tree() and sp.stream != null and not sp.playing and float(levels["report"]) > 0.0
		if finished or not st in ["lift", "prison", "report"] or (st == "lift" and report_key == ""):
			_stamp_on = false
	return "report" if _stamp_on else track_of(st)

func _process(delta: float) -> void:
	step(minf(delta, 0.1))

## One step of the fades and the duck (tests call it with their own delta).
func step(delta: float) -> void:
	track = wanted()
	duck_db = move_toward(duck_db, duck_target(ducked), DUCK_RATE * delta)
	for st: String in TRACKS:
		var p: AudioStreamPlayer = _players[st]
		var lv := move_toward(float(levels[st]), 1.0 if st == track else 0.0, delta / FADE)
		levels[st] = lv
		p.volume_db = float(TRACKS[st][1]) + linear_to_db(lv) + duck_db if lv > 0.0 else -80.0
		if p.stream == null or not p.is_inside_tree():
			continue
		if lv <= 0.0:
			if p.playing:
				p.stop()
			continue
		if not p.playing and st == track and st != "report":
			p.play(0.0)

## Tests and the scripted playthroughs: what the music is doing.
func describe() -> Dictionary:
	var playing := {}
	var vols := {}
	for st: String in TRACKS:
		var p: AudioStreamPlayer = _players[st]
		playing[st] = p.playing
		vols[st] = p.volume_db
	var bi := AudioServer.get_bus_index(BUS)
	var ei := AudioServer.get_bus_index(EFFECTS_BUS)
	return {"state": state, "track": track, "report": report_key, "stamp": _stamp_on, "levels": levels.duplicate(), "playing": playing,
		"volumes": vols, "duck": duck_db, "ducked": ducked, "musicBusDb": AudioServer.get_bus_volume_db(bi) if bi >= 0 else 0.0,
		"effectsBusDb": AudioServer.get_bus_volume_db(ei) if ei >= 0 else 0.0, "masterDb": AudioServer.get_bus_volume_db(0)}
