# The rules of a day in the prison: the day quota, a made or missed day, game over, shares, the
# streak, and the bedtime count. Pure rules: no engine random, no clock (every time is passed in),
# no rendering, no network. Every call returns new state; a state, wallet or list you pass in is
# never edited.
#
# The design: docs/floors/prison.md sections 1, 2 and 6, with "The owner's answers (17 November)"
# overriding it. A missed day no longer halves the pay: it pays the banked pay as normal, takes ONE
# upgrade by a seeded roll, and the third missed day of a night is game over. There is no clocking
# out. Lights go out 20 s after more than half the crew is in bed, and once that count has started
# it cannot be stopped. Day 1 every game night.
#
# Words: a WALLET is one player's Upgrades.UpgradeState (credits and owned nodes). Wallets are passed
# as a Dictionary {player_id: UpgradeState}. Credits are ints; the caller rounds the run's banked
# total (sim/run.gd keeps it as a float) down before passing it in.
#
# Readings built here that the owner has NOT confirmed (each one is a constant or one function):
#   - LOSS_RULE is the OWNER'S ANSWER (17 Nov): EACH_PLAYER_ONE. A missed day takes one upgrade from
#     EVERY player who owns any, each player's own picked by a seeded roll over that player's own
#     upgrades. Players with none lose nothing. LossRule.CREW_ONE (one upgrade for the whole crew by
#     one roll over the pooled upgrades) is kept as the other reading: change the constant to switch.
#   - Missed days count within one game night (start_night() clears them).
#   - Game over resets credits, upgrades, the day number, the streak and the quota level. It deletes
#     nothing: the caller keeps the save, records and days served.
#   - On the game-over day no roll is made: everything is reset anyway.
#   - The floor quota grows with the crew: first_floor_quota() = per player x crew size.
#
# API (all static, all pure):
#   DayState.fresh() -> DayState                 Day 1, streak 0, no misses, quota level 0
#   start_night() -> DayState                    a new game night: Day 1. Wallets (credits and
#       upgrades) are not touched by this module, so they are kept.
#   morning(s, crew_size) -> DayState            the crew that rides down this morning sets the quota
#   drop_out(s, crew_size_now) -> DayState       a friend leaves: the quota shrinks, never grows
#   first_floor_quota(floor_quota_per_player, crew_size) -> int
#   quota_for(level, crew_size, floor_quota_per_player) -> int
#       ceil((3 + level) x first floor quota / 2): 1.5 floor quotas at level 0, half a floor quota
#       more per made day, level capped at MAX_LEVEL (day 8 when every day is made). No dice.
#   day_quota(s, floor_quota_per_player) -> int  quota_for(s.level, s.crew_size, ...)
#   split_shares(total, crew, day) -> Dictionary {player: int}
#       Even split. total / n each; the remainder (total mod n) goes one credit each to the next
#       `remainder` players in sorted-id order, starting at index (day - 1) mod n, so the odd
#       credit rotates day by day. The shares always sum to total.
#   loss_odds(wallets) -> Dictionary             {"count": upgrades about to go, "text": "ann 1 in 3, bo 1 in 2" |
#       "nothing to take", "players": [{"player", "owned", "odds"}] (EACH_PLAYER_ONE: one per owner)}
#   take_by_roll(seed, day, wallets) -> Array[Dictionary]  [{"player": id, "node": id}], by LOSS_RULE
#   bank_preview(s, banked, wallets, floor_quota_per_player) -> Preview
#       What BANK would do right now, for the lift monitor and the quota board (promise 2: the
#       stakes and the odds are printed before the vote). end_day() always agrees with it.
#   end_day(s, banked, crew, wallets, floor_quota_per_player, seed) -> DayResult
#       Settles the day at BANK (or a wipe, banked 0). Pays every crew member their share into their
#       wallet. Made: streak + 1, level + 1 (capped). Missed: streak 0, misses + 1, one upgrade taken
#       from each player who owns any, by the seeded roll (none when nobody owns one); the third miss is game over: wallets reset to
#       empty and the state is start_night(). The returned state describes the NEXT day.
#   bunk_of(crew, player) -> Vector2i            the player's bunk cell (sim/prison.gd), sorted order
#
# Bedtime (section 6 and the owner's answer):
#   BedState.make(crew) -> BedState
#   climb_in(b, player, now) / climb_out(b, player, now) / leave(b, player, now) -> BedState
#       Refused (the same instance returned) after lights out, for strangers, or when nothing changes.
#       leave() is a player who quits the game: they leave the crew and the count.
#   more_than_half(in_count, crew_count) -> bool  2 x in > crew
#   lights_out_at(b) -> float                    the earlier of: the moment the count first went over half +
#       LIGHTS_OUT_DELAY, and the moment everyone currently in the crew is in bed; else INF.
#       The count, once started, is KEPT (owner's answer): climbing out or leaving the game never
#       stops or pauses it. Everyone in earlier means lights out at that moment.
#   is_lights_out(b, now) -> bool / seconds_left(b, now) -> float
#   assisted(b) -> Array[String]                 who is still up (sorted): "ASSISTED TO BED" at zero
#   count_text(b) -> String                      "IN BED 3 OF 4"
extends RefCounted

const Upgrades = preload("res://sim/upgrades.gd")
const Prison = preload("res://sim/prison.gd")

## Day 1 asks for (3 + 0) / 2 = 1.5 floor quotas; each made day adds half a floor quota.
const START_HALVES := 3
## The level stops here: day 8 when every day is made (level 0 on day 1).
const MAX_LEVEL := 7
## The third missed day of a night is game over.
const MISSES_FOR_GAME_OVER := 3
## Lights out this long after more than half the crew is in bed.
const LIGHTS_OUT_DELAY := 20.0
## How long the lights stay out before the next morning (a client concern, exported for it).
const LIGHTS_OUT_SECONDS := 5.0

enum LossRule { CREW_ONE, EACH_PLAYER_ONE }
## The reading of "an upgrade taken by roll" in force. See take_by_roll().
const LOSS_RULE := LossRule.EACH_PLAYER_ONE

## Separates player and node in a roll entry. Node ids never contain it.
const SEP := "|"

class DayState:
	## This night's day number, from 1.
	var day: int = 1
	## Days made in a row.
	var streak: int = 0
	## Days missed this game night.
	var misses: int = 0
	## Made days counted toward the quota, 0..MAX_LEVEL.
	var level: int = 0
	## The crew that rode down this morning (0 before morning()).
	var crew_size: int = 0

	static func fresh() -> DayState:
		return DayState.new()

	func copy() -> DayState:
		var s := DayState.new()
		s.day = day
		s.streak = streak
		s.misses = misses
		s.level = level
		s.crew_size = crew_size
		return s

## What BANK would do now.
class Preview:
	var day: int
	var quota: int
	var banked: int
	var made: bool
	## quota - banked when short, else 0.
	var short_by: int
	## Missed days this night if BANK now (misses + 1 when short).
	var misses_after: int
	## True when BANK now would be the third miss.
	var game_over: bool
	## How many upgrades BANK would take now: one per owner (EACH_PLAYER_ONE), or the pool size under
	## CREW_ONE (0 when made or game over).
	var at_stake: int
	## "ann 1 in 4, bo 1 in 2" (or "1 in 4" under CREW_ONE), "nothing to take", or "" when made or game over.
	var odds: String
	## Per owner, [{"player", "owned", "odds"}], sorted by player: each loses one of their own owned
	## upgrades at these odds. Empty when made, game over or nothing is owned (EACH_PLAYER_ONE only).
	var per_player: Array[Dictionary] = []
	## The monitor line, e.g. "BANK NOW: 640 OF 900. SHORT 260. EACH OWNER LOSES ONE UPGRADE: ANN 1 IN 4, BO 1 IN 2. MISS 1 OF 3."
	var text: String

class DayResult:
	## The NEXT day's state (Day 1 of a fresh run after game over).
	var state: DayState
	## {player: UpgradeState} after pay, any loss, or the game-over reset. New objects.
	var wallets: Dictionary = {}
	## &"made", &"missed" or &"game_over".
	var outcome: StringName
	var made: bool
	var game_over: bool
	var day: int
	var quota: int
	var banked: int
	var short_by: int
	## {player: int}, summing to banked.
	var shares: Dictionary = {}
	## One made day's pay for one player (banked / crew size), the unit upgrade prices use.
	var share: int
	## [{"player": id, "node": id}]; empty when made, game over or nothing was owned.
	var taken: Array[Dictionary] = []
	var odds: String
	## The facts the narrator's line is written from (see _facts()).
	var facts: Dictionary = {}

class BedState:
	var crew: Array[String] = []
	## Sorted ids of players in bed.
	var in_bed: Array[String] = []
	## When the count FIRST went over half, or -1. Kept for good: it is never cleared.
	var count_from: float = -1.0
	## When everyone was in, or -1.
	var all_in_at: float = -1.0

	static func make(crew_: Array[String]) -> BedState:
		var b := BedState.new()
		for p in crew_:
			if not b.crew.has(p):
				b.crew.append(p)
		b.crew.sort()
		return b

	func copy() -> BedState:
		var b := BedState.new()
		b.crew = crew.duplicate()
		b.in_bed = in_bed.duplicate()
		b.count_from = count_from
		b.all_in_at = all_in_at
		return b

# ---------------------------------------------------------------- the day state

static func start_night() -> DayState:
	return DayState.fresh()

static func morning(s: DayState, crew_size: int) -> DayState:
	var t := s.copy()
	t.crew_size = maxi(1, crew_size)
	return t

static func drop_out(s: DayState, crew_size_now: int) -> DayState:
	if crew_size_now >= s.crew_size or crew_size_now < 1:
		return s
	var t := s.copy()
	t.crew_size = crew_size_now
	return t

# ---------------------------------------------------------------- the quota

## C9's proposal: the floor quota grows with the size of the crew. Change here if it does not.
static func first_floor_quota(floor_quota_per_player: int, crew_size: int) -> int:
	return maxi(0, floor_quota_per_player) * maxi(1, crew_size)

static func quota_for(level: int, crew_size: int, floor_quota_per_player: int) -> int:
	var lv := clampi(level, 0, MAX_LEVEL)
	var halves := (START_HALVES + lv) * first_floor_quota(floor_quota_per_player, crew_size)
	return (halves + 1) / 2

static func day_quota(s: DayState, floor_quota_per_player: int) -> int:
	return quota_for(s.level, s.crew_size, floor_quota_per_player)

# ---------------------------------------------------------------- shares

static func split_shares(total: int, crew: Array[String], day: int) -> Dictionary:
	var ids := _sorted_unique(crew)
	var out := {}
	var n := ids.size()
	if n == 0:
		return out
	var amount := maxi(0, total)
	var base := amount / n
	var extra := amount % n
	var start := posmod(day - 1, n)
	for id in ids:
		out[id] = base
	for k in extra:
		var id: String = ids[(start + k) % n]
		out[id] = int(out[id]) + 1
	return out

static func _sorted_unique(list: Array[String]) -> Array[String]:
	var ids: Array[String] = []
	for p in list:
		if not ids.has(p):
			ids.append(p)
	ids.sort()
	return ids

# ---------------------------------------------------------------- the roll

static func _wallet(wallets: Dictionary, id: String) -> Upgrades.UpgradeState:
	var v: Variant = wallets.get(id, null)
	if v is Upgrades.UpgradeState:
		return v as Upgrades.UpgradeState
	return Upgrades.UpgradeState.make(0)

static func _ids(wallets: Dictionary) -> Array[String]:
	var ids: Array[String] = []
	for k: Variant in wallets.keys():
		ids.append(String(k))
	ids.sort()
	return ids

## Every upgrade the crew owns, as "player|node" entries, sorted.
static func crew_pool(wallets: Dictionary) -> Array[String]:
	var pool: Array[String] = []
	for id in _ids(wallets):
		for node_id in _wallet(wallets, id).owned:
			pool.append("%s%s%s" % [id, SEP, node_id])
	pool.sort()
	return pool

## The odds printed before BANK, under LOSS_RULE.
static func loss_odds(wallets: Dictionary) -> Dictionary:
	if LOSS_RULE == LossRule.CREW_ONE:
		var o := Upgrades.odds_before_roll(crew_pool(wallets))
		return {"count": int(o["count"]), "text": String(o["text"])}
	# EACH_PLAYER_ONE: every player who owns any loses one of their own, 1 in (their count).
	var count := 0
	var parts := PackedStringArray()
	var players: Array[Dictionary] = []
	for id in _ids(wallets):
		var n := _wallet(wallets, id).owned.size()
		if n > 0:
			count += 1
			parts.append("%s 1 in %d" % [id, n])
			players.append({"player": id, "owned": n, "odds": "1 in %d" % n})
	return {"count": count, "text": "nothing to take" if count == 0 else ", ".join(parts), "players": players}

## THE place that decides what a missed day takes. Seeded from the day's seed and day number only,
## so every player computes the same result; the order of `wallets` does not matter.
static func take_by_roll(seed_text: String, day: int, wallets: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if LOSS_RULE == LossRule.CREW_ONE:
		var entry := Upgrades.lose_one_by_roll(seed_text, day, crew_pool(wallets))
		if entry != "":
			var cut := entry.rfind(SEP)
			out.append({"player": entry.substr(0, cut), "node": entry.substr(cut + 1)})
		return out
	for id in _ids(wallets):
		var owned: Array[String] = _wallet(wallets, id).owned
		var node_id := Upgrades.lose_one_by_roll("%s:%s" % [seed_text, id], day, owned)
		if node_id != "":
			out.append({"player": id, "node": node_id})
	return out

# ---------------------------------------------------------------- BANK

static func bank_preview(s: DayState, banked: int, wallets: Dictionary, floor_quota_per_player: int) -> Preview:
	var p := Preview.new()
	p.day = s.day
	p.quota = day_quota(s, floor_quota_per_player)
	p.banked = maxi(0, banked)
	p.made = p.banked >= p.quota
	p.short_by = 0 if p.made else p.quota - p.banked
	p.misses_after = s.misses if p.made else s.misses + 1
	p.game_over = not p.made and p.misses_after >= MISSES_FOR_GAME_OVER
	p.at_stake = 0
	p.odds = ""
	if not p.made and not p.game_over:
		var o := loss_odds(wallets)
		p.at_stake = int(o["count"])
		p.odds = String(o["text"])
		for k: Dictionary in o.get("players", []):
			p.per_player.append(k)
	var line := "BANK NOW: %d OF %d." % [p.banked, p.quota]
	if p.made:
		line += " MADE."
	elif p.game_over:
		line += " SHORT %d. THIRD MISS: GAME OVER." % p.short_by
	elif p.at_stake == 0:
		line += " SHORT %d. NOTHING TO TAKE. MISS %d OF %d." % [p.short_by, p.misses_after, MISSES_FOR_GAME_OVER]
	else:
		line += " SHORT %d. %s MISS %d OF %d." % [p.short_by, _stake_text(p, wallets.size()), p.misses_after, MISSES_FOR_GAME_OVER]
	p.text = line
	return p

## The stakes sentence on the lift monitor. Short: the odds are listed when three or fewer players
## stand to lose one; the full per-player odds are in Preview.per_player for the quota board.
static func _stake_text(p: Preview, player_count: int) -> String:
	if LOSS_RULE == LossRule.CREW_ONE:
		return "ONE UPGRADE LOST, %s." % p.odds.to_upper()
	var who := "EACH OF YOU" if p.at_stake >= player_count else "EACH OWNER"
	var text := "%s LOSES ONE UPGRADE" % who
	if p.at_stake <= 3:
		return "%s: %s." % [text, p.odds.to_upper()]
	return text + "."

static func end_day(s: DayState, banked: int, crew: Array[String], wallets: Dictionary, floor_quota_per_player: int, seed_text: String) -> DayResult:
	var pv := bank_preview(s, banked, wallets, floor_quota_per_player)
	var r := DayResult.new()
	r.day = s.day
	r.quota = pv.quota
	r.banked = pv.banked
	r.made = pv.made
	r.short_by = pv.short_by
	r.game_over = pv.game_over
	r.odds = pv.odds
	var crew_ids := _sorted_unique(crew)
	r.shares = split_shares(pv.banked, crew_ids, s.day)
	r.share = 0 if crew_ids.is_empty() else pv.banked / crew_ids.size()

	# Everyone in the wallets or the crew, paid.
	var ids := _ids(wallets)
	for id in crew_ids:
		if not ids.has(id):
			ids.append(id)
	ids.sort()
	var paid := {}
	for id in ids:
		paid[id] = Upgrades.add_credits(_wallet(wallets, id), int(r.shares.get(id, 0)))

	var t := s.copy()
	if pv.made:
		r.outcome = &"made"
		t.day += 1
		t.streak += 1
		t.level = mini(t.level + 1, MAX_LEVEL)
		r.wallets = paid
	elif pv.game_over:
		r.outcome = &"game_over"
		t = start_night()
		var reset := {}
		for id in ids:
			reset[id] = Upgrades.UpgradeState.make(0)
		r.wallets = reset
	else:
		r.outcome = &"missed"
		t.day += 1
		t.streak = 0
		t.misses += 1
		# The roll is over what was owned when BANK was pressed: the same pool the preview counted.
		r.taken = take_by_roll(seed_text, s.day, wallets)
		for k: Dictionary in r.taken:
			var pid: String = k["player"]
			paid[pid] = Upgrades.apply_loss(_wallet(paid, pid), String(k["node"]))
		r.wallets = paid
	r.state = t
	r.facts = _facts(s, r)
	return r

## What the narrator's line (on screen and spoken) is written from. Facts only; the wording is the
## announcer's. "misses_left" is how many more misses this night the crew can take.
static func _facts(s: DayState, r: DayResult) -> Dictionary:
	var f := {
		"kind": String(r.outcome),
		"day": r.day,
		"quota": r.quota,
		"banked": r.banked,
		"short_by": r.short_by,
		"streak": r.state.streak if r.made else 0,
		"misses": s.misses + (0 if r.made else 1),
		"misses_left": maxi(0, MISSES_FOR_GAME_OVER - s.misses - (0 if r.made else 1)),
		"odds": r.odds,
		"taken": [],
	}
	var taken: Array = []
	for k: Dictionary in r.taken:
		var n := Upgrades.node(String(k["node"]))
		taken.append({"player": k["player"], "node": k["node"], "name": String(n.get("name", k["node"]))})
	f["taken"] = taken
	return f

static func bunk_of(crew: Array[String], player: String) -> Vector2i:
	var ids := _sorted_unique(crew)
	var i := ids.find(player)
	var bunks := Prison.bunk_positions()
	if i < 0 or bunks.is_empty():
		return Vector2i(-1, -1)
	return bunks[i % bunks.size()]

# ---------------------------------------------------------------- bedtime

static func more_than_half(in_count: int, crew_count: int) -> bool:
	return 2 * in_count > crew_count

static func lights_out_at(b: BedState) -> float:
	var at := INF
	if b.all_in_at >= 0.0:
		at = b.all_in_at
	if b.count_from >= 0.0:
		at = minf(at, b.count_from + LIGHTS_OUT_DELAY)
	return at

static func is_lights_out(b: BedState, now: float) -> bool:
	return now >= lights_out_at(b)

static func seconds_left(b: BedState, now: float) -> float:
	return maxf(0.0, lights_out_at(b) - now)

static func assisted(b: BedState) -> Array[String]:
	var out: Array[String] = []
	for p in b.crew:
		if not b.in_bed.has(p):
			out.append(p)
	return out

static func count_text(b: BedState) -> String:
	return "IN BED %d OF %d" % [b.in_bed.size(), b.crew.size()]

## Re-reads the count after a change at `now`.
static func _settle(b: BedState, now: float) -> void:
	if b.in_bed.size() >= b.crew.size():
		if b.all_in_at < 0.0:
			b.all_in_at = now
	else:
		b.all_in_at = -1.0
	# The count starts the first time more than half are in and is never cleared: nobody can stop it
	# by climbing out or leaving the game.
	if b.count_from < 0.0 and more_than_half(b.in_bed.size(), b.crew.size()):
		b.count_from = now

static func climb_in(b: BedState, player: String, now: float) -> BedState:
	if is_lights_out(b, now) or not b.crew.has(player) or b.in_bed.has(player):
		return b
	var t := b.copy()
	t.in_bed.append(player)
	t.in_bed.sort()
	_settle(t, now)
	return t

static func climb_out(b: BedState, player: String, now: float) -> BedState:
	if is_lights_out(b, now) or not b.in_bed.has(player):
		return b
	var t := b.copy()
	t.in_bed.erase(player)
	_settle(t, now)
	return t

static func leave(b: BedState, player: String, now: float) -> BedState:
	if is_lights_out(b, now) or not b.crew.has(player):
		return b
	var t := b.copy()
	t.crew.erase(player)
	t.in_bed.erase(player)
	_settle(t, now)
	return t
