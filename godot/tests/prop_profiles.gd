# The actual profile adapter honours the stamp, shared identity and cabinet-only storage.
extends RefCounted

const T = preload("res://tests/t.gd")
const Save = preload("res://net/save_slip.gd")
const Profiles = preload("res://net/profiles.gd")
const Run = preload("res://sim/run.gd")
const Shop = preload("res://sim/shop.gd")
const Inventory = preload("res://sim/inventory.gd")

static func _key() -> PackedByteArray:
	var key := PackedByteArray()
	key.resize(32)
	key.fill(11)
	return key

static func _state(ids: Array[String]) -> Run.RunState:
	return Run.with_shop(Run.with_inventory(Run.create_run("profiles", ids)))

static func _cabinet(s: Run.RunState, id: String) -> Array:
	var shop: Shop.ShopState = s.shop_state
	return Shop.cabinet_of(shop.cabinets, id)

func test_profile_restores_legacy_wallet_and_rejects_unsigned_or_altered_lines(t: T) -> void:
	var key := _key()
	var legacy := Save.fresh("1111111111111111")
	legacy.credits = 111
	legacy.days = 4
	var sealed := Save.seal(legacy, key)
	var seam := sealed.find("|111|")
	var tampered := sealed.substr(0, seam + 1) + "911" + sealed.substr(seam + 4)
	var ids: Array[String] = ["old", "unsigned", "edited"]
	var s := _state(ids)
	var profiles := Profiles.new(key)
	profiles.join("old", "Proof", sealed)
	profiles.join("unsigned", "Proof", Save.make(legacy))
	profiles.join("edited", "Proof", tampered)
	for id in ids:
		s = profiles.apply_for(s, id, "Proof")
	t.eq(s.wallets["old"].credits, 111, "old signed wallet survives")
	t.eq(s.wallets["unsigned"].credits, 0, "a solo file cannot enter a stamped room")
	t.eq(s.wallets["edited"].credits, 0, "changing credits breaks the seal")
	t.eq(_cabinet(s, "old"), Shop.empty_cabinet(), "legacy save starts with an empty cabinet")

func test_profile_prevents_copied_identity_and_keeps_the_latest_cabinet_on_rejoin(t: T) -> void:
	var key := _key()
	var cab := Shop.empty_cabinet()
	cab[0] = ["speed", 1]
	var saved := Save.fresh("2222222222222222")
	saved.cabinet = Shop.cabinet_text(cab)
	var sealed := Save.seal(saved, key)
	var p := Profiles.new(key)
	var ids: Array[String] = ["one", "copy", "next"]
	var s := _state(ids)
	p.join("one", "Proof", sealed)
	p.join("copy", "Proof", sealed)
	s = p.apply_for(s, "one", "Proof")
	s = p.apply_for(s, "copy", "Proof")
	t.eq(_cabinet(s, "one")[0], ["speed", 1], "the authentic cabinet is available")
	t.eq(_cabinet(s, "copy")[0], ["", 0], "a simultaneous copy cannot recover a second cabinet")
	s = Run.with_cabinet(s, "one", Shop.empty_cabinet())
	var bags := s.bags.duplicate()
	bags["one"] = Inventory.add(Inventory.bag_of(bags, "one"), "speed", 1, 4).bag
	s.bags = bags
	var updated := Save.open(p.checkpoint(s, "one", "Proof", false), key)
	t.check(updated.ok and not updated.fields.has("inventory"), "the freshly held item never enters the stamp")
	p.leave("one")
	p.join("next", "Proof", sealed)
	s = p.apply_for(s, "next", "Proof")
	t.eq(_cabinet(s, "next")[0], ["", 0], "the room prefers its latest confirmed state over an older copied stamp")