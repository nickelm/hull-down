class_name Config
extends RefCounted

## Loads data/*.json and serves every tunable number in the game.
##
## No magic numbers in .gd files. If you are about to type a threshold, a cost, a color, or a
## probability into code, it belongs in JSON and is read through here. Structural constants — grid
## size, the quantum, direction tables — are the exception and live in Grid and MapData.
##
## Config is passed explicitly rather than being a singleton, so tests can inject a tiny one
## (see from_dicts) instead of depending on the shipping values.

const DATA_DIR := "res://data/"

var rules: Dictionary = {}
var terrain_types: Array[Dictionary] = []
var units: Dictionary = {}
var cliff_color: Color = Color(0.37, 0.35, 0.31)

## Dotted paths that were requested but not found, in request order. Empty is the healthy state:
## a non-empty list means code is silently running on a default that nobody tuned. tests/test_config
## asserts this stays empty across the paths the pipeline actually reads.
var missing: PackedStringArray = PackedStringArray()

# Parallel to terrain_types, flattened for the hot paths that index them per tile.
var terrain_spotting: PackedFloat32Array = PackedFloat32Array()
var terrain_blocker_h: PackedFloat32Array = PackedFloat32Array()
var terrain_colors: PackedColorArray = PackedColorArray()
var terrain_names: PackedStringArray = PackedStringArray()

## Movement cost per (class, terrain type), flat: `mclass * type_count() + type`. Negative means
## the class cannot enter that terrain at all. This is the authoritative table.
var class_move_cost: PackedFloat32Array = PackedFloat32Array()
var class_names: PackedStringArray = PackedStringArray()

## The reference class's row of `class_move_cost`, as a plain per-type array.
##
## Not a second source of truth — it is sliced out of the table at load. It exists because most
## callers genuinely mean "the going for the vehicles this game fields", and making every one of
## them write `class_move_cost[MovementClass.REFERENCE * n + t]` would be noise.
var terrain_move_cost: PackedFloat32Array = PackedFloat32Array()

## Concealment per (class, terrain type), flat: `mclass * type_count() + type`. A multiplier on the
## observer's optical range for a unit standing on that ground. The authoritative table, and the
## reason `terrain_spotting` above is a slice rather than a field — docs/decisions/0028.
var class_concealment: PackedFloat32Array = PackedFloat32Array()
var concealment_class_names: PackedStringArray = PackedStringArray()


static func load_default() -> Config:
	var c := Config.new()
	c.rules = _read_json(DATA_DIR + "rules.json")
	c.units = _read_json(DATA_DIR + "units.json")
	# The AI's weights live in their own file (2e-ii) but are mounted under `rules` so they resolve
	# through the same dotted paths, the same `missing` guard, and the same leaf test in
	# tests/test_config. The mount point is asserted free first: a rules.json that grew its own "ai"
	# section would otherwise be silently shadowed, and neither file would say so.
	if c.rules.has("ai"):
		push_error("Config: rules.json contains an 'ai' section — data/ai.json owns that name")
	else:
		c.rules["ai"] = _read_json(DATA_DIR + "ai.json")
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
	if terrain.has("cliff_color"):
		cliff_color = Color.html(str(terrain["cliff_color"]))
	var list: Array = terrain.get("types", []) as Array
	terrain_types.clear()
	terrain_blocker_h.resize(list.size())
	terrain_colors.resize(list.size())
	terrain_names.resize(list.size())
	for i: int in list.size():
		var t: Dictionary = list[i] as Dictionary
		terrain_types.append(t)
		terrain_names[i] = str(t.get("name", "?"))
		terrain_blocker_h[i] = float(t.get("blocker_h", 0.0))
		terrain_colors[i] = Color.html(str(t.get("color", "#ff00ff")))

	_ingest_movement_classes(terrain.get("movement_classes", []) as Array, list.size())
	_ingest_concealment_classes(terrain.get("concealment_classes", []) as Array, list.size())


## Flatten the per-class cost table, and slice the reference class out of it.
##
## A class whose `costs` array is short is padded as impassable rather than as cost 1.0. A missing
## entry means nobody decided, and "nobody decided" must not read as "drive straight through" — a
## silent 1.0 there would put a lorry through a river and no test would notice.
func _ingest_movement_classes(list: Array, type_count_in: int) -> void:
	class_names.resize(list.size())
	class_move_cost.resize(list.size() * type_count_in)
	class_move_cost.fill(-1.0)

	for c: int in list.size():
		var entry: Dictionary = list[c] as Dictionary
		class_names[c] = str(entry.get("name", "?"))
		var costs: Array = entry.get("costs", []) as Array
		for t: int in mini(costs.size(), type_count_in):
			class_move_cost[c * type_count_in + t] = float(costs[t])

	terrain_move_cost.resize(type_count_in)
	var base: int = MovementClass.REFERENCE * type_count_in
	for t2: int in type_count_in:
		terrain_move_cost[t2] = (
			class_move_cost[base + t2] if base + t2 < class_move_cost.size() else -1.0
		)


## Flatten the per-class concealment table, and slice the reference class out of it as
## `terrain_spotting` — docs/decisions/0028.
##
## The padding is the mirror image of `_ingest_movement_classes`', and deliberately so. A missing
## movement cost pads to impassable, because "nobody decided" must not read as "drive straight
## through". A missing concealment pads to 1.0, fully visible, because "nobody decided" must not read
## as "invisible". In both cases the default is the one that fails loudly in play rather than the one
## that quietly hands out an advantage.
func _ingest_concealment_classes(list: Array, type_count_in: int) -> void:
	concealment_class_names.resize(list.size())
	class_concealment.resize(list.size() * type_count_in)
	class_concealment.fill(1.0)

	for c: int in list.size():
		var entry: Dictionary = list[c] as Dictionary
		concealment_class_names[c] = str(entry.get("name", "?"))
		var values: Array = entry.get("values", []) as Array
		for t: int in mini(values.size(), type_count_in):
			class_concealment[c * type_count_in + t] = float(values[t])

	terrain_spotting.resize(type_count_in)
	terrain_spotting.fill(1.0)
	var base: int = MovementClass.REFERENCE * type_count_in
	for t2: int in type_count_in:
		if base + t2 < class_concealment.size():
			terrain_spotting[t2] = class_concealment[base + t2]


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


## Colors are stored as "#rrggbb" strings so a designer can read and edit them in the JSON.
func color(path: String, default_value: Color) -> Color:
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


func class_count() -> int:
	return class_names.size()


## Index of a movement class by name, or -1. Generation and gameplay code should use the
## MovementClass.Kind enum; this exists for tools, tests and units.json.
func class_by_name(n: String) -> int:
	for k: int in class_names.size():
		if class_names[k] == n:
			return k
	return -1


## Cost multiplier for a class entering a terrain type. Negative means it cannot.
func class_cost(mclass: int, terrain_type: int) -> float:
	return class_move_cost[mclass * type_count() + terrain_type]


## Concealment multiplier for a class standing on a terrain type. 1.0 is fully visible; smaller is
## harder to see. Never negative — there is no "impassable" equivalent for being looked at.
func concealment(mclass: int, terrain_type: int) -> float:
	return class_concealment[mclass * type_count() + terrain_type]


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
