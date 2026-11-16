# Server cost: the host's milliseconds per tick (receiving every input, the tick, encoding and sending
# every snapshot) and bytes per second per client, with 4 and 8 players, bots driving every player,
# over the in-memory network with no delay, for 60 s of game time each.
#   godot --headless --path godot --script res://tests/net_bench.gd
extends SceneTree

const Harness = preload("res://tests/net_harness.gd")

func _init() -> void:
	for players: int in [4, 8]:
		var s := Harness.new("bench-%d" % players, players - 1, Harness.zero())
		s.run(60.0)
		var h := s.host
		var ticks := h.stats.ticks
		var per_client := h.stats.snapshot_bytes / float(players) / 60.0
		var input_bytes := 0
		for m in s.machines:
			input_bytes += m.client.stats.input_bytes
		print("%d players: %.3f ms a tick on average (worst %.2f ms), %d ticks; snapshots %.0f bytes/s per client (largest %d bytes), inputs %.0f bytes/s per client" % [
			players, s.host_us / 1000.0 / ticks, s.host_max_us / 1000.0, ticks, per_client, h.stats.max_snapshot_bytes, input_bytes / float(players) / 60.0])
	quit(0)
