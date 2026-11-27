# Dangers (DG0): the class every kind extends (sim/dangers/<kind>.gd). Pure logic, no nodes, no engine randomness, no
# state of its own: everything a kind remembers lives in its records. sim/dangers.gd makes one instance per kind.
extends RefCounted

const Api = preload("res://sim/dangers/api.gd")

## Must equal the file's name.
func kind_name() -> StringName:
	return &""

## Every state name; the first is where place() starts a record.
func states() -> Array[StringName]:
	return [&"idle"]

## Once per floor: the records (see sim/dangers.gd's header for their shape).
func place(_p: Api.Place) -> Array[Dictionary]:
	return []

## Every host tick, per record (a copy: change "n" and "k" freely, the state only with ask.set_state).
func step(_rec: Dictionary, _k: Api.Tick, _ask: Api.Asks) -> void:
	pass

## The test channel's `dangerstate`: put the record into `state` now.
func force(rec: Dictionary, state: StringName, _k: Api.Tick, ask: Api.Asks) -> void:
	ask.set_state(rec, state)
