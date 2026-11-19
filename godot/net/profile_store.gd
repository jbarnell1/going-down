# Client-only save files. Staging and replacing in one directory preserves the previous save on error.
extends RefCounted

const Save = preload("res://net/save_slip.gd")
const DEFAULT_DIR := "user://saves"

static func remote_path(root: String, url: String) -> String:
	if root.is_empty():
		return ""
	return root.path_join(url.trim_suffix("/").sha256_text() + ".gds")

static func read(path: String) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > Save.MAX_SEALED:
		return ""
	return file.get_as_text()

static func store(path: String, line: String) -> bool:
	if path.is_empty() or line.is_empty() or line.to_utf8_buffer().size() > Save.MAX_SEALED:
		return false
	var abs := ProjectSettings.globalize_path(path)
	if DirAccess.make_dir_recursive_absolute(abs.get_base_dir()) != OK:
		return false
	var pending := "%s.%d.tmp" % [abs, OS.get_process_id()]
	var file := FileAccess.open(pending, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(line)
	file.flush()
	var err := file.get_error()
	file.close()
	if err != OK or DirAccess.rename_absolute(pending, abs) != OK:
		DirAccess.remove_absolute(pending)
		return false
	return true