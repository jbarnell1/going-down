# BR1: the Orderly's breathing is heard only near it, measured from the game's real camera. The game draws its 3D in
# a SubViewport (client/main.gd make_picture) with the camera there, while the Sfx node sits in the root viewport,
# whose 3D is off and which has no camera. Sfx asked its own viewport for the ear, found none, read every distance as
# 0 m, and played the slow breath at full level everywhere on the Clinic and through its floors (the owner, 21 Nov:
# "I hear it just as loud by the elevator as I do by the entity"). These tests build that same layout.
extends RefCounted

const T = preload("res://tests/t.gd")
const Sfx = preload("res://client/sfx.gd")

## The game's layout: `holder` (a viewport with 3D off and no camera) holds the Sfx node; the picture (a SubViewport)
## holds the camera and the node the 3D players go under. Returns [holder, picture, sfx, camera].
static func _game_layout() -> Array:
	var root := (Engine.get_main_loop() as SceneTree).root
	var holder := SubViewport.new()
	holder.disable_3d = true
	root.add_child(holder)
	var picture := SubViewport.new()
	picture.own_world_3d = true
	root.add_child(picture)
	var cam := Camera3D.new()
	picture.add_child(cam)
	cam.current = true
	var audio3d := Node3D.new()
	audio3d.name = "Audio3D"
	picture.add_child(audio3d)
	var sfx: Sfx = Sfx.new()
	holder.add_child(sfx)
	sfx.setup(audio3d)
	return [holder, picture, sfx, cam]

static func _drop(parts: Array) -> void:
	for n: Node in [parts[0], parts[1]]:
		n.get_parent().remove_child(n)
		n.free()

static func _frame(x: float, y: float, z: float) -> Dictionary:
	return {"pose": {"x": x, "y": y, "z": z, "anim": "idle"}, "mode": "waiting", "distance": 99.0}

func test_the_ear_is_the_pictures_camera(t: T) -> void:
	var parts := _game_layout()
	var sfx: Sfx = parts[2]
	var cam: Camera3D = parts[3]
	t.check(sfx.ear_camera() == cam, "the Sfx node hears from the camera of the world its 3D players are in")
	cam.position = Vector3(30.0, 1.6, 0.0)
	t.check(absf(sfx._ear_distance(Vector3.ZERO) - Vector3(30.0, 1.6, 0.0).length()) < 0.01, "a sound 30 m away is 30 m away, not 0: %.2f" % sfx._ear_distance(Vector3.ZERO))
	_drop(parts)

func test_the_orderlys_breath_is_silent_far_away_and_through_floors(t: T) -> void:
	var parts := _game_layout()
	var sfx: Sfx = parts[2]
	var cam: Camera3D = parts[3]
	# The Orderly asleep at the far end of the storey; the player at the lift landing 28 m away.
	var o := _frame(0.0, 0.0, 0.0)
	cam.position = Vector3(28.0, 1.6, 0.0)
	sfx._orderly(0.02, o)
	t.check(not sfx.orderly_breath.playing, "28 m away (by the lift) its breath is not playing (volume %.1f dB)" % sfx.orderly_breath.volume_db)
	cam.position = Vector3(12.0, 1.6, 0.0)
	sfx._orderly(0.02, o)
	t.check(not sfx.orderly_breath.playing, "12 m away, past the breath's 8 m onset, it is not playing")
	# Straight above it, on the next storey: the floor stops it.
	cam.position = Vector3(0.0, Sfx.LH + 1.6, 1.0)
	sfx._orderly(0.02, o)
	t.check(not sfx.orderly_breath.playing, "on the storey above it, it is not playing")
	# Near and unseen on its own storey: heard before it is seen.
	cam.position = Vector3(2.0, 1.6, 0.0)
	sfx._orderly(0.02, o)
	t.check(sfx.orderly_breath.playing, "2 m away on its storey, unseen, it breathes")
	var near_db := sfx.orderly_breath.volume_db
	cam.position = Vector3(6.0, 1.6, 0.0)
	sfx._orderly(0.02, o)
	t.check(sfx.orderly_breath.playing and sfx.orderly_breath.volume_db < near_db - 6.0, "6 m away it is quieter (%.1f dB against %.1f dB at 2 m)" % [sfx.orderly_breath.volume_db, near_db])
	_drop(parts)

func test_the_rattle_is_not_played_far_away(t: T) -> void:
	var parts := _game_layout()
	var sfx: Sfx = parts[2]
	var cam: Camera3D = parts[3]
	cam.position = Vector3(28.0, 1.6, 0.0)
	t.check(sfx.play_at("rattle", Vector3(0.0, 2.2, 0.0)) == null, "a rattle 28 m away is not played")
	cam.position = Vector3(2.0, 1.6, 0.0)
	t.check(sfx.play_at("rattle", Vector3(0.0, 2.2, 0.0)) != null, "a rattle 2 m away is")
	_drop(parts)
