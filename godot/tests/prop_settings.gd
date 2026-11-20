# Live settings, piece LS1 (docs/floors/live-settings.md section 7): the registry (sim/settings.gd), the run's
# tuning (sim/run.gd RunState.tuning) and the first ten settings the rules read. Proved here:
#   1. Every registry row: today's value is the game's (the constant this file names for it, with the rooms'
#      switches on), least <= today <= most, today lies on the step, the id is unique, the name is unique in
#      its section and at most 32 characters, it holds in one of the four kinds; 59 rows in the panel's groups;
#      exactly the ten LS1 rows are wired.
#   2. Settings.check refuses under least, over most, NaN, infinity, a string, an unknown id, fewest floors
#      above most and a shortest wait under 15 s (and the other pair rules); it accepts today's and a fair change.
#   3. Untuned is untouched: with the game's switches on, bot floors (Clinic, Annex and Playroom: the call, the
#      blackout, catches, downs, the count) with a null tuning, an empty one, and all ten set to today's value
#      give the same state and events on every tick.
#   4. The ten proofs, each at least, today's and most: the Orderly's and the Temp's metres in 5 s unwatched, lit
#      and in the blackout, follow their own speeds (and only their own); the Minder's search and run pace follow
#      theirs; over 500 call plans a set the wait lies within delay + floors x seconds for the set bounds and never
#      repeats a floor count, and in a run the car arrives when its plan said, whatever is changed during the wait;
#      "out" comes down.time after "downed" at 5, 10 and 60 s, and a player already down when it changes goes
#      out at the time their "downed" event gave.
#   5. Every wired id has a proof here (PROOFS): a slider can never be wired to nothing.
#   6. The Groundskeeper's six (piece AR1; sim/hearing.gd, tests/prop_hearing.gd): its metres in a second of coming
#      follow its speed, lit and in the blackout (each only its own); a player standing just inside the reach is
#      taken and one just outside is not, at three reaches; the lean goes to a player just inside the lean range
#      and the sweep to one just outside; the lean lasts the lean time; and a player is out at the snatch after
#      `heals` heals. The other Groundskeeper and noise rows are listed and read by nothing yet.
extends RefCounted

const T = preload("res://tests/t.gd")
const Settings = preload("res://sim/settings.gd")
const Run = preload("res://sim/run.gd")
const Entity = preload("res://sim/entity.gd")
const Seek = preload("res://sim/seek.gd")
const Stamina = preload("res://sim/stamina.gd")
const Instr = preload("res://sim/instrument.gd")
const Relocate = preload("res://sim/relocate.gd")
const Day = preload("res://sim/day.gd")
const Marks = preload("res://sim/marks.gd")
const Places = preload("res://sim/places.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Rng = preload("res://sim/rng.gd")
const Bot = preload("res://sim/bot.gd")
const M = preload("res://sim/jsmath.gd")
const HostRules = preload("res://net/host_rules.gd")
const Snap = preload("res://tests/snap.gd")
const CountRun = preload("res://tests/prop_count_run.gd")
const PropSeek = preload("res://tests/prop_seek.gd")
const PropHunt = preload("res://tests/prop_minder_hunt.gd")
const PropLonely = preload("res://tests/prop_lonely.gd")
const Lonely = preload("res://sim/lonely.gd")
const Hearing = preload("res://sim/hearing.gd")
const Noises = preload("res://sim/noise.gd")
const PropHearing = preload("res://tests/prop_hearing.gd")
const Findables = preload("res://sim/findables.gd")
const Inventory = preload("res://sim/inventory.gd")
const PropInventory = preload("res://tests/prop_inventory.gd")
const Shop = preload("res://sim/shop.gd")
const PropCabinet = preload("res://tests/prop_cabinet.gd")
const Upgrades = preload("res://sim/upgrades.gd")
const Prison = preload("res://sim/prison.gd")
const StationRules = preload("res://sim/station_floor.gd")
const StationPlan = preload("res://sim/station.gd")
const Flare = preload("res://sim/flare.gd")
const Lamp = preload("res://sim/lamp.gd")
const PropO2 = preload("res://tests/prop_second_orderly.gd")
const PropParty = preload("res://tests/prop_party_table.gd")

const DT := 0.05
const EPS := 1e-9

## The LS1 wires, in the registry's order: the first ten, and the Lonely Temp's chase alone (temp.alone_speed),
## added with the Lonely fix.
const TEN: Array[StringName] = [&"orderly.speed", &"orderly.dark_speed", &"temp.speed", &"temp.dark_speed", &"temp.alone_speed",
	&"minder.search_speed", &"minder.run_speed", &"lift.floors_min", &"lift.floors_max", &"lift.floor_time", &"down.time"]

## The Groundskeeper's six AR1 wires, in the registry's order.
const KEEPER_SIX: Array[StringName] = [&"groundskeeper.speed", &"groundskeeper.dark_speed", &"groundskeeper.reach",
	&"groundskeeper.lean_range", &"groundskeeper.lean", &"groundskeeper.heals"]

## Every wired id's proof: the test in this file that measures the thing it changes.
const PROOFS := {
	&"groundskeeper.tilt": "test_garden_state_clock_settings",
	&"groundskeeper.beat": "test_garden_state_clock_settings",
	&"groundskeeper.sweep": "test_garden_state_clock_settings",
	&"groundskeeper.turn": "test_garden_state_clock_settings",
	&"noise.creep_loud": "test_garden_noise_table_settings",
	&"noise.walk_moss": "test_garden_noise_table_settings",
	&"noise.walk_litter": "test_garden_noise_table_settings",
	&"noise.walk_gravel": "test_garden_noise_table_settings",
	&"noise.twig": "test_garden_noise_table_settings",
	&"noise.sprint": "test_garden_noise_table_settings",
	&"noise.crawl": "test_garden_noise_table_settings",
	&"noise.hide": "test_garden_noise_table_settings",
	&"noise.drop": "test_garden_noise_table_settings",
	&"noise.emote": "test_garden_noise_table_settings",
	&"noise.cone": "test_cone_hearing_radius",
	&"noise.search_open": "test_garden_search_hearing_radius",
	&"noise.search_rush": "test_garden_search_hearing_radius",
	&"groundskeeper.speed": "test_groundskeeper_six",
	&"groundskeeper.dark_speed": "test_groundskeeper_six",
	&"groundskeeper.reach": "test_groundskeeper_six",
	&"groundskeeper.lean_range": "test_groundskeeper_six",
	&"groundskeeper.lean": "test_groundskeeper_six",
	&"groundskeeper.heals": "test_groundskeeper_six",
	&"orderly.catch_dance": "test_catch_dance_setting",
	&"orderly.speed": "test_orderly_and_temp_speeds_lit",
	&"orderly.dark_speed": "test_orderly_and_temp_speeds_in_the_blackout",
	&"temp.speed": "test_temp_chase_speeds_under_lonely",
	&"temp.dark_speed": "test_temp_chase_speeds_under_lonely",
	&"temp.alone_speed": "test_temp_chase_speeds_under_lonely",
	&"minder.search_speed": "test_minder_search_and_run_pace",
	&"minder.run_speed": "test_minder_search_and_run_pace",
	&"lift.floors_min": "test_lift_wait_over_500_plans_and_in_a_run",
	&"lift.floors_max": "test_lift_wait_over_500_plans_and_in_a_run",
	&"lift.floor_time": "test_lift_wait_over_500_plans_and_in_a_run",
	&"down.time": "test_down_time",
	# LS4 and LS5, wired a group at a time.
	&"lift.false_stop": "test_false_stop_chance",
	&"lift.board": "test_boarding_hold_and_ride",
	&"lift.hold": "test_boarding_hold_and_ride",
	&"lift.ride": "test_boarding_hold_and_ride",
	&"dark.min": "test_blackout_lengths_and_warning",
	&"dark.max": "test_blackout_lengths_and_warning",
	&"dark.first_min": "test_blackout_lengths_and_warning",
	&"dark.first_max": "test_blackout_lengths_and_warning",
	&"dark.warning": "test_blackout_lengths_and_warning",
	&"minder.stroll": "test_minder_stroll",
	&"minder.hide_time": "test_minder_anger_and_count_lengths",
	&"minder.hide_more": "test_minder_anger_and_count_lengths",
	&"minder.last_hide": "test_minder_anger_and_count_lengths",
	&"minder.search": "test_minder_anger_and_count_lengths",
	&"minder.anger_sprint": "test_minder_anger_and_count_lengths",
	&"minder.anger_noise": "test_minder_anger_and_count_lengths",
	&"minder.anger_cool": "test_minder_anger_and_count_lengths",
	&"stamina.tank": "test_stamina_tank",
	&"heal.time": "test_heal_time_and_quiet",
	&"heal.quiet": "test_heal_time_and_quiet",
	&"heal.health": "test_heal_health",
	&"health.walk": "test_health_rates",
	&"health.sprint": "test_health_rates",
	&"health.rest": "test_health_rates",
	# S1: carrying (the four-slot inventory).
	&"inv.stack": "test_inventory_stack_and_hand_reach",
	&"inv.hand_reach": "test_inventory_stack_and_hand_reach",
	# S2: the shop and the cabinet.
	&"cabinet.slots": "test_cabinet_slots",
	&"shop.price.marker": "test_shop_prices",
	&"shop.price.glow": "test_shop_prices",
	&"shop.price.flash": "test_shop_prices",
	&"shop.price.speed": "test_shop_prices",
	&"shop.price.toy": "test_shop_prices",
	&"shop.price.salts": "test_shop_prices",
	&"shop.glow": "test_glow_seconds",
	&"badge.chance": "test_badge_search_odds",
	&"badge.depth_chance": "test_badge_search_odds",
	# TT1: the Tenant clock.
	&"tenant.minutes": "test_tenant_minutes",
	# RN1: the Reactor.
	&"reactor.power_hold": "test_reactor_numbers",
	&"reactor.wake_after": "test_reactor_numbers",
	&"reactor.wake_gap": "test_reactor_numbers",
	&"reactor.crawl_time": "test_reactor_numbers",
	&"reactor.crawl_speed": "test_reactor_numbers",
	&"reactor.run_speed": "test_reactor_numbers",
	# T22b.
	&"orderly2.first_floor": "test_second_orderly_first_floor",
	&"flare.throw": "test_flare_settings",
	&"flare.reach": "test_flare_settings",
	&"flare.stun": "test_flare_settings",
	&"flare.blind": "test_flare_settings",
	&"flare.noise": "test_flare_settings",
	&"lamp.seconds": "test_lamp_settings",
	&"lamp.range": "test_lamp_settings",
	&"record.reach": "test_recording_reach_and_rate",
	&"record.rate": "test_recording_reach_and_rate",
	&"quota.step": "test_quota_step",
	&"marks.pad": "test_marks_pad",
	# T22c: the party table.
	&"party.free_time": "test_party_table_numbers",
	&"party.free_anger": "test_party_table_numbers",
	&"party.reach": "test_party_table_numbers",
	# DF1: the pressures of floor 8 and deeper.
	&"pressure.quota": "test_pressure_settings",
	&"pressure.quota3": "test_pressure_settings",
	&"pressure.heals": "test_pressure_settings",
	&"pressure.heals3": "test_pressure_settings",
	&"pressure.watchers": "test_pressure_settings",
	&"pressure.watchers3": "test_pressure_settings",
	&"pressure.near_light": "test_pressure_settings",
	&"pressure.near_light3": "test_pressure_settings",
	&"pressure.tenant_minutes": "test_pressure_settings",
	&"pressure.tenant_minutes3": "test_pressure_settings",
}

## The rows of later pieces wired so far (sim/settings.gd WIRED_IDS), in the registry's order.
const MORE: Array[StringName] = [
	&"groundskeeper.tilt", &"groundskeeper.beat", &"groundskeeper.sweep", &"groundskeeper.turn",
	&"noise.creep_loud", &"noise.walk_moss", &"noise.walk_litter", &"noise.walk_gravel", &"noise.twig",
	&"noise.sprint", &"noise.crawl", &"noise.hide", &"noise.drop", &"noise.emote",
	&"orderly.catch_dance", &"noise.cone", &"noise.search_open", &"noise.search_rush", &"minder.stroll", &"minder.hide_time", &"minder.hide_more", &"minder.last_hide", &"minder.search",
	&"minder.anger_sprint", &"minder.anger_noise", &"minder.anger_cool",
	&"lift.false_stop", &"lift.board", &"lift.hold", &"lift.ride", &"dark.min", &"dark.max", &"dark.first_min", &"dark.first_max", &"dark.warning",
	&"stamina.tank", &"heal.time", &"heal.quiet", &"heal.health", &"health.walk", &"health.sprint", &"health.rest", &"inv.stack", &"inv.hand_reach", &"cabinet.slots",
	&"shop.price.marker", &"shop.price.glow", &"shop.price.flash", &"shop.price.speed", &"shop.price.toy", &"shop.price.salts", &"shop.glow", &"badge.chance", &"badge.depth_chance",
	&"tenant.minutes",
	&"reactor.power_hold", &"reactor.wake_after", &"reactor.wake_gap", &"reactor.crawl_time", &"reactor.crawl_speed", &"reactor.run_speed",
	&"orderly2.first_floor", &"flare.throw", &"flare.reach", &"flare.stun", &"flare.blind", &"flare.noise", &"lamp.seconds", &"lamp.range",
	&"quota.step", &"record.reach", &"record.rate", &"marks.pad",
	&"party.free_time", &"party.free_anger", &"party.reach",
	&"pressure.quota", &"pressure.quota3", &"pressure.heals", &"pressure.heals3", &"pressure.watchers", &"pressure.watchers3", &"pressure.near_light", &"pressure.near_light3", &"pressure.tenant_minutes", &"pressure.tenant_minutes3"]

## The game's value of every setting: the constant the game uses, with the rooms' switches on (paced, the long
## dark, the car waits: net/host_rules.gd). This table, not the registry, is the test's oracle.
static func game_values() -> Dictionary:
	return {
		&"resident.wind_up": Entity.WIND_UP_TIME,
		&"resident.rest": Entity.DORMANT_TIME,
		&"resident.wake_near": Entity.WAKE_DISTANCE,
		&"resident.wake_after": Entity.WAKE_TIMEOUT,
		&"reloc.rest": Relocate.REST,
		&"reloc.near_min": Relocate.NEAR_MIN,
		&"reloc.near_max": Relocate.NEAR_MAX,
		&"orderly.speed": Run.PACED_HUNT_SPEED,
		&"orderly.catch_dance": 0.0,
		&"orderly2.first_floor": float(Run.SECOND_ORDERLY_DEPTH),
		&"party.free_time": Seek.FETCH_TIME,
		&"party.free_anger": Seek.FETCH_ANGER * 100.0,
		&"party.reach": Seek.FETCH_REACH,
		&"orderly.dark_speed": Run.PACED_BLACKOUT_HUNT_SPEED,
		# The Temp is Lonely in the game's rooms (sim/lonely.gd): its chase, lit and in the blackout, and alone.
		&"temp.speed": Lonely.CHASE_SPEED,
		&"temp.dark_speed": Lonely.CHASE_SPEED,
		&"temp.alone_speed": Lonely.SOLO_CHASE_SPEED,
		&"minder.stroll": Seek.WANDER_SPEED,
		&"minder.search_speed": Seek.SEARCH_SPEED,
		&"minder.run_speed": Seek.RUN_SPEED,
		# The tuned Playroom (T15m) is on in the game's rooms.
		&"minder.hide_time": Seek.TUNED_HIDE_LENGTHS[0],
		&"minder.hide_more": Seek.TUNED_HIDE_LENGTHS[1] - Seek.TUNED_HIDE_LENGTHS[0],
		&"minder.last_hide": Seek.TUNED_LAST_HIDE,
		&"minder.search": Seek.TUNED_SEARCH,
		# The Minder's hunt (PT1) is on with it in the game's rooms: its own anger numbers.
		&"minder.anger_sprint": Seek.HUNT_ANGER_SPRINT,
		&"minder.anger_noise": Seek.HUNT_ANGER_NOISE,
		&"minder.anger_cool": 1.0 / Seek.ANGER_COOL,
		&"minder.last_count": Seek.LAST_LENGTH,
		&"minder.calm": Seek.CALM_TIME,
		&"minder.sight": Seek.SIGHT_RANGE,
		&"minder.found_after": Seek.FOUND_TIME,
		&"groundskeeper.speed": Hearing.SPEED,
		&"groundskeeper.dark_speed": Hearing.DARK_SPEED,
		&"groundskeeper.reach": Hearing.REACH,
		&"groundskeeper.lean_range": Hearing.LEAN_RANGE,
		&"groundskeeper.lean": Hearing.LEAN,
		&"groundskeeper.heals": float(Run.KEEPER_HEALS),
		&"groundskeeper.tilt": Hearing.TILT,
		&"groundskeeper.beat": Hearing.BEAT,
		&"groundskeeper.sweep": Hearing.SWEEP,
		&"groundskeeper.turn": Hearing.TURN,
		&"noise.creep_loud": Noises.CREEP_LOUD,
		&"noise.walk_moss": Noises.WALK_MOSS,
		&"noise.walk_litter": Noises.WALK_LITTER,
		&"noise.walk_gravel": Noises.WALK_GRAVEL,
		&"noise.twig": Noises.TWIG_CRACK,
		&"noise.sprint": Noises.SPRINT,
		&"noise.crawl": Noises.CRAWL,
		&"noise.hide": Noises.HIDE,
		&"noise.drop": Noises.DROP,
		&"noise.cone": Noises.CONE,
		&"flare.throw": Flare.THROW, &"flare.reach": Flare.REACH, &"flare.stun": Flare.STUN,
		&"flare.blind": Flare.BLIND, &"flare.noise": Flare.NOISE,
		&"lamp.seconds": Lamp.CHARGE, &"lamp.range": Lamp.REACH,
		&"noise.search_open": Noises.SEARCH_OPEN,
		&"noise.search_rush": Noises.SEARCH_RUSH,
		&"noise.emote": Noises.EMOTE,
		&"tenant.minutes": float(HostRules.TENANT_MINUTES),
		&"reactor.power_hold": StationRules.POWER_HOLD,
		&"reactor.wake_after": StationRules.WAKE_AFTER,
		&"reactor.wake_gap": StationRules.WAKE_GAP,
		&"reactor.crawl_time": StationRules.CRAWL_TIME,
		&"reactor.crawl_speed": StationRules.CRAWL_SPEED,
		&"reactor.run_speed": StationRules.RUN_SPEED,
		&"lift.floors_min": float(Run.CALL_FLOORS_MIN),
		&"lift.floors_max": float(Run.CALL_FLOORS_MAX),
		&"lift.floor_time": Run.FLOOR_TIME,
		&"lift.false_stop": Run.FALSE_STOP_CHANCE * 100.0,
		&"lift.board": Run.BOARD_TIME_WAITS,
		&"lift.hold": Run.HOLD_LIMIT,
		&"lift.ride": Run.RIDE_TIME,
		&"dark.min": Run.LONG_BLACKOUT_MIN,
		&"dark.max": Run.LONG_BLACKOUT_MAX,
		&"dark.first_min": Run.LONG_BLACKOUT_FIRST_MIN,
		&"dark.first_max": Run.LONG_BLACKOUT_FIRST_MAX,
		&"dark.warning": Run.BLACKOUT_WARNING,
		&"player.walk": Stamina.WALK_SPEED,
		&"player.sprint": Stamina.SPRINT_SPEED,
		&"player.creep": Stamina.CREEP_SPEED,
		&"player.raised": Instr.RAISED_SPEED_CAP,
		&"stamina.tank": Stamina.PACED_SPRINT_SECONDS,
		&"stamina.refill_walk": Stamina.RECOVER_WALKING,
		&"stamina.refill_rest": Stamina.RECOVER_RESTING,
		&"stamina.winded": Stamina.WINDED_UNTIL * 100.0,
		&"down.time": Run.DOWN_TIME,
		&"heal.time": Run.HEAL_TIME,
		&"heal.reach": Run.HEAL_REACH,
		&"down.crawl": Run.CRAWL_SPEED,
		&"heal.quiet": Run.HEAL_QUIET,
		&"health.walk": Seek.WALK_DRAIN,
		&"health.sprint": Seek.SPRINT_DRAIN,
		&"health.rest": Seek.REST_GAIN,
		&"heal.health": Run.HEAL_HEALTH,
		&"inv.stack": float(Inventory.STACK),
		&"inv.hand_reach": Inventory.HAND_REACH,
		&"cabinet.slots": float(Shop.CAB_SLOTS),
		&"shop.price.marker": float(Shop.base_price("marker")),
		&"shop.price.glow": float(Shop.base_price("glow")),
		&"shop.price.flash": float(Shop.base_price("flash")),
		&"shop.price.speed": float(Shop.base_price("speed")),
		&"shop.price.toy": float(Shop.base_price("toy")),
		&"shop.price.salts": float(Shop.base_price("salts")),
		&"shop.glow": Shop.GLOW_SECONDS,
		&"badge.chance": float(Findables.BADGE_FIRST_CHANCE),
		&"badge.depth_chance": float(Findables.BADGE_DEPTH_CHANCE),
		&"quota.each": float(Run.QUOTA_PER_PLAYER),
		&"quota.step": Run.QUOTA_DEPTH_STEP,
		&"pay.step": Run.DEPTH_PAY_STEP,
		&"record.reach": Instr.RECORD_RANGE,
		&"record.rate": Instr.RATE_NEAR,
		&"day.first": Day.START_HALVES / 2.0,
		&"day.lights_out": Day.LIGHTS_OUT_DELAY,
		&"marks.pad": float(Marks.DEFAULT_PAD),
		&"hide.in_slow": Seek.IN_SLOW,
		&"hide.in_fast": Seek.IN_FAST,
		&"hide.reach": Seek.HIDE_REACH,
		&"pressure.quota": Run.PRESSURE_QUOTA, &"pressure.quota3": Run.PRESSURE_QUOTA3,
		&"pressure.heals": float(Run.PRESSURE_HEALS), &"pressure.heals3": float(Run.PRESSURE_HEALS3),
		&"pressure.watchers": float(Run.PRESSURE_WATCHERS), &"pressure.watchers3": float(Run.PRESSURE_WATCHERS3),
		&"pressure.near_light": Run.PRESSURE_NEAR_LIGHT, &"pressure.near_light3": Run.PRESSURE_NEAR_LIGHT3,
		&"pressure.tenant_minutes": float(Run.PRESSURE_TENANT), &"pressure.tenant_minutes3": float(Run.PRESSURE_TENANT3),
	}

## Every wired setting at today's value (the "all at today's" tuning).
static func ten_at_today() -> Dictionary:
	var out := {}
	for id in TEN + MORE:
		out[id] = Settings.today(id)
	return out

# ---------------------------------------------------------------------------------------------
# 1. The registry.

func test_catch_dance_setting(t: T) -> void:
	var row := Settings.row(&"orderly.catch_dance")
	t.check(row != null and row.wired and row.section == &"orderly", "the host can find the dance under the Orderly")
	t.eq(Settings.text(&"orderly.catch_dance", Settings.today(&"orderly.catch_dance")), "OFF", "fresh rooms show OFF")
	t.eq(Settings.text(&"orderly.catch_dance", 1), "ON", "the enabled setting reads ON")

func test_registry_rows(t: T) -> void:
	var game := game_values()
	var rows := Settings.list()
	# DF1 added the ten pressure rows (floor 8 and deeper, their own group before the player speeds).
	t.eq(rows.size(), 130, "rows in the registry")
	var ids := {}
	var names := {}
	var by_group := {}
	var sections := {}
	for sec in Settings.sections():
		sections[sec["id"]] = sec["group"]
	var groups := {}
	for g in Settings.groups():
		groups[g["id"]] = true
	var last_group := -1
	var group_order: Array = []
	for g in Settings.groups():
		group_order.append(g["id"])
	for s in rows:
		var tag := String(s.id)
		t.check(not ids.has(s.id), "%s: the id is listed twice" % tag)
		ids[s.id] = true
		var key := "%s/%s" % [s.section, s.name]
		t.check(not names.has(key), "%s: the name %s is used twice in its section" % [tag, s.name])
		names[key] = true
		t.check(s.name.length() <= 32 and not s.name.is_empty(), "%s: name %s is %d characters (at most 32)" % [tag, s.name, s.name.length()])
		t.check(sections.get(s.section, &"") == s.group and groups.has(s.group), "%s: section %s in group %s" % [tag, s.section, s.group])
		t.check(Settings.HOLDS_SHOWN.has(s.holds), "%s: holds %s" % [tag, s.holds])
		t.check(game.has(s.id), "%s: the test's table does not name its game value" % tag)
		if game.has(s.id):
			t.check(absf(float(game[s.id]) - s.today) < 1e-9, "%s: today %s, the game's %s" % [tag, str(s.today), str(game[s.id])])
		t.check(s.lo <= s.today + EPS and s.today <= s.hi + EPS and s.lo < s.hi, "%s: %s <= today %s <= %s" % [tag, str(s.lo), str(s.today), str(s.hi)])
		t.check(s.step > 0.0 and Settings.snap(s.id, s.today) == s.today, "%s: today %s is on the step %s" % [tag, str(s.today), str(s.step)])
		t.check(Settings.snap(s.id, s.lo) == s.lo and Settings.snap(s.id, s.hi) == s.hi, "%s: least and most on the step" % tag)
		t.check(not s.whole or (roundf(s.today) == s.today and roundf(s.step) == s.step), "%s: a whole number with a whole step" % tag)
		t.check(Settings.check(s.id, s.today) == &"", "%s: today's value passes the check (%s)" % [tag, Settings.check(s.id, s.today)])
		t.check(Settings.row(s.id) == s and Settings.today(s.id) == s.today, "%s: row() and today() find it" % tag)
		# The panel's order: group by group, never back to an earlier group.
		var gi := group_order.find(s.group)
		t.check(gi >= last_group, "%s: out of the panel's group order" % tag)
		last_group = maxi(last_group, gi)
		by_group[s.group] = int(by_group.get(s.group, 0)) + 1
	for id: StringName in game:
		t.check(ids.has(id), "%s: in the test's table but not in the registry" % id)
	var wired: Array[StringName] = []
	for s in Settings.list(true):
		wired.append(s.id)
	var want: Array[StringName] = []
	for s in rows:
		if TEN.has(s.id) or MORE.has(s.id) or KEEPER_SIX.has(s.id):
			want.append(s.id)
	t.check(wired == want and want.size() == TEN.size() + MORE.size() + KEEPER_SIX.size(), "the wired rows are exactly those of LS1 and the groups wired since, in order: %s" % str(wired))
	t.eq(by_group.get(&"residents", 0), 61, "residents")
	t.eq(by_group.get(&"lift", 0), 12, "the lift and the dark")
	t.eq(by_group.get(&"players", 0), 30, "players")
	t.eq(by_group.get(&"earning", 0), 10, "earning")
	t.eq(by_group.get(&"hiding", 0), 3, "hiding")
	t.eq(by_group.get(&"deeper", 0), 10, "floor 8 and deeper")
	t.eq(by_group.get(&"speeds", 0), 4, "player speeds, the last group")
	t.eq(group_order[group_order.size() - 1], &"speeds", "player speeds come last")
	t.eq(Settings.LIFT_DELAY_MIN, Run.CALL_START_DELAY_MIN, "the pair rule's start delay is the run's")
	t.check(Settings.pair_broken({}).is_empty(), "today's values keep every pair rule: %s" % Settings.pair_broken({}))
	t.eq(Settings.text(&"orderly.speed", 3.6), "3.60 M/S", "the panel's words")
	t.eq(Settings.text(&"lift.floors_min", 6.0), "6 FLOORS", "the panel's words")
	t.note("%d rows: %s; wired: %d" % [rows.size(), str(by_group), wired.size()])

# ---------------------------------------------------------------------------------------------
# 2. The checker.

func test_check_refuses_and_accepts(t: T) -> void:
	var refused := [
		["under least", &"orderly.speed", 2.35, {}, &"range"],
		["over most", &"orderly.speed", 4.85, {}, &"range"],
		["NaN", &"down.time", NAN, {}, &"range"],
		["infinity", &"down.time", INF, {}, &"range"],
		["minus infinity", &"down.time", -INF, {}, &"range"],
		["a string", &"down.time", "12", {}, &"range"],
		["a bool", &"down.time", true, {}, &"range"],
		["null", &"down.time", null, {}, &"range"],
		["an unknown id", &"orderly.sped", 3.6, {}, &"id"],
		["fewest floors above most", &"lift.floors_min", 13, {}, &"pair"],
		["fewest floors equal to most", &"lift.floors_max", 6, {}, &"pair"],
		["fewest above most already asked", &"lift.floors_max", 9, {&"lift.floors_min": 10.0}, &"pair"],
		["a shortest wait under 15 s", &"lift.floor_time", 2.0, {}, &"pair"],
		["a shortest wait under 15 s (fewer floors)", &"lift.floors_min", 3, {}, &"pair"],
		["a blackout's shortest over its longest", &"dark.min", 25.0, {}, &"pair"],
		["the first floor's shortest over its longest", &"dark.first_max", 13.0, {}, &"pair"],
		["arrives no nearer within 2 m of no further", &"reloc.near_min", 19.0, {}, &"pair"],
		["the instrument's cap at creep", &"player.raised", 1.2, {}, &"pair"],
		["sprint at walk", &"player.sprint", 3.5, {&"player.walk": 3.5}, &"pair"],
	]
	for r: Array in refused:
		var got := Settings.check(StringName(r[1]), r[2], r[3] as Dictionary)
		t.check(got == r[4], "%s: %s = %s gives %s, want %s" % [r[0], r[1], str(r[2]), got, r[4]])
	var accepted := [
		["today's", &"orderly.speed", 3.8, {}],
		["slower", &"orderly.speed", 3.6, {}],
		["least", &"orderly.speed", 2.4, {}],
		["most", &"orderly.speed", 4.8, {}],
		["a whole number as an int", &"down.time", 14, {}],
		["off the step, snapped", &"orderly.speed", 3.61, {}],
		["the shortest wait exactly 15 s", &"lift.floor_time", 7.0, {&"lift.floors_min": 2.0}],
		["fewest one under most", &"lift.floors_min", 11, {}],
	]
	for r: Array in accepted:
		var got := Settings.check(StringName(r[1]), r[2], r[3] as Dictionary)
		t.check(got == &"", "%s: %s = %s is refused (%s)" % [r[0], r[1], str(r[2]), got])
	t.eq(Settings.snap(&"orderly.speed", 3.61), 3.6, "snapped to the step")
	t.eq(Settings.snap(&"minder.run_speed", 6.9), 7.0, "snapped to a quarter")
	t.check(not Settings.has(&"resident.grace") and not Settings.has(&"watchers"), "nothing from the fairness contract")

# ---------------------------------------------------------------------------------------------
# 3. Untuned is untouched.

## A floor of `depth` of the game's deck (1, 2 Clinic; 3 Annex; 4 Playroom) with the game's switches on (as the
## server's room: downs, two watchers, relocation, the long dark, paced, the car waits), the car away, the crew
## of `n` on the landing, the resident hunting 6 to 14 cells' walk away (as tests/waits.gd wait_start).
static func game_floor(seed: String, depth: int, n: int) -> Run.RunState:
	var ids: Array[String] = []
	for k in n:
		ids.append("p%d" % k)
	# The game's switches, the Minder's hunt (PT1, the last parameter) with the tuned Playroom as the rooms have it.
	var rules := HostRules.new(true, depth, Places.FULL, false, false, true, true, true, true, true, true, true, true,
		false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, true)
	var st := rules.prepare(Run.create_run(seed, ids, Places.FULL))
	var plan := st.plan
	var dist := Floor.distances_from(plan, plan.landing)
	var cands: Array = []
	for i in dist.size():
		var d := dist[i]
		if d < 6 or d > 14:
			continue
		var p := Floor.pos_from_index(plan, i)
		if Floor.is_walkable(plan, p.level, p.x, p.y):
			cands.append(p)
	var at: Floor.Pos = Rng.make_rng(seed).fork("orderly").pick(cands)
	var o := Places.create_resident(plan)
	o.body = Move.body_at_cell(plan, at)
	o.mode = &"hunting"
	var s := st.copy()
	s.orderly = o
	s.phase = &"away"
	s.timer = 0.0
	var players: Array[Run.RunPlayer] = []
	for p in st.players:
		var np := p.copy()
		np.aboard = false
		players.append(np)
	s.players = players
	return s

## Everything a tick decides, as plain values (compared with ==: every float exactly).
static func fingerprint(s: Run.RunState, events: Array[Dictionary]) -> Array:
	var down: Array = []
	for id: String in s.down:
		var d: Run.Downed = s.down[id]
		down.append([id, d.at, d.until, d.healer, d.heal_from])
	var seek: Variant = null
	if s.seek != null:
		var m := (s.seek as Seek.SeekState).minder
		seek = [m.body.x, m.body.z, m.body.level, m.yaw, String(m.mode), m.speed, (s.seek as Seek.SeekState).counting]
	return [Snap.run(s), Snap.events(events), down, seek, s.spots.size(), s.left_out.size()]

class Lane:
	var st: Run.RunState
	var bots: Array[Bot.WaitBot] = []
	var caught := {}

	func _init(s: Run.RunState, style: StringName) -> void:
		st = s
		for k in st.players.size():
			var b := Bot.create_wait_bot(st, st.players[k].id, k, style)
			b.stamina = Stamina.fresh_stamina(Run.sprint_seconds(st))
			bots.append(b)
		var s2 := st.copy()
		s2.players = []
		for k in st.players.size():
			var np := st.players[k].copy()
			np.body = bots[k].body
			s2.players.append(np)
		st = s2

	## One tick as tests/waits.gd plays a wait: the first bot calls on tick 0.
	func tick(k: int) -> Array[Dictionary]:
		var live: Array[Bot.WaitBot] = []
		for b in bots:
			var p: Run.RunPlayer = null
			for q in st.players:
				if q.id == b.id:
					p = q
			if not caught.has(b.id) and (p == null or p.status == &"ok"):
				live.append(b)
		if k > 0:
			for b in live:
				Bot.step_wait_bot(st, b, DT)
		var waiting := false
		for b in live:
			if not Run.in_car(st.car, b.body):
				waiting = true
		var inputs: Array[Run.PlayerInput] = []
		for j in live.size():
			var b := live[j]
			inputs.append(Bot.wait_bot_input(b, b.mode == &"aboard" and waiting, k == 0 and j == 0))
		var r := Run.step_run(st, inputs, DT)
		st = r.state
		for e in r.events:
			if e["type"] == "caught":
				caught[e["playerId"]] = true
		return r.events

func test_untuned_empty_and_all_at_today_match_tick_for_tick(t: T) -> void:
	var floors := 4 if t.quick else (200 if t.full else 24)
	var secs := 70.0
	var ticks := 0
	var differ := 0
	var calls := 0
	var blackouts := 0
	var downs := 0
	var counts := 0
	var places := {}
	for i in floors:
		var depth := 1 + i % 4
		var n := 1 + (i / 4) % 4
		var seed := "ls1-same-%d" % i
		var base := game_floor(seed, depth, n)
		t.check(base.minder_hunt and base.playroom_tuned, "%s: the game's switches include the Minder's hunt" % seed)
		places[base.plan.place] = int(places.get(base.plan.place, 0)) + 1
		var style: StringName = &"stay" if i % 2 == 0 else &"flee"
		var lanes: Array[Lane] = [Lane.new(base, style), Lane.new(Run.with_tuning(base, {}), style), Lane.new(Run.with_tuning(base, ten_at_today()), style)]
		t.check(lanes[0].st.tuning == null and lanes[1].st.tuning != null and lanes[1].st.tuning.size() == 0 and lanes[2].st.tuning.size() == TEN.size() + MORE.size(), "%s: the three tunings" % seed)
		for k in roundi(secs / DT):
			var prints: Array = []
			var evs0: Array[Dictionary] = []
			for li in lanes.size():
				var evs := lanes[li].tick(k)
				if li == 0:
					evs0 = evs
				prints.append(fingerprint(lanes[li].st, evs))
			ticks += 1
			for e in evs0:
				match String(e["type"]):
					"called":
						calls += 1
					"blinkStart":
						if e["blackout"]:
							blackouts += 1
					"downed":
						downs += 1
					"count":
						counts += 1
			if prints[1] != prints[0] or prints[2] != prints[0]:
				differ += 1
				t.check(false, "%s (depth %d, %d players, %s) tick %d: %s differs from the untuned run" % [seed, depth, n, style, k, "the empty tuning" if prints[1] != prints[0] else "all ten at today's"])
				break
			if lanes[0].st.phase == &"ended":
				break
	t.eq(differ, 0, "floors that differ")
	t.check(places.size() == 3 or t.quick, "every place played: %s" % str(places))
	t.check(calls > 0 and blackouts > 0 and downs > 0, "not vacuous: calls %d, blackouts %d, downs %d" % [calls, blackouts, downs])
	t.note("%d floors (%s), %d ticks x 3 runs, every tick the same: %d calls, %d blackouts, %d downs, %d count events" % [floors, str(places), ticks, calls, blackouts, downs, counts])

# ---------------------------------------------------------------------------------------------
# 4. The proofs. Each value at least, today's and most.

## A floor of `depth` (1 the Orderly's Clinic, 3 the Temp's Annex) with the game's switches but relocation (it
## would carry the resident off mid-measure), p0 on the landing facing the car, the car away and the resident
## parked; the tuning `given`.
static func chase_floor(seed: String, depth: int, given: Dictionary) -> Run.RunState:
	var rules := HostRules.new(true, depth, Places.FULL, false, false, true, false, false, true, true, true)
	var st := rules.prepare(Run.create_run(seed, ["p0"] as Array[String], Places.FULL))
	var s := Run.with_tuning(st, given)
	s.orderly = HostRules.parked_orderly(s)
	s.phase = &"away"
	s.timer = 0.0
	var np := s.players[0].copy()
	np.aboard = false
	np.body = Run.car_body(s.car, -1.0, 0.0)
	s.players = [np] as Array[Run.RunPlayer]
	return s

static func landing_input(s: Run.RunState, call: bool = false) -> Run.PlayerInput:
	var i := Run.PlayerInput.make("p0", Run.car_body(s.car, -1.0, 0.0), 1.65, Entity.yaw_toward(s.car.in_x, s.car.in_z), 0.0, 90.0, 70.0)
	i.call = call
	return i

## The resident hunting from the walkable cell of the landing's level furthest from it.
static func hunting_far(s0: Run.RunState) -> Run.RunState:
	var plan := s0.plan
	var dist := Floor.distances_from(plan, plan.landing)
	var best := -1
	for i in dist.size():
		if dist[i] > (dist[best] if best >= 0 else -1) and Floor.pos_from_index(plan, i).level == plan.landing.level:
			best = i
	var s := s0.copy()
	var o := Places.create_resident(plan)
	o.body = Move.body_at_cell(plan, Floor.pos_from_index(plan, best))
	o.mode = &"hunting"
	o.replan_in = 0.0
	s.orderly = o
	return s

class Pace:
	var metres := 0.0
	var top := 0.0
	var dark_ticks := 0
	var ticks := 0
	var body: StringName

## Metres the resident covers in 5 s unwatched (p0 on the landing facing the car), lit or (dark) in the blackout.
static func pace(seed: String, depth: int, given: Dictionary, dark: bool) -> Pace:
	var s := chase_floor(seed, depth, given)
	if dark:
		s = Run.step_run(s, [landing_input(s, true)] as Array[Run.PlayerInput], DT).state
		for _k in roundi(80.0 / DT):
			if Run.blacked_out(s):
				break
			s = Run.step_run(s, [landing_input(s)] as Array[Run.PlayerInput], DT).state
	s = hunting_far(s)
	var out := Pace.new()
	out.body = Entity.kind_of(s.orderly).name
	for _k in roundi(5.0 / DT):
		var before := s.orderly.body
		var lit_before := not Run.blacked_out(s)
		s = Run.step_run(s, [landing_input(s)] as Array[Run.PlayerInput], DT).state
		if s.orderly.mode != &"hunting":
			break
		out.metres += M.hypot2(s.orderly.body.x - before.x, s.orderly.body.z - before.z)
		out.top = maxf(out.top, s.orderly.speed)
		out.ticks += 1
		if not lit_before:
			out.dark_ticks += 1
	return out

func _speed_proof(t: T, dark: bool) -> void:
	var seeds := 1 if t.quick else 3
	var lines: Array[String] = []
	# The Orderly only: the Temp is Lonely in the game (test_temp_chase_speeds_under_lonely).
	for who: Array in [[&"orderly", 1]]:
		var id := StringName("%s.%s" % [who[0], "dark_speed" if dark else "speed"])
		# The other resident's id at the other end of its range: a read of the wrong id shows.
		var other := StringName("%s.%s" % ["temp" if who[0] == &"orderly" else "orderly", "dark_speed" if dark else "speed"])
		var row := Settings.row(id)
		for i in seeds:
			var seed := "ls1-pace-%d" % i
			var last := -1.0
			var untuned := pace(seed, who[1], {}, dark)
			for v: float in [row.lo, row.today, row.hi]:
				var given := {id: v, other: row.hi if v < row.hi else row.lo}
				var p := pace(seed, who[1], given, dark)
				var tag := "%s %s = %.2f (%s)" % [seed, id, v, "dark" if dark else "lit"]
				t.eq(p.body, who[0], "%s: the resident's body" % tag)
				t.check(p.ticks == roundi(5.0 / DT), "%s: hunted for the whole 5 s (%d ticks)" % [tag, p.ticks])
				t.check(not dark or p.dark_ticks == p.ticks, "%s: in the blackout all 5 s (%d of %d ticks)" % [tag, p.dark_ticks, p.ticks])
				t.check(absf(p.top - v) < 0.02, "%s: top speed %.3f m/s" % [tag, p.top])
				t.check(p.metres <= v * 5.0 + 0.05 and p.metres >= v * 5.0 * 0.85, "%s: %.2f m in 5 s, want about %.2f" % [tag, p.metres, v * 5.0])
				t.check(p.metres > last, "%s: %.2f m is not more than at the slower speed (%.2f m)" % [tag, p.metres, last])
				last = p.metres
				if v == row.today:
					t.check(absf(p.metres - untuned.metres) < 1e-9 and p.top == untuned.top, "%s: today's value is the untuned run (%.4f m against %.4f m)" % [tag, p.metres, untuned.metres])
				if i == 0:
					lines.append("%s %.2f: %.2f m" % [id, v, p.metres])
	t.note("5 s unwatched %s: %s" % ["in the blackout" if dark else "lit", ", ".join(lines)])

func test_orderly_and_temp_speeds_lit(t: T) -> void:
	_speed_proof(t, false)

func test_orderly_and_temp_speeds_in_the_blackout(t: T) -> void:
	_speed_proof(t, true)

## The Minder's top pace while it searches and while it runs someone down, in one count on the Playroom: p0
## sprints once to start it; 3 s into the search p1 stands in its view (as tests/prop_seek.gd standing_in_view).
static func minder_pace(seed: String, given: Dictionary, t: T) -> Vector2:
	var r := CountRun.Rig.new(seed)
	r.st = Run.with_tuning(r.st, given)
	CountRun.to_away(t, r)
	r.gait["p0"] = &"sprint"
	r.step()
	r.gait["p0"] = &"creep"
	var search := 0.0
	var run := 0.0
	var seek_for := 0.0
	var placed := false
	var cells := CountRun.safe_cells(r.plan(), 0.0, seed + ":view")
	for _k in roundi(60.0 / DT):
		var ss: Seek.SeekState = r.st.seek
		if ss == null or not ss.counting:
			break
		if Seek.phase_of(ss) == &"seek":
			seek_for += DT
		var m := ss.minder
		if not placed and seek_for >= 3.0:
			for c in cells:
				var cb := Move.body_at_cell(r.plan(), c)
				var d := PropSeek.horiz(cb, m.body)
				if d >= 5.0 and d <= 10.0 and PropSeek.o_sight(r.plan(), m.body, m.yaw, cb) == 1:
					r.bodies["p1"] = cb
					placed = true
					break
		var mode_before := m.mode
		r.step()
		if r.st.seek == null:
			break
		var m2 := (r.st.seek as Seek.SeekState).minder
		if mode_before == m2.mode and m2.mode == &"search":
			search = maxf(search, m2.speed)
		if mode_before == m2.mode and m2.mode == &"run":
			run = maxf(run, m2.speed)
	return Vector2(search, run)

func test_minder_search_and_run_pace(t: T) -> void:
	var seeds := 2 if t.quick else 4
	var lines: Array[String] = []
	for id: StringName in [&"minder.search_speed", &"minder.run_speed"]:
		var row := Settings.row(id)
		var axis := 0 if id == &"minder.search_speed" else 1
		for v: float in [row.lo, row.today, row.hi]:
			var seen := 0
			for i in seeds:
				var seed := "ls1-minder-%d" % i
				# The other speed at the other end of its range.
				var other := &"minder.run_speed" if axis == 0 else &"minder.search_speed"
				var orow := Settings.row(other)
				var got := minder_pace(seed, {id: v, other: orow.hi if v < row.hi else orow.lo}, t)
				var top := got[axis]
				if top <= 0.0:
					continue
				seen += 1
				t.check(absf(top - v) < 0.02, "%s %s = %.2f: its top pace %.3f m/s" % [seed, id, v, top])
			t.check(seen > 0, "%s = %.2f: never seen at that pace in %d counts (vacuous)" % [id, v, seeds])
			lines.append("%s %.2f in %d of %d counts" % [id, v, seen, seeds])
	t.note("the Minder's top pace matched: %s" % ", ".join(lines))

## The bound sets of the lift proof: [fewest, most, seconds a floor], each keeping the pair rules.
const LIFT_SETS: Array = [[6, 12, 4.0], [2, 3, 7.0], [14, 20, 1.0], [19, 20, 8.0], [9, 10, 2.5]]

func test_lift_wait_over_500_plans_and_in_a_run(t: T) -> void:
	var n := 100 if t.quick else 500
	var lines: Array[String] = []
	for b: Array in LIFT_SETS:
		var lo: int = b[0]
		var hi: int = b[1]
		var sec: float = b[2]
		var given := {&"lift.floors_min": lo, &"lift.floors_max": hi, &"lift.floor_time": sec}
		var tag := "%d-%d floors x %.1f s" % [lo, hi, sec]
		t.check(Settings.pair_broken(given).is_empty(), "%s: keeps the pair rules" % tag)
		for id: StringName in given:
			t.eq(Settings.check(id, given[id], given), &"", "%s: %s passes the check" % [tag, id])
		var tuning := Settings.make(given)
		var seen := {}
		var short := INF
		var long := 0.0
		var bad := 0
		for i in n:
			var seed := "ls1-lift-%d" % i
			var prev := -1 if i % 5 == 0 else lo + (i * 7) % (hi - lo + 1)
			var depth := 1 + i % 3
			var p := Run.call_plan(seed, i % 3, prev, depth, true, tuning)
			var ok := p.floors >= lo and p.floors <= hi and p.floors != prev and p.floor_time == sec \
				and p.wait == p.delay + p.floors * sec + p.extra \
				and p.wait >= Run.CALL_START_DELAY_MIN + lo * sec - EPS \
				and p.wait <= Run.CALL_START_DELAY_MAX + hi * sec + Run.FALSE_STOP_EXTRA_MAX + EPS
			if not ok:
				bad += 1
				if bad <= 3:
					t.check(false, "%s %s: %d floors (prev %d) x %.2f s, wait %.3f" % [tag, seed, p.floors, prev, p.floor_time, p.wait])
			seen[p.floors] = true
			short = minf(short, p.wait - p.extra)
			long = maxf(long, p.wait)
			# The same draws: the plan's other numbers are the untuned plan's.
			var u := Run.call_plan(seed, i % 3, -1, depth, true)
			var tp := Run.call_plan(seed, i % 3, -1, depth, true, tuning)
			if u.delay != tp.delay or u.false_stop != tp.false_stop or u.extra != tp.extra:
				bad += 1
				t.check(false, "%s %s: a draw moved" % [tag, seed])
		t.eq(bad, 0, "%s: plans out of bounds" % tag)
		t.check(seen.has(lo) and seen.has(hi), "%s: both bounds drawn over %d plans: %s" % [tag, n, str(seen.keys())])
		lines.append("%s: %d floor counts, waits %.1f to %.1f s" % [tag, seen.size(), short, long])
		# In a run: the car arrives when its plan said, though the host changes all three during the wait.
		var s := chase_floor("ls1-lift-run-%d" % lo, 1, given)
		var r := Run.step_run(s, [landing_input(s, true)] as Array[Run.PlayerInput], DT)
		s = r.state
		var called_at := -1.0
		var indicators := 0
		for e in r.events:
			if e["type"] == "called":
				called_at = float(e["t"])
			if e["type"] == "indicator":
				indicators += 1
		t.check(s.call != null and called_at >= 0.0, "%s: the car was called" % tag)
		if s.call == null:
			continue
		var plan := s.call.plan
		t.check(plan.floors >= lo and plan.floors <= hi and plan.floor_time == sec, "%s: the run's plan %d floors x %.1f s" % [tag, plan.floors, plan.floor_time])
		var arrived := -1.0
		var changed := false
		for _k in roundi((plan.wait + 5.0) / DT):
			if not changed and s.t >= called_at + plan.delay + sec:
				# Mid-wait: every lift number changed. The call keeps the plan it was given.
				s = Run.with_tuning(s, {&"lift.floors_min": 2, &"lift.floors_max": 3, &"lift.floor_time": 8.0} if lo != 2 else {&"lift.floors_min": 19, &"lift.floors_max": 20, &"lift.floor_time": 1.0})
				changed = true
			r = Run.step_run(s, [landing_input(s)] as Array[Run.PlayerInput], DT)
			s = r.state
			for e in r.events:
				if e["type"] == "indicator":
					indicators += 1
				if e["type"] == "carArrived" and arrived < 0.0:
					arrived = float(e["t"])
			if arrived >= 0.0:
				break
		t.check(changed and arrived >= 0.0 and absf(arrived - called_at - plan.wait) <= DT + 1e-6,
			"%s: the car arrived %.3f s after the call, its plan said %.3f s" % [tag, arrived - called_at, plan.wait])
		t.eq(indicators, plan.floors + 1, "%s: the indicator showed every floor" % tag)
	t.note("%d plans a set: %s" % [n, "; ".join(lines)])

## p0, alone, caught by the resident 1.2 m behind them (as tests/prop_downs.gd); the tuning `given`.
## Returns [the downed event's t and until, the out event's t] (-1 for none). `retune`: set this tuning
## 1 s after the down.
static func down_and_out(seed: String, given: Dictionary, retune: Variant = null) -> PackedFloat64Array:
	var rng := Rng.make_rng(seed)
	var s := Run.with_paced(Run.create_run(seed, ["p0"] as Array[String], [], false, false, true))
	s = Run.with_tuning(s, given)
	var plan := s.plan
	var dist := Floor.distances_from(plan, plan.landing)
	var cells: Array[Floor.Pos] = []
	for i in dist.size():
		var p := Floor.pos_from_index(plan, i)
		if dist[i] >= 3 and p.level == plan.landing.level:
			cells.append(p)
	var vb := Move.body_at_cell(plan, cells[rng.int_in(0, cells.size() - 1)])
	var ob := Move.body_at_cell(plan, plan.landing)
	for j in 8:
		var a := (rng.int_in(0, 7) + j) * PI / 4.0
		var b := Move.move_with_collision(plan, vb, cos(a) * 1.2, sin(a) * 1.2, Entity.ORDERLY_RADIUS)
		if M.hypot2(b.x - vb.x, b.z - vb.z) >= 1.15:
			ob = b
			break
	s = s.copy()
	s.phase = &"away"
	s.call = null
	s.blink = null
	s.lure = false
	var o := s.orderly.copy()
	o.body = ob
	o.yaw = Entity.yaw_toward(vb.x - ob.x, vb.z - ob.z)
	o.mode = &"hunting"
	o.replan_in = 0.0
	o.ever_seen = true
	s.orderly = o
	var np := s.players[0].copy()
	np.body = vb
	np.aboard = false
	s.players = [np] as Array[Run.RunPlayer]
	var yaw := Entity.yaw_toward(vb.x - ob.x, vb.z - ob.z)
	var out := PackedFloat64Array([-1.0, -1.0, -1.0])
	for _k in roundi(75.0 / DT):
		var ins: Array[Run.PlayerInput] = [Run.PlayerInput.make("p0", vb, 1.65, yaw, 0.0, 90.0, 70.0)]
		var r := Run.step_run(s, ins, DT)
		s = r.state
		for e in r.events:
			if e["type"] == "downed" and e["playerId"] == "p0" and out[0] < 0.0:
				out[0] = float(e["t"])
				out[1] = float(e["until"])
			if e["type"] == "out" and e["playerId"] == "p0":
				out[2] = s.t
				return out
		if retune != null and out[0] >= 0.0 and s.t >= out[0] + 1.0:
			s = Run.with_tuning(s, retune)
			retune = null
	return out

func test_down_time(t: T) -> void:
	var seeds := 2 if t.quick else 6
	var lines: Array[String] = []
	for d: float in [5.0, 10.0, 60.0]:
		var caught := 0
		for i in seeds:
			var seed := "ls1-down-%d" % i
			var got := down_and_out(seed, {&"down.time": d})
			if got[0] < 0.0:
				continue
			caught += 1
			t.check(absf(got[1] - got[0] - d) < 1e-6, "%s down.time %.0f: downed at %.3f, until %.3f" % [seed, d, got[0], got[1]])
			t.check(got[2] >= got[1] - 1e-6 and got[2] < got[1] + DT + 1e-6, "%s down.time %.0f: out at %.3f, until %.3f" % [seed, d, got[2], got[1]])
		t.check(caught > 0, "down.time %.0f: no seed caught p0 (vacuous)" % d)
		lines.append("%.0f s (%d downs)" % [d, caught])
	# Already down when it changes: out when their "downed" said (10 s), not at the new 60 or 5.
	for retune: float in [60.0, 5.0]:
		var got := down_and_out("ls1-down-0", {}, {&"down.time": retune})
		t.check(got[0] >= 0.0 and absf(got[1] - got[0] - Run.DOWN_TIME) < 1e-6 and got[2] >= got[1] - 1e-6 and got[2] < got[1] + DT + 1e-6,
			"changed to %.0f s while down: downed %.3f, until %.3f, out %.3f" % [retune, got[0], got[1], got[2]])
	t.note("out came down.time after downed at %s; already down keeps its time" % ", ".join(lines))

## The Lonely Temp's chase (sim/lonely.gd, on in the game's rooms) over the first second after it starts: a setup of
## tests/prop_lonely.gd (the Temp 8 to 15 m from b0 with a clear line, facing them), b0 standing; with a crew (b1
## 40 m off, so b0 is lonely) unless `solo`, lit unless `dark` (the blackout on: Run.blacked_out). Returns
## [metres, top speed, chase ticks, dark ticks].
static func lonely_chase(row: Array, given: Dictionary, solo: bool, dark: bool) -> PackedFloat64Array:
	var ids: Array[String] = ["b0"]
	if not solo:
		ids.append("b1")
	var s := PropLonely.floor_run(str(row[0]), ids, false, false)
	var plan := s.plan
	if dark:
		# The crew calls the car from the landing and waits there until the blackout is on (the Temp parked).
		s.orderly = HostRules.parked_orderly(s)
		var at_car := {}
		for id in ids:
			at_car[id] = Run.car_body(s.car, -1.0, 0.0 if id == "b0" else 0.5)
		s = PropLonely.stand(s, at_car)
		var first := true
		for _k in roundi(90.0 / DT):
			if Run.blacked_out(s):
				break
			var ins := PropLonely.inputs(s, at_car, false)
			ins[0].call = first
			first = false
			s = Run.step_run(s, ins, DT).state
	var tb := PropLonely.cell_body(plan, row[1])
	var pb := PropLonely.cell_body(plan, row[2])
	var bodies := {"b0": pb}
	if not solo:
		bodies["b1"] = PropLonely.cell_body(plan, row[3])
	s = PropLonely.temp_at(PropLonely.stand(s, bodies), tb, Entity.yaw_toward(pb.x - tb.x, pb.z - tb.z))
	s = Run.with_tuning(s, given) if not given.is_empty() else s
	var out := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	for _k in roundi(1.0 / DT):
		var before := s.orderly.body
		var r := Run.step_run(s, PropLonely.inputs(s, bodies, false), DT)
		s = r.state
		if s.orderly.lonely_phase != &"chase" or s.orderly.mode != &"hunting":
			break
		out[0] += M.hypot2(s.orderly.body.x - before.x, s.orderly.body.z - before.z)
		out[1] = maxf(out[1], s.orderly.speed)
		out[2] += 1.0
		if Run.blacked_out(s):
			out[3] += 1.0
	return out

func test_temp_chase_speeds_under_lonely(t: T) -> void:
	var n := 3 if t.quick else 8
	var setups: Array = PropLonely.new()._line_setups(n, 9.0, 15.0)
	t.check(setups.size() >= 2, "setups found: %d" % setups.size())
	var lines: Array[String] = []
	# [id, solo, dark]
	for c: Array in [[&"temp.speed", false, false], [&"temp.dark_speed", false, true], [&"temp.alone_speed", true, false]]:
		var id: StringName = c[0]
		var row := Settings.row(id)
		# The other two at the far end of their ranges: a read of the wrong id shows.
		var others: Array[StringName] = []
		for o: StringName in [&"temp.speed", &"temp.dark_speed", &"temp.alone_speed"]:
			if o != id:
				others.append(o)
		for setup: Array in setups:
			var untuned := lonely_chase(setup, {}, c[1], c[2])
			var tag0 := "%s %s" % [setup[0], id]
			t.check(untuned[2] == roundi(1.0 / DT) and (not c[2] or untuned[3] == untuned[2]), "%s: untuned, chased for the whole second (%d ticks, %d dark)" % [tag0, untuned[2], untuned[3]])
			var want_today := Lonely.SOLO_CHASE_SPEED if c[1] else Lonely.CHASE_SPEED
			t.check(absf(untuned[1] - want_today) < 1e-6, "%s: untuned chase %.4f m/s, Lonely's own %.2f" % [tag0, untuned[1], want_today])
			var last := -1.0
			for v: float in [row.lo, row.today, row.hi]:
				var given := {id: v}
				for o in others:
					var orow := Settings.row(o)
					given[o] = orow.hi if v < row.hi else orow.lo
				var got := lonely_chase(setup, given, c[1], c[2])
				var tag := "%s = %.2f" % [tag0, v]
				t.check(got[2] == roundi(1.0 / DT), "%s: chased for the whole second (%d ticks)" % [tag, got[2]])
				t.check(absf(got[1] - v) < 0.02, "%s: top speed %.3f m/s" % [tag, got[1]])
				t.check(got[0] <= v * 1.0 + 0.05 and got[0] >= v * 0.85, "%s: %.2f m in 1 s" % [tag, got[0]])
				t.check(got[0] > last, "%s: %.2f m is not more than at the slower speed (%.2f m)" % [tag, got[0], last])
				last = got[0]
				if v == row.today:
					t.check(got[0] == untuned[0] and got[1] == untuned[1], "%s: today's value is the untuned run (%.4f m against %.4f m)" % [tag, got[0], untuned[0]])
				if setup == setups[0]:
					lines.append("%s %.2f: %.2f m" % [id, v, got[0]])
	t.note("the Lonely Temp's first second of a chase (%d setups): %s" % [setups.size(), ", ".join(lines)])

# ---------------------------------------------------------------------------------------------
# 4b. LS4: the lift and the dark.

## The blackout bounds of the proof: [dark.min, dark.max, dark.first_min, dark.first_max, dark.warning], each pair-safe.
const DARK_SETS: Array = [[20.0, 24.0, 14.0, 16.0, 3.0], [5.0, 5.0, 5.0, 5.0, 1.0], [40.0, 40.0, 40.0, 40.0, 6.0], [8.0, 30.0, 10.0, 12.0, 2.0]]

func test_blackout_lengths_and_warning(t: T) -> void:
	var n := 60 if t.quick else 200
	var lines: Array[String] = []
	for d: Array in DARK_SETS:
		for lift: Array in LIFT_SETS:
			var given := {&"dark.min": d[0], &"dark.max": d[1], &"dark.first_min": d[2], &"dark.first_max": d[3], &"dark.warning": d[4],
				&"lift.floors_min": lift[0], &"lift.floors_max": lift[1], &"lift.floor_time": lift[2]}
			var tag := "dark %s, lift %s" % [str(d), str(lift)]
			t.check(Settings.pair_broken(given).is_empty(), "%s: keeps the pair rules" % tag)
			var tuning := Settings.make(given)
			var bad := 0
			var at_bound := 0
			var capped := 0
			for i in n:
				var depth := 1 + i % 3
				var p := Run.call_plan("ls4-dark-%d" % i, i % 3, -1, depth, true, tuning)
				var b: Run.DarkStretch = p.darks[p.darks.size() - 1]
				var lo: float = d[2] if depth <= 1 else d[0]
				var hi: float = d[3] if depth <= 1 else d[1]
				var ok := b.blackout and absf(b.warn - float(d[4])) < 1e-9 and absf(b.at + b.len - p.wait) < 1e-6 and b.len <= hi + 1e-9 \
					and b.at - b.warn >= -1e-9 and p.darks.size() >= 2
				# The first blink and its warning fit before the blackout's warning (prop_blackout's rule).
				if p.darks.size() >= 2:
					var first: Run.DarkStretch = p.darks[0]
					ok = ok and first.at - first.warn >= -1e-9 and p.darks[p.darks.size() - 2].at + p.darks[p.darks.size() - 2].len <= b.at - b.warn + 1e-9
				if b.len >= lo - 1e-9:
					at_bound += 1
				else:
					capped += 1
				if not ok:
					bad += 1
					if bad <= 3:
						t.check(false, "%s %d (depth %d): wait %.2f, blackout at %.2f for %.2f (warn %.2f), %d darks" % [tag, i, depth, p.wait, b.at, b.len, b.warn, p.darks.size()])
			t.eq(bad, 0, "%s: plans breaking the blackout's rules" % tag)
			t.check(at_bound > 0 or float(d[0]) >= 30.0, "%s: some blackout within its bounds (%d, %d capped by a short wait)" % [tag, at_bound, capped])
			if lift == LIFT_SETS[0]:
				lines.append("%s: %d in bounds, %d capped" % [str(d), at_bound, capped])
	# All at today's is the untuned plan, every dark stretch exactly.
	var today := Settings.make({&"dark.min": 20.0, &"dark.max": 24.0, &"dark.first_min": 14.0, &"dark.first_max": 16.0, &"dark.warning": 3.0, &"lift.false_stop": 25.0})
	var same := 0
	for i in n:
		var u := Run.call_plan("ls4-same-%d" % i, i % 3, -1, 1 + i % 3, true)
		var v := Run.call_plan("ls4-same-%d" % i, i % 3, -1, 1 + i % 3, true, today)
		var eq := u.wait == v.wait and u.false_stop == v.false_stop and u.darks.size() == v.darks.size()
		for k in mini(u.darks.size(), v.darks.size()):
			eq = eq and u.darks[k].at == v.darks[k].at and u.darks[k].len == v.darks[k].len and u.darks[k].warn == v.darks[k].warn
		if eq:
			same += 1
	t.eq(same, n, "plans at today's values equal the untuned ones")
	# The blackout follows its bounds: min = max = v gives v exactly when the wait has room.
	for v: float in [5.0, 14.0, 22.0]:
		var exact := 0
		for i in n:
			var p := Run.call_plan("ls4-exact-%d" % i, 0, -1, 2, true, Settings.make({&"dark.min": v, &"dark.max": v, &"lift.floor_time": 8.0}))
			if absf(p.darks[p.darks.size() - 1].len - v) < 1e-9:
				exact += 1
		t.eq(exact, n, "dark.min = dark.max = %.0f: every blackout %.0f s long (waits of 49 s and more)" % [v, v])
	t.note("blackout corners over %d plans each: %s" % [n, "; ".join(lines)])

func test_false_stop_chance(t: T) -> void:
	var n := 200 if t.quick else 1000
	var counts := {}
	for v: float in [0.0, 25.0, 100.0]:
		var stops := 0
		var same := 0
		for i in n:
			var p := Run.call_plan("ls4-stop-%d" % i, i % 3, -1, 1, true, Settings.make({&"lift.false_stop": v}))
			var u := Run.call_plan("ls4-stop-%d" % i, i % 3, -1, 1, true)
			if p.false_stop:
				stops += 1
			if p.delay == u.delay and p.floors == u.floors:
				same += 1
		counts[v] = stops
		t.eq(same, n, "false_stop %.0f: the other draws are the untuned plan's" % v)
	t.eq(counts[0.0], 0, "chance 0: never")
	t.eq(counts[100.0], n, "chance 100: always")
	var untuned := 0
	for i in n:
		if Run.call_plan("ls4-stop-%d" % i, i % 3, -1, 1, true).false_stop:
			untuned += 1
	t.eq(counts[25.0], untuned, "chance 25: the untuned plans' false stops exactly")
	t.note("false stops in %d plans: 0 -> %d, 25 -> %d, 100 -> %d" % [n, counts[0.0], counts[25.0], counts[100.0]])

## p0 on the landing calls the car (2 or 3 floors at 7 s), steps in when it is there, and rides down: the bell,
## the hold and the ride as the run counts them. Returns [bell_left at the doors opening, hold_left then, seconds
## from the doors opening to the bell, the ride's timer on its first tick, seconds riding]. `retune`: a tuning
## put in force the tick after the doors open.
static func board_and_ride(seed: String, given: Dictionary, retune: Variant = null) -> PackedFloat64Array:
	var g := given.duplicate()
	g.merge({&"lift.floors_min": 2, &"lift.floors_max": 3, &"lift.floor_time": 7.0})
	var s := chase_floor(seed, 1, g)
	var out := PackedFloat64Array([-1.0, -1.0, -1.0, -1.0, -1.0])
	var opened := -1.0
	var riding := -1.0
	var first := true
	var inside := Run.car_body(s.car, 1.0, 0.0)
	for _k in roundi(200.0 / DT):
		var inp := landing_input(s, first)
		first = false
		if opened >= 0.0:
			inp = Run.PlayerInput.make("p0", inside, 1.65, 0.0, 0.0, 90.0, 70.0)
		var r := Run.step_run(s, [inp] as Array[Run.PlayerInput], DT)
		s = r.state
		for e in r.events:
			if e["type"] == "carArrived" and opened < 0.0:
				opened = s.t
				out[0] = s.bell_left
				out[1] = s.hold_left
				if retune != null:
					s = Run.with_tuning(s, retune)
			if e["type"] == "bell" and out[2] < 0.0:
				out[2] = s.t - opened
		if s.phase == &"riding" and riding < 0.0:
			riding = s.t
			out[3] = s.timer
		elif riding >= 0.0 and s.phase != &"riding":
			out[4] = s.t - riding
			return out
	return out

func test_boarding_hold_and_ride(t: T) -> void:
	var lines: Array[String] = []
	for c: Array in [[&"lift.board", 0], [&"lift.hold", 1], [&"lift.ride", 3]]:
		var id: StringName = c[0]
		var row := Settings.row(id)
		var untuned := board_and_ride("ls4-board-0", {})
		for v: float in [row.lo, row.today, row.hi]:
			var got := board_and_ride("ls4-board-0", {id: v})
			var k: int = c[1]
			var tag := "%s = %.0f" % [id, v]
			match k:
				0:
					t.check(absf(got[0] - v) <= DT + 1e-6, "%s: the bell is %.2f s off when the doors open" % [tag, got[0]])
					t.check(absf(got[2] - v) <= DT + 1e-6, "%s: the bell rang %.2f s after the doors opened" % [tag, got[2]])
				1:
					t.check(absf(got[1] - v) <= DT + 1e-6, "%s: the doors can be held %.2f s" % [tag, got[1]])
				3:
					t.check(absf(got[3] - v) <= DT + 1e-6 and absf(got[4] - v) <= 2.0 * DT + 1e-6, "%s: the ride's timer %.2f, it rode %.2f s" % [tag, got[3], got[4]])
			if v == row.today:
				t.check(got == untuned, "%s: today's value is the untuned run: %s / %s" % [tag, str(got), str(untuned)])
			lines.append("%s: %s" % [tag, str(got[k] if k != 3 else got[4])])
	# A boarding already open rings its bell when it would have, whatever is changed.
	var before := board_and_ride("ls4-board-0", {&"lift.board": 30.0})
	var changed := board_and_ride("ls4-board-0", {&"lift.board": 30.0}, {&"lift.board": 10.0, &"lift.hold": 0.0, &"lift.floors_min": 2, &"lift.floors_max": 3, &"lift.floor_time": 7.0})
	t.check(before[2] > 0.0 and changed[2] == before[2], "changed while the doors are open: the bell at %.2f s, as before (%.2f)" % [changed[2], before[2]])
	t.note(", ".join(lines))

# ---------------------------------------------------------------------------------------------
# 4c. LS4: the Playroom (the Minder's stroll; with the tuned Playroom, T15m, on as in the game: the time to hide,
# the search, the anger bar).

## A Playroom rig (tests/prop_count_run.gd) with the tuned Playroom on as the game's rooms have it, the tuning
## `given`, out on the floor, everyone creeping.
static func tuned_rig(seed: String, given: Dictionary, t: T) -> CountRun.Rig:
	var r := CountRun.Rig.new(seed)
	# The game's Playroom: the tuned one (net/host_rules.gd playroom_tuned) with the Minder's hunt (PT1, the last
	# parameter), as the rooms have it.
	var rules := HostRules.new(true, 4, Places.FULL, false, false, false, false, false, false, false, false, false, true,
		false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, true)
	r.st = rules.prepare(Run.create_run(seed, CountRun.IDS, Places.FULL))
	for p in r.st.players:
		r.bodies[p.id] = p.body
	r.st = Run.with_tuning(r.st, given) if not given.is_empty() else r.st
	CountRun.to_away(t, r)
	return r

func test_minder_stroll(t: T) -> void:
	var row := Settings.row(&"minder.stroll")
	var lines: Array[String] = []
	var last := -1.0
	for v: float in [row.lo, row.today, row.hi]:
		var r := CountRun.Rig.new("ls4-stroll-0")
		r.st = Run.with_tuning(r.st, {&"minder.stroll": v})
		CountRun.to_away(t, r)
		var top := 0.0
		var metres := 0.0
		for _k in roundi(12.0 / DT):
			var before := (r.st.seek as Seek.SeekState).minder.body
			r.step()
			var ss: Seek.SeekState = r.st.seek
			if ss.counting:
				break
			top = maxf(top, ss.minder.speed)
			metres += M.hypot2(ss.minder.body.x - before.x, ss.minder.body.z - before.z)
		t.check(absf(top - v) < 0.02, "minder.stroll = %.1f: it strolled at %.3f m/s" % [v, top])
		t.check(metres > last, "minder.stroll = %.1f: %.2f m in 12 s, not more than at the slower (%.2f)" % [v, metres, last])
		last = metres
		lines.append("%.1f: %.2f m" % [v, metres])
	t.note("the Minder's stroll, 12 s outside a count: %s" % ", ".join(lines))

## Seconds of sprinting from an empty bar to the count (p0 sprints on the spot... across the floor), and the
## count's own hide and search seconds.
static func sprint_to_count(seed: String, given: Dictionary, t: T) -> PackedFloat64Array:
	var r := tuned_rig(seed, given, t)
	r.gait["p0"] = &"sprint"
	var out := PackedFloat64Array([-1.0, -1.0, -1.0])
	var from := r.st.t
	var cells := CountRun.safe_cells(r.plan(), 0.0, seed + ":run")
	var b0: Move.Body = Move.body_at_cell(r.plan(), cells[0])
	var k := 0
	for _i in roundi(30.0 / DT):
		# Keep p0 moving at a sprint's pace, to and fro on one safe cell (a sprint that goes nowhere is no noise).
		k += 1
		r.bodies["p0"] = Move.Body.make(b0.x + (0.25 if k % 2 == 1 else 0.0), b0.z, b0.level, b0.y)
		r.step()
		var ss: Seek.SeekState = r.st.seek
		if ss.counting:
			out[0] = r.st.t - from
			out[1] = ss.hide_len
			out[2] = ss.len
			return out
	return out

func test_minder_anger_and_count_lengths(t: T) -> void:
	var lines: Array[String] = []
	# The first count: its time to hide and its search, from a sprint (as the game's).
	var untuned := sprint_to_count("ls4-count-0", {}, t)
	t.check(untuned[1] == Seek.TUNED_HIDE_LENGTHS[0] and untuned[2] == Seek.TUNED_SEARCH, "untuned: hide %.0f, search %.0f" % [untuned[1], untuned[2]])
	for c: Array in [[&"minder.hide_time", 1], [&"minder.search", 2]]:
		var row := Settings.row(c[0])
		for v: float in [row.lo, row.today, row.hi]:
			var got := sprint_to_count("ls4-count-0", {c[0]: v}, t)
			t.check(got[c[1]] == v, "%s = %.0f: the count has %.0f" % [c[0], v, got[c[1]]])
			if v == row.today:
				t.check(got == untuned, "%s at today's: the untuned count (%s / %s)" % [c[0], str(got), str(untuned)])
			lines.append("%s %.0f -> %.0f" % [c[0], v, got[c[1]]])
	# The anger bar: seconds of sprinting to a full bar follow minder.anger_sprint.
	var srow := Settings.row(&"minder.anger_sprint")
	var last := -1.0
	for v: float in [srow.lo, srow.today, srow.hi]:
		var got := sprint_to_count("ls4-count-0", {&"minder.anger_sprint": v}, t)
		t.check(got[0] > last and absf(got[0] - v) <= 2.0 * DT + 1e-6, "minder.anger_sprint = %.1f: a sprint started the count after %.2f s" % [v, got[0]])
		last = got[0]
		if v == srow.today:
			t.check(got == untuned, "minder.anger_sprint at today's: the untuned count")
		lines.append("anger %.1f s -> %.2f s" % [v, got[0]])
	# The rest of the counts, the noise's lump and the cooling: the rules' own numbers, as the step reads them.
	for counts: int in [1, 2, 3, 4, 6]:
		for given: Dictionary in [{}, {&"minder.hide_time": 10.0, &"minder.hide_more": 0.0}, {&"minder.hide_time": 60.0, &"minder.hide_more": 15.0}, {&"minder.hide_time": 30.0, &"minder.hide_more": 5.0}]:
			var want: float = Seek.TUNED_HIDE_LENGTHS[mini(counts - 1, 3)] if given.is_empty() else float(given[&"minder.hide_time"]) + float(given[&"minder.hide_more"]) * mini(counts - 1, 3)
			t.eq(Seek.tuned_hide(Settings.make(given) if not given.is_empty() else null, counts, false), want, "count %d %s: time to hide" % [counts, str(given)])
	for v: float in [3.0, 30.0, 60.0]:
		t.eq(Seek.tuned_hide(Settings.make({&"minder.last_hide": v}), 2, true), v, "the last count's time to hide at %.0f" % v)
	t.eq(Seek.tuned_hide(null, 2, true), Seek.TUNED_LAST_HIDE, "the last count's, untuned")
	for v: float in [5.0, 34.0, 100.0]:
		t.eq(Seek.anger_gain(&"emote", DT, Settings.make({&"minder.anger_noise": v})), v / 100.0, "minder.anger_noise = %.0f: one noise adds %.2f" % [v, v / 100.0])
	t.eq(Seek.anger_gain(&"emote", DT, Settings.make({&"minder.anger_noise": 34.0})), Seek.anger_gain(&"emote", DT, null), "a noise at the old 34 without the hunt: the untuned lump")
	var nrow := Settings.row(&"minder.anger_noise")
	t.eq(Seek.anger_gain(&"emote", DT, Settings.make({&"minder.anger_noise": nrow.today}), true), Seek.anger_gain(&"emote", DT, null, true), "a noise at today's (the hunt, as the rooms have it): the untuned lump")
	t.check(tuned_rig("ls4-count-0", {}, t).seek().hunt, "the proofs above ran with the Minder's hunt on")
	for v: float in [10.0, 50.0, 300.0]:
		t.eq(Seek.anger_cool(Settings.make({&"minder.anger_cool": v})), 1.0 / v, "minder.anger_cool = %.0f: it cools %.4f a second" % [v, 1.0 / v])
	t.eq(Seek.anger_cool(Settings.make({&"minder.anger_cool": 50.0})), Seek.anger_cool(null), "cooling at today's: the untuned rate")
	t.note("; ".join(lines))

# ---------------------------------------------------------------------------------------------
# 4d. LS5: the tank and the heal.

func test_stamina_tank(t: T) -> void:
	var row := Settings.row(&"stamina.tank")
	var base := Run.with_paced(Run.create_run("ls5-tank", ["p0"] as Array[String]))
	t.eq(Run.sprint_seconds(base), Stamina.PACED_SPRINT_SECONDS, "untuned: the paced tank")
	var lines: Array[String] = []
	for v: float in [row.lo, row.today, row.hi]:
		var s := Run.with_tuning(base, {&"stamina.tank": v})
		t.eq(Run.sprint_seconds(s), v, "stamina.tank = %.1f: the run's tank" % v)
		# A full tank sprints for v seconds (sim/stamina.gd, as the host and the game step it).
		var st := Stamina.fresh_stamina(Run.sprint_seconds(s))
		var secs := 0.0
		while st.level > 0.0 and secs < 60.0:
			st = Stamina.step_stamina(st, &"sprint", Stamina.SPRINT_SPEED, DT)
			secs += DT
		t.check(absf(secs - v) <= DT + 1e-6, "stamina.tank = %.1f: a full tank sprinted %.2f s" % [v, secs])
		lines.append("%.1f s" % secs)
	# The host resizes a tank mid-run keeping how full it is, so the bar never jumps (net/host.gd _step_gait).
	var half := Stamina.Stamina.make(0.5, false, 7.0)
	var resized := Stamina.Stamina.make(half.level, half.winded, 12.0)
	t.check(resized.level == 0.5 and resized.tank == 12.0, "a resized tank keeps its level")
	t.note("a full tank sprinted %s" % ", ".join(lines))

## p0 is caught (as down_and_out) and p1, stood beside them from the tick they go down, holds F: [the healStart's
## from and done, the tick of healed, the resident's quiet after it]. `retune`: put in force 0.5 s into the hold.
static func heal_run(seed: String, given: Dictionary, retune: Variant = null) -> PackedFloat64Array:
	var rng := Rng.make_rng(seed)
	var s := Run.with_paced(Run.create_run(seed, ["p0", "p1"] as Array[String], [], false, false, true))
	s = Run.with_tuning(s, given) if not given.is_empty() else s
	var plan := s.plan
	var dist := Floor.distances_from(plan, plan.landing)
	var cells: Array[Floor.Pos] = []
	for i in dist.size():
		var p := Floor.pos_from_index(plan, i)
		if dist[i] >= 3 and p.level == plan.landing.level:
			cells.append(p)
	var vb := Move.body_at_cell(plan, cells[rng.int_in(0, cells.size() - 1)])
	var ob := Move.body_at_cell(plan, plan.landing)
	var hb := vb
	for j in 8:
		var a := (rng.int_in(0, 7) + j) * PI / 4.0
		var b := Move.move_with_collision(plan, vb, cos(a) * 1.2, sin(a) * 1.2, Entity.ORDERLY_RADIUS)
		if M.hypot2(b.x - vb.x, b.z - vb.z) >= 1.15:
			ob = b
			hb = Move.move_with_collision(plan, vb, -cos(a) * 0.8, -sin(a) * 0.8, 0.3)
			break
	s = s.copy()
	s.phase = &"away"
	s.call = null
	s.blink = null
	s.lure = false
	var o := s.orderly.copy()
	o.body = ob
	o.yaw = Entity.yaw_toward(vb.x - ob.x, vb.z - ob.z)
	o.mode = &"hunting"
	o.replan_in = 0.0
	o.ever_seen = true
	s.orderly = o
	var away := Run.car_body(s.car, 1.0, 0.0)
	var players: Array[Run.RunPlayer] = []
	for q in s.players:
		var np := q.copy()
		np.body = vb if q.id == "p0" else away
		np.aboard = q.id != "p0"
		players.append(np)
	s.players = players
	var yaw := Entity.yaw_toward(vb.x - ob.x, vb.z - ob.z)
	var out := PackedFloat64Array([-1.0, -1.0, -1.0, -1.0])
	var downed := false
	for _k in roundi(40.0 / DT):
		var p1 := Run.PlayerInput.make("p1", hb if downed else away, 1.65, yaw + PI, 0.0, 90.0, 70.0)
		p1.use = downed
		var ins: Array[Run.PlayerInput] = [Run.PlayerInput.make("p0", vb, 1.65, yaw, 0.0, 90.0, 70.0), p1]
		var r := Run.step_run(s, ins, DT)
		s = r.state
		for e in r.events:
			if e["type"] == "downed" and e["playerId"] == "p0":
				downed = true
			if e["type"] == "healStart" and out[0] < 0.0:
				out[0] = float(e["from"])
				out[1] = float(e["done"])
			if e["type"] == "healed":
				out[2] = s.t
				out[3] = s.orderly.dormant_left if s.orderly.mode == &"dormant" else -1.0
				return out
		if retune != null and out[0] >= 0.0 and s.t >= out[0] + 0.5:
			s = Run.with_tuning(s, retune)
			retune = null
	return out

func test_heal_time_and_quiet(t: T) -> void:
	var lines: Array[String] = []
	var untuned := heal_run("ls5-heal-0", {})
	t.check(untuned[2] > 0.0, "untuned: p1 healed p0 (%s)" % str(untuned))
	t.check(absf(untuned[1] - untuned[0] - Run.HEAL_TIME) < 1e-9, "untuned: the hold is Run.HEAL_TIME")
	for c: Array in [[&"heal.time", 0], [&"heal.quiet", 1]]:
		var row := Settings.row(c[0])
		for v: float in [row.lo, row.today, row.hi]:
			var got := heal_run("ls5-heal-0", {c[0]: v})
			var tag := "%s = %.1f" % [c[0], v]
			t.check(got[2] > 0.0, "%s: healed (%s)" % [tag, str(got)])
			if c[1] == 0:
				t.check(absf(got[1] - got[0] - v) < 1e-9 and got[2] >= got[1] - 1e-6 and got[2] < got[1] + DT + 1e-6, "%s: the hold from %.2f, done %.2f, healed %.2f" % [tag, got[0], got[1], got[2]])
				lines.append("%s: healed %.2f s into the hold" % [tag, got[2] - got[0]])
			else:
				t.check(absf(got[3] - v) <= DT + 1e-6, "%s: the resident stood off %.2f s" % [tag, got[3]])
				lines.append("%s: quiet %.2f" % [tag, got[3]])
			if v == row.today:
				t.check(got == untuned, "%s: today's value is the untuned run (%s / %s)" % [tag, str(got), str(untuned)])
	# A hold already begun ends when its healStart said, whatever is changed.
	var stamped := heal_run("ls5-heal-0", {&"heal.time": 6.0}, {&"heal.time": 1.0})
	t.check(absf(stamped[1] - stamped[0] - 6.0) < 1e-9 and stamped[2] >= stamped[1] - 1e-6, "changed to 1 s mid-hold: healed at %.2f, its healStart said %.2f" % [stamped[2], stamped[1]])
	t.note("; ".join(lines))

func test_heal_health(t: T) -> void:
	var row := Settings.row(&"heal.health")
	for v: float in [row.lo, row.today, row.hi]:
		var r := CountRun.Rig.new("ls5-health-0")
		CountRun.to_away(t, r)
		var s := Run.with_tuning(r.st, {&"heal.health": v})
		var ss: Seek.SeekState = s.seek
		var ns := ss.copy()
		var list: Array[Seek.SeekPlayer] = []
		for q in ss.players:
			var nq := q.copy()
			if q.id == "p0":
				nq.status = &"down"
				nq.health = 0.0
			list.append(nq)
		ns.players = list
		s.seek = ns
		Run._seek_heal(s, s.players[0])
		t.eq(Seek.player_of(s.seek, "p0").health, v, "heal.health = %.0f: the healed player's health" % v)
	var r0 := CountRun.Rig.new("ls5-health-0")
	t.eq(Settings.f(r0.st.tuning, &"heal.health", Run.HEAL_HEALTH), Run.HEAL_HEALTH, "untuned: Run.HEAL_HEALTH")

## Health on the Playroom (sim/seek.gd step 7, and PT1's health as the game's rooms have it): a second of walking,
## sprinting (each moving every tick, out of a hide) or standing still changes health by exactly the host's
## health.walk, health.sprint or health.rest, at least, today's and most; untuned (null, empty, or all three at
## today's) it is the rules' WALK_DRAIN, SPRINT_DRAIN and REST_GAIN to the last bit.
static func health_after(i: int, hunt: bool, gait: StringName, given: Variant) -> float:
	var k := PropHunt.sk(i, ["a"] as Array[String], hunt, hunt)
	var s := k.s
	if hunt:
		# The search is running (after its time to hide), the Minder far from "a".
		var ev: Array[Dictionary] = []
		Seek._start_count(s, s.t, "x", &"sprint", false, ev)
		s.t0 = s.t - s.hide_len - 0.01
	else:
		# After the first count, outside any: health runs (and the lift called, so a sprint starts no count).
		s.ended = 1
		s.calm_until = 0.0
		s.called = true
	if given != null:
		k.tuning = Settings.make(given)
	var pair := PropHunt.far_pair(k, i)
	# One tick to stand there first (a body's first tick is never a move), then 50 health and one second.
	k.step([PropSeek.inp("a", pair[0], &"creep")] as Array[Seek.SeekInput])
	Seek.player_of(k.s, "a").health = 50.0
	for n in roundi(1.0 / DT):
		var inp: Seek.SeekInput = PropHunt.pace("a", pair, n + 1, gait) if gait != &"stand" else PropSeek.inp("a", pair[0], &"creep")
		k.step([inp] as Array[Seek.SeekInput])
	var p := Seek.player_of(k.s, "a")
	return p.health if p.status == &"ok" else NAN

func test_health_rates(t: T) -> void:
	var lines: Array[String] = []
	for hunt: bool in [true, false]:
		for row_id: StringName in [&"health.walk", &"health.sprint", &"health.rest"]:
			var gait: StringName = {&"health.walk": &"walk", &"health.sprint": &"sprint", &"health.rest": &"stand"}[row_id]
			var sign := 1.0 if row_id == &"health.rest" else -1.0
			var base := health_after(0, hunt, gait, null)
			for given: Variant in [{}, {row_id: Settings.today(row_id)}, {&"health.walk": Settings.today(&"health.walk"), &"health.sprint": Settings.today(&"health.sprint"), &"health.rest": Settings.today(&"health.rest")}]:
				t.eq(health_after(0, hunt, gait, given), base, "hunt %s, %s, tuning %s: exactly the untuned health" % [str(hunt), row_id, str(given)])
			var want0: float = {&"health.walk": Seek.WALK_DRAIN, &"health.sprint": Seek.SPRINT_DRAIN, &"health.rest": Seek.REST_GAIN}[row_id]
			t.check(absf(base - (50.0 + sign * want0)) < 1e-6, "hunt %s, %s untuned: 50 -> %.4f (the rules' %.2f a second)" % [str(hunt), row_id, base, want0])
			var row := Settings.row(row_id)
			for v: float in [row.lo, row.today, row.hi]:
				var got := health_after(0, hunt, gait, {row_id: v})
				t.check(absf(got - (50.0 + sign * v)) < 1e-6, "hunt %s, %s = %.2f: a second moves health 50 -> %.4f" % [str(hunt), row_id, v, got])
				lines.append("%s%s %.2f -> %.2f" % ["" if hunt else "old ", row_id, v, got])
	t.note("; ".join(lines))

## S1, carrying: ONE SLOT HOLDS (a pickup of five juice taken into empty hands: slot 1 holds exactly the number, the rest
## stays on the floor) and HAND OVER WITHIN (a hand-over 5 cm inside the reach goes through, 5 cm outside is refused),
## each at least, today's and most, through the rules.
func test_inventory_stack_and_hand_reach(t: T) -> void:
	var ids: Array[String] = ["p0", "p1"]
	var s0 := PropInventory.open_doors(PropInventory.inv_run("ls-inv", ids))
	var a := PropInventory.spot(s0, -1.5, -0.7)
	var b := PropInventory.spot(s0, -1.5, 0.7)
	var row := Settings.row(&"inv.stack")
	for v: float in [row.lo, row.today, row.hi]:
		var s := s0.copy()
		s.pickups = [Inventory.Pickup.make(1, "juice", 5, a)]
		s.pickups_plan = s.plan
		s = Run.with_tuning(s, {&"inv.stack": v})
		var r := PropInventory.tick(s, PropInventory.ins2(PropInventory.req(PropInventory.inp("p0", a), &"take", 1), PropInventory.inp("p1", b)))
		var bag := Inventory.bag_of(r.state.bags, "p0")
		t.eq(bag.count(0), roundi(v), "inv.stack = %d: slot 1 holds" % roundi(v))
		t.eq(Run.items_in_world(r.state), {"juice": 5}, "inv.stack = %d: nothing made or lost" % roundi(v))
	var dx := b.x - a.x
	var dz := b.z - a.z
	var dl := sqrt(dx * dx + dz * dz)
	var hr := Settings.row(&"inv.hand_reach")
	for v: float in [hr.lo, hr.today, hr.hi]:
		var s := Run.with_tuning(PropInventory.with_bags(s0, {"p0": [["badge", 1]]}), {&"inv.hand_reach": v})
		for d: float in [v - 0.05, v + 0.05]:
			var at := Move.Body.make(a.x + dx / dl * d, a.z + dz / dl * d, a.level, a.y)
			var r := PropInventory.tick(s, PropInventory.ins2(PropInventory.req(PropInventory.inp("p0", a), &"give", "p1"), PropInventory.inp("p1", at)))
			t.eq(Inventory.bag_of(r.state.bags, "p1").totals().size(), 1 if d < v else 0, "inv.hand_reach = %.1f: a hand-over at %.2f m" % [v, d])
	t.eq(Inventory.stack_limit(null, "p0"), Inventory.STACK, "untuned: Inventory.STACK")
	t.eq(Inventory.hand_reach(null), Inventory.HAND_REACH, "untuned: Inventory.HAND_REACH")

## S2, the cabinet: CABINET HOLDS, at least, today's and most: at home, at your own cabinet, with every open slot
## full but one, a stash goes into the last open slot; with all of them full the next is refused (cabFull).
func test_cabinet_slots(t: T) -> void:
	var ids: Array[String] = ["p0"]
	var s0 := PropCabinet.home_run("ls-cab", ids)
	if not t.check(Run.at_home(s0) and s0.shop, "home with the shop"):
		return
	var at := PropCabinet.cab_body(s0, ids, "p0")
	var row := Settings.row(&"cabinet.slots")
	for v: float in [row.lo, row.today, row.hi]:
		var n := roundi(v)
		var cab := Shop.empty_cabinet()
		for k in n - 1:
			cab[k] = ["toy", 1]
		var s := Run.with_tuning(PropCabinet.with_bags(Run.with_cabinet(s0, "p0", cab), {"p0": [["glow", 1], ["salts", 1]]}), {&"cabinet.slots": v})
		var r := PropCabinet.tick(s, {"p0": at}, {"p0": ["stash", 0]})
		t.eq(Shop.cabinet_of((r.state.shop_state as Shop.ShopState).cabinets, "p0")[n - 1], ["glow", 1], "cabinet.slots = %d: the last open slot takes it" % n)
		var r2 := PropCabinet.tick(r.state, {"p0": at}, {"p0": ["stash", 1]})
		var w := PropCabinet.of_type(r2.events, "invRefused")
		t.check(w.size() == 1 and str(w[0]["why"]) == "cabFull", "cabinet.slots = %d: then it is full (%s)" % [n, str(w)])
	t.eq(Shop.cab_slots(null), Shop.CAB_SLOTS, "untuned: Shop.CAB_SLOTS")

## S2, the prices: each item's price at least, today's and most, bought at window 1 with exactly that many credits
## (bought, nothing left) and with one fewer (refused, poor).
## TT1: the Tenant clock's length is the setting, stamped as the doors open on arrival (tests/prop_tenant.gd has the
## rest: once a floor, never in the prison or on Practice, the same on every screen).
## RN1, the Reactor (sim/station_floor.gd): each of its six numbers at least, today's and most, the others at today's,
## on a generated station with one player standing on the landing after passing into the hall: the cut comes
## power_hold after the hold starts; the first stir wake_after after the cut and the second body wake_gap later; seat
## 1 stands crawl_time after it stirs; its metres a second crawling and in its first second standing follow the two
## speeds. Untuned (null) reads today's.
func test_reactor_numbers(t: T) -> void:
	var plan := StationPlan.generate_station("ls-reactor", 7)
	var land: Rect2 = plan.station["landing"]
	var hall: Rect2 = plan.station["hall"]
	for id: StringName in [&"reactor.power_hold", &"reactor.wake_after", &"reactor.wake_gap", &"reactor.crawl_time",
			&"reactor.crawl_speed", &"reactor.run_speed"]:
		var row := Settings.row(id)
		for v: float in [row.lo, row.today, row.hi]:
			var tuning: Settings.Values = null if v == row.today else Settings.make({id: v})
			var r := _reactor_clock(plan, tuning, land, hall)
			var want := {&"reactor.power_hold": float(r["cut"]) - float(r["hold"]), &"reactor.wake_after": float(r["stir"]) - float(r["cut"]),
				&"reactor.wake_gap": float(r["second"]) - float(r["stir"]), &"reactor.crawl_time": float(r["stand"]) - float(r["stir"]),
				&"reactor.crawl_speed": float(r["crawl_m"]) / maxf(1e-9, float(r["crawl_s"])), &"reactor.run_speed": float(r["run_m"]) / maxf(1e-9, float(r["run_s"]))}
			var got := float(want[id])
			var ok := absf(got - v) <= DT + 1e-6 if not String(id).ends_with("speed") else (got <= v + 1e-6 and got >= 0.85 * v)
			t.check(ok, "%s at %s: measured %.3f" % [id, str(v), got])

## One player passes into the hall then stands on the landing; the times of the hold, the cut, the first and second
## stir and seat 1 standing, and seat 1's metres crawling and in its first second standing.
func _reactor_clock(plan: Floor.FloorPlan, tuning: Settings.Values, land: Rect2, hall: Rect2) -> Dictionary:
	var st := StationRules.make(plan)
	var out := {"hold": -1.0, "cut": -1.0, "stir": -1.0, "second": -1.0, "stand": -1.0, "crawl_m": 0.0, "crawl_s": 0.0, "run_m": 0.0, "run_s": 0.0}
	var tt := 0.0
	var x := hall.get_center().x
	for k in 8000:
		tt += DT
		var z := land.position.y - 1.0 if k < 3 else land.end.y - 1.0
		var crew: Array[StationRules.Crew] = [StationRules.Crew.make("p0", Move.Body.make(x, z, 0, 0.0), &"ok", &"walk", false, true)]
		var events: Array[Dictionary] = []
		var before: Move.Body = st.bodies[0].body
		var phase0 := st.bodies[0].phase
		StationRules.step(st, crew, tt, DT, tuning, events)
		var moved := M.hypot2(st.bodies[0].body.x - before.x, st.bodies[0].body.z - before.z)
		if phase0 == "zombie_crawl" and st.bodies[0].phase == "zombie_crawl":
			out["crawl_m"] = float(out["crawl_m"]) + moved
			out["crawl_s"] = float(out["crawl_s"]) + DT
		elif phase0 == "zombie_run" and float(out["run_s"]) < 1.0 - 1e-9:
			out["run_m"] = float(out["run_m"]) + moved
			out["run_s"] = float(out["run_s"]) + DT
		for e in events:
			match str(e["type"]):
				"powerHold": out["hold"] = tt
				"powerCut": out["cut"] = tt
				"stationStir": out["stir"] = tt
				"bodyStands":
					if int(e["seat"]) == 1:
						out["stand"] = tt
		if float(out["second"]) < 0.0 and st.bodies[1].phase != "still":
			out["second"] = tt
		if float(out["run_s"]) >= 1.0 - 1e-9 and float(out["second"]) >= 0.0:
			break
	return out

func test_tenant_minutes(t: T) -> void:
	for m: float in [2.0, float(HostRules.TENANT_MINUTES), 30.0]:
		var r := HostRules.new(true, 1, Places.FULL, false, true, true)
		r.tenant_timer = true
		var s := r.prepare(Run.create_run("ls-tenant-%d" % int(m), ["p0"]))
		if m != float(HostRules.TENANT_MINUTES):
			s = Run.with_tuning(s, {&"tenant.minutes": m})
		var opened := -1.0
		var arrived := -1.0
		var k := 0
		# The least is run to the moment itself; today's and the most are read off the clock the doors started.
		while arrived < 0.0 and k < int((m * 60.0 + 30.0) / DT) and (m == 2.0 or opened < 0.0):
			var inputs: Array[Run.PlayerInput] = []
			for p in s.players:
				if p.status == &"ok" or p.status == &"down":
					inputs.append(Run.PlayerInput.make(p.id, p.body, 1.65, 0.0, 0.0, 90.0, 70.0))
			var st := r.step(s, inputs, DT)
			s = st.state
			k += 1
			for e in st.events:
				if e["type"] == "doorsOpened" and e.get("reason") == "arrival" and opened < 0.0:
					opened = s.t
				elif e["type"] == "tenantArrived":
					arrived = s.t
		var b: Variant = r.tenant_block(s)
		if m == 2.0:
			t.check(opened >= 0.0 and absf(arrived - opened - m * 60.0) < DT + 1e-6, "%d minutes: the doors opened at %.2f, the Tenant arrived at %.2f" % [int(m), opened, arrived])
		t.check(b is Dictionary and absf(float(b["at"]) - opened - m * 60.0) < 1e-6 and absf(float(b["len"]) - m * 60.0) < 1e-9,
			"%d minutes: the clock the doors started is %s (opened %.2f)" % [int(m), str(b), opened])

func test_badge_search_odds(t: T) -> void:
	var ids: Array[String] = ["crew"]
	var s := Run.with_inventory(Run.with_findables(Run.create_run("badge-settings", ids)))
	t.eq(Run.badge_search_chance(Run.with_tuning(s, {&"badge.chance": 100.0})), 0.0, "settings alone do not opt in")
	s = Run.with_badge_search(s)
	s.depth = 1
	t.eq(Run.badge_search_chance(s), 0.75, "first floor's default")
	t.eq(Run.badge_search_chance(Run.with_tuning(s, {&"badge.chance": 20.0, &"badge.depth_chance": 50.0})), 0.2, "the first floor uses only its starting chance")
	s.depth = 3
	t.eq(Run.badge_search_chance(s), 0.91, "deeper floors get the default increase")
	t.eq(Run.badge_search_chance(Run.with_tuning(s, {&"badge.chance": 20.0, &"badge.depth_chance": 15.0})), 0.5, "the tuned increase applies twice by floor 3")
	t.eq(Run.badge_search_chance(Run.with_tuning(s, {&"badge.chance": 0.0, &"badge.depth_chance": 0.0})), 0.0, "both controls at zero turn off the finds")
	t.eq(Run.badge_search_chance(Run.with_tuning(s, {&"badge.chance": 90.0, &"badge.depth_chance": 20.0})), 1.0, "higher chances cap at certainty")

func test_shop_prices(t: T) -> void:
	var ids: Array[String] = ["p0"]
	var s0 := PropCabinet.home_run("ls-price", ids)
	if not t.check(Run.at_home(s0) and s0.shop, "home with the shop"):
		return
	var at := PropCabinet.at_cell(s0, Prison.WINDOWS[0])
	for k in Shop.ITEMS.size():
		var item: String = Shop.ITEMS[k]
		var row := Settings.row(Shop.price_id(item))
		for v: float in [row.lo, row.today, row.hi]:
			var n := roundi(v)
			for have: int in [n, n - 1]:
				if have < 0:
					continue
				var s := PropCabinet.with_bags(s0, {"p0": []})
				var w := s.wallets.duplicate()
				w["p0"] = Upgrades.UpgradeState.make(have)
				s.wallets = w
				s = Run.with_tuning(s, {Shop.price_id(item): v})
				var r := PropCabinet.tick(s, {"p0": at}, {"p0": ["buy", k]})
				var ok := not PropCabinet.of_type(r.events, "bought").is_empty()
				t.check(ok == (have >= n), "%s at %d with %d credits: %s" % [item, n, have, "bought" if ok else "refused"])
				if ok:
					t.eq((r.state.wallets["p0"] as Upgrades.UpgradeState).credits, have - n, "%s at %d: exactly the price is taken" % [item, n])
		t.eq(Shop.price(null, item), Shop.base_price(item), "untuned %s: the design's price" % item)

## S2, A GLOW STICK LASTS: at least, today's and most, a glow stick dropped now is lit exactly that long (the host's
## shop block's until), and goes out once.
func test_glow_seconds(t: T) -> void:
	var ids: Array[String] = ["p0"]
	var rules := HostRules.new(false, 1, Places.FULL, false, false, false, false, false, false, false, false, false, false, false, false, false, true, false, false, true)
	var s0 := PropInventory.open_doors(rules.prepare(Run.create_run("ls-glow", ids)))
	var row := Settings.row(&"shop.glow")
	for v: float in [row.lo, row.today, row.hi]:
		var s := Run.with_tuning(PropCabinet.with_bags(s0, {"p0": [["glow", 1]]}), {&"shop.glow": v})
		var r := PropCabinet.tick(s, {}, {"p0": ["use", 0]})
		var g: Array = (r.state.shop_state as Shop.ShopState).glows
		t.check(g.size() == 1 and absf(float(g[0]["until"]) - r.state.t - v) < 1e-6, "shop.glow = %.0f: lit until %.0f s from now" % [v, v])
		var st := r.state
		var outs := 0
		var out_t := -1.0
		for _k in roundi((v + 0.3) / DT):
			var rr := PropCabinet.tick(st, {})
			st = rr.state
			for e: Dictionary in PropCabinet.of_type(rr.events, "glowOut"):
				outs += 1
				out_t = float(e["t"])
		t.check(outs == 1 and absf(out_t - r.state.t - v) <= DT + 1e-6, "shop.glow = %.0f: out once, on time" % v)
	t.eq(Shop.glow_seconds(null), Shop.GLOW_SECONDS, "untuned: Shop.GLOW_SECONDS")

# ---------------------------------------------------------------------------------------------
# 6. The Groundskeeper's six (AR1).

## A whistle `d` metres west of it on the test garden's moss, the whistler standing: [metres it covered in the
## first second of coming, taken, the first of lean/sweep it did, seconds the lean lasted].
static func keeper_case(given: Dictionary, d: float, dark: bool) -> Array:
	var plan := PropHearing.striped()
	var sim := PropHearing.Sim.make(plan, PropHearing.at(24.0, 40.0))
	sim.tuning = Settings.make(given) if not given.is_empty() else null
	sim.dark = dark
	var b := sim.bot("a", PropHearing.at(24.0 - d, 40.0))
	b.emote = true
	sim.tick()
	var from: Move.Body = null
	var metres := -1.0
	var came := 0
	var what := ""
	var lean_ticks := 0
	for _n in int(20.0 / DT):
		var before := sim.k
		sim.tick()
		if before.mode == &"coming":
			if from == null:
				from = before.body
			came += 1
			if came == int(1.0 / DT):
				metres = M.hypot2(sim.k.body.x - from.x, sim.k.body.z - from.z)
		if what == "" and (sim.k.mode == &"lean" or sim.k.mode == &"sweep"):
			what = String(sim.k.mode)
		if before.mode == &"lean":
			lean_ticks += 1
		if sim.k.mode == &"listening":
			break
	return [metres, sim.taken.has("a"), what, lean_ticks * DT]

func test_groundskeeper_six(t: T) -> void:
	var lines: PackedStringArray = []
	# Speeds: a second of coming covers the speed, lit and dark, each following only its own setting.
	for dark: bool in [false, true]:
		var id: StringName = &"groundskeeper.dark_speed" if dark else &"groundskeeper.speed"
		var other: StringName = &"groundskeeper.speed" if dark else &"groundskeeper.dark_speed"
		var row := Settings.row(id)
		# (The least needs a slower sprint to be allowed; the rules read the speed alone.)
		for v: float in [row.lo, row.today, row.hi]:
			var got: Array = keeper_case({id: v}, 17.5, dark)
			t.check(absf(float(got[0]) - v) < 0.02, "%s %.1f: %.2f m in a second of coming" % [id, v, got[0]])
			var cross: Array = keeper_case({other: row.hi}, 17.5, dark)
			t.check(absf(float(cross[0]) - row.today) < 0.02, "%s moved the %s speed: %.2f m in a second" % [other, "dark" if dark else "lit", cross[0]])
			lines.append("%s %.1f: %.2f m in a second" % [id, v, got[0]])
	# Reach: standing just inside it at the lean's end is taken, just outside is not.
	var reach := Settings.row(&"groundskeeper.reach")
	for v: float in [reach.lo, reach.today, reach.hi]:
		var given := {&"groundskeeper.reach": v, &"groundskeeper.lean_range": 6.0}
		var sim := PropHearing.Sim.make(PropHearing.striped(), PropHearing.at(24.0, 40.0))
		sim.tuning = Settings.make(given)
		var whistler := sim.bot("w", PropHearing.at(12.0, 40.0))
		var inside := sim.bot("in", PropHearing.at(12.0, 40.0 + v - 0.05))
		var outside := sim.bot("out", PropHearing.at(12.0, 40.0 - v - 0.05))
		whistler.emote = true
		sim.tick()
		whistler.go(&"creep", -1.0, 0.0)
		for _n in int(12.0 / DT):
			sim.tick()
		t.check(sim.taken.has("in") and not sim.taken.has("out"), "reach %.1f: just inside taken %s, just outside taken %s" % [v, sim.taken.has("in"), sim.taken.has("out")])
	# Lean range: a player just inside it is leaned to; just outside, the sweep.
	var lr := Settings.row(&"groundskeeper.lean_range")
	for v: float in [lr.lo, lr.today, lr.hi]:
		for inside: bool in [true, false]:
			var sim := PropHearing.Sim.make(PropHearing.striped(), PropHearing.at(24.0, 40.0))
			sim.tuning = Settings.make({&"groundskeeper.lean_range": v})
			var whistler := sim.bot("w", PropHearing.at(12.0, 40.0))
			whistler.emote = true
			sim.tick()
			# The whistler steps to its mark at once (a test's move, not a walk: nothing is heard).
			whistler.body = PropHearing.at(12.0, 40.0 + v + (-0.05 if inside else 0.05))
			var what := ""
			for _n in int(8.0 / DT):
				sim.tick()
				if what == "" and (sim.k.mode == &"lean" or sim.k.mode == &"sweep"):
					what = String(sim.k.mode)
			t.check(what == ("lean" if inside else "sweep"), "lean range %.1f: a player just %s it gets the %s" % [v, "inside" if inside else "outside", what])
	# The lean's length, and the heals.
	var lean := Settings.row(&"groundskeeper.lean")
	for v: float in [lean.lo, lean.today, lean.hi]:
		var got: Array = keeper_case({&"groundskeeper.lean": v}, 10.0, false)
		t.check(got[1] and absf(float(got[3]) - v) <= DT + 1e-6, "lean %.1f s: it lasted %.2f s (taken %s)" % [v, got[3], got[1]])
		lines.append("lean %.1f: %.2f s" % [v, got[3]])
	var heals := Settings.row(&"groundskeeper.heals")
	for v: float in [heals.lo, heals.today, heals.hi]:
		var ids: Array[String] = ["a"]
		var s := PropHearing.garden_run(ids, {"a": PropHearing.at(12.0, 40.0)}, PropHearing.at(15.0, 40.0))
		s = Run.with_tuning(s, {&"groundskeeper.heals": v})
		t.eq(Run.KEEPER_HEALS, 2, "the game's heals")
		# With `had` heals already had on the floor, the next snatch is down while had < v, else out.
		for had: int in [0, int(v) - 1, int(v)]:
			if had < 0:
				continue
			var st := s
			var out_now := false
			var down_now := false
			for step in int(8.0 / DT):
				var ia := PropHearing.input("a", PropHearing.at(12.0, 40.0))
				ia.emote_sound = step == 2
				if step == 1:
					var g := st.garden.copy()
					g.heals = {"a": had}
					st = st.copy()
					st.garden = g
				var r := Run.step_run(st, PropHearing.one(ia), DT)
				st = r.state
				for e in r.events:
					out_now = out_now or (e["type"] == "out" and e.get("by") == "keeper")
					down_now = down_now or e["type"] == "downed"
			t.check(down_now == (had < int(v)) and out_now == (had >= int(v)), "heals %d, had %d: down %s, out at once %s" % [int(v), had, down_now, out_now])
	t.note("; ".join(lines))

# ---------------------------------------------------------------------------------------------
# 5. Every wired id has a proof.

func test_every_wired_setting_has_a_proof(t: T) -> void:
	var wired := {}
	for s in Settings.list(true):
		wired[s.id] = true
		t.check(PROOFS.has(s.id) and has_method(String(PROOFS.get(s.id, ""))), "%s is wired and has no proof in tests/prop_settings.gd" % s.id)
	for id: StringName in PROOFS:
		t.check(wired.has(id), "%s has a proof but is not wired" % id)

## AR5: the tuning applies at the actual landing point.
func test_cone_hearing_radius(t: T) -> void:
	var tuned := Settings.Values.new()
	tuned.values[&"noise.cone"] = 8.0
	var normal := Noises.cone(13.0, 15.0, 0)
	var quiet := Noises.cone(13.0, 15.0, 0, tuned)
	t.check(Noises.heard_at(normal, 23.0, 15.0, 0), "default cone reaches 10 m")
	t.check(not Noises.heard_at(quiet, 23.0, 15.0, 0), "tuned cone cannot be heard at 10 m")
	t.check(Noises.heard_at(quiet, 21.0, 15.0, 0), "8 m is still audible")

func test_garden_search_hearing_radius(t: T) -> void:
	var tuned := Settings.Values.new()
	tuned.values[&"noise.search_open"] = 3.0
	tuned.values[&"noise.search_rush"] = 11.0
	t.eq(Noises.search_radius(false), 4.0, "opening storage carries 4 m")
	t.eq(Noises.search_radius(true), 8.0, "rummaging carries 8 m")
	t.eq(Noises.search_radius(false, tuned), 3.0, "quiet opening uses its own live setting")
	t.eq(Noises.search_radius(true, tuned), 11.0, "rummaging uses its own live setting")

func test_garden_noise_table_settings(t: T) -> void:
	var tuned := Settings.Values.new()
	tuned.values = {&"noise.creep_loud": 1.5, &"noise.walk_moss": 2.0, &"noise.walk_litter": 6.0,
		&"noise.walk_gravel": 7.0, &"noise.sprint": 19.0, &"noise.twig": 16.0, &"noise.crawl": 3.0,
		&"noise.hide": 8.0, &"noise.drop": 9.0, &"noise.emote": 20.0}
	t.eq(Noises.gait_radius(&"creep", Noises.LITTER, tuned), 1.5, "litter creep radius")
	t.eq(Noises.gait_radius(&"creep", Noises.MOSS, tuned), 0.0, "moss creep remains silent")
	t.eq(Noises.gait_radius(&"walk", Noises.MOSS, tuned), 2.0, "moss walk radius")
	t.eq(Noises.gait_radius(&"walk", Noises.LITTER, tuned), 6.0, "litter walk radius")
	t.eq(Noises.gait_radius(&"walk", Noises.GRAVEL, tuned), 7.0, "gravel walk radius")
	t.eq(Noises.gait_radius(&"sprint", Noises.MOSS, tuned), 19.0, "sprint radius")
	var ground := Noises.Ground.new()
	ground.width = 1
	ground.height = 1
	ground.cell_size = 2.0
	ground.cells = PackedByteArray([Noises.TWIG])
	ground.falls = PackedInt32Array([0])
	var a := Noises.Act.make("a", Move.Body.make(1.0, 1.0, 0, 0.0), Move.Body.make(0.8, 1.0, 0, 0.0), &"walk")
	t.eq(Noises.of(ground, a, DT, {}, tuned).r, 16.0, "twig cracking radius")
	a.down = true
	t.eq(Noises.of(null, a, DT, {}, tuned).r, 3.0, "downed movement radius")
	a.down = false
	a.from = a.body
	a.hide = 1
	t.eq(Noises.of(null, a, DT, {}, tuned).r, 8.0, "hide radius")
	a.hide = -1
	a.healed = true
	t.eq(Noises.of(null, a, DT, {}, tuned).r, 9.0, "getting up radius")
	a.emote = true
	t.eq(Noises.of(null, a, DT, {}, tuned).r, 20.0, "emote is the single louder noise")
	t.eq(Noises.drop("a", a.body, tuned).r, 9.0, "a fallen tape shares the getting-up setting")

func test_garden_state_clock_settings(t: T) -> void:
	var tuning := Settings.Values.new()
	tuning.values = {&"groundskeeper.turn": 55.0, &"groundskeeper.tilt": 1.7, &"groundskeeper.sweep": 4.0, &"groundskeeper.beat": 1.5}
	var plan := PropHearing.field()
	var at := Move.Body.make(40.0, 40.0, 0, 0.0)
	var never: Array[Hearing.Person] = []
	var quiet: Array[Noises.Sound] = []
	var k := Hearing.create(at, 0.0)
	var r := Hearing.step(plan, plan.ground as Noises.Ground, k, never, quiet, false, DT, tuning)
	t.check(absf(r.state.yaw - deg_to_rad(55.0) * DT) < 1e-7, "listening yaw uses the live turn rate")
	var noises: Array[Noises.Sound] = [Noises.cone(at.x, at.z, at.level)]
	r = Hearing.step(plan, plan.ground as Noises.Ground, k, never, noises, false, DT, tuning)
	t.eq(r.state.left, 1.7, "the next hearing reaction uses the live delay")
	k.mode = &"coming"
	k.target = noises[0]
	r = Hearing.step(plan, plan.ground as Noises.Ground, k, never, quiet, false, DT, tuning)
	t.eq(r.state.mode, &"sweep", "an empty target gets a sweep")
	t.eq(r.state.left, 4.0, "the next sweep uses the live duration")
	k.mode = &"lean"
	k.left = DT
	r = Hearing.step(plan, plan.ground as Noises.Ground, k, never, quiet, false, DT, tuning)
	t.eq(r.state.mode, &"beat", "a lean ending safely holds one extra beat")
	t.eq(r.state.left, 1.5, "the next beat uses the live duration")

func test_custom_sprint_radius_is_checked_from_the_current_listener(t: T) -> void:
	for radius: float in [8.0, 19.0]:
		var sim := PropHearing.Sim.make(PropHearing.field(), PropHearing.at(24.0, 40.0))
		var runner := sim.bot("runner", PropHearing.at(24.0 + radius - 0.4, 40.0))
		sim.tuning = Settings.Values.new()
		sim.tuning.values = {&"noise.sprint": radius}
		sim.warm()
		runner.go(&"sprint", 1.0, 0.0)
		var step := sim.tick()
		if not t.check(step.heard.size() == 1, "just inside %.1f m is heard" % radius):
			continue
		var last_x := step.heard[0].x
		step = sim.tick()
		t.check(step.heard.is_empty() and sim.k.target.x == last_x, "outside %.1f m preserves last heard step" % radius)
		runner.go(&"sprint", -1.0, 0.0)
		step = sim.tick()
		t.check(step.heard.size() == 1 and sim.k.target.t == step.heard[0].t, "first step back within %.1f m is reacquired" % radius)

# ---------------------------------------------------------------------------------------------
# T22b: more of the host's numbers (the owner, 19 Nov: "Yes let's connect more of the live settings").

## orderly2.first_floor: a Clinic floor this deep or deeper has a second Orderly, decided as the car arrives.
func test_second_orderly_first_floor(t: T) -> void:
	var ids: Array[String] = ["p0", "p1"]
	var none: Array[Run.PlayerInput] = []
	for row: Array in [[null, [false, true, true]], [3.0, [false, false, true]], [20.0, [false, false, false]], [1.0, [true, true, true]]]:
		var given := {} if row[0] == null else {&"orderly2.first_floor": row[0]}
		var tag := "first floor %s" % ("today's" if row[0] == null else str(row[0]))
		var st: Array = PropO2.start("ls-o2-%s" % str(row[0]), ids, 1, true)
		var r: HostRules = st[0]
		var s: Run.RunState = st[1]
		if not given.is_empty():
			s = Run.with_tuning(s, given)
		# Depth 1 with the setting in force as its second is decided (with_second_orderly decides it again).
		var at1 := Run.with_second_orderly(s)
		var seen: Array = [at1.orderly2 != null]
		for depth: int in [2, 3]:
			var ride := s.copy()
			ride.phase = &"riding"
			ride.timer = DT / 2.0
			s = r.step(ride, none, DT).state
			t.check(s.depth == depth, "%s: arrived at depth %d" % [tag, s.depth])
			seen.append(s.orderly2 != null)
		t.eq(seen, row[1], "%s: a second Orderly at depths 1, 2, 3" % tag)
	# A change waits for the next floor: set on depth 2 (which has its second), the second stays until the car leaves.
	var st2: Array = PropO2.start("ls-o2-wait", ids, 2, true)
	var s2: Run.RunState = Run.with_tuning(st2[1], {&"orderly2.first_floor": 9.0})
	s2 = (st2[0] as HostRules).step(s2, none, DT).state
	t.check(s2.depth == 2 and s2.orderly2 != null, "a second Orderly already on the floor is not taken away mid-floor")

## The flare (B3): its five numbers, each measured on a real burst.
static func _flare_burst(given: Dictionary, teammate: bool) -> Array:
	var ids: Array[String] = ["a"]
	if teammate:
		ids.append("b")
	var s := Run.with_orientation(Run.with_flare(Run.create_run("ls-flare", ids)))
	if not given.is_empty():
		s = Run.with_tuning(s, given)
	s.phase = &"away"
	var o := s.orderly.body
	var a := PropCabinet.inp("a", Move.Body.make(o.x, o.z + (3.0 if teammate else 1.6), o.level, o.y))
	a.yaw = 0.0 if teammate else PI
	a.blind = true
	var inputs: Array[Run.PlayerInput] = [a]
	if teammate:
		var b := PropCabinet.inp("b", Move.Body.make(o.x, o.z + 2.0, o.level, o.y))
		b.blind = true
		inputs.append(b)
	s = Run.step_run(s, inputs, DT).state
	a.inv_op = &"use"
	var r := Run.step_run(s, inputs, DT)
	var used := PropCabinet.of_type(r.events, "flareUsed")
	return [used[0] if used.size() == 1 else {}, r.state, a.body]

func test_flare_settings(t: T) -> void:
	# Thrown away from the Orderly along an open corridor (as tests/prop_flare.gd's practice): the burst lands
	# `throw` along the aim and stuns when the Orderly is within `reach` of it.
	for row: Array in [[{}, Flare.THROW, Flare.REACH, true], [{&"flare.reach": 5.0}, Flare.THROW, 5.0, false],
			[{&"flare.throw": 2.0, &"flare.reach": 4.0}, 2.0, 4.0, true], [{&"flare.throw": 2.0, &"flare.reach": 3.0}, 2.0, 3.0, false]]:
		var got := _flare_burst(row[0], false)
		var e: Dictionary = got[0]
		if not t.check(not e.is_empty(), "%s: a burst" % str(row[0])):
			continue
		var s: Run.RunState = got[1]
		var a: Move.Body = got[2]
		var thrown := Vector2(float(e["x"]) - a.x, float(e["z"]) - a.z).length()
		var to_o := Vector2(float(e["x"]) - s.orderly.body.x, float(e["z"]) - s.orderly.body.z).length()
		t.check(absf(thrown - float(row[1])) < 1e-6, "%s: thrown %.3f m, want %.1f" % [str(row[0]), thrown, row[1]])
		t.check(bool(e["stunned"]) == row[3] and (to_o <= float(row[2])) == row[3], "%s: %.2f m from the Orderly, reach %.1f: stunned %s" % [str(row[0]), to_o, row[2], str(e["stunned"])])
	for stun: float in [0.5, Flare.STUN, 3.0]:
		for noise: float in [12.0, Flare.NOISE, 30.0]:
			var given := {} if stun == Flare.STUN and noise == Flare.NOISE else {&"flare.stun": stun, &"flare.noise": noise}
			var got := _flare_burst(given, false)
			var e: Dictionary = got[0]
			var s: Run.RunState = got[1]
			t.check(not e.is_empty() and bool(e["stunned"]) and absf(s.flare_stun_until - float(e["t"]) - stun) < 1e-9 and float(e["noise"]) == noise,
				"stun %.2f noise %.0f: stunned until +%.3f, noise %s" % [stun, noise, s.flare_stun_until - float(e.get("t", 0.0)), str(e.get("noise"))])
	for blind: float in [0.5, Flare.BLIND, 2.0]:
		var got := _flare_burst({} if blind == Flare.BLIND else {&"flare.blind": blind}, true)
		var e: Dictionary = got[0]
		t.check(not e.is_empty() and e["blind"] == "b" and absf(float(e["blindUntil"]) - float(e["t"]) - blind) < 1e-9,
			"blind %.2f: the struck crewmate is blind for %s" % [blind, str(float(e.get("blindUntil", 0.0)) - float(e.get("t", 0.0)))])

## The lamp (B4): a fresh battery's seconds, and the beam's reach, on the host's lamp row.
func test_lamp_settings(t: T) -> void:
	for row: Array in [[15.0, 5.0], [Lamp.CHARGE, Lamp.REACH], [180.0, 22.0]]:
		var ids: Array[String] = ["a"]
		var s := Run.with_lamp(Run.create_run("ls-lamp", ids))
		if row[0] != Lamp.CHARGE:
			s = Run.with_tuning(s, {&"lamp.seconds": row[0], &"lamp.range": row[1]})
		var a := PropCabinet.inp("a", s.players[0].body)
		a.inv_op = &"lamp"
		a.inv_arg = 1
		var r := Run.step_run(s, [a], DT)
		var lamp := Run.lamp_of(r.state, "a")
		t.check(absf(float(lamp.get("charge", -1.0)) - (float(row[0]) - DT)) < 1e-9 and float(lamp.get("range", -1.0)) == float(row[1]),
			"%.0f s, %.0f m: charge %s, range %s" % [row[0], row[1], str(lamp.get("charge")), str(lamp.get("range"))])
		if row[0] == 15.0:
			var empty_at := -1.0
			var st := r.state
			for _k in roundi(16.0 / DT):
				var rr := Run.step_run(st, [a], DT)
				st = rr.state
				if not PropCabinet.of_type(rr.events, "lampEmpty").is_empty():
					empty_at = st.t
					break
			t.check(absf(empty_at - 15.0) < DT + 1e-6, "a 15 s battery is empty at %.2f s" % empty_at)

## Recording (sim/instrument.gd): the reach the needle writes within, and the rate up close, on a crew step.
static func _rate_at_distance(d: float, given: Dictionary) -> float:
	var ids: Array[String] = ["a"]
	var s := Run.create_run("ls-record", ids)
	var plan := s.plan
	var o := Entity.create_orderly(plan)
	var holder := Move.Body.make(o.body.x + d, o.body.z, o.body.level, o.body.y)
	var crew := Instr.set_raised(Instr.create_crew(ids), "a", true)
	var players: Array[Instr.CrewPlayer] = [Instr.CrewPlayer.make("a", holder, true)]
	var no_events: Array[Dictionary] = []
	var e := Instr.EntityTick.make("orderly", &"hearing", o, o, no_events)
	e.acting = true
	var ets: Array[Instr.EntityTick] = [e]
	var out := Instr.step_crew(plan, crew, players, ets, DT, null if given.is_empty() else Settings.make(given))
	return Instr.member(out.crew, "a").instrument.rate

func test_recording_reach_and_rate(t: T) -> void:
	for reach: float in [4.0, Instr.RECORD_RANGE, 16.0]:
		var given := {} if reach == Instr.RECORD_RANGE else {&"record.reach": reach}
		var inside := _rate_at_distance(reach - 0.05, given)
		var outside := _rate_at_distance(reach + 0.05, given)
		t.check(inside > 0.0 and outside == 0.0, "reach %.1f: %.2f a second just inside, %.2f just outside" % [reach, inside, outside])
	for rate: float in [40.0, Instr.RATE_NEAR, 400.0]:
		var given := {} if rate == Instr.RATE_NEAR else {&"record.rate": rate}
		var near := _rate_at_distance(1.0, given)
		t.check(absf(near - rate) < 1e-9, "rate up close %.0f: %.3f a second at 1 m" % [rate, near])
	t.eq(_rate_at_distance(5.0, {}), Instr.rate_at(5.0), "untuned, the same number by the same path")

## quota.step: the floor quota grows by it a floor; a quota already shown never moves, the next floor takes the new.
func test_quota_step(t: T) -> void:
	for step: float in [1.0, Run.QUOTA_DEPTH_STEP, 2.0]:
		var tun: Settings.Values = null if step == Run.QUOTA_DEPTH_STEP else Settings.make({&"quota.step": step})
		var want := maxi(Run.QUOTA_ROUND, roundi(float(Run.QUOTA_PER_PLAYER * 2) * M.pow_js(step, 2.0) / Run.QUOTA_ROUND) * Run.QUOTA_ROUND)
		t.eq(Run.floor_quota(3, 2, tun), want, "step %.2f: floor 3 asks a crew of two for %d" % [step, want])
	t.eq(Run.floor_quota(1, 3, Settings.make({&"quota.step": 2.0})), Run.floor_quota(1, 3), "floor 1 does not grow")
	var ids: Array[String] = ["p0", "p1"]
	var none: Array[Run.PlayerInput] = []
	var s := Run.create_run("ls-quota", ids, [], false, true)
	s = Run.with_tuning(s, {&"quota.step": 2.0})
	s.phase = &"riding"
	s.timer = DT / 2.0
	s = Run.step_run(s, none, DT).state
	# The desk lets a NEXT FLOOR value in on "carLeft", never while the car arrives (when the quota is set).
	for _k in roundi(5.0 / DT):
		if s.phase != &"arriving":
			break
		s = Run.step_run(s, none, DT).state
	t.check(s.depth == 2 and s.phase != &"arriving" and s.floor_needed == Run.floor_quota(2, 2, s.tuning) and s.floor_needed != Run.floor_quota(2, 2),
		"arrived at depth %d asking %d (the step at 2.0)" % [s.depth, s.floor_needed])
	var shown := s.floor_needed
	s = Run.with_tuning(s, {&"quota.step": 1.0})
	for _k in roundi(10.0 / DT):
		s = Run.step_run(s, none, DT).state
	t.check(s.depth == 2 and s.floor_needed == shown, "changed mid-floor, the quota on screen stays %d (now %d)" % [shown, s.floor_needed])
	s.phase = &"riding"
	s.timer = DT / 2.0
	s = Run.step_run(s, none, DT).state
	t.check(s.depth == 3 and s.floor_needed == Run.floor_quota(3, 2, s.tuning) and s.floor_needed != Run.floor_quota(3, 2),
		"the next floor asks %d with the step at 1.0 (%d; untuned %d)" % [Run.floor_quota(3, 2, s.tuning), s.floor_needed, Run.floor_quota(3, 2)])

## marks.pad: the Annex's pad a floor.
func test_marks_pad(t: T) -> void:
	for pad: int in [0, Marks.DEFAULT_PAD, 9]:
		var ids: Array[String] = ["p0"]
		var rules := HostRules.new(true, 3, Places.FULL)
		var s := rules.prepare(Run.create_run("ls-pad", ids, Places.FULL))
		if pad != Marks.DEFAULT_PAD:
			s = Run.with_tuning(s, {&"marks.pad": float(pad)})
		var none: Array[Run.PlayerInput] = []
		s = Run.step_run(s, none, DT).state
		t.check(s.annex != null and s.annex.marks.pad == pad and s.annex.marks.pad_size == pad, "pad %d on the Annex: %s" % [pad, "no Annex" if s.annex == null else "%d of %d" % [s.annex.marks.pad, s.annex.marks.pad_size]])

## The party table's three numbers (party.free_time, party.free_anger, party.reach). Read by the rules and by the
## client's table prompt (tests/prop_party_table.gd test_table_prompt_follows_the_host), so on the panel (T22c).
func test_party_table_numbers(t: T) -> void:
	var ids: Array[String] = ["a", "c"]
	for row: Array in [[5.0, 20.0], [Seek.FETCH_TIME, Seek.FETCH_ANGER * 100.0], [1.0, 100.0]]:
		var k := PropParty.sk(0, ids, true)
		if row[0] != Seek.FETCH_TIME:
			k.tuning = Settings.make({&"party.free_time": row[0], &"party.free_anger": row[1]})
		PropParty.seat(k.s, "a", 0)
		var evs: Array[Dictionary] = []
		var anger0 := k.s.anger
		var freed_at := -1.0
		var first := -1.0
		for j in roundi((float(row[0]) + 1.0) / DT):
			var ev := k.step([PropParty.holder(k.s, "c", 1, true)] as Array[Seek.SeekInput])
			evs.append_array(ev)
			if first < 0.0:
				first = k.s.t - DT
			# Changed mid-hold: the hold already begun keeps the length its fetchStart gave.
			if j == 2 and row[0] == 5.0:
				k.tuning = Settings.make({&"party.free_time": 1.0, &"party.free_anger": row[1]})
			if not PropHunt.of_type(ev, "tableFreed").is_empty():
				freed_at = k.s.t
				break
		var st := PropHunt.of_type(evs, "fetchStart")
		t.check(st.size() == 1 and absf(float(st[0]["done"]) - float(st[0]["from"]) - float(row[0])) < 1e-9, "%.1f s: fetchStart says %s" % [row[0], str(st)])
		t.check(absf(freed_at - first - float(row[0])) < 1e-6, "%.1f s: freed %.3f s after the hold began" % [row[0], freed_at - first])
		t.check(absf(k.s.anger - anger0 - float(row[1]) / 100.0) < 1e-9 or (anger0 + float(row[1]) / 100.0 >= 1.0 and k.s.counting),
			"anger %.0f: the bar %.3f -> %.3f" % [row[1], anger0, k.s.anger])
	# A point 1.6 to 2.4 m from the nearest seat: off the table today, at it with party.reach 2.5, off it at 1.0.
	var k2 := PropParty.sk(0, ids, true)
	var seat := PropParty.seat_body(k2.s, 0)
	var off: Move.Body = null
	var nearest := 0.0
	for a in 16:
		var cand := Move.Body.make(seat.x + 2.0 * cos(a * PI / 8.0), seat.z + 2.0 * sin(a * PI / 8.0), seat.level, seat.y)
		var dmin := INF
		for st in k2.s.floor.seats:
			if st.level == cand.level:
				dmin = minf(dmin, M.hypot2(st.at.x / 100.0 - cand.x, st.at.y / 100.0 - cand.z))
		if dmin > 1.6 and dmin < 2.4:
			off = cand
			nearest = dmin
			break
	if t.check(off != null, "a point 1.6 to 2.4 m from the nearest seat"):
		t.check(not Seek.at_table(k2.s, off) and Seek.at_table(k2.s, off, Settings.make({&"party.reach": 2.5})) and not Seek.at_table(k2.s, off, Settings.make({&"party.reach": 1.0})),
			"%.2f m from the nearest seat: at the table only with party.reach 2.5" % nearest)
	t.eq([Seek.fetch_time(), Seek.fetch_anger(), Seek.fetch_reach()], [Seek.FETCH_TIME, Seek.FETCH_ANGER, Seek.FETCH_REACH], "untuned, today's constants")

# DF1: the pressures of floor 8 and deeper (sim/run.gd "Pressures"). Each setting moves its number on the floors it is
# for, its "off" value gives the number without the pressure, and cycle 1 never reads it.
static func _pressure_state(depth: int, crew: int, given: Dictionary) -> Run.RunState:
	var ids: Array[String] = []
	for i in crew:
		ids.append("p%d" % i)
	var s := Run.create_run("ls-pressure", ids)
	s.deck = Places.with_cycles(Places.FULL)
	s.depth = depth
	s.downs = true
	s = Run.with_pressures(s)
	return Run.with_tuning(s, given) if not given.is_empty() else s

func test_pressure_settings(t: T) -> void:
	var q := func(depth: int, given: Dictionary) -> float:
		var st := _pressure_state(depth, 2, given)
		return float(Run.floor_quota(depth, 2, st.tuning, Run.pressure_quota_mult(st, st.tuning)))
	t.eq(q.call(8, {}), float(Run.floor_quota(8, 2, null, 1.5)), "floor 8's quota at today's x1.5")
	t.eq(q.call(8, {&"pressure.quota": 1.0}), float(Run.floor_quota(8, 2)), "pressure.quota 1 is off")
	t.eq(q.call(8, {&"pressure.quota": 3.0}), float(Run.floor_quota(8, 2, null, 3.0)), "pressure.quota 3 is x3")
	t.eq(q.call(15, {}), float(Run.floor_quota(15, 2, null, 2.25)), "floor 15's at today's x2.25")
	t.eq(q.call(15, {&"pressure.quota3": 1.0}), float(Run.floor_quota(15, 2)), "pressure.quota3 1 is off")
	t.eq(q.call(1, {&"pressure.quota": 3.0}), float(Run.floor_quota(1, 2)), "floor 1 never reads it")
	var heals := func(depth: int, given: Dictionary) -> int:
		return Run.pressure_heals_left(_pressure_state(depth, 3, given))
	t.eq([heals.call(8, {}), heals.call(15, {}), heals.call(1, {})], [2, 1, -1], "heals: 2 in cycle 2, 1 in cycle 3, no limit in cycle 1")
	t.eq([heals.call(8, {&"pressure.heals": 5.0}), heals.call(8, {&"pressure.heals": 0.0}), heals.call(15, {&"pressure.heals3": 3.0}), heals.call(15, {&"pressure.heals3": 0.0})], [5, -1, 3, -1], "heals: set, and 0 is no limit")
	var need := func(depth: int, up: int, given: Dictionary) -> int:
		return Run.pressure_watch_need(_pressure_state(depth, up, given), up, Entity.watch_need(up))
	t.eq([need.call(8, 4, {}), need.call(15, 4, {}), need.call(1, 4, {})], [3, 3, 2], "watchers with four up: 3, 3, and cycle 1's 2")
	t.eq([need.call(8, 6, {&"pressure.watchers": 5.0}), need.call(8, 4, {&"pressure.watchers": 2.0}), need.call(15, 6, {&"pressure.watchers3": 4.0}), need.call(15, 4, {&"pressure.watchers3": 2.0})], [5, 2, 4, 2], "watchers: set, and 2 is off")
	var light := func(depth: int, given: Dictionary) -> float:
		return Run.pressure_near_light(_pressure_state(depth, 1, given))
	t.eq([light.call(8, {}), light.call(15, {}), light.call(1, {})], [1.5, 0.0, -1.0], "near light: 1.5 m, none, and cycle 1's own")
	t.eq([light.call(8, {&"pressure.near_light": 3.0}), light.call(15, {&"pressure.near_light3": 2.5})], [3.0, 2.5], "near light: set")
	var tenant := func(depth: int, given: Dictionary) -> int:
		var st := _pressure_state(depth, 1, given)
		return Run.pressure_tenant_minutes(st, Settings.i(st.tuning, &"tenant.minutes", HostRules.TENANT_MINUTES))
	t.eq([tenant.call(8, {}), tenant.call(15, {}), tenant.call(1, {})], [8, 6, 10], "the Tenant: 8, 6, and cycle 1's 10 minutes")
	t.eq([tenant.call(8, {&"pressure.tenant_minutes": 4.0}), tenant.call(8, {&"pressure.tenant_minutes": 0.0}), tenant.call(15, {&"pressure.tenant_minutes3": 3.0}), tenant.call(15, {&"pressure.tenant_minutes3": 0.0})], [4, 10, 3, 10], "the Tenant: set, and 0 is off")
	t.eq(tenant.call(8, {&"tenant.minutes": 5.0}), 5, "never later than ARRIVES AFTER")
