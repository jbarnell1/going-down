# LS1 on screen, the words and the switches (North Star B7: "When one living player remains, every camera feed locks onto
# them, the music cuts, and their tape gains a sole-survivor bonus. It is a spotlight."). Pure: client/main.gd reads these
# every frame from the snapshot (client/play_link.gd "stand", "wipe", from the host's blocks; net/protocol.gd). Nothing
# here reaches the host, and nothing here decides anything: the host's block says who and what the bonus is.
#  - The line: the survivor reads that their tape pays the bonus from now on (the number is the host's, stamped as the
#    spotlight began, so it is printed before a credit of it is earned); everyone else reads whom every camera is on.
#    No new voice: the announcer's recorded lines have nothing for this, so it is words only, in its dry tone.
#  - The watch lock: an out player's crewmate's-eyes view (client/crew_watch.gd) goes to the survivor and stays there.
#  - The music: silent while the spotlight lasts, and while the wipe's scene plays (client/wipe_scene.gd).
extends RefCounted

const WipeScene = preload("res://client/wipe_scene.gd")

## The host's spotlight in a snapshot: {id, since, mult}, or null.
static func stand_of(s: Dictionary) -> Variant:
	var st: Variant = s.get("stand")
	return st if st is Dictionary and str((st as Dictionary).get("id", "")) != "" else null

## The bonus as the line prints it: "X1.5", "X1.25".
static func mult_text(mult: float) -> String:
	return "X" + String.num(mult, 2)

## The line for this player while there is a spotlight ("" for none).
static func line_for(s: Dictionary, my_id: String, names: Dictionary) -> String:
	var st: Variant = stand_of(s)
	if st == null:
		return ""
	var id := str(st["id"])
	if id == my_id:
		return "LAST ONE UP. YOUR TAPE PAYS %s WHILE YOU STAY THAT WAY" % mult_text(float(st["mult"]))
	return "ALL CAMERAS ON %s. THE LAST ONE UP" % str(names.get(id, id)).to_upper()

## The crewmate an out player's view is locked on ("" for none): the survivor, never yourself.
static func lock_for(s: Dictionary, my_id: String) -> String:
	var st: Variant = stand_of(s)
	if st == null or str(st["id"]) == my_id:
		return ""
	return str(st["id"])

## Whether the music (and the Playroom's tune) is silent: a spotlight, or the wipe's scene still playing at `host_now`.
static func music_quiet(s: Dictionary, host_now: float) -> bool:
	return stand_of(s) != null or WipeScene.playing(s.get("wipe"), host_now)
