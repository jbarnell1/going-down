# The stamped save (docs/floors/prison.md section 7, task P3): the player's progress as one short line
# of text that the player keeps on their own PC and the server can trust without storing anything.
#
# At bedtime the server seals each player's fields with a secret key (HMAC-SHA256) and sends them the
# sealed line; on joining the player sends it back and the server opens it. A line changed by hand
# (any character), sealed with another key, or carrying another save's stamp is refused, and the
# player starts fresh. The server keeps the key in memory only and still writes no file.
#
# The fields (a Dictionary with exactly these keys, nothing else):
#   "player"   String  a random player number, 16 lowercase hex characters (not an account)
#   "name"     String  1..16 printable ASCII characters, no " or \, no space at either end
#                      (the same characters net/ws_server.gd _clean_name lets into the lobby)
#   "credits"  int     0..MAX_INT
#   "nodes"    Array   owned upgrade ids from data/upgrades.json, each at most once
#   "days"     int     days served, 0..MAX_INT
#   "records"  Dictionary  String key ([a-z0-9_], 1..24 characters) -> int 0..MAX_INT, at most
#                      MAX_RECORDS entries (award counts, bests: whatever the report keeps)
# Integers only: a float anywhere is refused, so the text never depends on float formatting.
#
# The canonical text (one line, ASCII only, safe inside JSON and a URL without escaping):
#   GDS1|<player>|<name as hex>|<credits>|<nodes, sorted, comma-separated>|<days>|<records, sorted by key, key:value comma-separated>
# The sealed line is the text, "|", then the stamp: 64 lowercase hex characters of
# HMAC-SHA256(key, text). Same fields, same key: always the same line.
#
# API (all static; everything but new_player_number and key_from_env is pure):
#   make(fields) -> String                  the canonical text, or "" when the fields are not valid
#   check(fields) -> String                 "" when valid, else the reason make() refuses
#   stamp(text, key) -> String              64 hex characters, or "" for a key under MIN_KEY_BYTES
#   seal(fields, key) -> String             text + "|" + stamp: what the client stores; "" when refused
#   open(sealed, key) -> Dictionary         {"ok": bool, "reason": String, "fields": Dictionary}
#       Refusal reasons: "key", "too_big", "chars", "shape", "version", "stamp", then (only for a
#       correctly stamped line) "player", "name", "credits", "nodes", "days", "records",
#       "not_canonical". On a refusal "fields" is {}; the caller starts the player fresh.
#   fresh(player_number) -> Dictionary      a new player's fields (no credits, no nodes)
#   new_player_number() -> String           16 random hex characters (the engine's secure random)
#   key_from_hex(text) -> Dictionary        {"ok", "reason", "key": PackedByteArray}
#   key_from_env(var_name := ENV_KEY) -> Dictionary   the same, read from the environment
# Nothing here prints or logs a key, a stamp or a save.
extends RefCounted

const Upgrades = preload("res://sim/upgrades.gd")

const VERSION := "GDS1"
## The environment variable the server reads the key from: hex, at least MIN_KEY_BYTES bytes
## (64 hex characters). It belongs in the same private file as GD_JOIN_SECRET and is NOT changed
## when the passphrase is: changing it turns every player's save fresh.
const ENV_KEY := "GD_SAVE_KEY"
const MIN_KEY_BYTES := 32
## The server's largest message from a client: net/ws_server.gd `const MAX_MESSAGE := 4096`
## (closed with 4003 above it). tests/prop_save.gd checks the two agree.
const SERVER_MESSAGE_LIMIT := 4096
## The sealed line's own limit, leaving 1024 bytes of that message for whatever carries it (the
## hello's passphrase and name, or a JSON wrapper). The largest valid save is about 1.3 KB.
const MAX_SEALED := SERVER_MESSAGE_LIMIT - 1024
const MAX_INT := 999999999
const MAX_NAME := 16
const MAX_RECORDS := 32
const MAX_RECORD_KEY := 24
const PLAYER_HEX := 16
const STAMP_HEX := 64
const FIELDS: Array[String] = ["player", "name", "credits", "nodes", "days", "records"]

# ---------------------------------------------------------------- making

static func check(fields: Dictionary) -> String:
	if fields.size() != FIELDS.size():
		return "fields"
	for k in FIELDS:
		if not fields.has(k):
			return "fields"
	var player: Variant = fields["player"]
	if not (player is String) or not _is_lower_hex(player, PLAYER_HEX):
		return "player"
	var name: Variant = fields["name"]
	if not (name is String) or not _good_name(name):
		return "name"
	var credits: Variant = fields["credits"]
	if typeof(credits) != TYPE_INT or int(credits) < 0 or int(credits) > MAX_INT:
		return "credits"
	var nodes: Variant = fields["nodes"]
	if not (nodes is Array):
		return "nodes"
	var seen: Array[String] = []
	for n: Variant in nodes:
		if not (n is String) or Upgrades.node(String(n)).is_empty() or seen.has(String(n)):
			return "nodes"
		seen.append(String(n))
	var days: Variant = fields["days"]
	if typeof(days) != TYPE_INT or int(days) < 0 or int(days) > MAX_INT:
		return "days"
	var records: Variant = fields["records"]
	if not (records is Dictionary):
		return "records"
	var rec: Dictionary = records
	if rec.size() > MAX_RECORDS:
		return "records"
	for k: Variant in rec.keys():
		if not (k is String) or not _good_record_key(k):
			return "records"
		var v: Variant = rec[k]
		if typeof(v) != TYPE_INT or int(v) < 0 or int(v) > MAX_INT:
			return "records"
	return ""

static func make(fields: Dictionary) -> String:
	if check(fields) != "":
		return ""
	var nodes: Array[String] = []
	for n: Variant in fields["nodes"]:
		nodes.append(String(n))
	nodes.sort()
	var rec: Dictionary = fields["records"]
	var keys: Array[String] = []
	for k: Variant in rec.keys():
		keys.append(String(k))
	keys.sort()
	var pairs: Array[String] = []
	for k in keys:
		pairs.append("%s:%d" % [k, int(rec[k])])
	var name: String = fields["name"]
	var text := "%s|%s|%s|%d|%s|%d|%s" % [VERSION, String(fields["player"]), name.to_ascii_buffer().hex_encode(),
		int(fields["credits"]), ",".join(nodes), int(fields["days"]), ",".join(pairs)]
	if text.length() + 1 + STAMP_HEX > MAX_SEALED:
		return ""
	return text

static func stamp(text: String, key: PackedByteArray) -> String:
	if key.size() < MIN_KEY_BYTES:
		return ""
	return _hmac(text, key).hex_encode()

static func seal(fields: Dictionary, key: PackedByteArray) -> String:
	if key.size() < MIN_KEY_BYTES:
		return ""
	var text := make(fields)
	if text == "":
		return ""
	return text + "|" + stamp(text, key)

static func fresh(player_number: String) -> Dictionary:
	return {"player": player_number, "name": "player", "credits": 0, "nodes": [], "days": 0, "records": {}}

static func new_player_number() -> String:
	return Crypto.new().generate_random_bytes(PLAYER_HEX >> 1).hex_encode()

# ---------------------------------------------------------------- opening

static func open(sealed: String, key: PackedByteArray) -> Dictionary:
	if key.size() < MIN_KEY_BYTES:
		return _no("key")
	if sealed.length() > MAX_SEALED or sealed.to_utf8_buffer().size() > MAX_SEALED:
		return _no("too_big")
	for i in sealed.length():
		if not _allowed(sealed.unicode_at(i)):
			return _no("chars")
	var parts := sealed.split("|", true)
	if parts.size() != FIELDS.size() + 2:
		return _no("shape")
	if parts[0] != VERSION:
		return _no("version")
	var given_hex: String = parts[parts.size() - 1]
	if not _is_lower_hex(given_hex, STAMP_HEX):
		return _no("stamp")
	var text := sealed.substr(0, sealed.length() - STAMP_HEX - 1)
	if not _same_bytes(_hex_to_bytes(given_hex), _hmac(text, key)):
		return _no("stamp")
	# Stamped by this server's key. Still parsed as if hostile: a key leak, an old server with other
	# upgrade ids, or a bug must not put a bad value into the game.
	if not _is_lower_hex(parts[1], PLAYER_HEX):
		return _no("player")
	var name_hex: String = parts[2]
	if name_hex.length() % 2 != 0 or not _is_lower_hex(name_hex, name_hex.length()):
		return _no("name")
	var name := _hex_to_bytes(name_hex).get_string_from_ascii()
	if not _good_name(name) or name.to_ascii_buffer().hex_encode() != name_hex:
		return _no("name")
	var credits := _parse_int(parts[3])
	if credits < 0:
		return _no("credits")
	var nodes: Array[String] = []
	if parts[4] != "":
		for n: String in parts[4].split(",", true):
			if Upgrades.node(n).is_empty() or nodes.has(n):
				return _no("nodes")
			nodes.append(n)
	var days := _parse_int(parts[5])
	if days < 0:
		return _no("days")
	var records: Dictionary = {}
	if parts[6] != "":
		for pair: String in parts[6].split(",", true):
			var kv := pair.split(":", true)
			if kv.size() != 2 or not _good_record_key(kv[0]) or records.has(kv[0]):
				return _no("records")
			var v := _parse_int(kv[1])
			if v < 0:
				return _no("records")
			records[kv[0]] = v
	var fields := {"player": parts[1], "name": name, "credits": credits, "nodes": nodes, "days": days, "records": records}
	var why := check(fields)
	if why != "":
		return _no(why)
	if make(fields) != text:
		return _no("not_canonical")
	return {"ok": true, "reason": "", "fields": fields}

# ---------------------------------------------------------------- the key

static func key_from_hex(text: String) -> Dictionary:
	var t := text.strip_edges().to_lower()
	if t.is_empty():
		return {"ok": false, "reason": "missing", "key": PackedByteArray()}
	if t.length() % 2 != 0 or not _is_lower_hex(t, t.length()):
		return {"ok": false, "reason": "not_hex", "key": PackedByteArray()}
	var key := _hex_to_bytes(t)
	if key.size() < MIN_KEY_BYTES:
		return {"ok": false, "reason": "short", "key": PackedByteArray()}
	return {"ok": true, "reason": "", "key": key}

static func key_from_env(var_name: String = ENV_KEY) -> Dictionary:
	return key_from_hex(OS.get_environment(var_name))

# ---------------------------------------------------------------- helpers

static func _no(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "fields": {}}

static func _hmac(text: String, key: PackedByteArray) -> PackedByteArray:
	var h := HMACContext.new()
	h.start(HashingContext.HASH_SHA256, key)
	h.update(text.to_utf8_buffer())
	return h.finish()

## Every byte compared whatever the first difference: the time taken says nothing about the stamp.
static func _same_bytes(a: PackedByteArray, b: PackedByteArray) -> bool:
	if a.size() != b.size():
		return false
	var diff := 0
	for i in a.size():
		diff |= a[i] ^ b[i]
	return diff == 0

static func _allowed(c: int) -> bool:
	return (c >= 0x30 and c <= 0x39) or (c >= 0x41 and c <= 0x5a) or (c >= 0x61 and c <= 0x7a) \
		or c == 0x7c or c == 0x2c or c == 0x3a or c == 0x5f  # | , : _

static func _is_lower_hex(s: String, want_len: int) -> bool:
	if s.length() != want_len or want_len == 0:
		return false
	for i in s.length():
		var c := s.unicode_at(i)
		if not ((c >= 0x30 and c <= 0x39) or (c >= 0x61 and c <= 0x66)):
			return false
	return true

## Lowercase hex of even length (checked by the caller) to bytes.
static func _hex_to_bytes(s: String) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(s.length() >> 1)
	for i in out.size():
		out[i] = _nibble(s.unicode_at(2 * i)) * 16 + _nibble(s.unicode_at(2 * i + 1))
	return out

static func _nibble(c: int) -> int:
	return c - 0x30 if c <= 0x39 else c - 0x61 + 10

## Canonical decimal only ("0" or no leading zero, at most 9 digits); -1 for anything else.
static func _parse_int(s: String) -> int:
	if s.is_empty() or s.length() > 9 or (s.length() > 1 and s.unicode_at(0) == 0x30):
		return -1
	var v := 0
	for i in s.length():
		var c := s.unicode_at(i)
		if c < 0x30 or c > 0x39:
			return -1
		v = v * 10 + (c - 0x30)
	return v

static func _good_name(s: String) -> bool:
	if s.is_empty() or s.length() > MAX_NAME or s.strip_edges() != s:
		return false
	for i in s.length():
		var c := s.unicode_at(i)
		if c < 0x20 or c >= 0x7f or c == 0x22 or c == 0x5c:
			return false
	return true

static func _good_record_key(s: String) -> bool:
	if s.is_empty() or s.length() > MAX_RECORD_KEY:
		return false
	for i in s.length():
		var c := s.unicode_at(i)
		if not ((c >= 0x30 and c <= 0x39) or (c >= 0x61 and c <= 0x7a) or c == 0x5f):
			return false
	return true
