# The Playroom count's voice lines (T15i), for the count on screen (T15e) to play. Nothing calls this yet.
# Load it with preload("res://client/count_lines.gd"). The files are res://assets/voice/<voice>/<id>.mp3
# (only bella in the Godot project), listed with their subtitles in res://assets/voice/manifest.json.
# Their text and reads are in assets_src/voice/lines.json, group "playroom" (docs/floors/playarea.md 3, 10).
#
# Play these by id, not through Announcer.request(): that deals a random line of a moment, and the
# numbers share one moment. The numbers come one a second, so give them their own player on the Voice
# bus (each clip is 1.15 to 1.41 s long: about 0.1 s before the word, 0.75 to 1.0 s of word, then
# silence; stop the previous number when the next one starts).
extends RefCounted

## Count event -> line id. Times are host time; t0 and len come from the host's count event.
const LINES := {
	"last_called": "count_last_1", # the call button on this floor: the last count is coming
	"hide": "count_hide_1",        # the count event arrives: t0, the 6 s to hide begin (with the xylophone)
	"search": "count_coming_1",    # t0 + 6: the search begins
	"found": "count_found_1",      # a player is found; the audio says "Found you!", the caption adds the name
	"done": "count_done_1",        # t0 + 6 + len: the count reaches zero
}

## The caption for "found". The recording cannot say the name, so only the caption does.
const FOUND_CAPTION := "Found you, %s!"

## The numbers recorded. The bell carries the seconds in between.
const NUMBERS := [40, 30, 20, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1]

## The line to say when `remaining` whole seconds of a `length`-second search are left, or "" for none.
## A number is said on the bell stroke at t0 + 6 + length - remaining. The search's first second
## belongs to "Coming, ready or not!", so the count's own length is never said (30 in a 30 s count).
static func number_line(remaining: int, length: int) -> String:
	if remaining >= length or not NUMBERS.has(remaining):
		return ""
	return "count_%d" % remaining
