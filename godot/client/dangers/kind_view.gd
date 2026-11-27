# Dangers (DG0) on screen: the class every kind's view extends (client/dangers/<kind>_view.gd). One view per record,
# a Node3D the base (client/dangers/dangers_view.gd) adds under the level at the record's position and yaw, freed on
# the next floor. It draws and plays what the host's record says; it decides nothing and has no collision.
extends Node3D

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

## A one-off sound at `at` (world) on the Effects bus; `from`: seconds into the stream (start part way in).
func play_cue(stream: AudioStream, at: Vector3, db := 0.0, unit := 6.0, from := 0.0) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.bus = &"Effects"
	p.volume_db = db
	p.unit_size = unit
	p.top_level = true
	add_child(p)
	p.global_position = at
	p.finished.connect(p.queue_free)
	p.play(maxf(0.0, from))
	return p

## Seconds the record has been in its state, by host time (so every screen is at the same moment of a sound).
func seconds_in(rec: Dictionary, ht: float) -> float:
	return maxf(0.0, ht - float(rec.get("since", ht)))

## Whether the room's light is on at `at`: off in the lift's blink or blackout and in a danger dark region.
func lit(at: Vector3) -> bool:
	return base.lit(at) if base != null else true

func my_id() -> String:
	return base.my_id() if base != null else ""

## A short tone made from arithmetic (a stand-in kinds may use): `hz`, `secs`, a decay.
static func tone(hz: float, secs: float, decay := 8.0, rate := 22050) -> AudioStreamWAV:
	var n := int(secs * rate)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / rate
		var v := sin(TAU * hz * t) * exp(-decay * t)
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 30000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	return w
