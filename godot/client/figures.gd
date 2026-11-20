## Which resident figures the game draws: the new ones (the Meshy figures, v2 files) unless the game was started
## with `figures=old`, as a user argument after `--` (`figures=old` or `--figures=old`) or, in the browser build,
## `?figures=old` in the address. `figures=new` is still accepted and means the new ones. Only the picture changes:
## where the rules put a resident, its reach, its timings and its sounds are the same with either figure. A view
## whose v2 file is missing still draws its old figure.
class_name Figures
extends RefCounted

## Tests: "new" or "old" picks the figures whatever the game was started with; "" follows the arguments.
static var override := ""

## The choice for these user arguments and this address query string ("?a=b&figures=old", or "").
## New unless `figures=old` is among them.
static func new_for(args: PackedStringArray, query: String) -> bool:
	for arg: String in args:
		if arg.trim_prefix("--") == "figures=old":
			return false
	for field: String in query.trim_prefix("?").split("&"):
		if field == "figures=old":
			return false
	return true

## Does this run draw the new figures?
static func use_new() -> bool:
	if override != "":
		return override != "old"
	var query := ""
	if OS.has_feature("web"):
		var search: Variant = JavaScriptBridge.eval("window.location.search", true)
		query = str(search) if search != null else ""
	return new_for(OS.get_cmdline_user_args(), query)
