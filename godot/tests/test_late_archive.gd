# PL3: the dedicated server's `late_archive=memory` (server/server.gd late_archive_root). tools/play_late.mjs runs
# one fixed seed; a Reactor tape carried out on one run was kept for that seed in the user data folder, so every
# later run arrived to an empty table ("Bob takes the tape" failed with the tape already recovered). Checked here:
# without the argument the server keeps the tapes where it always has; with it, a room keeps them in memory only
# (no folder for any seed).
extends RefCounted

const T = preload("res://tests/t.gd")
const Server = preload("res://server/server.gd")
const Room = preload("res://server/room.gd")

func test_the_default_keeps_the_tapes_in_the_user_data_folder(t: T) -> void:
	t.eq(Server.late_archive_root({}), "user://reactor-campaigns", "no argument: the user data folder, as before")
	t.eq(Server.late_archive_root({"late_archive": "1"}), "user://reactor-campaigns", "any other value: the user data folder")

func test_memory_keeps_no_folder(t: T) -> void:
	t.eq(Server.late_archive_root({"late_archive": "memory"}), "", "late_archive=memory: no folder")
	var say := func(_l: String) -> void: pass
	var room := Room.new(null, say)
	room.late_archive_root = Server.late_archive_root({"late_archive": "memory"})
	t.eq(room.late_archive_path("late-1"), "", "the room keeps the seed's tape in memory")
	room.late_archive_root = Server.late_archive_root({})
	t.check(room.late_archive_path("late-1").begins_with("user://reactor-campaigns/"), "and in the folder without it")
