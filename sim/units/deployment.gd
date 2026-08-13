class_name Deployment
extends RefCounted

## Putting units on the board at the start of a match.
##
## Deliberately dumb, and deterministic without touching the RNG: walk each deployment zone in tile
## order and take passable tiles that are far enough apart to be distinguishable. Unit composition
## and anything tactical about where a side sets up are iteration 2 problems — guessing at them now
## would be work thrown away, and a fixed rule is one less thing between a change and seeing it.


static func deploy(md: MapData, cfg: Config, per_side: int = -1) -> MatchState:
	var sides: int = maxi(cfg.i("turn.sides", 2), 1)
	var count: int = per_side if per_side > 0 else maxi(cfg.i("turn.units_per_side", 2), 1)
	var spacing: int = maxi(cfg.i("turn.unit_spacing_tiles", 6), 1)
	var roster: PackedStringArray = _roster(cfg)

	var m: MatchState = MatchState.create(sides)

	for side: int in range(1, sides + 1):
		var starts: PackedInt32Array = start_tiles(md, cfg, side, count, spacing)
		for k: int in starts.size():
			# Both sides field the same list in the same order, which is what makes an outcome
			# attributable to what the player did rather than to what they were handed. Asymmetric
			# forces are a scenario problem, and there are no scenarios yet.
			var u: UnitState = UnitState.create(md, cfg, starts[k], roster[k % roster.size()])
			u.side = side
			u.facing = _facing_across_map(md, starts[k])
			# After the hull, not before. `create` points the turret down the hull's heading, but the
			# heading is chosen here — a turret left at the constructor's default would start off-axis
			# on every unit on the board.
			u.turret = u.facing
			m.add_unit(u)

	var first: PackedInt32Array = m.side_units(m.active_side)
	if not first.is_empty():
		m.selected = first[0]
	return m


## The unit types a side fields, in deployment order, wrapping if there are more units than entries.
##
## Falls back to the default unit rather than to nothing, because a missing or malformed roster should
## deploy a plain force and be visible in play, not deploy an empty side and look like a broken map.
static func _roster(cfg: Config) -> PackedStringArray:
	var out := PackedStringArray()
	var listed: Variant = cfg.rules.get("turn", {}).get("roster", [])
	if typeof(listed) == TYPE_ARRAY:
		for entry: Variant in listed as Array:
			var name: String = str(entry)
			if not cfg.unit(name).is_empty():
				out.append(name)
	if out.is_empty():
		out.append(cfg.default_unit_name())
	return out


## Up to `count` passable tiles in a deployment zone, each at least `spacing` tiles from the ones
## already chosen, none of them in `taken` — the tiles a scenario's earlier-placing force already
## stands on (2f).
##
## Falls back three times: by relaxing the spacing, then by taking any passable tile **the zone
## can reach**, then — only for a zone that is itself unusable — any passable tile at all. A zone
## can be small, split across components, or mostly impassable, and a match that fails to deploy
## is worse than one whose units start closer together than intended. The reachability clause is
## what keeps the overflow out of a walled-off pocket or across a river the generator never
## promised was crossable from here; the traversal graph is only built when overflow actually
## happens, which on a healthy map is never.
static func start_tiles(
	md: MapData, cfg: Config, zone: int, count: int, spacing: int,
	taken: PackedInt32Array = PackedInt32Array()
) -> PackedInt32Array:
	var out := PackedInt32Array()
	var zone_tiles: PackedInt32Array = md.zone_tiles(zone)

	var gap: int = spacing
	while gap >= 0 and out.size() < count:
		for k: int in zone_tiles.size():
			if out.size() >= count:
				break
			var t: int = zone_tiles[k]
			if not md.is_passable(t) or out.has(t) or taken.has(t):
				continue
			if _too_close(md, out, t, gap):
				continue
			out.append(t)
		gap -= 2

	if out.size() < count and not zone_tiles.is_empty():
		var seen: PackedByteArray = ConnectivityRepair.reachable_from(
			md, zone_tiles, TraversalGraph.build(md, cfg)
		)
		for i: int in md.n:
			if out.size() >= count:
				break
			if seen[i] == 0 or not md.is_passable(i) or out.has(i) or taken.has(i):
				continue
			out.append(i)

	for i2: int in md.n:
		if out.size() >= count:
			break
		if md.is_passable(i2) and not out.has(i2) and not taken.has(i2):
			out.append(i2)

	return out


static func _too_close(md: MapData, chosen: PackedInt32Array, tile: int, gap: int) -> bool:
	var x: int = md.tx(tile)
	var y: int = md.ty(tile)
	for k: int in chosen.size():
		var dx: int = absi(md.tx(chosen[k]) - x)
		var dy: int = absi(md.ty(chosen[k]) - y)
		if maxi(dx, dy) < gap:
			return true
	return false


## Point at the middle of the map, so the first thing the visibility overlay shows is the ground the
## unit would actually be fighting across.
static func _facing_across_map(md: MapData, tile: int) -> int:
	var f: int = Grid.dir_between(md.tx(tile), md.ty(tile), md.size / 2, md.size / 2)
	return f if f >= 0 else Grid.E
