# Recorded Arboretum effects. The host's noise events and radii live in sim/noise.gd.
extends RefCounted

const DIRECTORY := "res://assets/sfx/arboretum/"
const BED_CUES := ["wind", "crickets", "sprinkler", "quiet"]
const TAKE_LIMITS := {
	"wind": 0, "crickets": 0, "sprinkler": 0, "quiet": 0,
	"step_leaves": 4, "step_moss": 3, "step_gravel": 4, "step_creep": 4, "twig": 3,
	"badge": 6, "badges_swing": 0, "breath": 0, "sniff": 1, "shears": 1, "snatch": 2,
}

static var _takes: Dictionary = {}
var _next: Dictionary = {}

## The floor and its resident each get their own take order. A single take repeats, multiple takes cycle.
func next(cue: String) -> AudioStreamOggVorbis:
	var takes := _load_takes(cue)
	if takes.is_empty():
		return null
	var i := int(_next.get(cue, 0))
	_next[cue] = (i + 1) % takes.size()
	return takes[i]

static func _load_takes(cue: String) -> Array[AudioStreamOggVorbis]:
	if _takes.has(cue):
		return _takes[cue]
	var takes: Array[AudioStreamOggVorbis] = []
	if TAKE_LIMITS.has(cue):
		var count := int(TAKE_LIMITS[cue])
		for i in range(1, maxi(count, 1) + 1):
			var take_name := cue if count == 0 else "%s_%d" % [cue, i]
			var path := DIRECTORY + take_name + ".ogg"
			if not ResourceLoader.exists(path, "AudioStreamOggVorbis"):
				continue
			var stream := load(path) as AudioStreamOggVorbis
			if stream != null:
				takes.append(stream)
	_takes[cue] = takes
	return takes

## The actual takes available to the live sound cues.
static func names() -> PackedStringArray:
	var out := PackedStringArray()
	for cue: String in TAKE_LIMITS:
		for take in _load_takes(cue):
			out.append(take.resource_path.get_file().get_basename())
	return out
