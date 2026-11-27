# Dangers (DG0) on screen: the class every kind's view extends (client/dangers/<kind>_view.gd). One view per record,
# a Node3D the base (client/dangers/dangers_view.gd) adds under the level at the record's position and yaw, freed on
# the next floor. It draws and plays what the host's record says; it decides nothing and has no collision.
extends Node3D

## DG0R3: named so no kind's own constants clash with them.
const _WALL_SIGHT = preload("res://sim/sight.gd")
const _WALL_MOVE = preload("res://sim/move.gd")

## Set by the base before build(): the base node (helpers), the record's id and kind.
var base: Node = null
var rec_id := -1
var kind := &""

## Once, when the record first appears on this floor. ctx: {plan, place, depth, level, floor_seed, ward}.
func build(_rec: Dictionary, _ctx: Dictionary) -> void:
	pass

## The record's state, since or numbers changed (ht: the host time now, as this screen estimates it).
func changed(_rec: Dictionary, _before: Dictionary, _ht: float) -> void:
	pass

## Every frame.
func frame(_rec: Dictionary, _ht: float, _delta: float) -> void:
	pass

## A danger event of this record (dangerNoise, dangerCue, dangerStumble, ...), at its host time.
func event(_e: Dictionary, _ht: float) -> void:
	pass

# --- helpers --------------------------------------------------------------------------------------

## The game's mix (assets/sfx/MIX.md, client/sfx.gd): every sound plays at the voice's own level (Sfx.BASE_DB), its
## loudness is set in the stream itself to its category's band, and it is never louder than its stream however close
## (max_db 0). A kind names the category; `trim_db` may only lower it (at most 0, at least -18).
## Category -> [bus, unit size m, max distance m] as client/sfx.gd CATS, plus "player" (your own body, V-8).
const CATS := {
	&"effect": [&"Effects", 3.0, 30.0], &"item": [&"Effects", 1.5, 8.0], &"room": [&"Ambience", 3.0, 28.0],
	&"ambience": [&"Ambience", 3.0, 28.0], &"scare": [&"Scare", 6.0, 45.0], &"ui": [&"UI", 3.0, 30.0],
	&"player": [&"Effects", 1.5, 10.0], &"entity": [&"Entity", 2.0, 18.0],
}
## The loudness band a stream of each category must sit in (dBFS, the simple loudness of measure(): the RMS of the
## part above -50 dBFS), from MIX.md's targets against the voice V = -16.1 LUFS: effects V-6, player V-8, room tones
## V-10, beds V-14, UI V-8, scares up to V+4 (by short-term loudness; here the whole stream's figure), each +-3.
const BANDS := {
	&"effect": [-25.1, -19.1], &"item": [-25.1, -19.1], &"player": [-27.1, -21.1], &"room": [-29.1, -23.1],
	&"ambience": [-33.1, -27.1], &"ui": [-27.1, -21.1], &"scare": [-19.1, -12.1], &"entity": [-25.1, -16.1],
}
## The most a sample may reach (dBFS).
const PEAK_MAX_DB := -1.0
## DG0R3: heard through a wall, as the game's other positional sounds are (client/temp_view.gd's stapler, Entity's
## MUFFLED_GAIN): duller (a low-pass at this cutoff) and quieter (this gain). Loops are checked again WALL_CHECK s apart.
const MUFFLED_GAIN := 0.45
const MUFFLED_CUTOFF_HZ := 1300.0
const CLEAR_CUTOFF_HZ := 20500.0
const WALL_CHECK := 0.25
## [player, its unmuffled volume_db] of every play_loop still playing.
var _wall_loops: Array = []
var _wall_next := 0.0

## A one-off sound at `at` (world), in `category`'s bus and distances, at Sfx.BASE_DB + trim_db (trim at most 0);
## `from`: seconds into the stream (start part way in, so every screen is at the same moment). (`category` may still be
## a number from the first contract: it is then a trim on the effect category.)
func play_cue(stream: AudioStream, at: Vector3, category: Variant = &"effect", trim_db := 0.0, from := 0.0) -> AudioStreamPlayer3D:
	var p := _player3d(stream, at, category, trim_db)
	p.finished.connect(p.queue_free)
	p.play(maxf(0.0, from))
	return p

## A looping sound at `at` (the stream must loop): started now, `from` seconds in; stop it with queue_free().
func play_loop(stream: AudioStream, at: Vector3, category: StringName = &"ambience", trim_db := 0.0, from := 0.0) -> AudioStreamPlayer3D:
	var p := _player3d(stream, at, category, trim_db)
	_wall_loops.append([p, p.volume_db - (linear_to_db(MUFFLED_GAIN) if bool(p.get_meta(&"muffled", false)) else 0.0)])
	var len := stream.get_length() if stream != null else 0.0
	p.play(fmod(maxf(0.0, from), len) if len > 0.0 else 0.0)
	return p

func _player3d(stream: AudioStream, at: Vector3, category: Variant, trim_db: float) -> AudioStreamPlayer3D:
	var cat: StringName = &"effect"
	var trim := trim_db
	if category is StringName or category is String:
		cat = StringName(category) if CATS.has(StringName(category)) else &"effect"
	else:
		trim = float(category)
	var row: Array = CATS[cat]
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.bus = row[0]
	p.volume_db = Sfx.BASE_DB + clampf(trim, -18.0, 0.0)
	p.max_db = 0.0
	p.unit_size = float(row[1])
	p.max_distance = float(row[2])
	p.top_level = true
	add_child(p)
	p.global_position = at
	_wall_muffle(p, at, p.volume_db)
	return p

## DG0R3: whether a sound at `at` is heard through a wall from an ear at `ear` on `plan` (pure; the line of sight the
## Temp's stapler uses). False with no plan (the Ward) or no ear.
static func through_wall(plan: Object, ear: Vector3, at: Vector3) -> bool:
	if plan == null or not ear.is_finite():
		return false
	var e := _WALL_SIGHT.Point3.make(ear.x, ear.y, ear.z, 1 if ear.y >= _WALL_MOVE.LEVEL_HEIGHT else 0)
	var s := _WALL_SIGHT.Point3.make(at.x, at.y, at.z, 1 if at.y >= _WALL_MOVE.LEVEL_HEIGHT else 0)
	return not _WALL_SIGHT.has_line_of_sight(plan, e, s)

## The ear: this screen's camera (Vector3.INF headless or outside the tree).
func _wall_ear() -> Vector3:
	var cam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() and get_viewport() != null else null
	return cam.global_position if cam != null else Vector3.INF

func _wall_muffle(p: AudioStreamPlayer3D, at: Vector3, clear_db: float) -> void:
	var plan: Variant = (base.get("_ctx") as Dictionary).get("plan") if base != null and base.get("_ctx") is Dictionary else null
	var m := through_wall(plan, _wall_ear(), at)
	p.set_meta(&"muffled", m)
	p.attenuation_filter_cutoff_hz = MUFFLED_CUTOFF_HZ if m else CLEAR_CUTOFF_HZ
	p.volume_db = clear_db + (linear_to_db(MUFFLED_GAIN) if m else 0.0)

## Called by the base every frame: each loop's muffling again, WALL_CHECK s apart (the ear moves).
func wall_check(now_s: float) -> void:
	if now_s < _wall_next:
		return
	_wall_next = now_s + WALL_CHECK
	var kept: Array = []
	for row: Array in _wall_loops:
		var p: Variant = row[0]
		if not is_instance_valid(p):
			continue
		_wall_muffle(p as AudioStreamPlayer3D, (p as AudioStreamPlayer3D).global_position, float(row[1]))
		kept.append(row)
	_wall_loops = kept

## DG0R3 (drawing from host time): the state to draw at host time `ht` for a record whose state `from` always ends in
## `next` after `length` seconds by the host's rules (e.g. a build that always ends in its jet). Once ht reaches
## since + length while the snapshot still says `from`, this gives `next`, so the screen draws it on time by its own
## host clock instead of when the snapshot saying so arrives; a kind's grace then covers only the upload delay. Any
## other state: the record's own. ht is the screen's estimate (error at most half the best round trip; early, never
## later than the snapshot would be).
static func scheduled(rec: Dictionary, ht: float, from: StringName, length: float, next: StringName) -> StringName:
	var state := StringName(str(rec.get("state", "")))
	if state == from and ht >= float(rec.get("since", INF)) + length - 1e-9:
		return next
	return state

## Headless measure of a stream made from arithmetic or loaded as WAV (8 or 16 bit): {peak_db (dBFS), loud_db (the
## RMS in dBFS of the samples above -50 dBFS, a simple loudness figure), clipped (samples at full scale)}.
## A kind's test asserts no clipping, peak_db <= PEAK_MAX_DB and loud_db inside BANDS[category] (in_band()).
static func measure(stream: AudioStreamWAV) -> Dictionary:
	var data := stream.data
	var vals := PackedFloat32Array()
	if stream.format == AudioStreamWAV.FORMAT_16_BITS:
		for i in data.size() / 2:
			vals.append(data.decode_s16(i * 2) / 32768.0)
	elif stream.format == AudioStreamWAV.FORMAT_8_BITS:
		for i in data.size():
			vals.append(data.decode_s8(i) / 128.0)
	var peak := 0.0
	var clipped := 0
	var sum := 0.0
	var n := 0
	var floor_lin := pow(10.0, -50.0 / 20.0)
	for v in vals:
		var a := absf(v)
		peak = maxf(peak, a)
		if a >= 32767.0 / 32768.0:
			clipped += 1
		if a >= floor_lin:
			sum += v * v
			n += 1
	return {"peak_db": linear_to_db(peak) if peak > 0.0 else -INF, "loud_db": 10.0 * log(sum / n) / log(10.0) if n > 0 else -INF,
		"clipped": clipped}

## Whether a measure() result fits `category`: no clipped sample, peak at most PEAK_MAX_DB, loudness inside its band.
static func in_band(m: Dictionary, category: StringName) -> bool:
	var band: Array = BANDS.get(category, BANDS[&"effect"])
	return int(m["clipped"]) == 0 and float(m["peak_db"]) <= PEAK_MAX_DB + 1e-6 and float(m["loud_db"]) >= float(band[0]) and float(m["loud_db"]) <= float(band[1])

## Seconds the record has been in its state, by host time (so every screen is at the same moment of a sound).
func seconds_in(rec: Dictionary, ht: float) -> float:
	return maxf(0.0, ht - float(rec.get("since", ht)))

## Whether the room's light is on at `at`: off in the lift's blink or blackout and in a danger dark region.
func lit(at: Vector3) -> bool:
	return base.lit(at) if base != null else true

func my_id() -> String:
	return base.my_id() if base != null else ""

## A short tone made from arithmetic (a stand-in kinds may use): `hz`, `secs`, a decay, its peak in dBFS (never above
## PEAK_MAX_DB). Measure it with measure() and set `peak_db` so it lands in its category's band.
static func tone(hz: float, secs: float, decay := 8.0, rate := 22050, peak_db := -6.0) -> AudioStreamWAV:
	var n := int(secs * rate)
	var data := PackedByteArray()
	data.resize(n * 2)
	var amp := db_to_linear(minf(peak_db, PEAK_MAX_DB - 0.1)) * 32767.0
	for i in n:
		var t := float(i) / rate
		var v := sin(TAU * hz * t) * exp(-decay * t)
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * amp))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	return w
