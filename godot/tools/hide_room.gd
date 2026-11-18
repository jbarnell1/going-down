# play_hide's room (tools/play_hide.mjs, through tools/hide_server.gd): the home server's own room
# (server/room.gd), unchanged but for where a run starts: on floor `start_depth` (the Playroom is floor
# 4 of the game's deck), so the check plays the count without riding down three floors first. Tests only.
extends "res://server/room.gd"

var start_depth := 4
## The tuned Playroom (sim/seek.gd T15m), for tools/play_hide_tuned.mjs. Off: the Playroom as play_hide checks it.
var tuned := false

func _start(now: float) -> void:
	# The ready players, as the room's own start (server/room.gd ready-up).
	var roster := _start_roster()
	if host != null or roster.is_empty():
		return
	epoch += 1
	var seed := fixed_seed
	if seed.is_empty():
		seed = Crypto.new().generate_random_bytes(6).hex_encode()
	rules = HostRules.new(true, start_depth, Places.FULL, days, false, false, false, false, false, false, false, false, tuned)
	_transport = RoomTransport.new(self)
	_day_logged = 1
	host = Host.new(_transport, seed, roster, now, Callable(rules, "prepare"), Callable(rules, "step"))
	_dirty = true
	_log.call("run %d started with %d players at depth %d" % [epoch, roster.size(), start_depth])
