# The game's sounds. The owner's recordings (assets/sfx/, ElevenLabs sound effects, see SOURCES.md) where one
# fits, and the stand-ins made here from a few lines of arithmetic where none exists yet or a file is
# missing (so the game never goes silent): the Orderly's trolley (in the world, at the Orderly, from the
# rules' audibility, only while it moves unseen), its breathing, rattle and reactions, its roar and
# chewing when it takes someone, the Clinic's tube hum (gone in every blink and the blackout), the blink
# warning's flicker, the tube popping at the blackout and the emergency lighting's drone, the vent, sparse
# room tones placed and timed from the floor's seed and the host's clock (the same for every player),
# the lift's chimes, dings, doors, bell, machinery and ride, the call panel's buzz (a press below the
# floor quota), the instrument's ticking, footsteps and breathing when winded.
#
# The mix (assets/sfx/MIX.md): every file is normalised by loudness to its category's level relative to
# the elevator voice, and every player here plays at the voice's own volume (BASE_DB), so the balance is
# set in the files and only modulated here (distance, the rules' gain, the lights). Buses: Entity (never
# ducked; its low-pass muffles the Orderly heard through walls), Scare, Effects, Ambience, UI, Voice,
# into Master with a limiter. While the announcer speaks, Effects and Ambience duck by DUCK_DB.
# Orchestration: at most one room tone at a time and ROOM_GAP seconds apart, room tones step aside while
# the Orderly is near and moving or just after a scare, never two shrieks within SHRIEK_GAP seconds, and
# each category has one 3D attenuation (CATS).
#
# The Playroom (docs/floors/playarea.md 10; client/hide_view.gd drives these from the host's count):
# the floor's tune from the ceiling speakers (made here, our own nursery loop, a little slow, on
# Ambience), which sags to half speed through a low-pass (a filter on the Ambience bus, on only then)
# for the whole count; three toy xylophone notes at the call to hide; the count's bell, one stroke a
# second on the Voice bus at the voice's own level (never buried), higher and louder in the last five;
# and the toy-piano trill only you hear while your own sight or gap total rises (UI).
#
# The second batch (17 Nov, assets/sfx/annex, playroom and player; MIX.md): the Annex's office tone and the
# Playroom's play-centre tone take the hum's place on their floors (following the lights the same way),
# the vent belongs to the Clinic; on the Annex the blink warnings are its sagging tube buzz, a far-off
# phone rings from everywhere and a photocopier warms up in a seeded copy room (room tones, as the
# Clinic's), and a catch ends with the stapler going into you; the lift's chime is the recorded two-tone
# bell from the ceiling speakers on every floor. The Playroom (driven by hide_view.gd from the host's
# events): the found-you sting, going down, getting into and out of hides, squeaker tiles, wading or
# jumping into the ball pit, the Minder's disappointed huff at an empty hide, the recorded count bell, and
# the count's three rising notes from one recorded note when there is one. Your winded breathing is the
# crew's own clean breath. The rest of that list: the call panel's refused buzz and quota chime, the lift
# straining on the ride up, the prison's night (its bed, through lights out), a bunk creaking as someone
# lies down, the lights-out switch, and the count's one recorded note (_events, from the host's events).
# Ready but with nothing in the game to trigger it yet: READY.
class_name Sfx
extends Node

const RATE := 22050
const DIR := "res://assets/sfx/"
## The voice's own volume (announcer.gd): every sound plays relative to it.
const BASE_DB := -5.0
const DUCK_DB := -6.0
## The Master limiter's ceiling (dBFS, sample peaks): 1 dB under the -1 dBTP rule for inter-sample peaks.
const MASTER_CEILING := -2.0
const DUCK_RATE := 30.0         # dB per second, in and out
const ROOM_GAP := 9.0           # seconds between room tones (at most one at a time)
const SCARE_QUIET := 8.0        # room tones step aside this long after a scare
const SHRIEK_GAP := 45.0
const RATTLE_EVERY := Vector2(8.0, 18.0)
const TONE_SLOT := 16.0         # host seconds per room-tone slot (one tone at most per slot)
const S := 2.0                  # cell size (m)
const LH := 3.2                 # storey height (m)
const HUNT_SPEED := 3.7         # sim/entity.gd: the trolley's pitch follows its speed
const APPROACH_DB := 7.0
const MUFFLED_DB := 5.0
## Per category: bus, 3D unit size (m, where it plays at its file's level) and max distance (m).
const CATS := {
	"entity": ["Entity", 2.0, 18.0],
	"scare": ["Scare", 6.0, 45.0],
	"room": ["Ambience", 3.0, 28.0],
	"effect": ["Effects", 3.0, 30.0],
	"steps": ["Effects", 3.0, 30.0],
	"ui": ["UI", 3.0, 30.0],
}
## The recordings: name -> [category, files...]. Several files are takes, dealt in turn.
const RECORDED := {
	"roar": ["scare", "orderly/roar"],
	"shriek": ["scare", "orderly/shriek_1", "orderly/shriek_2", "orderly/shriek_3"],
	"chew": ["entity", "orderly/chew"],
	"rattle": ["entity", "orderly/rattle"],
	"breath_quick": ["entity", "orderly/breath_quick"],
	"gown": ["entity", "orderly/gown"],
	"instruments": ["entity", "orderly/instruments"],
	"thud": ["entity", "orderly/thud"],
	"blink_warn": ["effect", "clinic/flicker"],
	"blackout_warn": ["effect", "clinic/flicker"],
	"pop": ["effect", "clinic/pop"],
	"slam": ["room", "clinic/slam_1", "clinic/slam_2"],
	"intercom": ["room", "clinic/intercom_1", "clinic/intercom_2"],
	"bed_roll": ["room", "clinic/bed_roll"],
	"step": ["steps", "player/step_1", "player/step_2", "player/step_3", "player/step_4"],
	# The crew.
	"down": ["effect", "player/down"],
	"healed": ["effect", "player/healed"],
	"hide_in": ["effect", "player/hide_in"],
	"slide_under": ["effect", "player/slide_under"],
	# The lift and the call panel.
	"lift_up": ["effect", "lift/up"],   # machinery, as the call's made-in-code motor: on Effects, over the ride's rumble
	"refused": ["ui", "lift/refused"],
	"quota_met": ["ui", "lift/quota_met"],
	# The prison.
	"bunk": ["effect", "prison/bunk"],
	"lights_out": ["effect", "prison/lights_out"],
	"cell_door": ["effect", "prison/cell_door"],
	"teller_window": ["effect", "prison/teller_window"],
	"teller_ding": ["ui", "prison/teller_ding"],
	# The Annex.
	"buzz": ["effect", "annex/buzz"],
	"phone": ["room", "annex/phone"],
	"copier": ["room", "annex/copier"],
	"staple_soft": ["entity", "annex/staple_soft"],
	"note_slap": ["effect", "annex/note_slap"],
	"note_peel": ["effect", "annex/note_peel"],
	"lift_bell": ["ui", "annex/lift_bell"],
	# The Playroom.
	"found": ["scare", "playroom/found"],
	"squeak": ["effect", "playroom/squeak_1", "playroom/squeak_2", "playroom/squeak_3"],
	"pit_wade": ["effect", "playroom/pit_wade"],
	"pit_jump": ["effect", "playroom/pit_jump"],
	"slide": ["effect", "playroom/slide"],
	"net_flap": ["effect", "playroom/net_flap"],
	"horn": ["effect", "playroom/horn_1", "playroom/horn_2", "playroom/horn_3"],
	"huff": ["entity", "playroom/huff"],
	## One struck toy note (#19); the count's call to hide plays it three times rising (XYLO_PITCH). The
	## made-in-code three notes when the file is missing.
	"xylo_note": ["ui", "playroom/xylo_note"],
}
## Recorded and loaded, but nothing in the game triggers them yet: name -> the event each needs.
const READY := {
	"healed": "a heal (downed-and-healed, T8): play('healed') for the one healed, play_at for the others",
	"crawl": "a downed player moving (crawl(true) while they drag themselves along)",
	"drag": "the Temp dragging someone by the ankle (T6): dragged(true) on the dragged player's screen",
	"hide_in (Annex)": "getting into an Annex filing cabinet: the cabinet's hide event (the Playroom's chests and cubbies already use it)",
	"note_slap": "a sticky note posted (T7, notes.gd): play_at('note_slap') where it is stuck",
	"note_peel": "a sticky note taken down (no such action yet)",
	"horn": "the party horn blown (T15h, inp.horn reaches the host but no event comes back to the screens)",
	"cell_door": "a cell door sliding shut (no cell doors in the rules yet)",
	"teller_window": "a teller window's shutter rolling up as a player steps up to it (F at a window: no event comes back to the screens)",
	"teller_ding": "the counter bell when a purchase or a skill is taken at a window (no such event yet)",
}
## The count's call to hide from one recorded note: three strokes this far apart, at these pitches.
const XYLO_PITCH: Array[float] = [1.0, 1.26, 1.5]
const XYLO_STEP := 0.2
## Carrying across the floor (the owner, playing build 0833: the shrieks, roars and raspy breathing were too
## quiet from far off; a distant wail near the lift should be scary, and the breathing should start well
## before a catch). Each has its own curve (far_db), panned in 3D, duller with distance (_far_cutoff, so a
## far one is muffled rather than lost). Before: a scare fell by the engine's inverse distance from 6 m
## (-12.4 dB at 25 m) and was cut off at 45 m; the slow breath from 1.5 m (-16.5 dB at 10 m), gone past
## 10 m; the rattle from 2 m, gone past 18 m (and only tried within 14 m).
const SCARE_NEAR := 8.0          # full level within this
const SCARE_FLOOR_DB := -10.0    # never quieter than this within SCARE_FAR (reached at 25 m)
const SCARE_FAR := 90.0
const BREATH_NEAR := 2.0         # full level within this
const BREATH_FAR := 28.0         # heard from here (the onset)
const BREATH_FAR_DB := -22.0     # at the onset; a slow build in dB from there to BREATH_NEAR
const RATTLE_FAR := 26.0         # the rattle is tried within this (was 14 m) and follows the breath curve
const BREATH_UNDER_TROLLEY_DB := -9.0   # while the trolley sounds (it is moving unseen)
const SILENT_DB := -79.0
## Tests (mix_check_floors.gd break=far): the curves before the change.
static var old_falloff := false

## dB a sound loses at `d` metres on its curve ("scare", "breath", "rattle"); -80 for not heard.
static func far_db(curve: String, d: float) -> float:
	if old_falloff:
		var unit := 6.0 if curve == "scare" else (1.5 if curve == "breath" else 2.0)
		var far := 45.0 if curve == "scare" else (10.0 if curve == "breath" else 18.0)
		return -80.0 if d > far else minf(0.0, 20.0 * log(unit / maxf(d, 0.01)) / log(10.0))
	if curve == "scare":
		if d > SCARE_FAR:
			return -80.0
		return maxf(minf(0.0, -20.0 * log(maxf(d, 0.01) / SCARE_NEAR) / log(10.0)), SCARE_FLOOR_DB)
	var far_m := BREATH_FAR if curve == "breath" else RATTLE_FAR
	if d > far_m:
		return -80.0
	return BREATH_FAR_DB * clampf((d - BREATH_NEAR) / (far_m - BREATH_NEAR), 0.0, 1.0)

## Far sounds lose their top: a low-pass from open at 8 m to 2.5 kHz at 60 m and beyond.
static func _far_cutoff(d: float) -> float:
	return lerpf(20500.0, 2500.0, clampf((d - 8.0) / 52.0, 0.0, 1.0))

func _ear_distance(pos: Vector3) -> float:
	var cam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	return cam.global_position.distance_to(pos) if cam != null else 0.0

## The far-off phone on the Annex: from every direction at once, quieter than a near room tone.
const PHONE_DB := -6.0
## The stapler going into you at the end of a catch on the Annex, this long after the roar.
const STAPLE_AFTER := 600
## Gain (dB, on top of BASE_DB) that puts each generated stand-in at its category's level (measured with
## tools/sfx_levels.gd; UI at the voice -8 LU, effects -6, scare short-term +2).
## The "far" variants keep their own step down from the near ones. The ticking: a train at 12 a second at
## full loudness reaches the UI level.
const SYNTH_DB := {
	"tick": -3.5, "chime": -12.1, "chime_far": -12.1, "ding": -5.7, "bell": -6.2, "bell_warn": -7.6, "closed": -8.6, "slip": -1.4,
	"doors": -2.8, "doors_far": -2.8, "blink_warn": 0.3, "blackout_warn": -0.7, "blink": -3.4, "caught": -7.0,
	"step": 0.8, "squeak": -4.0, "machinery": -7.6, "breath": -0.7, "hum": -13.9, "ride": -10.2,
	"xylo": -6.0, "count_bell": -3.0, "trill": -12.0, "tune": -16.0, "refused": -2.9,
}
const SYNTH_BUS := {
	"tick": "UI", "chime": "UI", "chime_far": "UI", "ding": "UI", "bell": "UI", "bell_warn": "UI", "closed": "UI", "slip": "UI",
	"doors": "Effects", "doors_far": "Effects", "blink_warn": "Effects", "blackout_warn": "Effects", "blink": "Effects", "caught": "Scare",
	"xylo": "UI", "refused": "UI",
}
## The count's bell: in the last RISE_FROM seconds each stroke is RISE_PITCH higher and RISE_DB louder.
const RISE_FROM := 5
const RISE_PITCH := 0.06
const RISE_DB := 0.8
## The tune: a note every TUNE_NOTE seconds (a little slow), from TUNE_HZ; the count's low-pass.
const TUNE_NOTE := 0.42
const TUNE_HZ := 523.25
const SAG_CUTOFF := 700.0

var streams := {}               # the generated stand-ins, by name
var recorded := {}              # name -> {cat, streams: Array, next}
var solo := ""                  # tests: only this group sounds ("" = all)
var duck_forced := -1           # tests: -1 follow the voice, 0 never, 1 always
var played: Array = []          # tests: the last one-shots, [{name, ms}]
var _one_shots: Array[AudioStreamPlayer] = []
var _by_name := {}              # one-shot name -> the player it last went to
var _shots3d: Array[AudioStreamPlayer3D] = []
var _shot3d_next := 0
var squeak: AudioStreamPlayer3D   # the trolley's squeaky wheel (or the stand-in)
var roll: AudioStreamPlayer3D     # the trolley rolling over the tiles (recording only)
var orderly_breath: AudioStreamPlayer3D
var machinery: AudioStreamPlayer3D
var breath: AudioStreamPlayer
var ride_loop: AudioStreamPlayer
var hum: AudioStreamPlayer
var vent: AudioStreamPlayer
var drone: AudioStreamPlayer
var drip: AudioStreamPlayer3D
var monitor: AudioStreamPlayer3D
var _room_player: AudioStreamPlayer3D   # the one room tone playing, if any
var _loops := {}                # name -> [player, group]
var _steps: Array[AudioStreamPlayer3D] = []
var _step_next := 0
var _entity_bus := -1
var _duck := 0.0
var _tick_phase := 0.0
var _rng := RandomNumberGenerator.new()
# The floor.
var _seed := ""
var _depth := 0
var _clinic := false
var _place := ""
var _plan := {}
var _copier_at: Variant = null    # the Annex: the seeded copy room's photocopier (or null)
var _hum_by_place := {}           # place -> the bed in the hum's place ("" = the Clinic's hum)
var crawl_loop: AudioStreamPlayer   # ready: a downed player dragging themselves along
var drag_loop: AudioStreamPlayer    # ready: being dragged across the carpet by the Temp
var _monitor_on := false
var _drip_on := false
var _tone_slot := -1
var _tone_next := {}
var _last := {}                 # what -> msec it last played
var _later: Array = []          # [{at, name, pos (or null), gain}]
var _rattle_in := 10.0
var _prev := {}                 # the Orderly's last mode / moving / anim
var _hunts := 0
var _releases := 0
var _shriek_pending_until := -1
# The Playroom.
var bell_player: AudioStreamPlayer
var trill_player: AudioStreamPlayer
var tune_player: AudioStreamPlayer
var _amb_lp := -1                 # the low-pass's index on the Ambience bus
var _trill_in := 0.0
var _trill_n := 0
## Tests: the bell strokes played ([ms, seconds left]).
var bells: Array = []

func setup(world_parent: Node3D) -> void:
	_rng.seed = 7
	# The Master limiter holds sample peaks; true peaks between samples run up to about 0.8 dB over them
	# (mix_check measured -0.7 dBTP once with the layout's -1.0 ceiling), so it holds MASTER_CEILING.
	var mi := AudioServer.get_bus_index("Master")
	for e in AudioServer.get_bus_effect_count(mi):
		var hl := AudioServer.get_bus_effect(mi, e) as AudioEffectHardLimiter
		if hl != null:
			hl.ceiling_db = MASTER_CEILING
	_entity_bus = AudioServer.get_bus_index("Entity")
	if _entity_bus >= 0 and AudioServer.get_bus_effect_count(_entity_bus) == 0:
		_entity_bus = -1
	streams["tick"] = _wav(_tick(), false)
	streams["chime"] = _wav(_tones([[660.0, 0.0], [880.0, 0.32]], 1.3, 0.5), false)
	streams["chime_far"] = _wav(_tones([[660.0, 0.0], [880.0, 0.32]], 1.3, 0.18), false)
	streams["ding"] = _wav(_tones([[1320.0, 0.0]], 0.35, 0.25), false)
	streams["bell"] = _wav(_bell(), false)
	streams["bell_warn"] = _wav(_tones([[1760.0, 0.0]], 0.22, 0.3), false)
	streams["doors"] = _wav(_doors(), false)
	streams["doors_far"] = _wav(_scale(_doors(), 0.3), false)
	streams["blink_warn"] = _wav(_buzz(0.6), false)
	streams["blackout_warn"] = _wav(_winddown(3.0), false)
	streams["blink"] = _wav(_thump(), false)
	streams["caught"] = _wav(_noise(2.0, 0.6), false)
	streams["slip"] = _wav(_printer(), false)
	streams["closed"] = _wav(_tones([[990.0, 0.0], [1480.0, 0.08]], 0.4, 0.25), false)
	streams["step"] = _wav(_step(), false)
	streams["xylo"] = _wav(_xylo(), false)
	streams["count_bell"] = _wav(_hand_bell(), false)
	streams["trill"] = _wav(_toy_note(), false)
	streams["tune"] = _wav(_tune(), true)
	streams["refused"] = _wav(_refused(), false)
	for name: String in RECORDED:
		var spec: Array = RECORDED[name]
		var list: Array = []
		for i in range(1, spec.size()):
			var st := _rec(str(spec[i]), false)
			if st != null:
				list.append(st)
		if not list.is_empty():
			recorded[name] = {"cat": spec[0], "streams": list, "next": 0}
	for i in 6:
		var p := AudioStreamPlayer.new()
		p.bus = "Effects"
		add_child(p)
		_one_shots.append(p)
	for i in 8:
		var p3 := AudioStreamPlayer3D.new()
		p3.max_db = 0.0
		world_parent.add_child(p3)
		_shots3d.append(p3)
	# The trolley: ATTENUATION_DISABLED, its loudness is the rules' audibility (distance and walls).
	squeak = _player3d(world_parent, _rec("orderly/trolley_squeak", true), "Entity", 6.0, 40.0)
	if squeak.stream == null:
		squeak.stream = _wav(_squeak(), true)
	squeak.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
	roll = _player3d(world_parent, _rec("orderly/trolley_roll", true), "Entity", 6.0, 40.0)
	roll.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
	# No air absorption either: walls and distance are in the rules' gain and the Entity bus' low-pass, and
	# the engine's distance filter took the squeal out of a far trolley entirely.
	squeak.attenuation_filter_db = 0.0
	roll.attenuation_filter_db = 0.0
	orderly_breath = _player3d(world_parent, _rec("orderly/breath_slow", true), "Entity", 1.5, 0.0)
	# Its loudness is far_db("breath"), set every frame from the distance to the ear.
	orderly_breath.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
	machinery = _player3d(world_parent, _wav(_rumble(2.0, 55.0), true), "Effects", 2.0, 40.0)
	breath = _player2d(_rec("player/breath_winded", true), "Effects")
	if breath.stream == null:
		breath.stream = _wav(_breathing(), true)
	hum = _player2d(_rec("clinic/hum", true), "Ambience")
	if hum.stream == null:
		hum.stream = _wav(_hum(), true)
	# The Annex's and the Playroom's beds in the hum's place (the Clinic's hum where a file is missing).
	_hum_by_place = {"": hum.stream}
	for k: Array in [["annex", "annex/office"], ["playroom", "playroom/room"], ["prison", "prison/night"]]:
		var st := _rec(str(k[1]), true)
		_hum_by_place[k[0]] = st if st != null else hum.stream
	crawl_loop = _player2d(_rec("player/crawl", true), "Effects")
	drag_loop = _player2d(_rec("annex/drag", true), "Entity")
	vent = _player2d(_rec("clinic/vent", true), "Ambience")
	drone = _player2d(_rec("clinic/drone", true), "Ambience")
	ride_loop = _player2d(_rec("lift/rumble", true), "Ambience")
	if ride_loop.stream == null:
		ride_loop.stream = _wav(_rumble(2.0, 42.0), true)
	drip = _player3d(world_parent, _rec("clinic/drip", true), "Ambience", 1.5, 16.0)
	monitor = _player3d(world_parent, _rec("clinic/monitor", true), "Ambience", 1.5, 18.0)
	bell_player = _player2d(_rec("playroom/count_bell", false), "Voice")
	if bell_player.stream == null:
		bell_player.stream = streams["count_bell"]
	trill_player = _player2d(streams["trill"], "UI")
	tune_player = _player2d(streams["tune"], "Ambience")
	var amb := AudioServer.get_bus_index("Ambience")
	if amb >= 0:
		var lp := AudioEffectLowPassFilter.new()
		lp.cutoff_hz = SAG_CUTOFF
		AudioServer.add_bus_effect(amb, lp)
		_amb_lp = AudioServer.get_bus_effect_count(amb) - 1
		AudioServer.set_bus_effect_enabled(amb, _amb_lp, false)
	_loops = {"tune": [tune_player, "tune"], "approach": [squeak, "approach"], "roll": [roll, "approach"], "orderly_breath": [orderly_breath, "orderly"],
		"machinery": [machinery, "machinery"], "breath": [breath, "breath"], "hum": [hum, "hum"], "vent": [vent, "vent"],
		"drone": [drone, "drone"], "ride": [ride_loop, "rumble"], "drip": [drip, "room"], "monitor": [monitor, "room"],
		"crawl": [crawl_loop, "breath"], "drag": [drag_loop, "orderly"]}
	for i in 6:
		var sp := AudioStreamPlayer3D.new()
		sp.bus = "Effects"
		sp.unit_size = 3.0
		sp.max_distance = 30.0
		sp.max_db = 0.0
		world_parent.add_child(sp)
		_steps.append(sp)

func _rec(path: String, loop: bool) -> AudioStream:
	var p := DIR + path + ".ogg"
	if not ResourceLoader.exists(p):
		return null
	var st := load(p) as AudioStreamOggVorbis
	if st == null:
		return null
	st.loop = loop
	return st

func _player2d(st: AudioStream, bus: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = st
	p.bus = bus
	add_child(p)
	return p

func _player3d(parent: Node3D, st: AudioStream, bus: String, unit: float, far: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = st
	p.bus = bus
	p.unit_size = unit
	p.max_distance = far
	p.max_db = 0.0   # never louder than its file's level, however close
	parent.add_child(p)
	return p

func _ok(group: String) -> bool:
	return solo == "" or solo == group

## Keep a loop going at `db` (or stop it). Nothing happens for a loop with no stream.
func _loop(p: Node, group: String, on: bool, db: float) -> void:
	if p.get("stream") == null:
		return
	on = on and _ok(group)
	if on:
		p.set("volume_db", db)
		if not p.get("playing"):
			p.call("play")
	elif p.get("playing"):
		p.call("stop")

static func _group_of(name: String, cat: String) -> String:
	match name:
		"roar", "shriek":
			return "scare"
		"step":
			return "steps"
	match cat:
		"entity":
			return "orderly"
		"room":
			return "room"
	return "fx" if cat == "effect" or cat == "" else cat

func _note(name: String) -> void:
	_last[name] = Time.get_ticks_msec()
	played.append({"name": name, "ms": Time.get_ticks_msec()})
	if played.size() > 40:
		played.pop_front()

func _since(what: String) -> float:
	return (Time.get_ticks_msec() - int(_last.get(what, -1000000))) / 1000.0

func _take(name: String) -> AudioStream:
	var r: Dictionary = recorded[name]
	var list: Array = r["streams"]
	var i := int(r["next"]) % list.size()
	# Takes are dealt in turn from a random start, so a repeat is never the same take twice running.
	r["next"] = i + 1 + (_rng.randi_range(0, list.size() - 2) if list.size() > 2 else 0)
	return list[i]

## A sound everywhere (not in the world): a recording if there is one, else the stand-in.
func play(name: String, gain_db := 0.0, pitch := 1.0) -> void:
	var st: AudioStream = null
	var bus := "Effects"
	var group := "fx"
	# Recordings that stand in for a generated sound (the name stays the one asked for).
	var rec := name
	match name:
		"chime", "chime_far":
			if recorded.has("lift_bell"):
				rec = "lift_bell"
				gain_db += -9.0 if name == "chime_far" else 0.0   # the stand-ins' own step down
		"blink_warn", "blackout_warn":
			if _place == "annex" and recorded.has("buzz"):
				rec = "buzz"
		"xylo":
			# One recorded note, three times, rising.
			if recorded.has("xylo_note"):
				for k in XYLO_PITCH.size():
					_later.append({"at": Time.get_ticks_msec() + int(k * XYLO_STEP * 1000.0), "name": "xylo_note", "pos": null, "gain": gain_db, "pitch": XYLO_PITCH[k]})
				_note(name)
				return
	if recorded.has(rec):
		st = _take(rec)
		var cat := str(recorded[rec]["cat"])
		bus = str(CATS[cat][0])
		group = _group_of(rec, cat)
		gain_db += BASE_DB
		if cat == "scare":
			_last["scare"] = Time.get_ticks_msec()
	elif streams.has(name):
		st = streams[name]
		bus = str(SYNTH_BUS.get(name, "Effects"))
		group = "ui" if bus == "UI" else ("scare" if bus == "Scare" else "fx")
		gain_db += BASE_DB + float(SYNTH_DB.get(name, 0.0))
	if st == null or not _ok(group):
		return
	_note(name)
	var pick: AudioStreamPlayer = _one_shots[0]
	for p in _one_shots:
		if not p.playing:
			pick = p
			break
	pick.stream = st
	pick.bus = bus
	pick.volume_db = gain_db
	pick.pitch_scale = pitch
	pick.play()
	_by_name[name] = [pick, st]

## Cut a one-shot short (the blink warning's flicker when the lights go), if it is still the one playing.
func stop(name: String) -> void:
	var e: Array = _by_name.get(name, [])
	if e.size() == 2:
		var p: AudioStreamPlayer = e[0]
		if p.playing and p.stream == e[1]:
			p.stop()
	_by_name.erase(name)

## A recording at a place in the world, with its category's attenuation. Returns the player (or null).
func play_at(name: String, pos: Vector3, gain_db := 0.0) -> AudioStreamPlayer3D:
	if not recorded.has(name):
		return null
	var cat := str(recorded[name]["cat"])
	if not _ok(_group_of(name, cat)):
		return null
	var c: Array = CATS[cat]
	var p: AudioStreamPlayer3D = null
	for i in _shots3d.size():
		var q := _shots3d[(_shot3d_next + i) % _shots3d.size()]
		if not q.playing:
			p = q
			break
	if p == null:
		p = _shots3d[_shot3d_next]
	_shot3d_next = (_shots3d.find(p) + 1) % _shots3d.size()
	p.stream = _take(name)
	p.bus = str(c[0])
	p.unit_size = float(c[1])
	p.max_distance = float(c[2])
	p.global_position = pos
	p.volume_db = BASE_DB + gain_db
	p.pitch_scale = 1.0
	# Scares and the rattle carry across the floor on their own curve (far_db), duller with distance.
	var curve := "scare" if cat == "scare" else ("rattle" if name == "rattle" else "")
	if curve != "":
		var d := _ear_distance(pos)
		var fd := far_db(curve, d)
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		p.max_distance = 0.0
		p.volume_db += fd
		p.attenuation_filter_cutoff_hz = _far_cutoff(d)
		if fd <= SILENT_DB:
			return null
	else:
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.attenuation_filter_cutoff_hz = 5000.0
	p.play()
	_note(name)
	return p

## Per frame: the trolley from the rules' audibility, the ticking, breathing, the lift's machinery.
func update(delta: float, sq: Dictionary, pose: Variant, tick_hz: float, loudness: float, exertion: float, winded: bool, machine: float, door_pos: Vector3, speed := HUNT_SPEED) -> void:
	var g := clampf(float(sq.get("gain", 0.0)), 0.0, 1.0)
	if g > 0.0 and pose != null:
		var at := Vector3(float(pose.x), float(pose.y) + 0.4, float(pose.z))
		squeak.global_position = at
		roll.global_position = at
		# It is only ever heard unseen, so mostly from behind or round a corner, where the panning takes
		# about 7 dB: +APPROACH_DB brings it back to the voice -3 LU right behind you, falling 3 dB to the edge
		# of hearing; through a wall the low-pass takes more and MUFFLED_DB gives it back. Measured by
		# tools/mix_check.mjs: never so quiet that it is not heard before it is seen (MIX.md).
		var muffled := bool(sq.get("muffled", false))
		var db := BASE_DB + APPROACH_DB - 3.0 * (1.0 - g) + (MUFFLED_DB if muffled else 0.0)
		var pitch := clampf(0.75 + 0.25 * speed / HUNT_SPEED, 0.8, 1.05)
		squeak.pitch_scale = pitch
		roll.pitch_scale = pitch
		_loop(squeak, "approach", true, db + (float(SYNTH_DB["squeak"]) if squeak.stream is AudioStreamWAV else 0.0))
		_loop(roll, "approach", true, db - 4.0)
		if _entity_bus >= 0:
			var lp := AudioServer.get_bus_effect(_entity_bus, 0) as AudioEffectLowPassFilter
			lp.cutoff_hz = 4000.0 if muffled else 20000.0
	else:
		_loop(squeak, "approach", false, 0.0)
		_loop(roll, "approach", false, 0.0)
	# Ticking: tickHz ticks a second at the given loudness.
	if tick_hz > 0.0:
		_tick_phase += tick_hz * delta
		if _tick_phase >= 1.0:
			_tick_phase -= floor(_tick_phase)
			play("tick", linear_to_db(maxf(0.02, loudness)))
	else:
		_tick_phase = 0.0
	# Breathing that rises as the tank empties, ragged when winded.
	var bdb := BASE_DB + linear_to_db(clampf((exertion - 0.15) * 1.1, 0.001, 1.0)) - (0.0 if winded else 6.0)
	if breath.stream is AudioStreamWAV:
		bdb += float(SYNTH_DB["breath"])
	# The recording is the crew's own clean breath, already winded: it is not sped up.
	breath.pitch_scale = (1.1 if winded else 1.0) if breath.stream is AudioStreamWAV else 1.0
	_loop(breath, "breath", exertion > 0.15, bdb)
	machinery.global_position = door_pos
	_loop(machinery, "machinery", machine > 0.0, BASE_DB + float(SYNTH_DB["machinery"]) + linear_to_db(clampf(machine, 0.05, 1.0)))
	_run_later()

## One footstep of another player at `pos` (gain in dB: a sprint is louder, a creep quieter).
func step_at(pos: Vector3, gain_db: float) -> void:
	if _steps.is_empty() or not _ok("steps"):
		return
	var sp := _steps[_step_next]
	_step_next = (_step_next + 1) % _steps.size()
	if recorded.has("step"):
		sp.stream = _take("step")
		sp.volume_db = BASE_DB + gain_db
	else:
		sp.stream = streams["step"]
		sp.volume_db = BASE_DB + float(SYNTH_DB["step"]) + gain_db
	sp.global_position = pos
	sp.pitch_scale = 0.92 + _rng.randf() * 0.16
	sp.play()

## The tubes' hum follows the lights (1 as built), and is gone whenever it is dark (a blink or the
## blackout cuts it at once).
func set_hum(light: float, dark := false) -> void:
	# The prison's night (pipes, snoring, a low hum) is the block's own, not its tubes': it stays through
	# lights out.
	if _place == "prison" and hum.stream != _hum_by_place.get("", null):
		_loop(hum, "hum", true, BASE_DB)
		return
	var db := BASE_DB + linear_to_db(clampf(light, 0.05, 1.0)) + (float(SYNTH_DB["hum"]) if hum.stream is AudioStreamWAV else 0.0)
	_loop(hum, "hum", not dark and light >= 0.05, db)

func ride(on: bool) -> void:
	_loop(ride_loop, "rumble", on, BASE_DB + 4.0 + (float(SYNTH_DB["ride"]) if ride_loop.stream is AudioStreamWAV else 0.0))

## Effects and Ambience step down while the announcer speaks (bus volume, so it works in the browser too).
func duck(voice_on: bool, delta: float) -> void:
	var want := DUCK_DB if (voice_on if duck_forced < 0 else duck_forced == 1) else 0.0
	_duck = move_toward(_duck, want, DUCK_RATE * delta)
	for b: String in ["Effects", "Ambience"]:
		var i := AudioServer.get_bus_index(b)
		if i >= 0:
			AudioServer.set_bus_volume_db(i, _duck)

# --- the floor: where its room tones are ----------------------------------------------------------

func set_floor(plan: Dictionary, seed_text: String) -> void:
	_plan = plan
	_seed = seed_text
	_depth = int(plan.get("depth", 0))
	_place = str(plan.get("place", "clinic"))
	_clinic = _place == "clinic"
	# The bed in the hum's place: the office on the Annex, the play centre on the Playroom.
	var bed: AudioStream = _hum_by_place.get(_place, _hum_by_place.get("", hum.stream))
	if hum.stream != bed:
		hum.stop()
		hum.stream = bed
	_copier_at = null
	if _place == "annex":
		var crng := RandomNumberGenerator.new()
		crng.seed = ("%s:%d:copier" % [seed_text, _depth]).hash()
		var copies: Array = (plan.get("rooms", []) as Array).filter(func(r: Dictionary) -> bool: return str(r["kind"]) == "copy")
		var cr: Variant = _pick(crng, copies)
		if cr != null:
			_copier_at = _room_point(cr, 0.9)
	_tone_slot = -1
	_tone_next = {}
	_prev = {}
	_hunts = 0
	_releases = 0
	_shriek_pending_until = -1
	_rattle_in = 10.0
	drip.stop()
	monitor.stop()
	_monitor_on = false
	_drip_on = false
	if not _clinic:
		return
	# The tap and the heart monitor: each in its own room, picked from the seed (the same for everyone).
	var rng := RandomNumberGenerator.new()
	rng.seed = ("%s:%d:rooms" % [seed_text, _depth]).hash()
	var rooms: Array = plan.get("rooms", [])
	var wards := rooms.filter(func(r: Dictionary) -> bool: return str(r["kind"]) in ["ward", "exam"])
	var others := rooms.filter(func(r: Dictionary) -> bool: return str(r["kind"]) in ["closet", "station", "exam", "lobby"])
	var mon: Variant = _pick(rng, wards if not wards.is_empty() else rooms)
	if mon != null:
		monitor.global_position = _room_point(mon, 1.1)
	others.erase(mon)
	var tap: Variant = _pick(rng, others if not others.is_empty() else rooms)
	if tap != null and tap != mon:
		drip.global_position = _room_point(tap, 0.9)
	_monitor_on = mon != null
	_drip_on = tap != null and tap != mon

func clear_floor() -> void:
	_clinic = false
	_place = ""
	_plan = {}
	_later.clear()
	for k: String in _loops:
		var p: Node = _loops[k][0]
		if p.get("playing"):
			p.call("stop")

static func _pick(rng: RandomNumberGenerator, list: Array) -> Variant:
	if list.is_empty():
		return null
	return list[rng.randi_range(0, list.size() - 1)]

static func _room_point(r: Dictionary, up: float) -> Vector3:
	return Vector3((float(r["x"]) + float(r["w"]) * 0.5) * S, int(r["level"]) * LH + up, (float(r["y"]) + float(r["h"]) * 0.5) * S)

## Per frame in a run: the beds, the Orderly's breathing and reactions, the room tones.
## s: the frame (play_link.gd); emergency: the emergency lighting (0..1).
func world(delta: float, s: Dictionary, emergency: float) -> void:
	var dark := bool(s.get("dark", false))
	var blackout := bool(s.get("blackout", false))
	# The vent is the Clinic's (and the lift's): the office, play centre and prison night beds carry their
	# own air (the vent comes back where a bed's file is missing).
	_loop(vent, "vent", not (_place in ["annex", "playroom", "prison"]) or _hum_by_place.get(_place) == _hum_by_place.get(""), BASE_DB - 4.0)
	_events(s)
	_loop(drone, "drone", blackout and emergency > 0.0, BASE_DB + linear_to_db(clampf(emergency, 0.05, 1.0)))
	_loop(monitor, "room", _clinic and _monitor_on and not blackout, BASE_DB)
	_loop(drip, "room", _clinic and _drip_on, BASE_DB)
	var o: Dictionary = s.get("orderly", {})
	# The Orderly's breathing, rattle, tray and shriek belong to the Clinic. Other places' residents bring
	# their own sounds (the Temp's stapler in client/temp_view.gd, the Minder's music box in minder_view.gd).
	_orderly(delta, o if _clinic else {})
	_room_tones(float(s.get("t", 0.0)), o, dark)

func _held(o: Dictionary) -> bool:
	return bool(o.get("held", false)) or bool(o.get("seeing", false))

func _opos(o: Dictionary, up: float) -> Variant:
	var pose: Variant = o.get("pose")
	if pose == null:
		return null
	var pd: Dictionary = pose
	return Vector3(float(pd["x"]), float(pd["y"]) + up, float(pd["z"]))

## A chance from the seed: the same on every screen for the same moment of the rules.
func _chance(kind: String, index: int) -> float:
	return float(("%s:%d:%s:%d" % [_seed, _depth, kind, index]).hash() % 1000) / 1000.0

func _orderly(delta: float, o: Dictionary) -> void:
	var at: Variant = _opos(o, 2.2)
	var held := _held(o)
	# A Stillness entity that is seen makes no sound at all: it breathes only while nobody looks.
	var bdb := SILENT_DB - 1.0
	if at != null:
		orderly_breath.global_position = at
		var bd := _ear_distance(at)
		bdb = far_db("breath", bd)
		# Under the trolley (it is coming) the breath steps back, so the two together stay under the voice.
		if not old_falloff and squeak.playing:
			bdb += BREATH_UNDER_TROLLEY_DB
		orderly_breath.attenuation_filter_cutoff_hz = _far_cutoff(bd)
	_loop(orderly_breath, "orderly", at != null and not held and not bool(o.get("taken", false)) and bdb > SILENT_DB, BASE_DB + bdb)
	if at == null:
		_prev = {}
		return
	var mode := str(o.get("mode", ""))
	var moving := bool(o.get("moving", false)) and not held
	var pose: Dictionary = o["pose"]
	var anim := str(pose.get("anim", ""))
	var near := float(o.get("distance", 99.0))
	if not _prev.is_empty():
		if str(_prev["mode"]) == "waiting" and mode == "hunting":
			_hunts += 1
			# The first wake on a floor may shriek, the moment it first moves unseen.
			if _hunts == 1 and _chance("wake", _depth) < 0.6:
				_shriek_pending_until = Time.get_ticks_msec() + 6000
		if mode == "windUp" and str(_prev["mode"]) != "windUp" and not held:
			play_at("breath_quick", at)
			play_at("gown", at, -2.0)
		if moving and not bool(_prev["moving"]):
			_releases += 1
			if _chance("tray", _releases) < 0.5:
				play_at("instruments", _opos(o, 0.9))
			if _chance("shriek", _releases) < 0.12:
				_shriek_pending_until = Time.get_ticks_msec() + 1500
		if moving and anim == "duck" and str(_prev["anim"]) != "duck" and _chance("thud", _releases) < 0.6:
			play_at("thud", _opos(o, 0.6))
	if _shriek_pending_until > 0 and moving:
		if _since("shriek") >= SHRIEK_GAP and _since("roar") >= SCARE_QUIET:
			play_at("shriek", at)
		_shriek_pending_until = -1
	elif _shriek_pending_until > 0 and Time.get_ticks_msec() > _shriek_pending_until:
		_shriek_pending_until = -1
	# The rattle in its throat, now and then, only near it and only unseen.
	if not held and near < (14.0 if old_falloff else RATTLE_FAR):
		_rattle_in -= delta
		if _rattle_in <= 0.0:
			play_at("rattle", at)
			_rattle_in = _rng.randf_range(RATTLE_EVERY.x, RATTLE_EVERY.y)
	_prev = {"mode": mode, "moving": moving, "anim": anim}

## Someone was taken. Mine: the roar in my face, then the chewing. Someone else's: heard from where it is.
## On the Playroom, found and down are client/hide_view.gd's (the found-you sting, the fall): nothing here.
func caught(mine: bool, pos: Variant) -> void:
	if _place == "playroom":
		return
	# The roar is the caught placeholder for every resident; after it, the Orderly chews and the Temp's
	# stapler goes into you.
	var after := ""
	var wait := 0
	if _clinic:
		after = "chew"
		wait = 1300
	elif _place == "annex" and recorded.has("staple_soft"):
		after = "staple_soft"
		wait = STAPLE_AFTER
	if mine or pos == null:
		if recorded.has("roar"):
			play("roar")
			if after != "":
				_later.append({"at": Time.get_ticks_msec() + wait, "name": after, "pos": null, "gain": 0.0})
		else:
			play("caught")
	else:
		play_at("roar", pos)
		if after != "":
			_later.append({"at": Time.get_ticks_msec() + wait, "name": after, "pos": pos, "gain": 0.0})
	_last["scare"] = Time.get_ticks_msec()

func _run_later() -> void:
	var now := Time.get_ticks_msec()
	for i in range(_later.size() - 1, -1, -1):
		var l: Dictionary = _later[i]
		if now >= int(l["at"]):
			_later.remove_at(i)
			if l["pos"] == null:
				play(str(l["name"]), float(l["gain"]), float(l.get("pitch", 1.0)))
			else:
				play_at(str(l["name"]), l["pos"], float(l["gain"]))

## Sparse room tones, the same for every player: host time is cut into TONE_SLOT slots and each slot's
## tone (whether, when, which, where) is drawn from the floor's seed and the slot number.
func _room_tones(t: float, o: Dictionary, dark: bool) -> void:
	if not (_clinic or _place == "annex") or _plan.is_empty():
		return
	var n := int(floorf(t / TONE_SLOT))
	if n != _tone_slot:
		_tone_slot = n
		_tone_next = {}
		var rng := RandomNumberGenerator.new()
		rng.seed = ("%s:%d:tone:%d" % [_seed, _depth, n]).hash()
		if rng.randf() < 0.6:
			var when := n * TONE_SLOT + rng.randf_range(1.0, TONE_SLOT - 2.0)
			var r := rng.randf()
			var kind := "slam" if r < 0.45 else ("intercom" if r < 0.75 else "bed_roll")
			var pos: Variant = null
			if not _clinic:
				# The Annex: a phone nobody answers, from everywhere (no direction), or the photocopier in
				# its copy room.
				kind = "copier" if r >= 0.55 and _copier_at != null else "phone"
				pos = _copier_at if kind == "copier" else Vector3.INF
			elif kind == "slam":
				var doors: Array = _plan.get("doors", [])
				var dv: Variant = _pick(rng, doors)
				if dv != null:
					var d: Dictionary = dv
					pos = Vector3(((float(d["ax"]) + float(d["bx"])) * 0.5 + 0.5) * S, int(d["level"]) * LH + 1.0, ((float(d["ay"]) + float(d["by"])) * 0.5 + 0.5) * S)
			else:
				var rooms: Array = _plan.get("rooms", [])
				var room: Variant = _pick(rng, rooms)
				if room != null:
					pos = _room_point(room, 2.6 if kind == "intercom" else 0.5)
			if pos != null and when > t - 0.25:
				_tone_next = {"at": when, "kind": kind, "pos": pos}
	if _tone_next.is_empty() or t < float(_tone_next["at"]):
		return
	var tone := _tone_next
	_tone_next = {}
	# Room tones step aside: one at a time, ROOM_GAP apart, not just after a scare, not while the Orderly
	# is close and coming, and the bed rolling only while it is watched (a rolling sound while it hunts
	# unseen would lie about where it is).
	if _room_player != null and _room_player.playing:
		return
	if _since("room") < ROOM_GAP or _since("scare") < SCARE_QUIET or _since("shriek") < SCARE_QUIET or _since("roar") < SCARE_QUIET:
		return
	var approaching := bool(o.get("moving", false)) and not _held(o) and float(o.get("distance", 99.0)) < 20.0
	if approaching:
		return
	if str(tone["kind"]) == "bed_roll" and o.get("pose") != null and not _held(o):
		return
	if str(tone["kind"]) == "intercom" and dark:
		return
	if tone["pos"] == Vector3.INF:
		if recorded.has(str(tone["kind"])) and _ok("room"):
			play(str(tone["kind"]), PHONE_DB)
			_last["room"] = Time.get_ticks_msec()
		return
	_room_player = play_at(str(tone["kind"]), tone["pos"])
	if _room_player != null:
		_last["room"] = Time.get_ticks_msec()

# --- the Playroom -----------------------------------------------------------------------------------

## The floor's tune, from the ceiling speakers: `on` on the Playroom; `sag` 0 at speed, 1 the count's
## half speed through the low-pass.
func playroom(on: bool, sag: float) -> void:
	_loop(tune_player, "tune", on, BASE_DB + float(SYNTH_DB["tune"]) - 3.0 * sag)
	tune_player.pitch_scale = lerpf(1.0, 0.5, clampf(sag, 0.0, 1.0))
	var amb := AudioServer.get_bus_index("Ambience")
	if amb >= 0 and _amb_lp >= 0 and _amb_lp < AudioServer.get_bus_effect_count(amb):
		AudioServer.set_bus_effect_enabled(amb, _amb_lp, on and sag > 0.02)

## One stroke of the count's bell, `left` seconds of the count left: rising in the last RISE_FROM.
func count_bell(left: int) -> void:
	if not _ok("bell"):
		return
	var rise := maxi(0, RISE_FROM + 1 - left) if left <= RISE_FROM else 0
	bell_player.stop()
	bell_player.pitch_scale = 1.0 + RISE_PITCH * rise
	bell_player.volume_db = BASE_DB + (float(SYNTH_DB["count_bell"]) if bell_player.stream is AudioStreamWAV else 0.0) + RISE_DB * rise
	bell_player.play()
	_note("count_bell")
	bells.append([Time.get_ticks_msec(), left])
	if bells.size() > 60:
		bells.pop_front()

## The trill: while `total` (this player's sight or gap total, 0..1) rises, toy-piano notes going up
## with it; -1 for none.
func trill(total: float, delta: float) -> void:
	if total < 0.0 or not _ok("ui"):
		_trill_in = 0.0
		return
	_trill_in -= delta
	if _trill_in > 0.0:
		return
	_trill_in = 0.07
	_trill_n += 1
	trill_player.pitch_scale = (1.0 + clampf(total, 0.0, 1.0) * 1.2) * (1.0 if _trill_n % 2 == 0 else 1.12)
	trill_player.volume_db = BASE_DB + float(SYNTH_DB["trill"]) + 6.0 * clampf(total, 0.0, 1.0)
	trill_player.play()
	_note("trill")

## The host's events this frame that have a recording and no other player of them (main.gd plays the
## lift's own): the ride up (the freight lift straining), someone getting into a bunk (yours here, another's
## from their bunk), lights out (the big switch, the power dropping), the floor quota met (the panel's
## chime; the refused buzz is quota_view.gd's play("refused"), the recording when there is one). Each event
## once, however many frames carry it.
var _heard := {}
func _events(s: Dictionary) -> void:
	var evs: Array = s.get("events", [])
	if evs.is_empty():
		return
	var me := str((s.get("me", {}) as Dictionary).get("id", ""))
	for e: Dictionary in evs:
		var ty := str(e.get("type", ""))
		if not ty in ["carLeft", "bed", "lightsOut", "quotaMet"]:
			continue
		var key := "%s:%s:%s" % [ty, str(e.get("t", "")), str(e.get("playerId", ""))]
		if _heard.has(key):
			continue
		_heard[key] = Time.get_ticks_msec()
		match ty:
			"carLeft":
				if str(e.get("reason", "")) == "up" and recorded.has("lift_up"):
					play("lift_up")
			"bed":
				if bool(e.get("inBed", false)):
					var who := str(e.get("playerId", ""))
					var at: Variant = null
					if who != me:
						for o: Dictionary in s.get("others", []):
							if str(o.get("id", "")) == who:
								at = Vector3(float(o["x"]), float(o["y"]) + 0.5, float(o["z"]))
						if at == null:
							continue
					_here_or_at("bunk", at)
			"lightsOut":
				play("lights_out")
			"quotaMet":
				play("quota_met")
	if _heard.size() > 64:
		var now := Time.get_ticks_msec()
		for k: String in _heard.keys():
			if now - int(_heard[k]) > 30000:
				_heard.erase(k)

## A one-shot here (pos null: this player's own) or at a place in the world.
func _here_or_at(name: String, pos: Variant, gain_db := 0.0) -> void:
	if pos == null:
		play(name, gain_db)
	else:
		play_at(name, pos, gain_db)

## The found-you sting, in your ear (both takes of the owner's sting layered, MIX.md). The stand-in noise
## when the file is missing.
func found_me() -> void:
	play("found" if recorded.has("found") else "caught")
	_last["scare"] = Time.get_ticks_msec()

## Going down (health ran out): your own body hitting the floor, or someone else's where they fell.
func went_down(pos: Variant) -> void:
	_here_or_at("down", pos)

## Getting into (or out of) a hide of `kind` (Playroom.Hide.kind): the ball pit waded (or jumped, the
## quick way in), the tube slide, the netting and flaps of a den or playhouse, squeezing into a chest or
## cubby, sliding under the table (cloth on the floor and a shoulder against the frame). The quick way is louder; getting out a little quieter than getting in.
func hide_move(kind: String, entering: bool, fast: bool, pos: Variant) -> void:
	var name := "hide_in"
	match kind:
		"pit":
			name = "pit_jump" if fast and entering else "pit_wade"
		"slide":
			name = "slide"
		"den", "playhouse":
			name = "net_flap"
		"table":
			name = "slide_under" if recorded.has("slide_under") else "hide_in"
	_here_or_at(name, pos, (0.0 if fast else -6.0) - (0.0 if entering else 3.0))

## A squeaker tile stepped on faster than a creep.
func squeaker(pos: Variant) -> void:
	_here_or_at("squeak", pos, 0.0 if pos == null else 2.0)

## Into the ball pit off a walkway: wading at a creep (quiet), jumping in otherwise (loud: a noise).
func ball_pit(loud: bool, pos: Variant) -> void:
	_here_or_at("pit_jump" if loud else "pit_wade", pos, 0.0 if loud else -4.0)

## The Minder's disappointed huff at an empty hide, from where it is.
func huff_at(pos: Vector3) -> void:
	play_at("huff", pos)

## Ready (READY): a downed player crawling; being dragged off by the Temp.
func crawl(on: bool) -> void:
	_loop(crawl_loop, "breath", on, BASE_DB)

func dragged(on: bool) -> void:
	_loop(drag_loop, "orderly", on, BASE_DB)

## Tests: every loop (playing, volume, bus), the bus volumes, the last one-shots.
func describe() -> Dictionary:
	var loops := {}
	for k: String in _loops:
		var p: Node = _loops[k][0]
		loops[k] = {"playing": p.get("playing"), "db": p.get("volume_db"), "bus": p.get("bus"), "recorded": p.get("stream") is AudioStreamOggVorbis}
	var buses := {}
	for i in AudioServer.bus_count:
		buses[AudioServer.get_bus_name(i)] = AudioServer.get_bus_volume_db(i)
	return {"loops": loops, "buses": buses, "played": played.duplicate(), "solo": solo, "recorded": recorded.keys(), "duck": _duck, "place": _place,
		"hum": str(hum.stream.resource_path) if hum.stream != null else ""}

# --- synthesis ------------------------------------------------------------------------------------

func _wav(samples: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = samples.size()
	return w

func _buf(seconds: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(int(seconds * RATE))
	return a

func _scale(a: PackedFloat32Array, k: float) -> PackedFloat32Array:
	for i in a.size():
		a[i] *= k
	return a

func _tick() -> PackedFloat32Array:
	var a := _buf(0.012)
	for i in a.size():
		var t := float(i) / RATE
		a[i] = (1.0 if fmod(t * 2400.0, 1.0) < 0.5 else -1.0) * exp(-t * 500.0) * 0.6 + (_rng.randf() - 0.5) * exp(-t * 900.0) * 0.6
	return a

func _tones(list: Array, seconds: float, amp: float) -> PackedFloat32Array:
	var a := _buf(seconds)
	for tone: Array in list:
		var f: float = tone[0]
		var at: float = tone[1]
		for i in range(int(at * RATE), a.size()):
			var t := float(i) / RATE - at
			a[i] += (sin(TAU * f * t) + 0.3 * sin(TAU * f * 2.0 * t)) * exp(-t * 3.2) * amp
	return a

func _bell() -> PackedFloat32Array:
	var a := _buf(1.8)
	var parts := [[523.0, 1.0], [1046.0, 0.6], [1567.0, 0.35], [2637.0, 0.2]]
	for i in a.size():
		var t := float(i) / RATE
		var s := 0.0
		for p: Array in parts:
			s += sin(TAU * p[0] * t) * p[1]
		a[i] = s * exp(-t * 2.2) * 0.22
	return a

func _doors() -> PackedFloat32Array:
	var a := _buf(1.0)
	var lp := 0.0
	for i in a.size():
		var t := float(i) / RATE
		lp += ((_rng.randf() - 0.5) - lp) * 0.08
		var env := sin(clampf(t / 0.9, 0.0, 1.0) * PI)
		a[i] = lp * env * 1.6 + sin(TAU * 70.0 * t) * env * 0.08
	# The clunk at the end.
	for i in range(int(0.88 * RATE), a.size()):
		var t := float(i) / RATE - 0.88
		a[i] += sin(TAU * 90.0 * t) * exp(-t * 40.0) * 0.5
	return a

func _buzz(seconds: float) -> PackedFloat32Array:
	var a := _buf(seconds)
	for i in a.size():
		var t := float(i) / RATE
		var on := 1.0 if fmod(t * 9.0, 1.0) < 0.6 else 0.2
		a[i] = (fmod(t * 120.0, 1.0) * 2.0 - 1.0) * 0.18 * on
	return a

## The call button pressed below the floor quota (client/quota_view.gd): two short low buzzes, a panel
## saying no.
func _refused() -> PackedFloat32Array:
	var a := _buf(0.34)
	for i in a.size():
		var t := float(i) / RATE
		var k := t if t < 0.14 else t - 0.19
		if t >= 0.14 and t < 0.19:
			continue
		var env := minf(1.0, k / 0.006) * minf(1.0, (0.14 - k) / 0.02)
		var saw := fmod(t * 150.0, 1.0) * 2.0 - 1.0
		var sq := 1.0 if fmod(t * 75.0, 1.0) < 0.5 else -1.0
		a[i] = (saw * 0.6 + sq * 0.25) * 0.3 * maxf(env, 0.0)
	return a

func _winddown(seconds: float) -> PackedFloat32Array:
	var a := _buf(seconds)
	var ph := 0.0
	for i in a.size():
		var t := float(i) / RATE
		var f := lerpf(240.0, 40.0, t / seconds)
		ph += f / RATE
		var stutter := 1.0 if fmod(t * lerpf(4.0, 14.0, t / seconds), 1.0) < 0.55 else 0.25
		a[i] = (fmod(ph, 1.0) * 2.0 - 1.0) * 0.2 * stutter * (1.0 - 0.4 * t / seconds)
	return a

func _thump() -> PackedFloat32Array:
	var a := _buf(0.5)
	for i in a.size():
		var t := float(i) / RATE
		a[i] = sin(TAU * 55.0 * t) * exp(-t * 9.0) * 0.7 + (_rng.randf() - 0.5) * exp(-t * 30.0) * 0.4
	return a

func _noise(seconds: float, amp: float) -> PackedFloat32Array:
	var a := _buf(seconds)
	for i in a.size():
		var t := float(i) / RATE
		a[i] = (_rng.randf() - 0.5) * 2.0 * amp * (1.0 - 0.6 * t / seconds)
	return a

func _printer() -> PackedFloat32Array:
	var a := _buf(1.1)
	for i in a.size():
		var t := float(i) / RATE
		a[i] = (_rng.randf() - 0.5) * 0.25 * (1.0 if fmod(t * 38.0, 1.0) < 0.5 else 0.3)
	return a

func _step() -> PackedFloat32Array:
	# A shoe on hard floor: a low knock and a short scuff.
	var a := _buf(0.16)
	var lp := 0.0
	for i in a.size():
		var t := float(i) / RATE
		lp += ((_rng.randf() - 0.5) - lp) * 0.25
		a[i] = sin(TAU * 85.0 * t) * exp(-t * 45.0) * 0.6 + lp * exp(-t * 30.0) * 1.2
	return a

func _squeak() -> PackedFloat32Array:
	# A wheel that squeaks once a turn, over a low rattle.
	var a := _buf(1.2)
	var lp := 0.0
	for i in a.size():
		var t := float(i) / RATE
		var turn := fmod(t, 0.6) / 0.6
		var env := smoothstep(0.0, 0.08, turn) * (1.0 - smoothstep(0.25, 0.45, turn))
		var f := 1900.0 + 500.0 * sin(TAU * 3.0 * t)
		lp += ((_rng.randf() - 0.5) - lp) * 0.05
		a[i] = sin(TAU * f * t) * env * 0.35 + lp * 0.6
	return a

func _rumble(seconds: float, f: float) -> PackedFloat32Array:
	var a := _buf(seconds)
	var lp := 0.0
	for i in a.size():
		var t := float(i) / RATE
		lp += ((_rng.randf() - 0.5) - lp) * 0.02
		a[i] = sin(TAU * f * t) * 0.25 + sin(TAU * f * 1.5 * t) * 0.1 + lp * 1.5
	return a

func _hum() -> PackedFloat32Array:
	# Mains hum and its buzzy harmonics; 1 s loops cleanly (whole cycles of 50 Hz).
	var a := _buf(1.0)
	for i in a.size():
		var t := float(i) / RATE
		a[i] = sin(TAU * 100.0 * t) * 0.25 + sin(TAU * 200.0 * t) * 0.12 + sin(TAU * 300.0 * t) * 0.06 + sin(TAU * 50.0 * t) * 0.1
	return a

## Three notes on a toy xylophone, going up: the call to hide.
func _xylo() -> PackedFloat32Array:
	var a := _buf(1.2)
	var fs: Array[float] = [1046.5, 1318.5, 1568.0]
	for k in 3:
		var f := fs[k]
		var at := k * 0.2
		for i in range(int(at * RATE), a.size()):
			var t := float(i) / RATE - at
			a[i] += (sin(TAU * f * t) + 0.25 * sin(TAU * f * 3.9 * t) * exp(-t * 30.0)) * exp(-t * 9.0) * 0.4
	return a

## A struck hand bell: bright, gone within the second, so one stroke a second stands out.
func _hand_bell() -> PackedFloat32Array:
	var a := _buf(0.9)
	var parts := [[880.0, 1.0], [1760.0, 0.5], [2640.0, 0.3], [3520.0, 0.18]]
	for i in a.size():
		var t := float(i) / RATE
		var s := 0.0
		for p: Array in parts:
			s += sin(TAU * p[0] * t) * p[1] * exp(-t * (5.0 + p[0] / 900.0))
		a[i] = s * 0.3
	return a

## One toy-piano note, short (the trill is made of these).
func _toy_note() -> PackedFloat32Array:
	var a := _buf(0.12)
	for i in a.size():
		var t := float(i) / RATE
		a[i] = (sin(TAU * 1568.0 * t) + 0.4 * sin(TAU * 4704.0 * t)) * exp(-t * 28.0) * 0.4
	return a

## The floor's tune (the Minder's music box plays the same notes, minder_view.gd TUNE): a soft,
## cheap-speaker voice, one note every TUNE_NOTE seconds, looping.
func _tune() -> PackedFloat32Array:
	var notes: Array[int] = [7, 4, 0, 4, 7, 7, 9, 7, 4, 2, 4, 0, 2, 4, 2, -1, 0, -100]
	var a := _buf(notes.size() * TUNE_NOTE)
	for k in notes.size():
		if notes[k] < -50:
			continue
		var f := TUNE_HZ * pow(2.0, notes[k] / 12.0)
		var at := int(k * TUNE_NOTE * RATE)
		for i in range(at, mini(a.size(), at + int(TUNE_NOTE * RATE))):
			var t := float(i - at) / RATE
			var env := minf(1.0, t / 0.01) * exp(-t * 3.0)
			a[i] += (sin(TAU * f * t) + 0.3 * sin(TAU * f * 3.0 * t) + 0.12 * sin(TAU * f * 5.0 * t)) * env * 0.3
	return a

func _breathing() -> PackedFloat32Array:
	var a := _buf(1.6)
	var lp := 0.0
	for i in a.size():
		var t := float(i) / RATE
		lp += ((_rng.randf() - 0.5) - lp) * 0.3
		var env := pow(maxf(0.0, sin(TAU * t / 0.8)), 2.0)
		a[i] = lp * env * 0.9
	return a
