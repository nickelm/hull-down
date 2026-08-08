class_name Config
extends RefCounted

## Loads data/*.json and serves every tunable number in the game.
##
## No magic numbers in .gd files. If you are about to type a threshold, a cost, a colour, or a
## probability into code, it belongs in JSON and is read through here. Structural constants — grid
## size, the quantum, direction tables — are the exception and live in Grid and MapData.
##
## Config is passed explicitly rather than being a singleton, so tests can inject a tiny one
## (see from_dicts) instead of depending on the shipping values.

const DATA_DIR := "res://data/"

var rules: Dictionary = {}
var terrain_types: Array[Dictionary] = []
var units: Dictionary = {}
var cliff_colour: Color = Color(0.37, 0.35, 0.31)

## Dotted paths that were requested but not found, in request order. Empty is the healthy state:
## a non-empty list means code is silently running on a default that nobody tuned. tests/test_config
## asserts this stays empty across the paths the pipeline actually reads.
var missing: PackedStringArray = PackedStringArray()

# Parallel to terrain_types, flattened for the hot paths that index them per tile.
var terrain_move_cost: PackedFloat32Array = PackedFloat32Array()
var terrain_spotting: PackedFloat32Array = PackedFloat32Array()
var terrain_blocker_h: PackedFloat32Array = PackedFloat32Array()
var terrain_colours: PackedColorArray = PackedColorArray()
var terrain_names: PackedStringArray = PackedStringArray()


static func load_default() -> Config:
	var c := Config.new()
	c.rules = _read_json(DATA_DIR + "rules.json")
	c.units = _read_json(DATA_DIR + "units.json")
	var terrain: Dictionary = _read_json(DATA_DIR + "terrain.json")
	c._ingest_terrain(terrain)
	return c


## Build a Config from literals. For tests that need a specific threshold without depending on the
## shipping data files.
static func from_dicts(rules: Dictionary, terrain: Dictionary, units: Dictionary) -> Config:
	var c := Config.new()
	c.rules = rules
	c.units = units
	c._ingest_terrain(terrain)
	return c


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("Config: missing data file %s" % path)
		return {}
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Config: %s did not parse as an object" % path)
		return {}
	return parsed as Dictionary


func _ingest_terrain(terrain: Dictionary) -> void:
	if terrain.has("cliff_colour"):
		cliff_colour = Color.html(str(terrain["cliff_colour"]))
	var list: Array = terrain.get("types", []) as Array
	terrain_types.clear()
	terrain_move_cost.resize(list.size())
	terrain_spotting.resize(list.size())
	terrain_blocker_h.resize(list.size())
	terrain_colours.resize(list.size())
	terrain_names.resize(list.size())
	for i: int in list.size():
		var t: Dictionary = list[i] as Dictionary
		terrain_types.append(t)
		terrain_names[i] = str(t.get("name", "?"))
		terrain_move_cost[i] = float(t.get("move_cost", 1.0))
		terrain_spotting[i] = float(t.get("spotting", 1.0))
		terrain_blocker_h[i] = float(t.get("blocker_h", 0.0))
		terrain_colours[i] = Color.html(str(t.get("colour", "#ff00ff")))


## Resolve a dotted path such as "erosion.hydraulic.capacity_k" against rules. Returns null and
## records the path in `missing` if any segment is absent.
func _resolve(path: String) -> Variant:
	var node: Variant = rules
	for part: String in path.split("."):
		if typeof(node) != TYPE_DICTIONARY:
			missing.append(path)
			return null
		var d: Dictionary = node as Dictionary
		if not d.has(part):
			missing.append(path)
			return null
		node = d[part]
	return node


func f(path: String, default_value: float) -> float:
	var v: Variant = _resolve(path)
	return default_value if v == null else float(v)


func i(path: String, default_value: int) -> int:
	var v: Variant = _resolve(path)
	return default_value if v == null else int(v)


func b(path: String, default_value: bool) -> bool:
	var v: Variant = _resolve(path)
	return default_value if v == null else bool(v)


## Colours are stored as "#rrggbb" strings so a designer can read and edit them in the JSON.
func colour(path: String, default_value: Color) -> Color:
	var v: Variant = _resolve(path)
	if v == null:
		return default_value
	return Color.html(str(v))


func has(path: String) -> bool:
	var before: int = missing.size()
	var v: Variant = _resolve(path)
	if missing.size() > before:
		missing.resize(before)
	return v != null


func type_count() -> int:
	return terrain_names.size()


## Index of a terrain type by name, or -1. Generation code should use the TerrainTyper.Type enum;
## this exists for tools and tests that work from the data file.
func type_by_name(n: String) -> int:
	for k: int in terrain_names.size():
		if terrain_names[k] == n:
			return k
	return -1


func unit(name: String) -> Dictionary:
	var all: Dictionary = units.get("units", {}) as Dictionary
	return all.get(name, {}) as Dictionary


func default_unit_name() -> String:
	return str(units.get("default_unit", "medium"))
