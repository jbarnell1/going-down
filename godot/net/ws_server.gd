# The server's public door: WebSocket connections on one TCP port, with the passphrase and the limits.
#
# Built on TCPServer and one WebSocketPeer per connection (not WebSocketMultiplayerPeer): every
# connection is handled by hand, so the server decides, per connection and before anything reaches
# the game, whether to accept it, when it has proved the passphrase, how big and how frequent its
# messages may be, and when to drop it. The multiplayer peer would add Godot's own high-level peer
# protocol (ids, relaying between clients) that this game neither needs nor wants exposed.
#
# A connection's life:
#   1. TCP accepted: refused at once (closed, nothing read) if its address is serving a back-off after
#      failed passphrases, or if MAX_PENDING connections are already waiting to prove theirs.
#   2. WebSocket handshake, then the first message must be the hello:
#        ["hello", 1, "<passphrase>", "<name>", "<build id>"]
#      The passphrase is compared in constant time (SHA-256 of both, every byte compared). A wrong or
#      missing one, a first message of any other shape, or no hello within AUTH_TIMEOUT closes the
#      connection (close code 4001) before any game message is read, and counts a failure against the
#      address: from the third failure on, that address is refused for 2^(failures - 2) seconds (at
#      most BACKOFF_MAX), whatever it sends. A bare TCP connection that never finishes the WebSocket
#      handshake (a health check) is dropped after AUTH_TIMEOUT without counting as a failure.
#      Then the build (net/build_info.gd): a client whose build id is not this server's (or that sent
#      none) is closed with 4007 and BuildInfo.OUT_OF_DATE, unless this server's own id is DEV.
#   3. Accepted: given an id ("c1", "c2", ...) unless MAX_PLAYERS are already in (4002, full).
#      From then on every message must be text, at most MAX_MESSAGE bytes (4003), at most MAX_RATE
#      per second over a one-second window (4004), and something must arrive at least every
#      IDLE_TIMEOUT seconds (4006). What a message may say is the room's business (server/room.gd),
#      which closes the connection (4005) for anything outside the protocol.
# The passphrase is never stored beyond its hash, never logged, never sent anywhere. Addresses are
# logged only as a short salted hash (addr_tag): enough to tell connections apart within one night.
extends RefCounted

const BuildInfo = preload("res://net/build_info.gd")

const MAX_PLAYERS := 8
const MAX_PENDING := 4
const MAX_MESSAGE := 4096
const MAX_RATE := 120
const AUTH_TIMEOUT := 5.0
const IDLE_TIMEOUT := 20.0
const BACKOFF_FREE := 2
## Behind a proxy (Tailscale Funnel, a container's port mapping) every friend may share one address, so
## the back-off is kept short: it slows guessing without locking the room for long.
const BACKOFF_MAX := 60.0
## Messages read from one connection per poll (so one connection cannot starve the rest).
const READ_PER_POLL := 64

const CLOSE_AUTH := 4001
const CLOSE_FULL := 4002
const CLOSE_TOO_BIG := 4003
const CLOSE_FLOOD := 4004
const CLOSE_PROTOCOL := 4005
const CLOSE_IDLE := 4006
const CLOSE_VERSION := 4007

class Conn:
	var ws: WebSocketPeer
	var addr: String
	var id := ""
	var opened_at := 0.0
	var last_at := 0.0
	var window_start := 0.0
	var window_count := 0
	var closing_since := -1.0

## Events since the last poll: {kind: "joined", id, name} | {kind: "message", id, data} | {kind: "left", id}.
var events: Array[Dictionary] = []
## Counters for the log.
var refused := {"backoff": 0, "pending": 0, "auth": 0, "full": 0, "too_big": 0, "flood": 0, "idle": 0, "protocol": 0, "version": 0}
## This server's build (BuildInfo.id(); tests and the server's `build=` argument may set it).
var build := BuildInfo.id()
## Why each accepted connection closed, for the night's log: id -> [code, reason]. Its reader erases them.
var closed := {}
var _tcp := TCPServer.new()
var _secret_hash: PackedByteArray
var _insecure: bool
var _conns: Array[Conn] = []
var _by_id := {}
var _fails := {}  # address -> [failures, refused until]
var _next_id := 1
var _log: Callable
var _salt := Crypto.new().generate_random_bytes(16)

## `secret`: the passphrase (only its hash is kept); `insecure`: accept any (local tests only).
## `log`: Callable(String) for one-line notes (never given the passphrase).
func _init(secret: String, insecure: bool, log: Callable) -> void:
	_secret_hash = _sha256(secret.to_utf8_buffer())
	_insecure = insecure
	_log = log

func listen(port: int, bind: String) -> Error:
	return _tcp.listen(port, bind)

func stop() -> void:
	for c in _conns:
		c.ws.close(1001, "server stopping")
	_tcp.stop()

static func _sha256(b: PackedByteArray) -> PackedByteArray:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	if not b.is_empty():
		h.update(b)
	return h.finish()

## Constant time: both sides hashed to 32 bytes, every byte compared, no early exit.
func _secret_ok(given: String) -> bool:
	var a := _sha256(given.to_utf8_buffer())
	var diff := 0
	for i in 32:
		diff |= a[i] ^ _secret_hash[i]
	return diff == 0 or _insecure

func players() -> int:
	return _by_id.size()

func pending() -> int:
	return _conns.size() - _by_id.size()

func send(id: String, text: String) -> void:
	var c: Conn = _by_id.get(id)
	if c != null and c.ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		c.ws.send_text(text)

func kick(id: String, code: int, reason: String) -> void:
	var c: Conn = _by_id.get(id)
	if c != null:
		if code == CLOSE_PROTOCOL:
			refused["protocol"] += 1
		_close(c, code, reason)

func _close(c: Conn, code: int, reason: String) -> void:
	if c.closing_since < 0.0:
		c.ws.close(code, reason)
		c.closing_since = Time.get_ticks_msec() / 1000.0
	if not c.id.is_empty() and _by_id.has(c.id):
		_by_id.erase(c.id)
		closed[c.id] = [code, reason]
		events.append({"kind": "left", "id": c.id})

## An address as the log may show it: 8 hex digits of a salted SHA-256 (the salt is new every start), so
## the same address reads the same all night and no address is ever written down.
func addr_tag(addr: String) -> String:
	var b := _salt.duplicate()
	b.append_array(addr.to_utf8_buffer())
	return _sha256(b).hex_encode().left(8)

func _fail(addr: String, now: float) -> void:
	var f: Array = _fails.get(addr, [0, 0.0])
	f[0] = int(f[0]) + 1
	if int(f[0]) > BACKOFF_FREE:
		f[1] = now + minf(BACKOFF_MAX, pow(2.0, int(f[0]) - BACKOFF_FREE))
	_fails[addr] = f

## Accepts, reads and times out connections. `now`: seconds (any monotonic clock).
func poll(now: float) -> void:
	while _tcp.is_connection_available():
		var tcp := _tcp.take_connection()
		var addr := tcp.get_connected_host()
		var f: Array = _fails.get(addr, [0, 0.0])
		if now < float(f[1]):
			refused["backoff"] += 1
			tcp.disconnect_from_host()
			continue
		if pending() >= MAX_PENDING:
			refused["pending"] += 1
			tcp.disconnect_from_host()
			continue
		var ws := WebSocketPeer.new()
		# Room for a message well over the limit, so an oversized one is read and refused with 4003
		# (anything over the buffer itself is dropped by the WebSocket layer).
		ws.inbound_buffer_size = 1 << 16
		ws.outbound_buffer_size = 1 << 18
		ws.max_queued_packets = 256
		if ws.accept_stream(tcp) != OK:
			tcp.disconnect_from_host()
			continue
		var c := Conn.new()
		c.ws = ws
		c.addr = addr
		c.opened_at = now
		c.last_at = now
		c.window_start = now
		_conns.append(c)
	var keep: Array[Conn] = []
	for c in _conns:
		c.ws.poll()
		var st := c.ws.get_ready_state()
		if st == WebSocketPeer.STATE_CLOSED:
			if not c.id.is_empty() and _by_id.has(c.id):
				_by_id.erase(c.id)
				closed[c.id] = [c.ws.get_close_code(), c.ws.get_close_reason()]
				events.append({"kind": "left", "id": c.id})
			continue
		if c.closing_since >= 0.0:
			# Give the close a second to be said, then drop the socket.
			if Time.get_ticks_msec() / 1000.0 - c.closing_since < 1.0:
				keep.append(c)
			continue
		if c.id.is_empty() and now - c.opened_at > AUTH_TIMEOUT:
			# A WebSocket that never said hello counts as a failure; a bare TCP connection that never
			# finished the handshake (a health check, a port scan) is only dropped.
			if st == WebSocketPeer.STATE_OPEN:
				refused["auth"] += 1
				_fail(c.addr, now)
			_close(c, CLOSE_AUTH, "no hello")
			keep.append(c)
			continue
		if st == WebSocketPeer.STATE_OPEN:
			_read(c, now)
			if c.closing_since < 0.0 and not c.id.is_empty() and now - c.last_at > IDLE_TIMEOUT:
				refused["idle"] += 1
				_close(c, CLOSE_IDLE, "idle")
		keep.append(c)
	_conns = keep

func _read(c: Conn, now: float) -> void:
	var n := 0
	while c.ws.get_available_packet_count() > 0 and c.closing_since < 0.0:
		n += 1
		if n > READ_PER_POLL:
			return
		var pkt := c.ws.get_packet()
		var text_frame := c.ws.was_string_packet()
		c.last_at = now
		if now - c.window_start >= 1.0:
			c.window_start = now
			c.window_count = 0
		c.window_count += 1
		if c.window_count > MAX_RATE:
			refused["flood"] += 1
			_close(c, CLOSE_FLOOD, "too many messages")
			return
		if pkt.size() > MAX_MESSAGE:
			refused["too_big"] += 1
			_close(c, CLOSE_TOO_BIG, "message too big")
			return
		if not text_frame:
			if c.id.is_empty():
				refused["auth"] += 1
				_fail(c.addr, now)
				_close(c, CLOSE_AUTH, "no hello")
			else:
				refused["protocol"] += 1
				_close(c, CLOSE_PROTOCOL, "binary message")
			return
		var text := pkt.get_string_from_utf8()
		if c.id.is_empty():
			_hello(c, text, now)
		else:
			events.append({"kind": "message", "id": c.id, "data": text})

func _hello(c: Conn, text: String, now: float) -> void:
	var p: Variant = JSON.parse_string(text) if text.length() <= 512 else null
	var ok: bool = p is Array and ((p as Array).size() == 4 or (p as Array).size() == 5) and p[0] is String and p[0] == "hello" and (p[1] is float or p[1] is int) \
		and float(p[1]) == 1.0 and p[2] is String and p[3] is String
	if not ok or not _secret_ok(p[2]):
		refused["auth"] += 1
		_fail(c.addr, now)
		_close(c, CLOSE_AUTH, "wrong passphrase")
		_log.call("refused a connection from address %s: no valid passphrase" % addr_tag(c.addr))
		return
	var their_build: String = p[4] if (p as Array).size() == 5 and BuildInfo.valid(p[4]) else ""
	if not BuildInfo.accepts(build, their_build):
		refused["version"] += 1
		_close(c, CLOSE_VERSION, BuildInfo.OUT_OF_DATE)
		_log.call("refused a connection from address %s: build %s, this server is %s" % [addr_tag(c.addr), their_build if their_build != "" else "(none)", build])
		return
	if _by_id.size() >= MAX_PLAYERS:
		refused["full"] += 1
		_close(c, CLOSE_FULL, "the room is full")
		_log.call("refused a connection from address %s: the room is full" % addr_tag(c.addr))
		return
	_fails.erase(c.addr)
	c.id = "c%d" % _next_id
	_next_id += 1
	_by_id[c.id] = c
	events.append({"kind": "joined", "id": c.id, "name": _clean_name(p[3]), "build": their_build, "addr": addr_tag(c.addr)})
	_log.call("%s joined from address %s" % [c.id, addr_tag(c.addr)])

## A name for the lobby: printable ASCII only, at most 16 characters.
static func _clean_name(s: String) -> String:
	var out := ""
	for i in s.length():
		var ch := s.unicode_at(i)
		if ch >= 0x20 and ch < 0x7f and ch != 0x22 and ch != 0x5c:
			out += String.chr(ch)
		if out.length() >= 16:
			break
	return out.strip_edges() if not out.strip_edges().is_empty() else "player"
