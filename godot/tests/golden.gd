# The goldens: the results the tests expect, recorded from this GDScript implementation itself by
# `npm run godot:golden` (run_tests.gd --golden), and the scenario inputs the tests replay.
#   tests/golden/*.json   expected results, written only by godot:golden (never by a test run)
#   tests/inputs/*.json   scenario inputs that are data rather than code (the bridge's requests, the
#                         network scripts, the maths samples, the literal table): never rewritten
# Format (the same as the TypeScript reference files the first goldens were proved against): floats
# that are not safe integers are "~" + the 16 hex digits of their bits; integers are JSON numbers.
# A test asks for a value by file and dotted path ("run.json" "scenes", "properties.json"
# "sub.entity"). While recording, the same calls store what the test computed instead.
extends RefCounted

const M = preload("res://sim/jsmath.gd")

const GOLDEN_DIR := "res://tests/golden/"
const INPUT_DIR := "res://tests/inputs/"
const TWO53 := 9007199254740992.0

## True while run_tests.gd --golden records: tests store their results instead of comparing.
static var recording := false

static var _docs := {}
static var _inputs := {}
static var _out := {}

# ---------------------------------------------------------------------------------------------
# Reading.

static func _read(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return null
	return decode(JSON.parse_string(text))

## A whole golden file (decoded), or null when it does not exist.
static func doc(name: String) -> Variant:
	if not _docs.has(name):
		_docs[name] = _read(GOLDEN_DIR + name)
	return _docs[name]

## The expected value at `path` of golden file `name`; null while recording, or when missing
## (push_error then, so the test fails and says to run godot:golden).
static func want(name: String, path: String = "") -> Variant:
	if recording:
		return null
	var v: Variant = doc(name)
	if v == null:
		push_error("missing golden file tests/golden/%s: run npm run godot:golden" % name)
		return null
	if not path.is_empty():
		for k in path.split("."):
			if not (v is Dictionary) or not (v as Dictionary).has(k):
				push_error("tests/golden/%s has no %s: run npm run godot:golden" % [name, path])
				return null
			v = v[k]
	return v

## Item `i` of a golden list, or null (recording, or the golden has fewer items: the test then fails).
static func item(list: Variant, i: int) -> Variant:
	if list is Array and i < (list as Array).size():
		return list[i]
	return null

## An inputs file (decoded): stable scenario data, never written by godot:golden.
static func input(name: String) -> Variant:
	if not _inputs.has(name):
		var v: Variant = _read(INPUT_DIR + name)
		if v == null:
			push_error("missing input file tests/inputs/%s" % name)
		_inputs[name] = v
	return _inputs[name]

# ---------------------------------------------------------------------------------------------
# Recording.

## Files whose other parts are kept when only some are recorded (the property counts: each test
## file owns its own keys, and only the sizes being regenerated are replaced).
const MERGED := {"properties.json": true}

## Stores `value` at `path` of golden file `name` (recording only).
static func put(name: String, path: String, value: Variant) -> void:
	if not _out.has(name):
		var start: Variant = null
		if MERGED.has(name):
			start = _read(GOLDEN_DIR + name)
		_out[name] = start if start is Dictionary else {}
	if path.is_empty():
		_out[name] = value
		return
	var keys := path.split(".")
	var d: Dictionary = _out[name]
	for i in keys.size() - 1:
		if not (d.get(keys[i]) is Dictionary):
			d[keys[i]] = {}
		d = d[keys[i]]
	d[keys[keys.size() - 1]] = value

## Stores `value` as item `index` of the list at `path` of golden file `name` (recording only).
static func put_item(name: String, path: String, index: int, value: Variant) -> void:
	var cur: Variant = null
	if _out.has(name):
		cur = _out[name]
		for k in path.split("."):
			cur = cur.get(k) if cur is Dictionary else null
	var list: Array = cur if cur is Array else []
	while list.size() <= index:
		list.append(null)
	list[index] = value
	put(name, path, list)

## The names of the files recorded so far.
static func recorded() -> Array:
	var names := _out.keys()
	names.sort()
	return names

## Writes every recorded file; returns the names written.
static func write_all() -> Array:
	var names := recorded()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GOLDEN_DIR))
	for name: String in names:
		var f := FileAccess.open(GOLDEN_DIR + name, FileAccess.WRITE)
		if f == null:
			push_error("cannot write tests/golden/%s" % name)
			continue
		f.store_string(JSON.stringify(encode(_out[name]), "", true))
		f.close()
	_out.clear()
	_docs.clear()
	return names

# ---------------------------------------------------------------------------------------------
# The file format.

## JSON from a golden or input file to native values: "~hex" strings become exact floats,
## integral numbers become ints.
static func decode(v: Variant) -> Variant:
	if v is String:
		var s: String = v
		if s.begins_with("~") and s.length() == 17:
			return M.from_hex(s.substr(1))
		return s
	if v is float:
		var f: float = v
		if f == floorf(f) and absf(f) < TWO53:
			return int(f)
		return f
	if v is Array:
		var out: Array = []
		for x: Variant in v:
			out.append(decode(x))
		return out
	if v is Dictionary:
		var d: Dictionary = v
		var out := {}
		for k: Variant in d:
			out[k] = decode(d[k])
		return out
	return v

## Native values to the file format (dump_reference.ts J): floats that are not safe integers become
## "~" + bits (so -0 is 0), StringNames strings, packed arrays plain arrays.
static func encode(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			var f: float = v
			if f == floorf(f) and absf(f) < TWO53:
				return int(f)
			return "~" + M.to_hex(f)
		TYPE_STRING_NAME:
			return String(v)
		TYPE_DICTIONARY:
			var d: Dictionary = v
			var out := {}
			for k: Variant in d:
				out[str(k)] = encode(d[k])
			return out
		TYPE_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_BYTE_ARRAY:
			var out: Array = []
			for x: Variant in v:
				out.append(encode(x))
			return out
	return v
