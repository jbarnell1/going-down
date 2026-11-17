# Plays the orientation tape (client/orientation_tape.gd) on its own, in a window, then quits.
#   Godot --path godot res://client/tape_demo.tscn -- [hold=1] [stills=DIR]
#   GoingDown.exe -- scene=tape                       (the same, from the game: client/main.gd)
# hold=1 plays it again and again instead of quitting. stills=DIR saves a picture of eight shots as the
# window draws them (the video of the whole tape: Godot's --write-movie, see docs/floors/story.md ST1).
extends Control

const OrientationTape = preload("res://client/orientation_tape.gd")
## The shots pictured by stills=, and how far into each (0..1).
const STILLS: Array = [[2, 0.85], [6, 0.9], [8, 0.9], [9, 0.8], [12, 0.85], [14, 0.9], [16, 0.3], [17, 0.9]]

var tape: OrientationTape
var hold := false
var stills_dir := ""
var _stills: Array = []

func _ready() -> void:
	for raw in OS.get_cmdline_user_args():
		var a := raw.trim_prefix("--")
		if a == "hold=1":
			hold = true
		elif a.begins_with("stills="):
			stills_dir = a.substr(7)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	tape = OrientationTape.new()
	tape.name = "OrientationTape"
	add_child(tape)
	tape.finished.connect(_on_finished)
	if stills_dir != "":
		DirAccess.make_dir_recursive_absolute(stills_dir)
		for s: Array in STILLS:
			var i := int(s[0]) - 1
			_stills.append([tape.starts[i] + tape.lengths[i] * float(s[1]), "shot_%02d.png" % int(s[0])])
	print("orientation tape: %d shots, %.2f s (%s)" % [tape.shots.size(), tape.total, "measured from the recordings" if tape.measured else "the design's seconds"])
	tape.start()

func _process(_delta: float) -> void:
	# The viewport's picture is the frame last drawn, so a still is taken a frame after its time.
	while not _stills.is_empty() and tape.time >= float((_stills[0] as Array)[0]):
		var s: Array = _stills.pop_front()
		var img := get_viewport().get_texture().get_image()
		var path := stills_dir.path_join(str(s[1]))
		img.save_png(path)
		print("still %s at %.2f s" % [path, tape.time])

func _on_finished(skipped: bool) -> void:
	print("orientation tape %s at %.2f s" % ["skipped" if skipped else "finished", tape.time])
	if hold:
		tape.start()
		return
	await get_tree().create_timer(0.4).timeout
	get_tree().quit(0)
