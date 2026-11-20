extends RefCounted
## World's optional slot 28 (after shop at 27) is a dictionary. This codec owns only envelope["reactor"].
## Fields are version, seed, tick, revision, power, awake time, fuse holder/install count,
## cassette and lift bits, fuse and cassette positions, four seat poses, then the connected crew.
## Each seat pose stores xyz, facing and roll, phase index and animation time (RX3 added "zombie_walk": searching).
const PHASES := ["still","zombie_crawl","zombie_run","zombie_walk"]

static func encode(s: Dictionary) -> Array:
	var actors := []
	for pose: Array in s.crew:
		actors.append([pose[0],pose[1],pose[2],pose[3],pose[4],PHASES.find(pose[5]),pose[6]])
	var players := []
	for id: String in s.players:
		players.append([id,s.players[id],s.status[id],s.low[id]])
	var payload := [1,s.seed,s.seq,s.rev,s.power,s.time,s.holder,s.fuseUses,s.cassette,s.lift,s.fuseAt,s.tapeAt,actors,players]
	if s.has("archive"):
		payload.append([s.get("cassetteHolder",""),s.get("extracted",false),s.archive.recovered,s.archive.discovered,s.archive.playing])
		# RN1, the Reactor as a place: slot 15 [native, holdLeft, seats]. Absent on the old floor (14 or 15 slots, as before).
		if s.get("native", false):
			payload.append([true,s.holdLeft,s.seats])
	return payload

static func number(value: Variant, lo: float, hi: float) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and float(value)>=lo and float(value)<=hi

static func integer(value: Variant, lo: float, hi: float) -> bool:
	return number(value,lo,hi) and floor(float(value))==float(value)

static func point(value: Variant) -> bool:
	if not value is Array or value.size()!=3:
		return false
	for coordinate: Variant in value:
		if not number(coordinate,-250,250):
			return false
	return true

static func decode(raw: Variant) -> Variant:
	if not raw is Array or raw.size() not in [14,15,16] or not integer(raw[0],1,1):
		return null
	if not integer(raw[1],-2147483648,2147483647) or not integer(raw[2],0,2147483647) or not integer(raw[3],0,2147483647):
		return null
	if not integer(raw[4],0,2) or not number(raw[5],0,86400) or not (integer(raw[6],0,2147483647) or (raw[6] is String and not raw[6].is_empty() and raw[6].length()<=64)) or not integer(raw[7],0,1):
		return null
	if not raw[8] is bool or not raw[9] is bool or not point(raw[10]) or not point(raw[11]):
		return null
	if not raw[12] is Array or raw[12].size()!=4 or not raw[13] is Array or raw[13].size()>8:
		return null
	var actors := []
	for pose: Variant in raw[12]:
		if not pose is Array or pose.size()!=7 or not point(pose.slice(0,3)):
			return null
		if not number(pose[3],-TAU,TAU) or not number(pose[4],-PI,PI) or not integer(pose[5],0,PHASES.size()-1) or not number(pose[6],0,32):
			return null
		actors.append([pose[0],pose[1],pose[2],pose[3],pose[4],PHASES[int(pose[5])],pose[6]])
	var players := {}
	var states := {}
	var low := {}
	for row: Variant in raw[13]:
		if not row is Array or row.size()!=4 or not row[0] is String:
			return null
		var id: String = row[0]
		if id.is_empty() or id.length()>64 or players.has(id) or not point(row[1]) or row[2] not in ["up","down","out"] or not row[3] is bool:
			return null
		players[id] = row[1]
		states[id] = row[2]
		low[id] = row[3]
	var out := {"seed":int(raw[1]),"seq":int(raw[2]),"rev":int(raw[3]),"power":int(raw[4]),"time":raw[5],
		"holder":raw[6],"fuseUses":int(raw[7]),"cassette":raw[8],"lift":raw[9],"fuseAt":raw[10],
		"tapeAt":raw[11],"crew":actors,"players":players,"status":states,"low":low}
	if raw.size()==16:
		var n: Variant = raw[15]
		if not n is Array or n.size()!=3 or n[0]!=true or not number(n[1],-1,86400) or not n[2] is Array or n[2].size()!=4:
			return null
		for seat: Variant in n[2]:
			if not integer(seat,1,4): return null
		out["native"] = true
		out["holdLeft"] = n[1]
		var seats := []
		for seat: Variant in n[2]: seats.append(int(seat))
		out["seats"] = seats
	if raw.size()>=15:
		var a: Variant = raw[14]
		if not a is Array or a.size()!=5 or not a[0] is String or a[0].length()>64 or not a[1] is bool or not a[2] is bool or not a[3] is bool or not a[4] is Dictionary or a[4].size()>8:
			return null
		if a[3] and not a[2]: return null
		for id: Variant in a[4]:
			if not id is String or not players.has(id) or not integer(a[4][id],1,2147483647): return null
		out["cassetteHolder"] = a[0]
		out["extracted"] = a[1]
		out["archive"] = {"recovered":a[2],"discovered":a[3],"playing":a[4]}
	return out
