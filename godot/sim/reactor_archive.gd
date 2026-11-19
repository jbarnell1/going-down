extends RefCounted
## The host keeps one archive per explicitly selected review campaign. These two markers only advance.
const FILM_SECONDS := 51.478639
## The Theora video stream ends at 51.0 s, during the final 0.48 s of silent container audio.
const END_TOLERANCE := .85
var recovered := false
var discovered := false
var tickets := {}
var ticket_seq := 0
var directory: String

func _init(path := "") -> void:
	directory = path
	if directory.is_empty(): return
	discovered = FileAccess.file_exists(directory.path_join("crew23.seen"))
	recovered = discovered or FileAccess.file_exists(directory.path_join("crew23.recovered"))

func persist(marker: String) -> bool:
	if directory.is_empty(): return true
	var path := directory.path_join(marker)
	if FileAccess.file_exists(path): return true
	if DirAccess.make_dir_recursive_absolute(directory)!=OK: return false
	var tmp := path+".tmp"
	var file := FileAccess.open(tmp,FileAccess.WRITE)
	if file==null: return false
	file.store_string("1")
	file.close()
	return DirAccess.rename_absolute(tmp,path)==OK or FileAccess.file_exists(path)

func bank() -> bool:
	if not recovered: recovered = persist("crew23.recovered")
	return recovered

func action(peer: String, op: String, ticket: int, now: float) -> bool:
	if not recovered: return false
	if op=="watch":
		if tickets.has(peer): return false
		ticket_seq += 1
		tickets[peer] = {"ticket":ticket_seq,"at":now}
		return true
	if not tickets.has(peer) or int(tickets[peer].ticket)!=ticket: return false
	if op=="skip":
		tickets.erase(peer)
		return true
	if op!="end" or now-float(tickets[peer].at)<FILM_SECONDS-END_TOLERANCE: return false
	if not discovered and not persist("crew23.seen"): return false
	discovered = true
	tickets.erase(peer)
	return true

func snapshot() -> Dictionary:
	var playing := {}
	for id: String in tickets: playing[id] = tickets[id].ticket
	return {"recovered":recovered,"discovered":discovered,"playing":playing}
