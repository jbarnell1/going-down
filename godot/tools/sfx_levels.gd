# Writes every generated stand-in sound of client/sfx.gd to WAV files, so their loudness can be measured
# beside the recordings (ffmpeg ebur128) and Sfx.SYNTH_DB set to put each at its category's level.
# Usage: godot --headless --path godot -s res://tools/sfx_levels.gd -- <output folder>
extends SceneTree

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "user://sfx_levels"
	DirAccess.make_dir_recursive_absolute(out)
	var sfx := Sfx.new()
	var world := Node3D.new()
	root.add_child(world)
	root.add_child(sfx)
	sfx.setup(world)
	var all := sfx.streams.duplicate()
	all["squeak"] = sfx._wav(sfx._squeak(), false)
	all["machinery"] = sfx._wav(sfx._rumble(2.0, 55.0), false)
	all["breath"] = sfx._wav(sfx._breathing(), false)
	all["hum"] = sfx._wav(sfx._hum(), false)
	all["ride"] = sfx._wav(sfx._rumble(2.0, 42.0), false)
	for name: String in all:
		var w: AudioStreamWAV = all[name]
		w.save_to_wav(out.path_join(name + ".wav"))
	print("wrote %d stand-ins to %s" % [all.size(), out])
	quit(0)
