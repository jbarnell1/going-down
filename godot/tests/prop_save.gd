# The stamped save's guarantees (net/save_slip.gd, task P3 of docs/floors/prison.md): a sealed save
# opens to exactly the fields it was made from; any single changed, removed or added character, a
# wrong key, or another save's stamp is refused; an over-size line, unknown upgrades, negative or
# non-integer numbers are refused; the same fields always give the same line; the key reader
# refuses short or malformed keys. Every key here is an obviously fake test value.
extends RefCounted

const T = preload("res://tests/t.gd")
const Rng = preload("res://sim/rng.gd")
const Upgrades = preload("res://sim/upgrades.gd")
const SaveSlip = preload("res://net/save_slip.gd")

const SEEDS := 40
## Substitutes tried at every position (the first that differs from the original is used, plus one
## letter): separators, digits, case, a space and a non-ASCII character.
const SWAPS: Array[String] = ["|", "0", "Z", ":", "_", ",", "f", "9", " ", "é", "-", "a"]

func _key(byte: int) -> PackedByteArray:
	var k := PackedByteArray()
	k.resize(32)
	k.fill(byte)
	return k

func _ids() -> Array[String]:
	var out: Array[String] = []
	for n in Upgrades.nodes():
		out.append(String(n["id"]))
	return out

func _sample(seed_text: String) -> Dictionary:
	var rng := Rng.make_rng(seed_text)
	var player := ""
	for _i in SaveSlip.PLAYER_HEX:
		player += "0123456789abcdef"[rng.int_in(0, 15)]
	var name := ""
	var name_len := rng.int_in(1, SaveSlip.MAX_NAME)
	for _i in name_len:
		var c := rng.int_in(0x21, 0x7e)
		if c == 0x22 or c == 0x5c:
			c = 0x41
		name += String.chr(c)
	var nodes: Array = []
	for id in _ids():
		if rng.chance(0.5):
			nodes.append(id)
	if rng.chance(0.5):
		nodes.reverse()  # make() sorts: the order handed in must not matter
	var records := {}
	for _i in rng.int_in(0, 6):
		records["award_%d" % rng.int_in(0, 40)] = rng.int_in(0, 50)
	return {"player": player, "name": name, "credits": rng.int_in(0, 100000), "nodes": nodes,
		"days": rng.int_in(0, 300), "records": records}

func _full() -> Dictionary:
	var records := {}
	for i in SaveSlip.MAX_RECORDS:
		records["r%023d" % i] = SaveSlip.MAX_INT
	var nodes: Array = []
	for id in _ids():
		nodes.append(id)
	return {"player": "ffffffffffffffff", "name": "Ab~!#$%&'()*+,-.", "credits": SaveSlip.MAX_INT,
		"nodes": nodes, "days": SaveSlip.MAX_INT, "records": records}

func _sorted_nodes(f: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for n: Variant in f["nodes"]:
		out.append(String(n))
	out.sort()
	return out

func _same_fields(t: T, got: Dictionary, want: Dictionary, label: String) -> void:
	t.eq(got.size(), want.size(), "%s: field count" % label)
	t.eq(got.get("player"), want["player"], "%s: player" % label)
	t.eq(got.get("name"), want["name"], "%s: name" % label)
	t.eq(got.get("credits"), want["credits"], "%s: credits" % label)
	t.eq(got.get("days"), want["days"], "%s: days" % label)
	t.eq(str(_sorted_nodes(got)), str(_sorted_nodes(want)), "%s: nodes" % label)
	var gr: Dictionary = got.get("records", {})
	var wr: Dictionary = want["records"]
	t.eq(gr.size(), wr.size(), "%s: record count" % label)
	for k: Variant in wr.keys():
		t.eq(gr.get(k), wr[k], "%s: record %s" % [label, k])

## A text stamped with the right key but built by hand: what a bug or an old server could send.
func _hand_sealed(text: String, key: PackedByteArray) -> String:
	return text + "|" + SaveSlip.stamp(text, key)

func _good_text() -> String:
	return SaveSlip.make({"player": "0123456789abcdef", "name": "Ann", "credits": 300, "nodes": ["whistle"], "days": 4, "records": {"heals": 2}})

# ---------------------------------------------------------------- tests

func test_round_trip_gives_back_the_fields(t: T) -> void:
	var key := _key(0x11)
	var cases: Array[Dictionary] = [SaveSlip.fresh("00000000000000aa"), _full()]
	for k in SEEDS:
		cases.append(_sample("save-%d" % k))
	for i in cases.size():
		var f := cases[i]
		var sealed := SaveSlip.seal(f, key)
		if not t.check(sealed != "", "case %d: seal refused valid fields (%s)" % [i, SaveSlip.check(f)]):
			continue
		var r := SaveSlip.open(sealed, key)
		if not t.check(bool(r["ok"]), "case %d: open refused its own save (%s)" % [i, r["reason"]]):
			continue
		_same_fields(t, r["fields"], f, "case %d" % i)
		t.eq(SaveSlip.seal(r["fields"], key), sealed, "case %d: reopened fields seal to the same line" % i)

func test_every_changed_character_is_refused(t: T) -> void:
	var key := _key(0x11)
	var tried := 0
	var accepted := 0
	# Every substitute at every position of a typical save; two per position of the largest one.
	for every: bool in [true, false]:
		var sealed := SaveSlip.seal(_sample("edit-1") if every else _full(), key)
		t.check(bool(SaveSlip.open(sealed, key)["ok"]), "the unedited save opens")
		for i in sealed.length():
			var used: Array[String] = []
			for j in SWAPS.size():
				var s: String = SWAPS[(i + j) % SWAPS.size()]
				if s != sealed[i] and (every or used.size() < 2):
					used.append(s)
			for s in used:
				var edited := sealed.substr(0, i) + s + sealed.substr(i + 1)
				var r := SaveSlip.open(edited, key)
				tried += 1
				if not t.check(not bool(r["ok"]), "position %d changed to %s was accepted" % [i, s]):
					accepted += 1
			var removed := sealed.substr(0, i) + sealed.substr(i + 1)
			if not t.check(not bool(SaveSlip.open(removed, key)["ok"]), "position %d removed was accepted" % i):
				accepted += 1
			var added := sealed.substr(0, i) + "1" + sealed.substr(i)
			if not t.check(not bool(SaveSlip.open(added, key)["ok"]), "a character added at %d was accepted" % i):
				accepted += 1
			tried += 2
	t.check(tried > 500, "not vacuous: %d edits tried" % tried)
	t.note("%d edited saves tried, %d accepted" % [tried, accepted])

func test_wrong_key_is_refused(t: T) -> void:
	var key := _key(0x11)
	var near := _key(0x11)
	near[31] = 0x10
	for k in 10:
		var sealed := SaveSlip.seal(_sample("key-%d" % k), key)
		for other: PackedByteArray in [_key(0x22), near]:
			var r := SaveSlip.open(sealed, other)
			t.check(not bool(r["ok"]), "save %d opened with another key" % k)
			t.eq(r["reason"], "stamp", "save %d: the reason is the stamp" % k)

func test_stamp_from_another_save_is_refused(t: T) -> void:
	var key := _key(0x11)
	for k in 10:
		var a := SaveSlip.seal(_sample("swap-a-%d" % k), key)
		var b := SaveSlip.seal(_sample("swap-b-%d" % k), key)
		var a_text := a.substr(0, a.length() - SaveSlip.STAMP_HEX)
		var b_stamp := b.substr(b.length() - SaveSlip.STAMP_HEX)
		var r := SaveSlip.open(a_text + b_stamp, key)
		t.check(not bool(r["ok"]), "save %d with save %d's stamp was accepted" % [k, k])
		t.eq(r["reason"], "stamp", "swap %d: the reason is the stamp" % k)
	# A rich player's stamp on a poor player's richer copy of the same text.
	var poor := {"player": "0123456789abcdef", "name": "Ann", "credits": 5, "nodes": [], "days": 1, "records": {}}
	var rich := poor.duplicate(true)
	rich["credits"] = 50000
	var poor_sealed := SaveSlip.seal(poor, key)
	var rich_text := SaveSlip.make(rich)
	t.check(not bool(SaveSlip.open(rich_text + poor_sealed.substr(poor_sealed.length() - SaveSlip.STAMP_HEX - 1), key)["ok"]),
		"more credits under the old stamp was accepted")

func test_over_size_is_refused(t: T) -> void:
	var key := _key(0x11)
	var r := SaveSlip.open("a".repeat(5000), key)
	t.eq(r["reason"], "too_big", "5000 bytes of junk")
	# A correctly stamped line that is too long (a huge records field, as a bug could build).
	var pairs: Array[String] = []
	for i in 400:
		pairs.append("k%d:%d" % [i, 100000 + i])
	var text := "GDS1|0123456789abcdef|416e6e|0||0|" + ",".join(pairs)
	var big := _hand_sealed(text, key)
	t.check(big.length() > SaveSlip.MAX_SEALED, "the test line is over the limit (%d)" % big.length())
	t.eq(SaveSlip.open(big, key)["reason"], "too_big", "a stamped over-size save")
	# make() refuses more records than allowed, so it can never build such a line itself.
	var many := SaveSlip.fresh("0123456789abcdef")
	var rec := {}
	for i in SaveSlip.MAX_RECORDS + 1:
		rec["r%d" % i] = 1
	many["records"] = rec
	t.eq(SaveSlip.make(many), "", "too many records refused by make")

func test_largest_save_fits_the_server_limit(t: T) -> void:
	var key := _key(0x11)
	var sealed := SaveSlip.seal(_full(), key)
	t.check(sealed != "", "the largest valid save seals (%s)" % SaveSlip.check(_full()))
	t.check(sealed.length() <= SaveSlip.MAX_SEALED, "largest save %d bytes, limit %d" % [sealed.length(), SaveSlip.MAX_SEALED])
	var wrapped := 'm|{"t":"save","save":%s}' % JSON.stringify(sealed)
	t.check(wrapped.to_utf8_buffer().size() < SaveSlip.SERVER_MESSAGE_LIMIT, "wrapped in a room message it is %d bytes" % wrapped.length())
	t.eq(JSON.stringify(sealed), "\"" + sealed + "\"", "the line needs no escaping inside JSON")
	t.note("largest valid sealed save: %d bytes (limit %d, server message limit %d)" % [sealed.length(), SaveSlip.MAX_SEALED, SaveSlip.SERVER_MESSAGE_LIMIT])

func test_server_limit_is_the_real_one(t: T) -> void:
	var ws: GDScript = load("res://net/ws_server.gd")
	if not t.check(ws != null, "net/ws_server.gd loads"):
		return
	var consts: Dictionary = ws.get_script_constant_map()
	t.eq(consts.get("MAX_MESSAGE"), SaveSlip.SERVER_MESSAGE_LIMIT, "save_slip's limit equals ws_server MAX_MESSAGE")

func test_unknown_nodes_and_bad_numbers_are_refused(t: T) -> void:
	var key := _key(0x11)
	var base := SaveSlip.fresh("0123456789abcdef")
	var bad: Array[Array] = [
		["nodes", ["jetpack"]], ["nodes", ["whistle", "whistle"]], ["nodes", [7]], ["nodes", "whistle"],
		["credits", -1], ["credits", 100.0], ["credits", "100"], ["credits", SaveSlip.MAX_INT + 1],
		["days", -3], ["days", 2.5], ["records", {"heals": -1}], ["records", {"Heals": 1}], ["records", {"heals": 1.0}],
		["name", ""], ["name", "a".repeat(SaveSlip.MAX_NAME + 1)], ["name", "Ann\"s"], ["name", " Ann"], ["name", "Ann\n"], ["name", "Zoë"],
		["player", "0123456789ABCDEF"], ["player", "0123"], ["player", 12345],
	]
	for b in bad:
		var f := base.duplicate(true)
		f[b[0]] = b[1]
		t.eq(SaveSlip.make(f), "", "make refuses %s = %s" % [b[0], str(b[1])])
		t.eq(SaveSlip.seal(f, key), "", "seal refuses %s = %s" % [b[0], str(b[1])])
		t.eq(SaveSlip.check(f), String(b[0]), "the reason names %s" % b[0])
	var extra := base.duplicate(true)
	extra["admin"] = 1
	t.eq(SaveSlip.make(extra), "", "an extra field is refused")
	var missing := base.duplicate(true)
	missing.erase("days")
	t.eq(SaveSlip.make(missing), "", "a missing field is refused")
	# Correctly stamped, but not a valid save: open still refuses.
	var stamped: Array[Array] = [
		["GDS1|0123456789abcdef|416e6e|-5||0|", "chars"],  # "-" never passes the character check
		["GDS1|0123456789abcdef|416e6e|300|jetpack|0|", "nodes"],
		["GDS1|0123456789abcdef|416e6e|300|whistle,whistle|0|", "nodes"],
		["GDS1|0123456789abcdef|416e6e|007||0|", "credits"],
		["GDS1|0123456789abcdef|416e6e|300||0|heals:-1", "chars"],
		["GDS1|0123456789abcdef|416e6e|300|whistle,flashbulb|0|", "not_canonical"],
		["GDS1|0123456789abcdef|416e6e|300||0|zz:1,aa:2", "not_canonical"],
		["GDS1|0123456789abcdef||300||0|", "name"],
		["GDS1|0123456789abcdef|416e6e|300||1000000000|", "days"],
		["GDS2|0123456789abcdef|416e6e|300||0|", "version"],
	]
	for s in stamped:
		var r := SaveSlip.open(_hand_sealed(String(s[0]), key), key)
		t.check(not bool(r["ok"]), "stamped %s was accepted" % s[0])
		t.eq(r["reason"], s[1], "stamped %s: reason" % s[0])
	t.check(bool(SaveSlip.open(_hand_sealed(_good_text(), key), key)["ok"]), "the control text opens")

func test_same_fields_same_line(t: T) -> void:
	var key := _key(0x11)
	for k in SEEDS:
		var f := _sample("same-%d" % k)
		var g := f.duplicate(true)
		var nodes: Array = g["nodes"]
		nodes.reverse()
		var rec: Dictionary = f["records"]
		var reordered := {}
		var keys: Array = rec.keys()
		keys.reverse()
		for key_name: Variant in keys:
			reordered[key_name] = rec[key_name]
		g["records"] = reordered
		var a := SaveSlip.seal(f, key)
		t.eq(SaveSlip.seal(f, key), a, "seed %d: sealing twice" % k)
		t.eq(SaveSlip.seal(g, key), a, "seed %d: node and record order do not matter" % k)
	t.eq(SaveSlip.make(SaveSlip.fresh("00000000000000aa")), "GDS1|00000000000000aa|706c61796572|0||0|", "a fresh save's text")

func test_keys_shorter_than_32_bytes_are_refused(t: T) -> void:
	var short := PackedByteArray()
	short.resize(31)
	short.fill(0x11)
	var f := SaveSlip.fresh("0123456789abcdef")
	t.eq(SaveSlip.stamp("x", short), "", "stamp with a 31-byte key")
	t.eq(SaveSlip.seal(f, short), "", "seal with a 31-byte key")
	t.eq(SaveSlip.open(SaveSlip.seal(f, _key(0x11)), short)["reason"], "key", "open with a 31-byte key")
	t.eq(SaveSlip.open(SaveSlip.seal(f, _key(0x11)), PackedByteArray())["reason"], "key", "open with no key")
	t.eq(SaveSlip.key_from_hex("11".repeat(31))["reason"], "short", "31 hex bytes")
	t.eq(SaveSlip.key_from_hex("")["reason"], "missing", "empty")
	t.eq(SaveSlip.key_from_hex("1".repeat(65))["reason"], "not_hex", "odd length")
	t.eq(SaveSlip.key_from_hex("zz".repeat(32))["reason"], "not_hex", "not hex")
	var ok := SaveSlip.key_from_hex("11".repeat(32))
	t.check(bool(ok["ok"]), "32 hex bytes accepted")
	t.eq(ok["key"], _key(0x11), "the bytes")
	t.eq(SaveSlip.key_from_hex(" " + "AB".repeat(40) + "\n")["key"].size(), 40, "upper case and spaces around are fine")

func test_key_from_env(t: T) -> void:
	var var_name := "GD_SAVE_KEY_PROP_TEST_FAKE"
	OS.unset_environment(var_name)
	t.eq(SaveSlip.key_from_env(var_name)["reason"], "missing", "unset variable")
	OS.set_environment(var_name, "11".repeat(32))
	var r := SaveSlip.key_from_env(var_name)
	t.check(bool(r["ok"]), "fake key read from the environment")
	t.eq(r["key"], _key(0x11), "fake key bytes")
	OS.set_environment(var_name, "11".repeat(16))
	t.eq(SaveSlip.key_from_env(var_name)["reason"], "short", "a 16-byte key in the environment")
	OS.unset_environment(var_name)
	t.eq(SaveSlip.ENV_KEY, "GD_SAVE_KEY", "the server's variable name")

func test_new_player_numbers_are_valid_and_differ(t: T) -> void:
	var seen := {}
	for i in 50:
		var p := SaveSlip.new_player_number()
		t.eq(SaveSlip.check(SaveSlip.fresh(p)), "", "player number %s makes a valid fresh save" % p)
		seen[p] = true
	t.eq(seen.size(), 50, "50 different player numbers")
