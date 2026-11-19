# T30: seeded old crew badges use one distant, otherwise empty piece and the regular search transaction.
extends RefCounted

const T = preload("res://tests/t.gd")
const Run = preload("res://sim/run.gd")
const Findables = preload("res://sim/findables.gd")
const Floor = preload("res://sim/floor.gd")
const Move = preload("res://sim/move.gd")
const Inventory = preload("res://sim/inventory.gd")
const Shop = preload("res://sim/shop.gd")
const InventoryView = preload("res://client/inventory_view.gd")
const SearchView = preload("res://client/search_view.gd")
const Search = preload("res://tests/prop_search.gd")
const Fill = preload("res://tests/prop_findables.gd")

func test_badge_replaces_only_empty_reachable_furniture(t: T) -> void:
	t.eq(Findables.WHAT, ["nothing", "credits", "note", "page", "juice", "badge"], "find-result wire ids only append")
	t.eq(Inventory.ITEMS.find("badge"), 1, "the old inventory badge id is unchanged")
	t.check(not Shop.ITEMS.has("badge"), "a badge cannot be bought")
	for place: StringName in [&"clinic", &"annex"]:
		var found := 0
		for i in 12:
			var depth := 1 if place == &"clinic" else 3
			var f := Fill.floor_of(place, "badge-%d" % i, depth)
			var trait_name := Findables.trait_for(place, true)
			var a := Findables.start_floor(f.plan, f.plan.seed, depth, f.base, trait_name, 3, [], false, 1.0)
			var b := Findables.fill_for(f.plan, f.plan.seed, depth, f.base, trait_name, 3, [], false, 1.0)
			t.eq(a.fill.contents, b.contents, "%s seed %d agrees across both generations" % [place, i])
			t.eq(Findables.sheet_text(a.fill), Findables.sheet_text(f.fill), "the lobby shows the same credit and lore counts")
			var badges := 0
			for piece in a.pieces:
				var row: Dictionary = a.fill.contents[piece.id]
				var previous: Dictionary = f.fill.contents[piece.id]
				if row["what"] != "badge":
					t.eq(row, previous, "the existing find at %d is unchanged" % piece.id)
					continue
				badges += 1
				var label := "%s seed %d piece %d" % [place, i, piece.id]
				t.eq(previous["what"], "nothing", "%s was empty with the flag off" % label)
				t.check(int(row["steps"]) >= Findables.FAR_STEPS, "%s is far by actual floor steps" % label)
				var stand := Search.stand(piece)
				var access := Move.cell_of(f.plan, stand[0])
				t.check(not Floor.find_path(f.plan, f.plan.landing, access).is_empty(), "%s has a route from the lift to its front" % label)
				t.eq(Findables.piece_in_reach(a, stand[0], stand[1]), piece, "%s can be searched from the front" % label)
			t.check(badges <= 1, "%s seed %d contains at most one badge" % [place, i])
			found += badges
		t.check(found >= 10, "%s at certainty has a badge on %d of 12 seeds" % [place, found])

func test_full_bag_leaves_the_badge_for_one_finder(t: T) -> void:
	var ids: Array[String] = ["p0", "p1"]
	var s := Search.find_run("badge-full", ids, 1, true, true)
	s = Run.with_tuning(Run.with_badge_search(Run.with_inventory(s)), {&"badge.chance": 100.0})
	s = Search.open_doors(s)
	var piece := Search.piece_with(s.find, "badge")
	if not t.check(piece != null, "the actual floor has a searchable badge"):
		return
	var stand := Search.stand(piece)
	var full_bag := Inventory.add(Inventory.Bag.empty(), "juice", Inventory.SLOTS, 1).bag
	s.bags[ids[0]] = full_bag
	var before_earnings := [s.day_earned, s.floor_earned, Search.member_found(s, ids[0]), Search.member_found(s, ids[1])]
	var one := func(_s: Run.RunState, k: int) -> Array[Run.PlayerInput]:
		return Search.one(Search.inp(ids[0], stand[0], stand[1], k > 0))
	var rejected := Search.run_for(s, 3.0, one)
	var pending: Run.RunState = rejected[0]
	var refusals := Search.of_type(rejected[1], "searchFull")
	t.eq(refusals.size(), 1, "one full-bag message")
	if not refusals.is_empty():
		t.eq(refusals[0].get("item"), "badge", "the refusal tells the finder what stays inside")
	t.eq(Search.of_type(rejected[1], "searchDone").size(), 0, "no find was announced")
	t.check(not (pending.find as Findables.FindFloor).opened.has(piece.id), "the drawer remains closed and available")
	t.eq(Inventory.bag_of(pending.bags, ids[0]).slots, full_bag.slots, "no slot was replaced")
	t.eq(Run.items_in_world(pending).get("badge", 0), 0, "no badge was duplicated onto the floor")

	pending.bags[ids[0]] = Inventory.Bag.empty()
	var both := func(_s: Run.RunState, k: int) -> Array[Run.PlayerInput]:
		var ins: Array[Run.PlayerInput] = [Search.inp(ids[0], stand[0], stand[1], k > 0), Search.inp(ids[1], stand[0], stand[1], k > 0)]
		return ins
	var claimed := Search.run_for(pending, 3.0, both)
	var taken: Run.RunState = claimed[0]
	var finishes := Search.of_type(claimed[1], "searchDone")
	t.eq(finishes.size(), 1, "two players finish one find between them")
	if not finishes.is_empty():
		var who := str(finishes[0]["playerId"])
		t.eq(finishes[0]["what"], "badge", "the drawer's actual result")
		t.eq(Inventory.bag_of(taken.bags, who).totals().get("badge", 0), 1, "exactly one badge in the finder's bag")
	t.check((taken.find as Findables.FindFloor).opened.has(piece.id), "the crew sees it open after collection")
	t.eq(Run.items_in_world(taken).get("badge", 0), 1, "only one badge in the world")
	t.eq([taken.day_earned, taken.floor_earned, Search.member_found(taken, ids[0]), Search.member_found(taken, ids[1])], before_earnings, "searching for a badge spends and earns no credits")
	var repeat := Search.run_for(taken, 3.0, both)
	t.eq(Search.of_type(repeat[1], "searchDone").size(), 0, "a new hold cannot collect a second badge")

func test_full_badge_refusal_shows_one_message_to_the_searcher(t: T) -> void:
	var inventory_view := InventoryView.new()
	var search_view := SearchView.new()
	var events := [{"type": "searchFull", "playerId": "p0", "item": "badge"}]
	inventory_view.on_events(events, "p1", {}, 0, null)
	t.eq(inventory_view.message_now(0), "", "a different player's pockets show no message")
	inventory_view.on_events(events, "p0", {}, 0, null)
	t.eq(inventory_view.message_now(0), "YOUR HANDS ARE FULL. BADGE IS STILL IN THERE.", "badge refusal uses the ordinary inventory notice")
	search_view.on_events(events, "p0", null, 0)
	t.eq(search_view.result_now(0), "", "the search result does not repeat the inventory notice")
	inventory_view.on_events([{"type": "searchFull", "playerId": "p0"}], "p0", {}, 0, null)
	t.eq(inventory_view.message_now(0), "YOUR HANDS ARE FULL. IT IS STILL IN THERE.", "ordinary search refusal remains the same")
	inventory_view.free()
