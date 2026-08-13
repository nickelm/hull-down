class_name Scenario
extends RefCounted

## A mission, as data — 2f and 2g, docs/decisions/0041.
##
## Map seed, force composition per side, how each side deploys, the turn limit, and the waves.
## Everything a battle *is* apart from the rules: the rules stay in `data/rules.json` and the
## scenario file only ever overrides what a mission genuinely owns (its clock, its forces).
##
## Deployment is asymmetric and the defender places first: a force whose `deploy` is
## `"objectives"` is planted around the map's objectives — the flags the generator put on villages
## and bridges (0040) — before any zone-deployed force is placed. Entrenchment is applied here at
## deployment and nowhere else; it is a property of having prepared the ground, and ground cannot
## be prepared mid-battle.
##
## Waves (2g) are whole units created up front with `on_board = false` and an arrival turn — not
## conjured when due. Created up front, because every side's `SideKnowledge` is sized to the unit
## roster and identity is positional (0031): a unit appended mid-match would renumber nothing but
## would exist for side A's knowledge and not side B's depending on when each side last resized.
## `spawn_due` only ever flips the flag and picks the entry tile.

## Where missions live on disk. The menu enumerates this directory; a mission is a file, not a
## registry entry, so dropping a JSON in is the whole act of adding one.
const SCENARIO_DIR := "res://data/scenarios"

var name: String = ""
var map_seed: int = 0
## 0 means the config's `victory.turn_limit`.
var turn_limit: int = 0
var forces: Array[Force] = []


class Wave:
	extends RefCounted
	var turn: int = 2
	## Map edge the wave enters from, as a Grid cardinal.
	var edge: int = Grid.W
	var units: PackedStringArray = PackedStringArray()


class Force:
	extends RefCounted
	var side: int = 1
	## `"zone"` deploys in the numbered deployment zone; `"objectives"` plants the force around
	## the map's objectives — the defender's deployment, and it places first.
	var deploy: StringName = &"zone"
	var zone: int = 1
	var radius_tiles: int = 6
	var entrenched: bool = false
	var units: PackedStringArray = PackedStringArray()
	var waves: Array[Wave] = []


static func load_file(path: String) -> Scenario:
	if not FileAccess.file_exists(path):
		push_error("Scenario: missing file %s" % path)
		return null
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Scenario: %s did not parse as an object" % path)
		return null
	return from_dict(parsed as Dictionary)


## Every mission on disk, as `[{ "name": String, "path": String }]`. Filenames are sorted before
## reading — directory order is whatever the filesystem feels like, and the menu must be stable.
## Files that do not parse as an object are skipped without a fuss: enumeration is not the place
## to shout about a broken file, opening it is.
static func list_available(dir: String = SCENARIO_DIR) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var files: PackedStringArray = DirAccess.get_files_at(dir)
	files.sort()
	for f: String in files:
		if not f.ends_with(".json"):
			continue
		var path: String = dir.path_join(f)
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		var s: Scenario = from_dict(parsed as Dictionary)
		var display: String = s.name if s.name != "" else f.get_basename()
		out.append({"name": display, "path": path})
	return out


static func from_dict(d: Dictionary) -> Scenario:
	var s := Scenario.new()
	s.name = str(d.get("name", ""))
	s.map_seed = int(d.get("map_seed", 0))
	s.turn_limit = int(d.get("turn_limit", 0))

	var listed: Variant = d.get("sides", [])
	if typeof(listed) == TYPE_ARRAY:
		for entry: Variant in listed as Array:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var fd: Dictionary = entry as Dictionary
			var f := Force.new()
			f.side = int(fd.get("side", 1))
			f.deploy = StringName(str(fd.get("deploy", "zone")))
			f.zone = int(fd.get("zone", f.side))
			f.radius_tiles = int(fd.get("radius_tiles", 6))
			f.entrenched = bool(fd.get("entrenched", false))
			f.units = _names(fd.get("units", []))
			var waves: Variant = fd.get("waves", [])
			if typeof(waves) == TYPE_ARRAY:
				for wentry: Variant in waves as Array:
					if typeof(wentry) != TYPE_DICTIONARY:
						continue
					var wd: Dictionary = wentry as Dictionary
					var w := Wave.new()
					w.turn = int(wd.get("turn", 2))
					w.edge = _edge(str(wd.get("edge", "west")))
					w.units = _names(wd.get("units", []))
					f.waves.append(w)
			s.forces.append(f)
	return s


static func _names(v: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if typeof(v) == TYPE_ARRAY:
		for entry: Variant in v as Array:
			out.append(str(entry))
	return out


static func _edge(edge_name: String) -> int:
	match edge_name:
		"north":
			return Grid.N
		"east":
			return Grid.E
		"south":
			return Grid.S
	return Grid.W


## Build the match this scenario describes. Defenders place first, then zone forces, then the
## waves are created off-board. Selection lands on the first unit of the active side, as
## `Deployment.deploy` does.
func build_state(md: MapData, cfg: Config) -> MatchState:
	var side_count: int = maxi(cfg.i("turn.sides", 2), 2)
	for f: Force in forces:
		side_count = maxi(side_count, f.side)
	var m: MatchState = MatchState.create(side_count)

	var taken := PackedInt32Array()

	# Two passes: objectives-deployed forces before zone-deployed ones. The defender must place
	# first — that is the scenario's asymmetry, stated as an ordering rather than a comment.
	for pass_deploy: StringName in [&"objectives", &"zone"]:
		for f: Force in forces:
			if f.deploy != pass_deploy:
				continue
			var tiles: PackedInt32Array
			if f.deploy == &"objectives":
				tiles = _around_objectives(md, cfg, f.units.size(), f.radius_tiles, taken)
			else:
				tiles = Deployment.start_tiles(
					md, cfg, f.zone, f.units.size(), cfg.i("turn.unit_spacing_tiles", 6), taken
				)
			var face_at: int = _facing_focus(md, f)
			for k: int in mini(tiles.size(), f.units.size()):
				var u: UnitState = UnitState.create(md, cfg, tiles[k], f.units[k])
				u.side = f.side
				var dir: int = Grid.dir_between(
					md.tx(tiles[k]), md.ty(tiles[k]), md.tx(face_at), md.ty(face_at)
				)
				u.facing = dir if dir >= 0 else Grid.E
				u.turret = u.facing
				u.entrenched = f.entrenched
				m.add_unit(u)
				taken.append(tiles[k])

	# The waves, created now and delivered later — see the class docstring for why now.
	for f2: Force in forces:
		for w: Wave in f2.waves:
			for type_name: String in w.units:
				var u2: UnitState = UnitState.create(md, cfg, 0, type_name)
				u2.side = f2.side
				u2.on_board = false
				u2.tile = -1
				u2.arrival_turn = maxi(w.turn, 2)
				u2.arrival_edge = w.edge
				m.add_unit(u2)

	var first: PackedInt32Array = m.side_units(m.active_side)
	if not first.is_empty():
		m.selected = first[0]
	return m


## Put every wave of the active side that is due on the board, at its edge. Returns the spawned
## unit indices; the caller refreshes knowledge if any arrived — an arrival can be seen.
func spawn_due(md: MapData, cfg: Config, state: MatchState) -> PackedInt32Array:
	var spawned := PackedInt32Array()
	for k: int in state.units.size():
		var u: UnitState = state.units[k]
		if u.side != state.active_side or u.on_board or not u.alive:
			continue
		if u.arrival_turn > state.turn:
			continue
		var tile: int = _edge_entry(md, state, u.arrival_edge)
		if tile < 0:
			continue   # the whole edge band is blocked this turn; try again next turn
		u.tile = tile
		u.on_board = true
		var dir: int = Grid.dir_between(md.tx(tile), md.ty(tile), md.size / 2, md.size / 2)
		u.facing = dir if dir >= 0 else Grid.E
		u.turret = u.facing
		u.begin_turn(cfg)
		spawned.append(k)
	return spawned


## Tiles around the objectives, round-robin across them so a three-flag defense is a three-post
## defense rather than a crowd on the first flag. Deterministic: per objective, candidates are
## sorted by distance then index, and the first free passable one wins.
##
## Candidates must also be reachable from the objectives over the traversal graph — a square ring
## does not know about rivers, and a passable tile across a bend would strand a defender where the
## generator's connectivity guarantee (which runs zone-to-objective, not ring-to-ring) never looked.
func _around_objectives(
	md: MapData, cfg: Config, count: int, radius: int, taken: PackedInt32Array
) -> PackedInt32Array:
	var out := PackedInt32Array()
	if md.objectives.is_empty():
		return out

	var seen: PackedByteArray = ConnectivityRepair.reachable_from(
		md, md.objectives, TraversalGraph.build(md, cfg)
	)

	# Per-objective sorted candidate lists, built once.
	var rings: Array[PackedInt64Array] = []
	for o: int in md.objectives.size():
		var center: int = md.objectives[o]
		var cx: int = md.tx(center)
		var cy: int = md.ty(center)
		var ring := PackedInt64Array()
		for y: int in range(maxi(cy - radius, 0), mini(cy + radius + 1, md.size)):
			for x: int in range(maxi(cx - radius, 0), mini(cx + radius + 1, md.size)):
				var i: int = y * md.size + x
				if not md.is_passable(i) or seen[i] == 0:
					continue
				var d2: int = (x - cx) * (x - cx) + (y - cy) * (y - cy)
				ring.append((d2 << 21) | i)
		ring.sort()
		rings.append(ring)

	var cursors := PackedInt32Array()
	cursors.resize(rings.size())
	var exhausted: int = 0
	while out.size() < count and exhausted < rings.size():
		exhausted = 0
		for o2: int in rings.size():
			if out.size() >= count:
				break
			var ring2: PackedInt64Array = rings[o2]
			var placed: bool = false
			while cursors[o2] < ring2.size():
				var i2: int = int(ring2[cursors[o2]] & 0x1FFFFF)
				cursors[o2] += 1
				if taken.has(i2) or out.has(i2):
					continue
				out.append(i2)
				placed = true
				break
			if not placed:
				exhausted += 1
	return out


## Where a force should face at deployment: an objective-deployed force faces the first
## zone-deployed enemy's ground (that is where the attack comes from); a zone force faces the map.
func _facing_focus(md: MapData, f: Force) -> int:
	if f.deploy == &"objectives":
		for other: Force in forces:
			if other.side != f.side and other.deploy == &"zone":
				var zone_tiles: PackedInt32Array = md.zone_tiles(other.zone)
				if not zone_tiles.is_empty():
					return zone_tiles[zone_tiles.size() / 2]
	return md.idx(md.size / 2, md.size / 2)


## The first free passable tile in a two-deep band along `edge`, walking from the middle of the
## edge outward — waves arrive as a group near the road in, not strung along the whole border.
func _edge_entry(md: MapData, state: MatchState, edge: int) -> int:
	var size: int = md.size
	for depth: int in [1, 2, 3]:
		for spread: int in size / 2:
			for sign: int in [1, -1]:
				var along: int = size / 2 + spread * sign
				if along < 0 or along >= size:
					continue
				var x: int
				var y: int
				match edge:
					Grid.N:
						x = along
						y = depth
					Grid.S:
						x = along
						y = size - 1 - depth
					Grid.E:
						x = size - 1 - depth
						y = along
					_:
						x = depth
						y = along
				var i: int = y * size + x
				if md.is_passable(i) and state.unit_at(i) < 0:
					return i
	return -1
