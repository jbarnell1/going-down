# What a transport must provide, and an in-memory one for tests. Port of src/net/transport.ts and
# src/net/pipe.ts. Transports move opaque strings (protocol.gd makes them); they promise nothing about
# delivery: messages may be late, lost, reordered or duplicated, and the host and clients cope.
#
# The in-memory network runs on an explicit clock (`now`, seconds, set by the test) and draws every
# delay, loss, duplicate and reordering from seeded generators, one per link, so the same seed and the
# same sends give the same deliveries as the TypeScript MemoryNetwork. The WebSocket transports live
# in net/ws_transport.gd.
extends RefCounted

const Rng = preload("res://sim/rng.gd")
const M = preload("res://sim/jsmath.gd")

## The interface. receive() returns Dictionaries {from, data} in arrival order; peer_events() returns
## Dictionaries {kind: "joined"|"left", peer}.
class Transport extends RefCounted:
	var self_id: String = ""

	## Sends to one peer (dropped silently if it is not connected).
	func send(_to: String, _data: String) -> void:
		pass

	## Sends to every other connected peer.
	func broadcast(_data: String) -> void:
		pass

	## Messages that have arrived since the last call, in arrival order.
	func receive() -> Array[Dictionary]:
		return []

	## Peers that joined or left since the last call.
	func peer_events() -> Array[Dictionary]:
		return []

	## Leaves the network.
	func close() -> void:
		pass

## One direction of one link.
class LinkConfig:
	## Base one-way delay, seconds.
	var delay := 0.0
	## Extra delay drawn uniformly from [0, jitter] per message, seconds.
	var jitter := 0.0
	## Chance a message is lost.
	var loss := 0.0
	## Chance a message is held back an extra [0, reorder_delay] seconds (so later ones overtake it).
	var reorder := 0.0
	var reorder_delay := 0.0
	## Chance a message is delivered twice (the copy with its own delay).
	var duplicate := 0.0

	func copy() -> LinkConfig:
		var c := LinkConfig.new()
		c.delay = delay
		c.jitter = jitter
		c.loss = loss
		c.reorder = reorder
		c.reorder_delay = reorder_delay
		c.duplicate = duplicate
		return c

	static func make(delay_: float, jitter_: float = 0.0, loss_: float = 0.0, reorder_: float = 0.0, reorder_delay_: float = 0.0, duplicate_: float = 0.0) -> LinkConfig:
		var c := LinkConfig.new()
		c.delay = delay_
		c.jitter = jitter_
		c.loss = loss_
		c.reorder = reorder_
		c.reorder_delay = reorder_delay_
		c.duplicate = duplicate_
		return c

class LinkStats:
	var sent := 0
	var bytes := 0
	var lost := 0
	var duplicated := 0

## A simulated network of peers on an explicit clock.
class MemoryNetwork extends RefCounted:
	## The network clock, seconds. Set it, then let peers receive.
	var now := 0.0
	var seed: String
	var _defaults: LinkConfig
	var _peers := {}
	var _links := {}
	var _rngs := {}
	## peer -> Array of [at, n, from, data]
	var _queues := {}
	var _n := 0
	var stats := {}
	## Every send, when a test asks for it: [now, from, to, data].
	var log_sends := false
	var sends: Array = []

	func _init(seed_: String, defaults: LinkConfig = null) -> void:
		seed = seed_
		_defaults = defaults if defaults != null else LinkConfig.new()

	## Configures the link from `a` to `b` (one direction).
	func set_link(a: String, b: String, cfg: LinkConfig) -> void:
		_links["%s>%s" % [a, b]] = cfg

	func link(a: String, b: String) -> LinkConfig:
		return _links.get("%s>%s" % [a, b], _defaults)

	## Joins a peer to the network.
	func connect_peer(id: String) -> MemoryTransport:
		assert(not _peers.has(id), "peer %s already connected" % id)
		var t := MemoryTransport.new(self, id)
		for other: MemoryTransport in _peers.values():
			other.push_peer({"kind": "joined", "peer": id})
			t.push_peer({"kind": "joined", "peer": other.self_id})
		_peers[id] = t
		_queues[id] = []
		return t

	func disconnect_peer(id: String) -> void:
		if not _peers.has(id):
			return
		_peers.erase(id)
		_queues.erase(id)
		for other: MemoryTransport in _peers.values():
			other.push_peer({"kind": "left", "peer": id})

	func connected(id: String) -> bool:
		return _peers.has(id)

	func peer_ids() -> Array:
		return _peers.keys()

	## Earliest time something is due to arrive, or null.
	func next_delivery() -> Variant:
		var best: Variant = null
		for q: Array in _queues.values():
			for m: Array in q:
				if best == null or m[0] < best:
					best = m[0]
		return best

	func _rng(key: String) -> Rng:
		if not _rngs.has(key):
			_rngs[key] = Rng.make_rng(Rng.hash_seed("%s|%s" % [seed, key]))
		return _rngs[key]

	func post(from: String, to: String, data: String) -> void:
		if not _queues.has(to):
			return
		var key := "%s>%s" % [from, to]
		var cfg := link(from, to)
		var rng := _rng(key)
		if not stats.has(key):
			stats[key] = LinkStats.new()
		var st: LinkStats = stats[key]
		st.sent += 1
		st.bytes += data.length()
		if log_sends:
			sends.append([now, from, to, data])
		# Draw everything for this message up front, whatever happens, so one outcome never shifts the next.
		var lost := rng.next() < cfg.loss
		var dup := rng.next() < cfg.duplicate
		var d1 := _draw_delay(rng, cfg)
		var d2 := _draw_delay(rng, cfg)
		if lost:
			st.lost += 1
			return
		var q: Array = _queues[to]
		q.append([now + d1, _n, from, data])
		_n += 1
		if dup:
			st.duplicated += 1
			q.append([now + d2, _n, from, data])
			_n += 1

	func _draw_delay(rng: Rng, cfg: LinkConfig) -> float:
		var j := rng.next() * cfg.jitter
		var r := rng.next() * cfg.reorder_delay if rng.next() < cfg.reorder else 0.0
		return maxf(0.0, cfg.delay + j + r)

	## Everything for `to` due by now, in arrival order.
	func take(to: String) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		if not _queues.has(to):
			return out
		var q: Array = _queues[to]
		if q.is_empty():
			return out
		var due: Array = []
		var rest: Array = []
		for m: Array in q:
			if m[0] <= now + 1e-12:
				due.append(m)
			else:
				rest.append(m)
		if due.is_empty():
			return out
		_queues[to] = rest
		# (at, n) pairs are all distinct, so an unstable sort is fine.
		due.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
		for m: Array in due:
			out.append({"from": m[2], "data": m[3]})
		return out

class MemoryTransport extends Transport:
	# Weak, so a network and its transports do not keep each other alive.
	var _net_ref: WeakRef
	var _net: MemoryNetwork:
		get:
			return _net_ref.get_ref()
	var _events: Array[Dictionary] = []
	var _closed := false

	func _init(net: MemoryNetwork, id: String) -> void:
		_net_ref = weakref(net)
		self_id = id

	func push_peer(e: Dictionary) -> void:
		_events.append(e)

	func send(to: String, data: String) -> void:
		if _closed or to == self_id:
			return
		_net.post(self_id, to, data)

	func broadcast(data: String) -> void:
		if _closed:
			return
		for p: String in _net.peer_ids():
			if p != self_id:
				_net.post(self_id, p, data)

	func receive() -> Array[Dictionary]:
		if _closed:
			return []
		return _net.take(self_id)

	func peer_events() -> Array[Dictionary]:
		var out := _events
		_events = []
		return out

	func close() -> void:
		if _closed:
			return
		_closed = true
		_net.disconnect_peer(self_id)

## One end of a virtual link the glue drives (src/net/pipe.ts): the glue pushes what arrives for it,
## and its sends go to the `out` Callable (to, data); broadcasts to `out_all` (data).
class Pipe extends Transport:
	var _inbox: Array[Dictionary] = []
	var _events: Array[Dictionary] = []
	var _closed := false
	var _out: Callable
	var _out_all: Callable
	var _on_close: Callable

	func _init(id: String, out: Callable, out_all: Callable, on_close: Callable = Callable()) -> void:
		self_id = id
		_out = out
		_out_all = out_all
		_on_close = on_close

	## The glue: a message for this end.
	func push(from: String, data: String) -> void:
		if not _closed:
			_inbox.append({"from": from, "data": data})

	## The glue: a peer came or went.
	func push_peer(e: Dictionary) -> void:
		if not _closed:
			_events.append(e)

	func send(to: String, data: String) -> void:
		if not _closed:
			_out.call(to, data)

	func broadcast(data: String) -> void:
		if not _closed:
			_out_all.call(data)

	func receive() -> Array[Dictionary]:
		var r := _inbox
		_inbox = []
		return r

	func peer_events() -> Array[Dictionary]:
		var r := _events
		_events = []
		return r

	func close() -> void:
		if _closed:
			return
		_closed = true
		_inbox = []
		if _on_close.is_valid():
			_on_close.call()
