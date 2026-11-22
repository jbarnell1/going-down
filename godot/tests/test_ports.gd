# The ports a test may open a real socket on (SH1). Every engine process that runs tests owns one block of
# SIZE ports starting at base(): a test asks for port(OFFSET) with its own offset below, never a literal.
# So two shards of one suite, or two suites in two checkouts, never listen on the same port, as long as
# each process is given its own block.
#   base(): `--port-base=N` after `--` on the engine's command line, else the environment variable
#   GD_TEST_PORT_BASE, else DEFAULT_BASE (a test file run straight from the engine, or CI).
# tools/godot.mjs test picks a free block for every engine it starts and says which (see godot/README.md).
# A new test that needs a port adds an offset here; raise SIZE (and the runner's PORT_BLOCK) if they run out.
# tests/test_test_ports.gd checks that no test file names a port number of its own.
extends RefCounted

## Ports in one engine process's block. tools/godot.mjs's PORT_BLOCK must equal this.
const SIZE := 14
## The block when nothing names one: a test run straight from the engine (`godot --script res://tests/run_tests.gd`).
const DEFAULT_BASE := 4910

## Each socket test's offset in the block. Two files may never share one (the shards run files side by side).
const TELEMETRY_SESSION := 0 # prop_telemetry: a real session's night log
const TELEMETRY_BUILD := 1 # prop_telemetry: another build is refused
const SETTINGS_A := 2 # prop_settings_net: the first server
const SETTINGS_B := 3 # prop_settings_net: the second server
const TENANT := 4 # prop_tenant
const STATION := 5 # prop_station (rule on); STATION + 1 is the rule off
const STATION_OFF := 6
const CYCLES := 7 # prop_cycles
const LATE_FLOORS := 8 # prop_late_floors
const LATE_ADMIT := 9 # prop_late_admit
const CREW_WATCH := 10 # test_crew_watch: a Clinic floor
const CREW_WATCH_REACTOR := 11 # test_crew_watch: the Reactor
const LEAVE := 12 # prop_leave_net: a player leaving mid-run
const START_ON := 13 # prop_host_start_on: the host's START ON in a shared room

static var _base := -1

## The first port of this process's block.
static func base() -> int:
	if _base < 0:
		_base = parse_base(OS.get_cmdline_user_args(), OS.get_environment("GD_TEST_PORT_BASE"))
	return _base

## What base() reads, given the user arguments and the environment variable (empty when unset).
static func parse_base(args: PackedStringArray, env: String) -> int:
	for a in args:
		if a.begins_with("--port-base="):
			var v := a.substr("--port-base=".length())
			if v.is_valid_int() and int(v) > 0 and int(v) + SIZE <= 65536:
				return int(v)
			push_error("--port-base=%s is not a port number" % v)
	if env.is_valid_int() and int(env) > 0 and int(env) + SIZE <= 65536:
		return int(env)
	return DEFAULT_BASE

## The port at `offset` in this process's block.
static func port(offset: int) -> int:
	if offset < 0 or offset >= SIZE:
		push_error("test port offset %d is outside the block of %d (tests/test_ports.gd)" % [offset, SIZE])
	return base() + offset
