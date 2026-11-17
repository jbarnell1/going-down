# The day's guarantees over seeded random days (sim/day.gd): shares always sum to what was banked
# (what was aboard), also when that is less than what was earned; BANK is locked exactly while earned is
# under the quota, at every level and crew size, and a BANK that is not locked is always made and pays
# what was aboard (FD1, docs/floors/findables-and-day.md section 1); a made day never takes an upgrade; a
# wipe is the missed day: it never raises the level, always adds one miss, and takes exactly one of their
# OWN upgrades from EVERY player who owns any (nothing from those who own none), and every player
# computes the same ones; the third miss of a night is game over and resets to a fresh Day 1 with empty
# wallets; the quota is deterministic, ignores the seed, grows only on made days and stops at day 8; the
# BANK preview (the monitor's three rows) always agrees with what BANK or a wipe then does; no call edits
# what it was given; and lights go out exactly 20 s after more than half the crew is in bed, never
# before, and at once when everyone is in; once the count has started it cannot be stopped by climbing
# out or leaving. A run without the lock passes earned = banked: a short BANK is then a missed day, as
# before FD1.
extends RefCounted

const T = preload("res://tests/t.gd")
const Rng = preload("res://sim/rng.gd")
const Day = preload("res://sim/day.gd")
const Upgrades = preload("res://sim/upgrades.gd")

const NAMES: Array[String] = ["ann", "bo", "cy", "di", "ed", "flo", "gus", "hal"]

func _node_ids() -> Array[String]:
	var out: Array[String] = []
	for n in Upgrades.nodes():
		out.append(String(n["id"]))
	return out

func _crew(rng: Rng, n: int) -> Array[String]:
	var pool: Array[String] = NAMES.duplicate()
	var out: Array[String] = []
	for _i in n:
		var k := rng.int_in(0, pool.size() - 1)
		out.append(pool[k])
		pool.remove_at(k)
	return out

## Random wallets for a crew: some credits, a random set of owned nodes (owned order shuffled).
func _wallets(rng: Rng, crew: Array[String], own_chance: float) -> Dictionary:
	var ids := _node_ids()
	var w := {}
	for p in crew:
		var s := Upgrades.UpgradeState.make(rng.int_in(0, 500))
		for id in ids:
			if rng.chance(own_chance):
				s.owned.append(id)
		_shuffle(rng, s.owned)
		w[p] = s
	return w

func _shuffle(rng: Rng, a: Array[String]) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.int_in(0, i)
		var tmp := a[i]
		a[i] = a[j]
		a[j] = tmp

func _state(day: int, streak: int, misses: int, level: int, crew_size: int) -> Day.DayState:
	var s := Day.DayState.fresh()
	s.day = day
	s.streak = streak
	s.misses = misses
	s.level = level
	s.crew_size = crew_size
	return s

func _random_state(rng: Rng, crew_size: int) -> Day.DayState:
	return _state(rng.int_in(1, 12), rng.int_in(0, 8), rng.int_in(0, 2), rng.int_in(0, Day.MAX_LEVEL), crew_size)

## Banked pay near the quota, hitting the edges (exactly the quota, one short) often.
func _banked(rng: Rng, quota: int) -> int:
	var pick := rng.int_in(0, 5)
	if pick == 0:
		return 0
	if pick == 1:
		return quota
	if pick == 2:
		return maxi(0, quota - 1)
	return rng.int_in(0, quota * 2 + 5)

func _fp_state(s: Day.DayState) -> String:
	return "%d/%d/%d/%d/%d" % [s.day, s.streak, s.misses, s.level, s.crew_size]

func _fp_wallets(w: Dictionary) -> String:
	var keys: Array[String] = []
	for k: Variant in w.keys():
		keys.append(String(k))
	keys.sort()
	var parts := PackedStringArray()
	for k in keys:
		var s: Upgrades.UpgradeState = w[k]
		var owned: Array[String] = s.owned.duplicate()
		owned.sort()
		parts.append("%s:%d:%s:%s" % [k, s.credits, ",".join(owned), str(s.in_bed)])
	return "|".join(parts)

func _owned_count(w: Dictionary) -> int:
	var n := 0
	for k: Variant in w.keys():
		var s: Upgrades.UpgradeState = w[k]
		n += s.owned.size()
	return n

func test_shares_sum_to_the_banked_total(t: T) -> void:
	var rng := Rng.make_rng("day-shares")
	var runs := 500 if t.quick else 3000
	for i in runs:
		var crew := _crew(rng, rng.int_in(1, 8))
		var total := rng.int_in(0, 100000) if rng.chance(0.8) else rng.int_in(0, 10)
		var day := rng.int_in(1, 30)
		var shares := Day.split_shares(total, crew, day)
		var sum := 0
		var lo := 1 << 60
		var hi := -1
		for p in crew:
			var v := int(shares.get(p, -1))
			sum += v
			lo = mini(lo, v)
			hi = maxi(hi, v)
		t.eq(sum, total, "case %d: shares sum" % i)
		t.eq(shares.size(), crew.size(), "case %d: one share per crew member" % i)
		t.check(hi - lo <= 1 and lo == total / crew.size(), "case %d: even split, %d..%d for %d over %d" % [i, lo, hi, total, crew.size()])
		t.check(Day.split_shares(total, crew, day) == shares, "case %d: same inputs, same split" % i)
	# The odd credit rotates: over n days of a total of n + 1 each player gets the extra once.
	var crew4: Array[String] = ["di", "ann", "cy", "bo"]
	var got := {}
	for d in range(1, 5):
		var sh := Day.split_shares(5, crew4, d)
		for p in crew4:
			if int(sh[p]) == 2:
				got[p] = int(got.get(p, 0)) + 1
	t.eq(got.size(), 4, "the remainder credit rotates through all four over four days")
	# Through end_day: every wallet gains exactly its share of what was aboard, made or missed, also when
	# aboard is less than earned (tapes dropped or left behind after they were recorded); a wipe pays nothing.
	var under := 0
	for i in (100 if t.quick else 600):
		var crew := _crew(rng, rng.int_in(1, 6))
		var w := _wallets(rng, crew, 0.3)
		var s := _random_state(rng, crew.size())
		var fq := rng.int_in(1, 300)
		var q := Day.day_quota(s, fq)
		var earned := _banked(rng, q)
		var aboard := rng.int_in(0, earned) if rng.chance(0.6) else _banked(rng, q)
		var wiped := rng.chance(0.2)
		if aboard < earned and not wiped:
			under += 1
		var r := Day.end_day(s, aboard, earned, crew, w, fq, "seed-%d" % i, wiped)
		var sum := 0
		for p in crew:
			sum += int(r.shares[p])
			if not r.game_over:
				var before: Upgrades.UpgradeState = w[p]
				var after: Upgrades.UpgradeState = r.wallets[p]
				t.eq(after.credits - before.credits, int(r.shares[p]), "day %d: %s paid their share" % [i, p])
		t.eq(r.banked, 0 if wiped else aboard, "day %d: what was aboard is what is paid (nothing at a wipe)" % i)
		t.eq(sum, r.banked, "day %d: end_day shares sum to the banked total" % i)
	t.check(under > 10, "not vacuous: %d days banked less than they earned" % under)

func test_locked_exactly_while_earned_is_under_the_quota(t: T) -> void:
	# Every level and crew size, at the edges: locked is false exactly when earned is at or over the quota.
	var w := {}
	var cases := 0
	for lv in range(0, Day.MAX_LEVEL + 3):
		for n in range(1, 9):
			var crew := NAMES.slice(0, n)
			for fq: int in [1, 7, 100, 333, 400]:
				var s := _state(1 + lv, lv, 0, lv, n)
				var q := Day.day_quota(s, fq)
				for earned: int in [0, maxi(0, q - 1), q, q + 1, q * 3]:
					cases += 1
					var tag := "level %d crew %d fq %d earned %d of %d" % [lv, n, fq, earned, q]
					t.eq(Day.is_locked(earned, q), earned < q, tag + ": is_locked")
					# Aboard is anything: a crew that dropped its tapes after earning enough is not locked.
					for aboard: int in [0, earned / 3, earned]:
						var p := Day.bank_preview(s, aboard, earned, crew, w, fq)
						t.eq(p.locked, earned < q, tag + " aboard %d: locked" % aboard)
						t.eq(p.made, earned >= q, tag + " aboard %d: BANK now makes the day" % aboard)
						t.eq(p.short_by, maxi(0, q - earned), tag + ": to go")
						t.eq(p.rows[1], ("BANK LOCKED. %d TO GO." % (q - earned)) if earned < q else ("BANK OPEN. ABOARD %d. EACH GETS %d." % [aboard, aboard / n]), tag + ": row 2")
	t.note("%d (level, crew, quota, earned) cases: locked exactly while earned < quota, whatever was aboard" % cases)
	# The owner's case: the crew earned the quota, then lost most of it (a dropped tape, a friend left
	# behind). BANK is open, the day is made, and it pays what came back.
	var crew3: Array[String] = ["ann", "bo", "cy"]
	var s3 := _state(2, 1, 0, 1, 3)
	var q3 := Day.day_quota(s3, 400)
	var r := Day.end_day(s3, 90, q3 + 50, crew3, {}, 400, "dropped")
	t.check(r.made and r.outcome == &"made", "earned enough, then dropped a tape: still made (%s)" % r.outcome)
	t.eq(r.banked, 90, "it pays what was aboard")
	t.eq(r.state.level, s3.level + 1, "a made day raises the level")

func test_without_the_lock_a_short_bank_is_the_missed_day_it_was(t: T) -> void:
	# A run without the lock passes earned = banked: the rule before FD1, unchanged.
	var rng := Rng.make_rng("day-nolock")
	for i in (100 if t.quick else 500):
		var crew := _crew(rng, rng.int_in(1, 6))
		var w := _wallets(rng, crew, 0.4)
		var s := _state(rng.int_in(1, 12), rng.int_in(0, 5), rng.int_in(0, 1), rng.int_in(0, Day.MAX_LEVEL), crew.size())
		var fq := rng.int_in(1, 300)
		var q := Day.day_quota(s, fq)
		var banked := _banked(rng, q)
		var r := Day.end_day(s, banked, banked, crew, w, fq, "nolock-%d" % i)
		t.eq(r.made, banked >= q, "case %d: banked %d of %d: made exactly when banked reaches the quota" % [i, banked, q])
		t.eq(r.banked, banked, "case %d: a short BANK still pays what was banked" % i)
		t.eq(r.short_by, maxi(0, q - banked), "case %d: short by" % i)
		t.eq(r.state.misses, s.misses + (0 if r.made else 1), "case %d: a short BANK is a miss" % i)

func test_a_made_day_never_takes_an_upgrade(t: T) -> void:
	var rng := Rng.make_rng("day-made")
	var runs := 200 if t.quick else 1000
	var made := 0
	for i in runs:
		var crew := _crew(rng, rng.int_in(1, 6))
		var w := _wallets(rng, crew, 0.5)
		var s := _random_state(rng, crew.size())
		var fq := rng.int_in(1, 300)
		var q := Day.day_quota(s, fq)
		# Earned at least the quota; aboard anything (even short of the quota): a BANK the lock lets
		# through is always made.
		var r := Day.end_day(s, rng.int_in(0, 2 * q), q + rng.int_in(0, q), crew, w, fq, "made-%d" % i)
		t.check(r.made and r.outcome == &"made" and not r.game_over, "day %d: earned at least the quota" % i)
		t.check(r.taken.is_empty(), "day %d: a made day took %s" % [i, str(r.taken)])
		t.eq(_owned_count(r.wallets), _owned_count(w), "day %d: upgrades owned" % i)
		t.check(r.state.misses == s.misses and r.state.streak == s.streak + 1 and r.state.day == s.day + 1, "day %d: streak up, misses kept" % i)
		made += 1
	t.note("%d made days, none took an upgrade" % made)

func test_a_missed_day_takes_one_upgrade_from_each_owner_the_same_for_everyone(t: T) -> void:
	t.eq(Day.LOSS_RULE, Day.LossRule.EACH_PLAYER_ONE, "the owner's answer: one upgrade from EVERY player who owns any")
	var rng := Rng.make_rng("day-missed")
	var runs := 200 if t.quick else 1500
	var took := 0
	var several := 0
	var empty := 0
	for i in runs:
		var crew := _crew(rng, rng.int_in(1, 6))
		var w := _wallets(rng, crew, 0.0 if rng.chance(0.15) else 0.3)
		# Some players own nothing at all.
		for p in crew:
			if rng.chance(0.25):
				w[p] = Upgrades.UpgradeState.make((w[p] as Upgrades.UpgradeState).credits)
		var s := _state(rng.int_in(1, 12), rng.int_in(0, 5), rng.int_in(0, 1), rng.int_in(0, Day.MAX_LEVEL), crew.size())
		var fq := rng.int_in(1, 300)
		var q := Day.day_quota(s, fq)
		var seed_text := "miss-%d" % i
		# A wipe: nobody came back. Earned anything (even over the quota): the day is missed all the same.
		var earned := rng.int_in(0, 2 * q)
		var r := Day.end_day(s, rng.int_in(0, q), earned, crew, w, fq, seed_text, true)
		t.check(not r.made and r.outcome == &"missed", "day %d: a wipe is a missed day" % i)
		t.eq(r.banked, 0, "day %d: a wipe pays nothing" % i)
		for p in crew:
			t.eq(int(r.shares[p]), 0, "day %d: %s is paid nothing at a wipe" % [i, p])
		var owners := 0
		var taken_by := {}
		for k: Dictionary in r.taken:
			t.check(not taken_by.has(k["player"]), "day %d: %s lost two" % [i, k["player"]])
			taken_by[k["player"]] = String(k["node"])
		for p in crew:
			var before: Upgrades.UpgradeState = w[p]
			var after: Upgrades.UpgradeState = r.wallets[p]
			if before.owned.is_empty():
				t.check(not taken_by.has(p) and after.owned.is_empty(), "day %d: %s owns none and loses nothing" % [i, p])
				continue
			owners += 1
			if not t.check(taken_by.has(p), "day %d: %s owns %d and lost none" % [i, p, before.owned.size()]):
				continue
			var node_id: String = taken_by[p]
			t.check(before.owned.has(node_id) and not after.owned.has(node_id), "day %d: %s owned %s and lost it" % [i, p, node_id])
			t.eq(after.owned.size(), before.owned.size() - 1, "day %d: %s lost exactly one" % [i, p])
		t.eq(r.taken.size(), owners, "day %d: one loss per owner" % i)
		t.eq(r.facts["taken"].size(), owners, "day %d: the narrator is told every loss" % i)
		if owners == 0:
			empty += 1
		else:
			took += 1
			if owners > 1:
				several += 1
		t.check(r.state.streak == 0 and r.state.misses == s.misses + 1 and r.state.level == s.level, "day %d: streak 0, one more miss, quota level kept" % i)
		# Every player computes the roll on their own machine, wallets and upgrades arriving in any order.
		var other := {}
		var order: Array[String] = crew.duplicate()
		_shuffle(rng, order)
		for p in order:
			var src: Upgrades.UpgradeState = w[p]
			var c := src.copy()
			_shuffle(rng, c.owned)
			other[p] = c
		var again := Day.end_day(s, r.banked, earned, order, other, fq, seed_text, true)
		t.check(str(again.taken) == str(r.taken), "day %d: the roll differs by order: %s vs %s" % [i, str(again.taken), str(r.taken)])
		t.eq(_fp_wallets(again.wallets), _fp_wallets(r.wallets), "day %d: the same wallets after" % i)
	t.check(took > runs / 2 and several > runs / 5 and empty > 0, "not vacuous: %d took, %d took from several players, %d had nothing" % [took, several, empty])
	t.note("%d missed days: %d took upgrades (%d from several players), %d had none to take" % [runs, took, several, empty])

func test_the_third_miss_is_game_over_and_resets_but_deletes_nothing(t: T) -> void:
	var rng := Rng.make_rng("day-over")
	var runs := 100 if t.quick else 600
	for i in runs:
		var crew := _crew(rng, rng.int_in(1, 6))
		var w := _wallets(rng, crew, 0.5)
		var s := _state(rng.int_in(3, 12), rng.int_in(0, 3), 2, rng.int_in(0, Day.MAX_LEVEL), crew.size())
		var fq := rng.int_in(1, 300)
		var r := Day.end_day(s, 0, rng.int_in(0, 2 * Day.day_quota(s, fq)), crew, w, fq, "over-%d" % i, true)
		t.check(r.game_over and r.outcome == &"game_over", "case %d: the third miss (a wipe) is game over" % i)
		t.eq(_fp_state(r.state), _fp_state(Day.start_night()), "case %d: the next state is a fresh Day 1" % i)
		t.check(r.taken.is_empty(), "case %d: no roll on game over" % i)
		t.eq(r.wallets.size(), crew.size(), "case %d: every player still has a wallet (nothing deleted)" % i)
		for p in crew:
			var after: Upgrades.UpgradeState = r.wallets[p]
			t.check(after.credits == 0 and after.owned.is_empty(), "case %d: %s reset to no credits, no upgrades" % [i, p])
	# A night played out: game over comes exactly on the third miss, never earlier; a new night
	# clears the misses but keeps the wallets.
	for i in (40 if t.quick else 200):
		var crew := _crew(rng, rng.int_in(1, 5))
		var w := _wallets(rng, crew, 0.6)
		var s := Day.morning(Day.start_night(), crew.size())
		var misses := 0
		var fq := 100
		for d in 30:
			var q := Day.day_quota(s, fq)
			var short := rng.chance(0.35)
			# A wipe or a BANK the lock let through (earned at least the quota, aboard anything).
			var r := Day.end_day(s, rng.int_in(0, 2 * q), q + rng.int_in(0, 50), crew, w, fq, "night-%d-%d" % [i, d], short)
			if short:
				misses += 1
			t.eq(r.game_over, misses == 3, "night %d day %d: game over exactly on the third miss" % [i, d])
			if r.game_over:
				break
			t.eq(r.state.misses, misses, "night %d day %d: misses counted" % [i, d])
			s = Day.morning(r.state, crew.size())
			w = r.wallets
			if misses == 2 and rng.chance(0.3):
				var kept := _fp_wallets(w)
				s = Day.morning(Day.start_night(), crew.size())
				misses = 0
				t.check(s.day == 1 and s.misses == 0 and s.level == 0 and s.streak == 0, "night %d: a new night is Day 1" % i)
				t.eq(_fp_wallets(w), kept, "night %d: a new night keeps credits and upgrades" % i)

func test_the_quota_is_set_by_rule_grows_only_on_made_days_and_stops_at_day_8(t: T) -> void:
	# The rule in closed form: 1.5 first-floor quotas on day 1, half a floor quota per made day.
	for n in range(1, 9):
		for fq: int in [1, 7, 100, 333]:
			var floor_q := fq * n
			t.eq(Day.quota_for(0, n, fq), (3 * floor_q + 1) / 2, "day 1 is 1.5 floor quotas (crew %d, fq %d)" % [n, fq])
			for lv in range(0, 12):
				t.eq(Day.quota_for(lv, n, fq), ((3 + mini(lv, 7)) * floor_q + 1) / 2, "level %d crew %d fq %d" % [lv, n, fq])
	t.eq(Day.quota_for(0, 4, 100), 600, "four players, 100 a floor each: 600 on day 1")
	t.eq(Day.quota_for(7, 4, 100), 2000, "the cap: five floor quotas")
	t.check(Day.quota_for(0, 3, 100) < Day.quota_for(0, 4, 100), "a smaller crew owes less")
	var s4 := Day.morning(Day.start_night(), 4)
	var dropped := Day.drop_out(s4, 3)
	t.check(Day.day_quota(dropped, 100) < Day.day_quota(s4, 100), "a friend drops out: the quota shrinks")
	t.check(Day.drop_out(dropped, 4) == dropped, "it never grows during the day")
	# Played out over random nights: the quota moves only on made days, and stops at day 8.
	var rng := Rng.make_rng("day-quota")
	for i in (60 if t.quick else 300):
		var crew := _crew(rng, rng.int_in(1, 6))
		var w := _wallets(rng, crew, 0.0)
		var fq := rng.int_in(1, 200)
		var s := Day.morning(Day.start_night(), crew.size())
		var made_days := 0
		for d in 20:
			var q := Day.day_quota(s, fq)
			t.eq(q, Day.quota_for(mini(made_days, 7), crew.size(), fq), "run %d day %d: quota from made days only" % [i, d])
			var miss := rng.chance(0.25) and s.misses < 2
			var banked := rng.int_in(0, 2 * q)
			var earned := q + rng.int_in(0, 40) if not miss or rng.chance(0.5) else rng.int_in(0, q - 1)
			var r := Day.end_day(s, banked, earned, crew, w, fq, "q-%d-%d" % [i, d], miss)
			var r2 := Day.end_day(s, banked, earned, crew, w, fq, "a different seed %d" % d, miss)
			t.eq(_fp_state(r2.state), _fp_state(r.state), "run %d day %d: the seed does not change the day's numbers" % [i, d])
			t.eq(r2.quota, r.quota, "run %d day %d: no dice in the quota" % [i, d])
			var next_q := Day.day_quota(Day.morning(r.state, crew.size()), fq)
			if miss:
				t.eq(next_q, q, "run %d day %d: a wipe does not raise it" % [i, d])
				t.eq(r.state.level, s.level, "run %d day %d: a wipe never raises the level" % [i, d])
				t.eq(r.state.misses, s.misses + 1, "run %d day %d: a wipe adds one miss" % [i, d])
			else:
				made_days += 1
				if made_days <= 7:
					t.check(next_q > q, "run %d day %d: a made day raises it" % [i, d])
				else:
					t.eq(next_q, q, "run %d day %d: past day 8 it stops" % [i, d])
			s = Day.morning(r.state, crew.size())

func test_bank_preview_agrees_with_end_day(t: T) -> void:
	var rng := Rng.make_rng("day-preview")
	var runs := 400 if t.quick else 4000
	var shorts := 0
	var overs := 0
	for i in runs:
		var crew := _crew(rng, rng.int_in(1, 7))
		var w := _wallets(rng, crew, 0.0 if rng.chance(0.1) else rng.next() * 0.7)
		var s := _random_state(rng, crew.size())
		var fq := rng.int_in(1, 400)
		var q := Day.day_quota(s, fq)
		var earned := _banked(rng, q)
		# Aboard: what earned left after drops, or (a run without the lock) the same as earned.
		var banked := earned if rng.chance(0.3) else rng.int_in(0, earned)
		var wiped := rng.chance(0.3)
		var p := Day.bank_preview(s, banked, earned, crew, w, fq)
		var r := Day.end_day(s, banked, earned, crew, w, fq, "pv-%d" % i, wiped)
		var tag := "day %d (earned %d, aboard %d of %d, misses %d, %s)" % [i, earned, banked, r.quota, s.misses, "wipe" if wiped else "BANK"]
		t.eq(p.quota, r.quota, tag + ": quota")
		t.eq(p.earned, r.earned, tag + ": earned")
		t.eq(p.locked, earned < q, tag + ": locked")
		t.eq(r.made, p.made and not wiped, tag + ": made: a BANK the preview shows open, and never a wipe")
		if not r.made:
			t.eq(p.game_over, r.game_over, tag + ": game over")
			t.eq(p.odds, r.odds, tag + ": odds")
			t.eq(r.short_by, maxi(0, q - earned), tag + ": short by is the real shortfall")
			if not r.game_over:
				t.eq(p.misses_after, r.state.misses, tag + ": misses after")
		else:
			t.eq(r.short_by, 0, tag + ": a made day is short of nothing")
			# The shares are the even split the monitor printed: each gets EACH GETS, or one credit more.
			for id in crew:
				var got := int(r.shares[id])
				t.check(got == p.each or got == p.each + 1, tag + ": %s got %d, the monitor said %d each" % [id, got, p.each])
		# The monitor's rows.
		t.eq(p.rows.size(), 3, tag + ": three rows")
		t.eq(p.rows[0], "DAY %d. EARNED %d OF %d." % [s.day, earned, q], tag + ": row 1")
		t.check(p.rows[2].begins_with("IF NOBODY COMES BACK: "), tag + ": row 3: " + p.rows[2])
		if p.game_over:
			t.eq(p.rows[2], "IF NOBODY COMES BACK: THIRD MISS: GAME OVER.", tag + ": row 3 on the last miss")
		else:
			t.check(p.rows[2].ends_with("MISS %d OF %d." % [s.misses + 1, Day.MISSES_FOR_GAME_OVER]), tag + ": row 3's miss count: " + p.rows[2])
		t.eq(Day.monitor_rows(s.day, earned, q, banked, p.each, p.rows[2]), p.rows, tag + ": the rows from the numbers are the preview's")
		if not r.made and not p.game_over:
			shorts += 1
			var owners: Array[String] = []
			for id in crew:
				if not (w[id] as Upgrades.UpgradeState).owned.is_empty():
					owners.append(id)
			t.eq(p.at_stake, owners.size(), tag + ": the stake is one upgrade per owner")
			t.eq(r.taken.size(), p.at_stake, tag + ": the preview's stake is what was taken")
			t.eq(p.per_player.size(), owners.size(), tag + ": the odds list every owner")
			var parts: Array[String] = []
			for k: Dictionary in p.per_player:
				var n := (w[k["player"]] as Upgrades.UpgradeState).owned.size()
				t.eq(k["owned"], n, tag + ": %s's pool" % k["player"])
				t.eq(k["odds"], "1 in %d" % n, tag + ": %s's printed odds" % k["player"])
				parts.append("%s 1 in %d" % [k["player"], n])
			if p.at_stake == 0:
				t.eq(p.odds, "nothing to take", tag + ": nothing to take")
				t.check(p.text.contains("NOTHING TO TAKE"), tag + ": the monitor says so: " + p.text)
			else:
				t.eq(p.odds, ", ".join(parts), tag + ": printed odds")
				t.check(p.text.contains("LOSES ONE UPGRADE"), tag + ": the monitor states the stakes: " + p.text)
				if p.at_stake <= 3:
					t.check(p.text.contains(p.odds.to_upper()), tag + ": the odds are on the monitor: " + p.text)
				t.check(("EACH OF YOU" if p.at_stake >= crew.size() else "EACH OWNER") in p.text, tag + ": who loses: " + p.text)
		else:
			t.check(r.taken.is_empty(), tag + ": a made day or game over takes nothing")
			if p.game_over:
				t.eq(p.at_stake, 0, tag + ": nothing at stake on the last miss")
		if p.game_over and not r.made:
			overs += 1
	t.check(shorts > runs / 5 and overs > 0, "not vacuous: %d missed days, %d game overs" % [shorts, overs])
	t.note("%d random days, preview matched end_day every time (%d missed, %d game over)" % [runs, shorts, overs])

func test_a_missed_day_with_nothing_owned_says_nothing_to_take_and_players_without_upgrades_lose_nothing(t: T) -> void:
	var crew: Array[String] = ["ann", "bo", "cy"]
	var fq := 100
	var s := _state(3, 1, 0, 2, crew.size())
	var q := Day.day_quota(s, fq)
	# Nobody owns anything: the odds, the monitor and the roll all say nothing is at stake.
	var empty := {}
	for p in crew:
		empty[p] = Upgrades.UpgradeState.make(50)
	var o := Day.loss_odds(empty)
	t.eq(int(o["count"]), 0, "nobody owns anything: loss_odds counts none at stake")
	t.eq(String(o["text"]), "nothing to take", "nobody owns anything: loss_odds text")
	t.check((o.get("players", []) as Array).is_empty(), "nobody owns anything: loss_odds lists no players")
	var pv := Day.bank_preview(s, q - 1, q - 1, crew, empty, fq)
	t.check(not pv.made and not pv.game_over, "short of the quota, not the third miss")
	t.eq(pv.at_stake, 0, "preview: nothing at stake")
	t.check(pv.per_player.is_empty(), "preview: per_player is empty")
	t.eq(pv.odds, "nothing to take", "preview: odds say nothing to take")
	t.check(pv.text.contains("NOTHING TO TAKE") and not pv.text.contains("LOSES ONE UPGRADE"), "the monitor says NOTHING TO TAKE: " + pv.text)
	var r := Day.end_day(s, 0, q - 1, crew, empty, fq, "nothing-owned", true)
	t.check(r.taken.is_empty() and r.facts["taken"].is_empty(), "end_day took nothing and told the narrator nothing")
	t.check(r.outcome == &"missed" and not r.made and not r.game_over, "it still counts as a missed day")
	t.eq(r.state.misses, s.misses + 1, "the miss is counted")
	t.eq(r.state.streak, 0, "the streak is broken")
	t.eq(_owned_count(r.wallets), 0, "no upgrades appear or vanish")
	t.eq(r.odds, pv.odds, "the result's odds are the preview's")
	# A mixed crew: bo and cy own nothing, ann owns three. Only ann is listed, only ann can lose.
	var mixed := empty.duplicate()
	var ann := Upgrades.UpgradeState.make(50)
	var ids := _node_ids()
	ann.owned.append(ids[0])
	ann.owned.append(ids[1])
	ann.owned.append(ids[2])
	mixed["ann"] = ann
	var mp := Day.bank_preview(s, q - 1, q - 1, crew, mixed, fq)
	t.eq(mp.at_stake, 1, "mixed: one owner at stake")
	t.eq(mp.per_player.size(), 1, "mixed: only the owner is listed")
	t.eq(String(mp.per_player[0]["player"]), "ann", "mixed: ann is the one listed")
	t.eq(mp.odds, "ann 1 in 3", "mixed: the printed odds")
	t.check(mp.text.contains("EACH OWNER") and not mp.text.contains("NOTHING TO TAKE") and not mp.text.contains("BO 1") and not mp.text.contains("CY 1"),"mixed: the monitor names only the owner: " + mp.text)
	for i in (20 if t.quick else 100):
		var mr := Day.end_day(s, 0, q - 1, crew, mixed, fq, "mixed-%d" % i, true)
		t.eq(mr.taken.size(), 1, "mixed %d: exactly one loss" % i)
		t.eq(String(mr.taken[0]["player"]), "ann", "mixed %d: ann lost it" % i)
		t.check(ann.owned.has(String(mr.taken[0]["node"])), "mixed %d: it was one of ann's own" % i)
		for p: String in ["bo", "cy"]:
			t.check((mr.wallets[p] as Upgrades.UpgradeState).owned.is_empty(), "mixed %d: %s still owns nothing" % [i, p])
		t.eq((mr.wallets["ann"] as Upgrades.UpgradeState).owned.size(), 2, "mixed %d: ann has two left" % i)
	t.note("nothing owned: no stake, NOTHING TO TAKE, miss counted; mixed crew: only the owner listed and losing")

func test_no_call_edits_what_it_was_given(t: T) -> void:
	var rng := Rng.make_rng("day-pure")
	for i in (100 if t.quick else 500):
		var crew := _crew(rng, rng.int_in(1, 6))
		var w := _wallets(rng, crew, 0.5)
		var s := _random_state(rng, crew.size())
		var fq := rng.int_in(1, 300)
		var fs := _fp_state(s)
		var fw := _fp_wallets(w)
		var crew_before := str(crew)
		var banked := _banked(rng, Day.day_quota(s, fq))
		var earned := _banked(rng, Day.day_quota(s, fq))
		Day.bank_preview(s, banked, earned, crew, w, fq)
		var r := Day.end_day(s, banked, earned, crew, w, fq, "pure-%d" % i, rng.chance(0.3))
		t.eq(_fp_state(s), fs, "case %d: the day state was edited" % i)
		t.eq(_fp_wallets(w), fw, "case %d: the wallets were edited" % i)
		t.eq(str(crew), crew_before, "case %d: the crew list was edited" % i)
		for p in crew:
			t.check(r.wallets[p] != w[p], "case %d: %s's wallet is a new object" % [i, p])

## A plain, separate model of the bed count, replayed from the log of accepted events.
func _expected_lights_out(crew_n: int, events: Array) -> float:
	var inside := {}
	var over_since := -1.0
	var all_since := -1.0
	var n := crew_n
	for e: Array in events:
		var kind: String = e[0]
		var who: String = e[1]
		var at: float = e[2]
		if kind == "in":
			inside[who] = true
		elif kind == "out":
			inside.erase(who)
		else:
			inside.erase(who)
			n -= 1
		var c := inside.size()
		# The count starts the first time more than half are in and is never stopped.
		if c * 2 > n and over_since < 0.0:
			over_since = at
		if c == n:
			if all_since < 0.0:
				all_since = at
		else:
			all_since = -1.0
	var out := INF
	if all_since >= 0.0:
		out = all_since
	if over_since >= 0.0:
		out = minf(out, over_since + 20.0)
	return out

func test_lights_out_20_seconds_after_more_than_half_never_before_at_once_when_all_in(t: T) -> void:
	t.eq(Day.LIGHTS_OUT_DELAY, 20.0, "the owner's twenty seconds")
	# Four players: the third in at 10 starts the count; lights out at exactly 30.
	var crew: Array[String] = ["ann", "bo", "cy", "di"]
	var b := Day.BedState.make(crew)
	b = Day.climb_in(b, "ann", 1.0)
	b = Day.climb_in(b, "bo", 5.0)
	t.eq(Day.lights_out_at(b), INF, "half in is not more than half: no count")
	b = Day.climb_in(b, "cy", 10.0)
	t.eq(Day.lights_out_at(b), 30.0, "three of four at 10 s: lights out at 30 s")
	t.check(not Day.is_lights_out(b, 29.999), "not before 30 s")
	t.check(Day.is_lights_out(b, 30.0), "out at 30 s")
	t.eq(Day.assisted(b), ["di"] as Array[String], "di is assisted to bed")
	t.eq(Day.count_text(b), "IN BED 3 OF 4", "the count over the cell doors")
	t.check(Day.climb_out(b, "cy", 31.0) == b, "nobody gets out after lights out")
	# The count cannot be stopped: climbing out (even back to half) keeps lights out at start + 20 s.
	var c := Day.climb_out(b, "bo", 20.0)
	t.eq(Day.lights_out_at(c), 30.0, "back to half at 20 s: the count runs on, lights out at 30 s")
	c = Day.climb_out(c, "cy", 21.0)
	t.eq(Day.lights_out_at(c), 30.0, "even with one in bed: lights out at 30 s")
	c = Day.climb_in(c, "bo", 25.0)
	t.eq(Day.lights_out_at(c), 30.0, "climbing back in does not restart it: still 30 s")
	t.check(Day.is_lights_out(c, 30.0) and not Day.is_lights_out(c, 29.999), "out at exactly start + 20 s")
	t.eq(Day.assisted(c), ["cy", "di"] as Array[String], "cy and di are assisted to bed")
	# Everyone in earlier means lights out at that moment.
	c = Day.climb_in(c, "cy", 26.0)
	c = Day.climb_in(c, "di", 27.0)
	t.eq(Day.lights_out_at(c), 27.0, "everyone in at 27 s: lights out at once")
	t.check(Day.assisted(c).is_empty(), "nobody assisted")
	# Leaving the game does not cancel it either.
	var lv := Day.climb_in(Day.climb_in(Day.climb_in(Day.BedState.make(crew), "ann", 1.0), "bo", 2.0), "cy", 10.0)
	lv = Day.leave(lv, "cy", 12.0)
	t.eq(Day.lights_out_at(lv), 30.0, "cy quits at 12 s: the count started at 10 s still ends at 30 s")
	lv = Day.leave(lv, "ann", 14.0)
	t.eq(Day.lights_out_at(lv), 30.0, "ann quits too: still 30 s")
	t.eq(Day.lights_out_at(Day.leave(lv, "di", 15.0)), 15.0, "bo is the whole crew and is in: lights out when di quits")
	# Never before more than half were in: a count that never went over half does not run.
	var half := Day.climb_out(Day.climb_in(Day.climb_in(Day.BedState.make(crew), "ann", 1.0), "bo", 2.0), "bo", 5.0)
	t.eq(Day.lights_out_at(half), INF, "two of four is not more than half: no count, climbing out changes nothing")
	# Small crews: more than half is everyone.
	var one := Day.climb_in(Day.BedState.make(["ann"] as Array[String]), "ann", 3.0)
	t.eq(Day.lights_out_at(one), 3.0, "alone: lights out as you get in")
	var two := Day.climb_in(Day.BedState.make(["ann", "bo"] as Array[String]), "ann", 3.0)
	t.eq(Day.lights_out_at(two), INF, "one of two is half: no count")
	# A player who quits the game leaves the count.
	var q := Day.climb_in(Day.climb_in(Day.BedState.make(crew), "ann", 1.0), "bo", 2.0)
	q = Day.leave(q, "di", 4.0)
	t.eq(Day.lights_out_at(q), 24.0, "di quits at 4 s: two of three, lights out at 24 s")
	t.eq(Day.count_text(q), "IN BED 2 OF 3", "the count without di")
	t.check(Day.climb_in(q, "zed", 5.0) == q, "a stranger cannot climb in")
	# Random bedtimes against the separate model.
	var rng := Rng.make_rng("day-bed")
	var runs := 200 if t.quick else 1500
	var counted := 0
	var all_in := 0
	for i in runs:
		var crew_n := rng.int_in(1, 8)
		var cr := _crew(rng, crew_n)
		var bed := Day.BedState.make(cr)
		var events: Array = []
		var now := 0.0
		for _k in 30:
			now += rng.next() * 6.0
			var who: String = cr[rng.int_in(0, cr.size() - 1)]
			var roll := rng.next()
			var kind := "in" if roll < 0.65 else ("out" if roll < 0.97 else "leave")
			var was_out := Day.is_lights_out(bed, now)
			var nb: Day.BedState
			if kind == "in":
				nb = Day.climb_in(bed, who, now)
			elif kind == "out":
				nb = Day.climb_out(bed, who, now)
			else:
				nb = Day.leave(bed, who, now)
			if was_out:
				t.check(nb == bed, "run %d: a change after lights out" % i)
			if nb != bed:
				events.append([kind, who, now])
			bed = nb
			var want := _expected_lights_out(crew_n, events)
			var got := Day.lights_out_at(bed)
			if not t.check(got == want, "run %d at %s: lights out %s, the model says %s" % [i, str(now), str(got), str(want)]):
				break
			if got < INF:
				t.check(not Day.is_lights_out(bed, got - 0.001) and Day.is_lights_out(bed, got), "run %d: lights out exactly at %s" % [i, str(got)])
				if bed.in_bed.size() < bed.crew.size():
					t.eq(got - bed.count_from, 20.0, "run %d: 20 s after the count first went over half" % i)
		if Day.lights_out_at(bed) < INF:
			if bed.in_bed.size() == bed.crew.size():
				all_in += 1
			else:
				counted += 1
	t.check(counted > 0 and all_in > 0, "not vacuous: %d timed lights-outs, %d with everyone in" % [counted, all_in])
	t.note("%d random bedtimes matched the model (%d by the 20 s count, %d everyone in)" % [runs, counted, all_in])

func test_bunks_are_the_prisons_and_distinct(t: T) -> void:
	var crew: Array[String] = ["di", "ann", "cy", "bo", "ed", "flo", "gus", "hal"]
	var seen := {}
	for p in crew:
		var cell := Day.bunk_of(crew, p)
		t.check(cell != Vector2i(-1, -1), "%s has a bunk" % p)
		seen[cell] = true
	t.eq(seen.size(), 8, "eight players, eight bunks")
	t.eq(Day.bunk_of(crew, "ann"), Day.Prison.bunk_positions()[0], "sorted order: ann is bunk 1")
	t.eq(Day.bunk_of(crew, "zed"), Vector2i(-1, -1), "a stranger has none")
